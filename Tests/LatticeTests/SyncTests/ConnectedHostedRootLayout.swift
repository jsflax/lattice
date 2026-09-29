import Foundation

/// Pure spelling/containment check shared by the hosted fixture and its value
/// tests. Workflow and Python wrapper select the workspace from explicit HOME;
/// Foundation's current-user home is a different source on hosted containers.
/// This returns no filesystem custody. The caller must still perform its
/// unchanged actual resolved-path check before reading any fixture files.
enum ConnectedHostedRootLayout {
    static func runRoot(_ raw: String, home: String?) -> URL? {
        guard let home, home.hasPrefix("/"), raw.hasPrefix("/"),
              !home.contains("\0"), !raw.contains("\0"),
              home.utf8.count <= 4096, raw.utf8.count <= 4096 else { return nil }
        // Reject alternate spellings lexically rather than asking Foundation
        // to normalize traversal or consult the current user's home database.
        func componentsAreCanonical(_ value: String) -> Bool {
            let parts = value.split(separator: "/", omittingEmptySubsequences: false)
            return parts.count > 1 && parts.first == "" &&
                parts.dropFirst().allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
        }
        guard componentsAreCanonical(home), componentsAreCanonical(raw),
              raw.hasPrefix(home + "/localdev/") else { return nil }
        return URL(fileURLWithPath: raw, isDirectory: true)
    }
}
