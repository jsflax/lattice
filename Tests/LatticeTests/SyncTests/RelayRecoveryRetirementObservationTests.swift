import Foundation
import Testing
import NIOConcurrencyHelpers
@testable import LatticeServerKit

@Suite("Relay retirement observation")
struct RelayRecoveryRetirementObservationTests {
    @Test func unavailableNativeFenceCannotCreateRetirementHandleOrKeepLifetimeAlive() {
        let peer = SyncRecoveryPeerIdentity(replicaID: "retirement-observer", receiverIncarnation: UUID(), channelIncarnation: UUID())
        var lifetime: RecoveryRelayLifetime? = RecoveryRelayLifetime()
        weak var weakLifetime = lifetime
        let observation = RelayRecoveryConnectionObservation(connectionID: UUID(), peer: peer,
            channel: "wss://127.0.0.1:9443/a", socket: nil, lifetime: lifetime)
        #expect(observation.retirementObservation() == nil)
        lifetime = nil
        #expect(weakLifetime == nil && observation.retirementObservation() == nil)
        let calls = NIOLockedValueBox(0)
        observation.sample { first in
            #expect(!first.available && !first.socketOpen && !first.lifetimeLive)
            // Preserve the original no-lock, reentrant unavailable callback.
            observation.sample { second in
                #expect(!second.available && !second.socketOpen && !second.lifetimeLive)
                calls.withLockedValue { $0 += 1 }
            }
            calls.withLockedValue { $0 += 1 }
        }
        #expect(calls.withLockedValue { $0 } == 2)
    }

    @Test func copiedRetirementFactsRequireEveryActualConnectionWitness() {
        // Pure copied facts exercise the predicates only. They cannot create
        // the private handle, a source, a native fence or disposal authority.
        let retired = RelayRecoveryRetirementSample(available: true, socketOpen: false, lifetimeStopped: true,
            nativeSetupRetired: true, nativeAvailable: true, nativeLive: false, nativeDrained: false)
        #expect(retired.connectionRetired && !retired.operationsDrained)
        let missing: [RelayRecoveryRetirementSample] = [
            .init(available: false, socketOpen: false, lifetimeStopped: true, nativeSetupRetired: true,
                  nativeAvailable: true, nativeLive: false, nativeDrained: false),
            .init(available: true, socketOpen: true, lifetimeStopped: true, nativeSetupRetired: true,
                  nativeAvailable: true, nativeLive: false, nativeDrained: false),
            .init(available: true, socketOpen: false, lifetimeStopped: false, nativeSetupRetired: true,
                  nativeAvailable: true, nativeLive: false, nativeDrained: false),
            .init(available: true, socketOpen: false, lifetimeStopped: true, nativeSetupRetired: false,
                  nativeAvailable: true, nativeLive: false, nativeDrained: false),
            .init(available: true, socketOpen: false, lifetimeStopped: true, nativeSetupRetired: true,
                  nativeAvailable: false, nativeLive: false, nativeDrained: false),
            .init(available: true, socketOpen: false, lifetimeStopped: true, nativeSetupRetired: true,
                  nativeAvailable: true, nativeLive: true, nativeDrained: false)
        ]
        for value in missing { #expect(!value.connectionRetired && !value.operationsDrained) }
    }

    @Test func copiedActualFenceDrainDoesNotInventMissingResourceRetirement() {
        let drained = RelayRecoveryRetirementSample(available: false, socketOpen: false, lifetimeStopped: false,
            nativeSetupRetired: false, nativeAvailable: true, nativeLive: false, nativeDrained: true)
        #expect(!drained.connectionRetired && drained.operationsDrained)
        let unavailable = RelayRecoveryRetirementSample(available: false, socketOpen: false, lifetimeStopped: false,
            nativeSetupRetired: false, nativeAvailable: false, nativeLive: false, nativeDrained: true)
        #expect(!unavailable.connectionRetired && !unavailable.operationsDrained)
        let live = RelayRecoveryRetirementSample(available: true, socketOpen: true, lifetimeStopped: false,
            nativeSetupRetired: false, nativeAvailable: true, nativeLive: true, nativeDrained: true)
        #expect(!live.connectionRetired && !live.operationsDrained)
    }
}
