import Foundation
import LatticeServerExportTestSupport
@testable import Lattice
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// Dedicated executable, not a Swift-Testing/XCTest child filter. Its only work
// is real global factory publication and destructor reentry. It never opens a
// database, allocates a platform client, or spawns another process.
private enum ChildFailure: Error { case arguments, installation, observations }
private func marker(_ text: String) {
    FileHandle.standardOutput.write(Data((text + "\n").utf8))
}
private func require(_ value: Bool) throws {
    guard value else { throw ChildFailure.observations }
}

private final class Observations {
    let lock = NSLock()
    var releases = 0
    var successfulReentries = 0
    var failurePublications = 0
    var failureReleases = 0
    var invalidOrder = false
    func change(_ body: (Observations) -> Void) {
        lock.lock(); defer { lock.unlock() }; body(self)
    }
}
private final class DisplacedContext {
    let gate: ConfiguredNetworkFactoryRegistration
    let observations: Observations
    let nonce: String
    init(_ gate: ConfiguredNetworkFactoryRegistration, _ observations: Observations, _ nonce: String) {
        self.gate = gate; self.observations = observations; self.nonce = nonce
    }
    func releasedByActualFactoryDestructor() {
        observations.change { $0.releases += 1 }
        do {
            // A broken publication ordering blocks here and the parent reports
            // its original 10-second timeout, even if later cleanup reaps us.
            try gate.ensureRegistered()
            observations.change { $0.successfulReentries += 1 }
            marker("CONFIGURED_FACTORY_PUBLICATION_REENTRY_READY \(nonce)")
        } catch { observations.change { $0.invalidOrder = true } }
    }
}
private final class FailedContext {
    let gate: ConfiguredNetworkFactoryRegistration
    let observations: Observations
    let nonce: String
    init(_ gate: ConfiguredNetworkFactoryRegistration, _ observations: Observations, _ nonce: String) {
        self.gate = gate; self.observations = observations; self.nonce = nonce
    }
    func publication(_ success: Bool) {
        observations.change {
            $0.failurePublications += 1
            if success || $0.failureReleases != 0 { $0.invalidOrder = true }
        }
    }
    func releasedAfterActualFailure() {
        observations.change {
            $0.failureReleases += 1
            if $0.failurePublications != 1 { $0.invalidOrder = true }
        }
        do {
            try gate.ensureRegistered()
            marker("CONFIGURED_FACTORY_FAILED_PUBLICATION_BEFORE_RELEASE \(nonce)")
        } catch { observations.change { $0.invalidOrder = true } }
    }
}

do {
    let arguments = CommandLine.arguments
    guard arguments.count == 3, arguments[1] == "--configured-factory-publication",
          UUID(uuidString: arguments[2]) != nil else { throw ChildFailure.arguments }
    let nonce = arguments[2]
    marker("CONFIGURED_FACTORY_ENTRY \(nonce)")
    let gate = ConfiguredNetworkFactoryRegistration()
    let observations = Observations()
    var displaced: DisplacedContext? = DisplacedContext(gate, observations, nonce)
    weak var oldOwner = displaced
    let retained = Unmanaged.passRetained(displaced!).toOpaque()
    displaced = nil
    guard lattice.install_configured_factory_reentry_probe(retained, { pointer in
        guard let pointer else { return }
        let context = Unmanaged<DisplacedContext>.fromOpaque(pointer).takeRetainedValue()
        context.releasedByActualFactoryDestructor()
    }) else { throw ChildFailure.installation }
    try require(oldOwner != nil)
    try gate.ensureRegistered()
    try require(oldOwner == nil)
    try gate.ensureRegistered() // No second registration or displaced release.
    try require(observations.releases == 1 && observations.successfulReentries == 1 && !observations.invalidOrder)
    marker("CONFIGURED_FACTORY_OUTER_READY \(nonce)")

    var failed: FailedContext? = FailedContext(gate, observations, nonce)
    weak var failedOwner = failed
    let failedRetain = Unmanaged.passRetained(failed!).toOpaque()
    // Publication borrows the same object; native consumes the owned retain
    // only after the actual failed registration's publication callback returns.
    failed = nil
    let accepted = lattice.register_configured_generic_network_factory(
        failedRetain, nil, nil, nil,
        { pointer in
            guard let pointer else { return }
            let context = Unmanaged<FailedContext>.fromOpaque(pointer).takeRetainedValue()
            context.releasedAfterActualFailure()
        },
        { pointer, success in
            guard let pointer else { return }
            Unmanaged<FailedContext>.fromOpaque(pointer).takeUnretainedValue().publication(success)
        }, failedRetain)
    try require(!accepted && failedOwner == nil)
    try require(observations.failurePublications == 1 && observations.failureReleases == 1 && !observations.invalidOrder)
    try require(observations.releases == 1 && observations.successfulReentries == 1)
    marker("CONFIGURED_FACTORY_EXIT \(nonce)")
} catch {
    FileHandle.standardError.write(Data("CONFIGURED_FACTORY_FAILURE \(error)\n".utf8))
    exit(1)
}
