import Foundation
import Testing
@testable import Lattice
#if canImport(SwiftUI)
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Validates the `@LatticeQuery` rebind-on-identity-change fix (SwiftUI.swift):
/// when the environment `\.lattice` swaps to a different handle, the query
/// re-observes the new handle instead of staying bound to the stale (possibly
/// closed) one.
@Suite("LatticeQuery rebind")
final class RebindTests: BaseTest {

    /// The rebind detects a swap by comparing `cxxLatticeRef.hash_value()`. This
    /// is the load-bearing invariant: closing a handle evicts it from the cache,
    /// so reopening the SAME path produces a fresh `impl_` with a DIFFERENT hash.
    /// If this regressed (e.g. close stopped evicting), rebind would silently
    /// no-op and the stale-handle bug would return.
    @Test func test_ReopenAfterClose_HasNewIdentity() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "\(String.random(length: 32)).sqlite")
        let config = Lattice.Configuration(fileURL: path)

        let a = try Lattice(Person.self, configuration: config)
        let hashA = a.cxxLatticeRef.hash_value()
        a.close()

        let b = try Lattice(Person.self, configuration: config)
        #expect(b.cxxLatticeRef.hash_value() != hashA)

        // Two distinct paths are also distinct identities.
        let other = try testLattice(path: "\(String.random(length: 32)).sqlite", Person.self)
        #expect(other.cxxLatticeRef.hash_value() != b.cxxLatticeRef.hash_value())
    }

#if canImport(SwiftUI) && canImport(AppKit)
    @MainActor
    final class CountProbe: ObservableObject { @Published var count: Int = -1 }

    private struct ProbeView: View {
        @LatticeQuery<Person>(sort: \Person.name, order: .forward) var people
        @ObservedObject var probe: CountProbe
        var body: some View {
            Color.clear
                .onChange(of: people.count, initial: true) { _, newValue in
                    probe.count = newValue
                }
        }
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// End-to-end: host a view whose `@LatticeQuery` is driven by `\.lattice`,
    /// then swap the environment lattice and confirm the query reflects the new
    /// handle's rows (not the first handle's). Hosted SwiftUI in a headless test
    /// is timing-sensitive, so this pumps the run loop generously.
    @MainActor
    @Test(.timeLimit(.minutes(1)))
    func test_SwapLattice_RebindsToNewHandle() throws {
        let a = try testLattice(path: "\(String.random(length: 32)).sqlite", Person.self)
        for name in ["A1", "A2"] { let p = Person(); p.name = name; p.age = 1; a.add(p) }

        let b = try testLattice(path: "\(String.random(length: 32)).sqlite", Person.self)
        for name in ["B1", "B2", "B3"] { let p = Person(); p.name = name; p.age = 1; b.add(p) }

        let probe = CountProbe()
        let host = NSHostingView(rootView: AnyView(ProbeView(probe: probe).environment(\.lattice, a)))
        host.frame = NSRect(x: 0, y: 0, width: 50, height: 50)
        host.layoutSubtreeIfNeeded()
        pump(0.3)
        #expect(probe.count == 2)

        // Swap the environment lattice — rebind must re-observe `b`.
        host.rootView = AnyView(ProbeView(probe: probe).environment(\.lattice, b))
        host.layoutSubtreeIfNeeded()
        pump(0.3)
        #expect(probe.count == 3)
    }
#endif
}
