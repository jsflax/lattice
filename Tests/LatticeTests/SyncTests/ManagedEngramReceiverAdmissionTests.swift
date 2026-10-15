import Foundation
import Testing
import LatticeSwiftCppBridge
@_spi(Installation) @testable import Lattice

@Model private final class ManagedReceiverUnissuedValue {
    var value: String = ""
    init(_ value: String) { self.value = value }
}

// Genuine file-backed owners and invalid-cap refusal only. No fake managed
// restart, directory response, issuer, profile or callback is supplied. The
// positive parent/child/TLS/restart/retirement fixture remains mandatory.
@Suite("Managed receiver closed admission", .serialized)
struct ManagedEngramReceiverAdmissionTests {
    private enum FixtureFailure: Error { case localdev, backend }
    private func directory() throws -> URL {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("localdev", isDirectory: true).standardizedFileURL
        guard base.path.hasPrefix("/"), base.resolvingSymlinksInPath().path == base.path,
              FileManager.default.fileExists(atPath: base.path) else { throw FixtureFailure.localdev }
        let root = base.appendingPathComponent("lattice-sdk-receiver-fixture-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        guard root.resolvingSymlinksInPath().path == root.path else { throw FixtureFailure.localdev }
        return root
    }
    private func configuration(_ root: URL) -> Lattice.Configuration {
        var config = Lattice.Configuration(storage: .file(root.appendingPathComponent("spoke.sqlite")))
        config.auditRetention = nil
        return config
    }
    private func session() throws -> ManagedEngramDirectorySession {
        // Any accidental transport would fail differently from native refusal.
        try ManagedEngramDirectorySession(endpoint: URL(string: "https://127.0.0.1:1")!, authorizationToken: "unissued-fixture-credential")
    }
    private func refused(_ auth: ManagedEngramDirectorySession, cap: OrdinaryReceiverPreservation) async {
        do {
            let owner = try await auth.startReceiver(for: cap)
            owner.stop(); Issue.record("Unissued archive unexpectedly started a managed receiver")
        } catch ManagedEngramDirectorySession.Failure.refused {
        } catch { Issue.record("Unexpected receiver refusal boundary: \(error)") }
    }

    @Test func actualUnenrolledFileCannotMintArchiveFromDefaultStartupAndRowsSurviveReopen() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = configuration(root)
        do {
            let store = try Lattice(ManagedReceiverUnissuedValue.self, configuration: config)
            defer { store.close() }
            let row = ManagedReceiverUnissuedValue("old local edit"); try store.add(row)
            store.transaction { row.value = "unsynced preserved edit" }
            guard let actual = store.backend.asCxxLatticeRef else { throw FixtureFailure.backend }
            let startup = lattice.swift_managed_history_startup()
            let first = actual.preserveManagedReceiver(startup: startup)
            let copied = actual.preserveManagedReceiver(startup: startup)
            #expect(!first.valid() && !copied.valid())
            #expect(store.objects(ManagedReceiverUnissuedValue.self).first?.value == "unsynced preserved edit")
            #expect(!store.isSyncConnected)
        }
        let reopened = try Lattice(ManagedReceiverUnissuedValue.self, configuration: config)
        defer { reopened.close() }
        #expect(reopened.objects(ManagedReceiverUnissuedValue.self).first?.value == "unsynced preserved edit")
    }

