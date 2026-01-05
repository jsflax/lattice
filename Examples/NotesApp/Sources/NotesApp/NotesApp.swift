import SwiftUI
import Foundation
import Lattice

// MARK: - Theme Colors (matching LatticePython, LatticeJS, LatticeKotlin)

enum LatticeColors {
    static let bgPrimary = Color(hex: 0x1a1a2e)
    static let bgSecondary = Color(hex: 0x16213e)
    static let bgCard = Color(hex: 0x2a2a4e)
    static let bgInput = Color(hex: 0x0f0f1a)
    static let accent = Color(hex: 0x00d9ff)
    static let accentDim = Color(hex: 0x008899)
    static let text = Color(hex: 0xeeeeee)
    static let textMuted = Color(hex: 0x888888)
    static let error = Color(hex: 0xff4444)
    static let success = Color(hex: 0x44ff88)
}

extension Color {
    init(hex: UInt) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }
}

// MARK: - Auth Models

struct AuthRequest: Codable {
    let email: String
    let password: String
}

struct AuthResponse: Codable {
    let token: String?
    let error: String?
    let userId: Int?
}

// MARK: - Main App

@main
struct NotesApp: App {
    private final class Delegate: NSObject, NSApplicationDelegate {
        func applicationDidFinishLaunching(_ notification: Notification) {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    
    @NSApplicationDelegateAdaptor(Delegate.self) private var appDelegate
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

// MARK: - Content View

struct ContentView: View {
    @State private var lattice: Lattice?
    @State private var noteText = ""
    @State private var notes: [Note] = []
    @State private var observerToken: Any?

    // Sync state
    @State private var syncExpanded = false
    @State private var serverUrl = "http://localhost:5050"
    @State private var email = ""
    @State private var password = ""
    @State private var authToken: String?
    @State private var syncStatus = "Not connected"
    @State private var isConnected = false
    @State private var authError: String?
    @State private var isLoading = false

    private var dbPath: String {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = url.appendingPathComponent("NotesApp", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return FileManager.default.temporaryDirectory.appendingPathComponent("notes.sqlite").path
    }

    var body: some View {
        ZStack {
            LatticeColors.bgPrimary.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                // Header
                Text("Lattice Notes")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(LatticeColors.accent)
                    .padding(.bottom, 4)

                // Sync Panel
                SyncPanel(
                    expanded: $syncExpanded,
                    serverUrl: $serverUrl,
                    email: $email,
                    password: $password,
                    isConnected: isConnected,
                    syncStatus: syncStatus,
                    authError: authError,
                    isLoading: isLoading,
                    onLogin: { await authenticate(isLogin: true) },
                    onRegister: { await authenticate(isLogin: false) }
                )

                // Input row
                HStack(spacing: 10) {
                    TextField("Type a note...", text: $noteText)
                        .textFieldStyle(.plain)
                        .padding(12)
                        .background(LatticeColors.bgInput)
                        .foregroundColor(LatticeColors.text)
                        .cornerRadius(8)
                        .onSubmit { addNote() }

                    Button(action: addNote) {
                        Text("Add")
                            .fontWeight(.bold)
                            .foregroundColor(LatticeColors.bgPrimary)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .background(LatticeColors.accent)
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }

                // Notes list
                if notes.isEmpty {
                    Spacer()
                    HStack {
                        Spacer()
                        Text("No notes yet. Add one!")
                            .foregroundColor(LatticeColors.textMuted)
                            .font(.system(size: 14))
                        Spacer()
                    }
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(notes, id: \.id) { note in
                                NoteCard(note: note, onDelete: { deleteNote(note) })
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .frame(minWidth: 400, minHeight: 600)
        .task {
            await initializeLattice()
        }
    }

    @MainActor
    private func initializeLattice() async {
        guard lattice == nil else { return }
        let config = Lattice.Configuration(fileURL: URL(fileURLWithPath: dbPath))
        lattice = try? Lattice(Note.self, configuration: config)
        refreshNotes()
        setupObserver()
    }

    private func setupObserver() {
        guard let lattice else { return }
        let results = lattice.objects(Note.self)
        observerToken = results.observe { _ in
            Task { @MainActor in
                refreshNotes()
            }
        }
    }

    @MainActor
    private func refreshNotes() {
        guard let lattice else { return }
        notes = lattice.objects(Note.self)
            .sortedBy(SortDescriptor(\Note.createdAt, order: .reverse))
            .map { $0 }
    }

    @MainActor
    private func addNote() {
        guard !noteText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        guard let lattice else { return }

        let note = Note(text: noteText, createdAt: Date())
        lattice.add(note)
        noteText = ""
        refreshNotes()
    }

    @MainActor
    private func deleteNote(_ note: Note) {
        guard let lattice else { return }
        lattice.delete(note)
        refreshNotes()
    }

    @MainActor
    private func reconnectWithSync(token: String) {
        // Close existing connection
        lattice = nil

        // Reconnect with sync enabled
        let wsUrl = serverUrl
            .replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://", with: "ws://") + "/sync"

        let config = Lattice.Configuration(
            fileURL: URL(fileURLWithPath: dbPath),
            authorizationToken: token,
            wssEndpoint: URL(string: wsUrl)
        )
        lattice = try? Lattice(Note.self, configuration: config)

        if lattice != nil {
            authToken = token
            isConnected = true
            syncStatus = "Connected"
            refreshNotes()
            setupObserver()
        } else {
            authError = "Failed to connect to sync server"
        }
    }

    @MainActor
    private func authenticate(isLogin: Bool) async {
        isLoading = true
        authError = nil

        do {
            let endpoint = isLogin ? "/login" : "/register"
            guard let url = URL(string: "\(serverUrl)\(endpoint)") else {
                authError = "Invalid server URL"
                isLoading = false
                return
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let body = AuthRequest(email: email, password: password)
            request.httpBody = try JSONEncoder().encode(body)

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                authError = "Invalid response"
                isLoading = false
                return
            }

            let authResponse = try JSONDecoder().decode(AuthResponse.self, from: data)

            if let token = authResponse.token {
                reconnectWithSync(token: token)
            } else if let error = authResponse.error {
                authError = error
            } else if httpResponse.statusCode >= 400 {
                authError = "Authentication failed (HTTP \(httpResponse.statusCode))"
            }
        } catch {
            authError = error.localizedDescription
        }

        isLoading = false
    }
}

// MARK: - Sync Panel

struct SyncPanel: View {
    @Binding var expanded: Bool
    @Binding var serverUrl: String
    @Binding var email: String
    @Binding var password: String
    let isConnected: Bool
    let syncStatus: String
    let authError: String?
    let isLoading: Bool
    let onLogin: () async -> Void
    let onRegister: () async -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header (always visible)
            Button(action: { withAnimation { expanded.toggle() } }) {
                HStack {
                    // Status dot
                    Circle()
                        .fill(isConnected ? LatticeColors.success : LatticeColors.textMuted)
                        .frame(width: 8, height: 8)

                    Text("Server Sync")
                        .foregroundColor(LatticeColors.text)
                        .font(.system(size: 14, weight: .medium))

                    Text("(\(syncStatus))")
                        .foregroundColor(LatticeColors.textMuted)
                        .font(.system(size: 12))

                    Spacer()

                    Text(expanded ? "-" : "+")
                        .foregroundColor(LatticeColors.accent)
                        .font(.system(size: 18, weight: .bold))
                }
                .padding(12)
            }
            .buttonStyle(.plain)

            // Expandable content
            if expanded {
                VStack(spacing: 8) {
                    if !isConnected {
                        // Server URL
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Server URL")
                                .font(.system(size: 12))
                                .foregroundColor(LatticeColors.textMuted)
                            TextField("", text: $serverUrl)
                                .textFieldStyle(.plain)
                                .padding(10)
                                .background(LatticeColors.bgInput)
                                .foregroundColor(LatticeColors.text)
                                .cornerRadius(8)
                        }

                        // Email
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Email")
                                .font(.system(size: 12))
                                .foregroundColor(LatticeColors.textMuted)
                            TextField("", text: $email)
                                .textFieldStyle(.plain)
                                .padding(10)
                                .background(LatticeColors.bgInput)
                                .foregroundColor(LatticeColors.text)
                                .cornerRadius(8)
                                .textContentType(.emailAddress)
                        }

                        // Password
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Password")
                                .font(.system(size: 12))
                                .foregroundColor(LatticeColors.textMuted)
                            SecureField("", text: $password)
                                .textFieldStyle(.plain)
                                .padding(10)
                                .background(LatticeColors.bgInput)
                                .foregroundColor(LatticeColors.text)
                                .cornerRadius(8)
                        }

                        // Error message
                        if let error = authError {
                            Text(error)
                                .foregroundColor(LatticeColors.error)
                                .font(.system(size: 12))
                        }

                        // Buttons
                        HStack(spacing: 8) {
                            Button(action: {
                                Task { await onLogin() }
                            }) {
                                if isLoading {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                } else {
                                    Text("Login")
                                        .fontWeight(.bold)
                                        .foregroundColor(LatticeColors.bgPrimary)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                }
                            }
                            .background(LatticeColors.accent)
                            .cornerRadius(8)
                            .disabled(isLoading || email.isEmpty || password.isEmpty)
                            .buttonStyle(.plain)

                            Button(action: {
                                Task { await onRegister() }
                            }) {
                                Text("Register")
                                    .foregroundColor(LatticeColors.accent)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                            }
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(LatticeColors.accent, lineWidth: 1)
                            )
                            .disabled(isLoading || email.isEmpty || password.isEmpty)
                            .buttonStyle(.plain)
                        }
                    } else {
                        Text("Connected to \(serverUrl)")
                            .foregroundColor(LatticeColors.success)
                            .font(.system(size: 12))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .background(LatticeColors.bgSecondary)
        .cornerRadius(8)
    }
}

// MARK: - Note Card

struct NoteCard: View {
    let note: Note
    let onDelete: () -> Void

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: note.createdAt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(note.text)
                .foregroundColor(LatticeColors.text)
                .font(.system(size: 14))
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Text(formattedDate)
                    .foregroundColor(LatticeColors.textMuted)
                    .font(.system(size: 11, design: .monospaced))

                Spacer()

                Button(action: onDelete) {
                    Text("Delete")
                        .foregroundColor(LatticeColors.error)
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(15)
        .background(LatticeColors.bgCard)
        .cornerRadius(8)
    }
}

#Preview {
    ContentView()
}
