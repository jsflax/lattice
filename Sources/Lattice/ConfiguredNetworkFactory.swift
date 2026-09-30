import Foundation
import LatticeSwiftCppBridge

internal enum ConfiguredNetworkFactoryError: Error {
    case registrationFailed
}

// This inert object may be lazily initialized. The actual native registration
// runs after initialization, outside its condition lock. Native publishes the
// result before releasing a displaced factory, so destructor reentry sees the
// completed state and cannot wait for its own registration to return.
internal final class ConfiguredNetworkFactoryRegistration: @unchecked Sendable {
    private enum Phase { case idle, registering, ready, failed }
    private let condition = NSCondition()
    private var phase = Phase.idle
    private var publicationCount = 0
    private var publishedResult: Bool?

    func publish(_ success: Bool) {
        condition.lock()
        if phase == .registering && publicationCount == 0 {
            publicationCount = 1
            publishedResult = success
            phase = success ? .ready : .failed
        } else {
            publicationCount = 2
            phase = .failed
        }
        condition.broadcast()
        condition.unlock()
    }

    func ensureRegistered() throws {
        condition.lock()
        while phase == .registering { condition.wait() }
        switch phase {
        case .ready:
            condition.unlock()
            return
        case .failed:
            condition.unlock()
            throw ConfiguredNetworkFactoryError.registrationFailed
        case .idle:
            phase = .registering
            condition.unlock()
        case .registering:
            preconditionFailure("Registration wait exited before publication")
        }

        let success = lattice.register_configured_generic_network_factory(
            nil, nil,
            { _ in
                #if os(Linux)
                return NIOWebsocketClient().createCxxClient()
                #else
                return Lattice.WebsocketClient().createCxxClient()
                #endif
            },
            { _, scheduler, receipt in
                guard scheduler != nil, let receipt else { return nil }
                // Both pointers are borrowed only for this synchronous call.
                // Native reserved capacity before entry; copy its exact receipt.
                return makeConfiguredPlatformTransport(
                    receipt.assumingMemoryBound(to: lattice.platform_retirement_receipt.self).pointee)
            },
            nil,
            { context, success in
                guard let context else { return }
                Unmanaged<ConfiguredNetworkFactoryRegistration>.fromOpaque(context)
                    .takeUnretainedValue().publish(success)
            },
            Unmanaged.passUnretained(self).toOpaque())

        condition.lock()
        if publicationCount != 1 || publishedResult != success || !success {
            phase = .failed
        }
        let ready = phase == .ready
        condition.broadcast()
        condition.unlock()
        guard ready else { throw ConfiguredNetworkFactoryError.registrationFailed }
    }
}

private let configuredNetworkFactoryRegistration = ConfiguredNetworkFactoryRegistration()

internal func registerConfiguredNetworkFactoryIfNeeded() throws {
    try configuredNetworkFactoryRegistration.ensureRegistered()
}