    @Test func invalidArchiveCannotStartHTTPOrWSSAndKeepsActualSiblingFileRows() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try Lattice(ManagedReceiverUnissuedValue.self, configuration: configuration(root))
        defer { store.close() }; try store.add(ManagedReceiverUnissuedValue("kept sibling"))
        let auth = try session(); defer { auth.revoke() }
        let cap = OrdinaryReceiverPreservation(lattice.swift_owned_receiver_preservation())
        await refused(auth, cap: cap); await refused(auth, cap: cap)
        #expect(store.objects(ManagedReceiverUnissuedValue.self).first?.value == "kept sibling")
        #expect(!store.isSyncConnected)
    }

    @Test func revokedActualCredentialSessionCannotStartAnUnissuedArchive() async throws {
        let auth = try session(); auth.revoke()
        let cap = OrdinaryReceiverPreservation(lattice.swift_owned_receiver_preservation())
        do {
            let owner = try await auth.startReceiver(for: cap)
            owner.stop(); Issue.record("Revoked session started a receiver")
        } catch ManagedEngramDirectorySession.Failure.cancelled {
        } catch { Issue.record("Unexpected revoked receiver result: \(error)") }
    }

    @Test func defaultAndCopiedNativeArchiveCannotSupplyCookieGroupOrOwner() throws {
        let auth = try session(); defer { auth.revoke() }
        let archive = lattice.swift_owned_receiver_preservation(), copy = archive
        #expect(!archive.valid() && !copy.valid())
        let request = archive.beginReceiverRequest(credentials: auth.credentials), duplicate = copy.beginReceiverRequest(credentials: auth.credentials)
        #expect(!request.valid() && !duplicate.valid())
        #expect(request.transportCookie() == 0 && duplicate.transportCookie() == 0)
        #expect(String(request.requestedGroup()).isEmpty)
        let owner = request.start(auth.credentials, std.string("unissued-fixture-credential"))
        #expect(!owner.valid() && !owner.settled())
        let result = owner.close(); #expect(!result.cleanupComplete())
        request.cancel(); duplicate.cancel(); owner.stop()
    }

    @Test func unavailableDefaultAndCopiedNativeSelectionCannotChoosePersonalOrGroupHTTP() throws {
        let auth = try session(); defer { auth.revoke() }
        let request = lattice.swift_managed_receiver_request(), copied = request
        // Exercise the genuine production accessor failure, not a fabricated
        // role/status DTO. Real issued allocation-fault coverage remains absent.
        let first = request.directorySelection(), again = copied.directorySelection()
        #expect(!first.isAvailable() && !again.isAvailable())
        #expect(!first.isPersonal() && !first.isGroup())
        #expect(!again.isPersonal() && !again.isGroup())
        #expect(String(first.groupIdentifier()).isEmpty && String(again.groupIdentifier()).isEmpty)
        #expect(!request.valid() && !copied.valid())
        #expect(request.transportCookie() == 0 && copied.transportCookie() == 0)
        let owner = request.start(auth.credentials, std.string("unissued-fixture-credential"))
        #expect(!owner.valid() && !owner.settled())
        owner.stop(); request.cancel(); copied.cancel()
    }

    @Test func actualUnenrolledArchiveSelectionRefusesAndPreservesUnsyncedRowsAfterReopen() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = configuration(root)
        do {
            let store = try Lattice(ManagedReceiverUnissuedValue.self, configuration: config)
            defer { store.close() }
            let row = ManagedReceiverUnissuedValue("kept local edit"); try store.add(row)
            store.transaction { row.value = "still unreceipted after refused selection" }
            guard let actual = store.backend.asCxxLatticeRef else { throw FixtureFailure.backend }
            let archive = actual.preserveManagedReceiver(startup: lattice.swift_managed_history_startup())
            let auth = try session(); defer { auth.revoke() }
            let request = archive.beginReceiverRequest(credentials: auth.credentials), selection = request.directorySelection()
            #expect(!archive.valid() && !request.valid() && !selection.isAvailable())
            #expect(!selection.isPersonal() && !selection.isGroup())
            #expect(request.transportCookie() == 0)
            await refused(auth, cap: OrdinaryReceiverPreservation(archive))
            #expect(!store.isSyncConnected)
            #expect(store.objects(ManagedReceiverUnissuedValue.self).first?.value == "still unreceipted after refused selection")
        }
        let reopened = try Lattice(ManagedReceiverUnissuedValue.self, configuration: config)
        defer { reopened.close() }
        #expect(reopened.objects(ManagedReceiverUnissuedValue.self).first?.value == "still unreceipted after refused selection")
    }
    @Test func defaultCopiedAndCancelledRequestCannotSupplyAnAdmissionNonce() throws {
        let request = lattice.swift_managed_receiver_request(), copied = request
        let first = request.directorySelection()
        #expect(!first.isAvailable() && String(first.admissionNonce()).isEmpty)
        request.cancel()
        let second = copied.directorySelection()
        #expect(!second.isAvailable() && String(second.admissionNonce()).isEmpty)
        #expect(!request.valid() && !copied.valid())
    }

}
