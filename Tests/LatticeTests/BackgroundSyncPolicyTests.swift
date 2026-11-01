import Foundation
import Testing
@testable import Lattice

@Suite("Background sync policy")
struct BackgroundSyncPolicyTests {
    private let identifier = "com.example.app.sync"

    @Test func backgroundSyncIsOptIn() {
        let configuration = Lattice.Configuration(storage: .memory(named: "background-policy-default"))
        #expect(configuration.backgroundSync == nil)
    }

    @Test func configurationCopiesPreservePolicyAndIncludeItInIdentity() {
        let policy = Lattice.Configuration.BackgroundSync.appRefresh(identifier: identifier)
        let original = Lattice.Configuration(
            storage: .memory(named: "background-policy-copy"), backgroundSync: policy)
        var copy = original
        #expect(copy == original)
        #expect(copy.hashValue == original.hashValue)
        #expect(copy.backgroundSync == .appRefresh(identifier: identifier, minimumInterval: 900))

        copy.backgroundSync = nil
        #expect(copy != original)
        #expect(Set([copy, original]).count == 2)
        #expect(original.backgroundSync == policy)

        copy.backgroundSync = .appRefresh(identifier: identifier, minimumInterval: 1800)
        #expect(copy != original)
        #expect(Set([copy, original]).count == 2)

        copy.backgroundSync = policy
        #expect(copy == original)
        #expect(copy.hashValue == original.hashValue)
    }

    @Test func differentTaskIdentifiersRemainDifferentPolicies() {
        let first = Lattice.Configuration.BackgroundSync.appRefresh(identifier: identifier)
        let second = Lattice.Configuration.BackgroundSync.appRefresh(identifier: "com.example.app.other")
        #expect(first != second)
        #expect(Set([first, second]).count == 2)
    }

    @Test func validatesDeclaredIdentifierWithoutInventingDNSRules() throws {
        // Exact membership, not DNS parsing, determines whether the app has
        // declared the identifier. Underscores are not silently rewritten.
        let customIdentifier = "com.example.app.sync_refresh"
        let policy = Lattice.Configuration.BackgroundSync.appRefresh(identifier: customIdentifier)
        try policy.validate(permittedIdentifiers: [customIdentifier])
    }

    @Test func identifierMustAppearExactlyInPermittedIdentifiers() {
        let policy = Lattice.Configuration.BackgroundSync.appRefresh(identifier: identifier)
        #expect(throws: BackgroundSyncPolicyValidationError.identifierNotPermitted(identifier)) {
            try policy.validate(permittedIdentifiers: [])
        }
        #expect(throws: BackgroundSyncPolicyValidationError.identifierNotPermitted(identifier)) {
            try policy.validate(permittedIdentifiers: [identifier.uppercased()])
        }
    }

    @Test(arguments: ["", " ", " com.example.app.sync", "com.example.app.sync ",
                      "com.example.\napp.sync", "com.example.\tapp.sync", "com.example.\0app.sync"])
    func rejectsEmptyWhitespaceAndControlCharacters(identifier: String) {
        let policy = Lattice.Configuration.BackgroundSync.appRefresh(identifier: identifier)
        #expect(throws: BackgroundSyncPolicyValidationError.invalidIdentifier(identifier)) {
            // Even a matching plist entry cannot make malformed policy valid.
            try policy.validate(permittedIdentifiers: [identifier])
        }
    }

    @Test(arguments: [0.0, -1.0, Double.infinity, -Double.infinity, Double.nan])
    func rejectsNonpositiveAndNonfiniteIntervals(interval: Double) {
        let policy = Lattice.Configuration.BackgroundSync.appRefresh(
            identifier: identifier, minimumInterval: interval)
        #expect(throws: BackgroundSyncPolicyValidationError.invalidMinimumInterval) {
            try policy.validate(permittedIdentifiers: [identifier])
        }
    }

    @Test func validShortIntervalIsAHintWithoutAnInventedMinimum() throws {
        let policy = Lattice.Configuration.BackgroundSync.appRefresh(
            identifier: identifier, minimumInterval: 1)
        try policy.validate(permittedIdentifiers: [identifier])
    }
}
