import Foundation
import Testing
@testable import Lattice
@testable import LatticeServerKit

/// Pure API/wire checks. These values do not create native source authority or
/// qualify a v3 database, transport, migration, or cross-namespace application.
@Suite struct ReceiptCoverageAuthorizationTests {
    private typealias Fact = Lattice.RecoverySourceExpectation.ReceiptCoverage
    private let sourceID = UUID(uuidString: "A1000000-0000-4000-8000-000000000001")!
    private let epoch = UUID(uuidString: "A1000000-0000-4000-8000-000000000002")!
    private let cohortID = UUID(uuidString: "AB100000-0000-4000-8000-000000000003")!
    private let user = UUID(uuidString: "A1000000-0000-4000-8000-000000000004")!
    private let hash = String(repeating: "a", count: 64)
    private var namespaces: [SyncRecoveryNamespace] { [
        .init(namespaceID: "local", coverageID: "local-v1", revision: 1),
        .init(namespaceID: "a", coverageID: "a-v1", revision: 2),
        .init(namespaceID: "b", coverageID: "b-v1", revision: 3)
    ] }
    private func cohort(_ members: [SyncRecoveryNamespace]? = nil) throws -> SyncRecoveryReceiptCohort {
        try .init(id: cohortID, revision: 7, namespaces: members ?? [namespaces[2], namespaces[1]])
    }
    private func mount(_ coverage: SyncRecoveryReceiptCoveragePolicy = .singleNamespaceV2) throws -> SyncRecoveryMountConfiguration {
        let profile: SyncRecoveryReadyProfile
        switch coverage { case .singleNamespaceV2: profile = .boundedV1; case .registeredProducerV3: profile = .bounded48MiBV1 }
        return try .init(authority: "coverage-service", sourceID: sourceID, epoch: epoch, localNamespace: "local",
            namespaces: namespaces, receiptNamespace: "a", models: ["CoverageRow"], durability: .walFull,
            maximumAuthorizationMilliseconds: 60_000, readyProfile: profile, receiptCoverage: coverage)
    }
    private func fact() throws -> Fact { try .init(cohortID: cohortID, cohortRevision: 7, namespaces: ["b", "a"]) }
    private func source(_ coverage: Fact? = nil) -> SyncRecoverySourceDescriptor {
        .init(authority: "coverage-service", sourceID: sourceID, epoch: epoch, scopeDigest: hash, schemaDigest: hash,
              receiptNamespace: "a", coverageID: "a-v1", coverageRevision: 2, descriptorDigest: hash, receiptCoverage: coverage)
    }
    private func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
    private func turn(_ coverage: Fact? = nil, declaredPeer: SyncRecoveryPeerIdentity? = nil) throws -> RecoveryRelayAuthorizationTurn {
        let peer = declaredPeer ?? SyncRecoveryPeerIdentity(replicaID: "declared-peer", receiverIncarnation: sourceID, channelIncarnation: epoch)
        let incoming = SyncRecoveryIncomingScope(models: [.init(table: "CoverageRow", incomingOperations: [.insert, .update])],
            relations: [], scopedLinkTables: [], catalogDigest: hash)
        let descriptor = source(coverage)
        let context = SyncRecoveryAuthorizationContext(channel: .init(id: "channel-a", userId: user), declaredPeer: peer,
                                                       source: descriptor, incomingScope: incoming)
        let wire: [String: Any] = ["route": ["authenticatedUserID": user.uuidString, "peer": try object(peer)],
                                  "source": try object(descriptor), "incomingScope": try object(incoming)]
        return .init(context: context, wire: try JSONSerialization.data(withJSONObject: wire, options: [.sortedKeys]),
                     maximumAuthorizationMilliseconds: 60_000)
    }
    private func answer(_ turn: RecoveryRelayAuthorizationTurn,
                        coverage: SyncRecoveryReceiptCoverageAuthorization = .namespaceOnly) -> SyncRecoveryAuthorization {
        .init(authenticatedUserID: turn.context.channel.userId, peer: turn.context.declaredPeer,
              source: turn.context.source, incomingScope: turn.context.incomingScope,
              authorizationRevision: "membership-7", validForMilliseconds: 60_000, receiptCoverage: coverage)
    }
    private func registration(_ id: String = "durable-store-registration") -> SyncRecoveryProducerRegistration {
        .init(registrationID: id, incarnation: cohortID)
    }
    @Test func defaultV2PolicyHasExactPriorBytesAndNoCoverageKey() throws {
        let actual = try mount().policy(nil)
        let golden = #"{"authority":"coverage-service","epoch":"a1000000-0000-4000-8000-000000000002","localNamespace":"local","maximumAuthorizationMilliseconds":60000,"models":["CoverageRow"],"namespaces":[{"coverageID":"local-v1","namespaceID":"local","revision":1},{"coverageID":"a-v1","namespaceID":"a","revision":2},{"coverageID":"b-v1","namespaceID":"b","revision":3}],"receiptNamespace":"a","sourceID":"a1000000-0000-4000-8000-000000000001","upload":{"maximumDeletes":256,"tables":[],"unlisted":"allow"},"version":1,"walFull":true}"#
        #expect(actual == Data(golden.utf8))
        let explicit = try mount(.singleNamespaceV2).policy(nil)
        #expect(explicit == actual)
    }
    @Test func v3PolicyUsesExactCohortSubsetWithoutRequiringLocalMembership() throws {
        let recipe = try cohort()
        #expect(recipe.namespaces.map(\.namespaceID) == ["a", "b"])
        let raw = try mount(.registeredProducerV3(recipe)).policy(nil)
        let root = try #require(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        #expect(root["version"] as? Int == 2)
        let coverage = try #require(root["receiptCoverage"] as? [String: Any])
        #expect(Set(coverage.keys) == Set(["kind", "cohortID", "cohortRevision", "operationCodec", "namespaces"]))
        #expect(coverage["kind"] as? String == "registeredProducerV3")
        #expect(coverage["cohortID"] as? String == cohortID.uuidString.lowercased())
        #expect(coverage["cohortRevision"] as? Int == 7)
        #expect(coverage["operationCodec"] as? Int == 1)
        #expect(coverage["namespaces"] as? [String] == ["a", "b"])
        #expect(root["localNamespace"] as? String == "local")
    }
    @Test func v3RequiresExplicitLargeReadyProfileWithoutChangingV2Default() throws {
        let policy = SyncRecoveryReceiptCoveragePolicy.registeredProducerV3(try cohort())
        #expect(throws: (any Swift.Error).self) {
            try SyncRecoveryMountConfiguration(authority: "coverage-service", sourceID: sourceID, epoch: epoch,
                localNamespace: "local", namespaces: namespaces, receiptNamespace: "a", models: ["CoverageRow"],
                durability: .walFull, maximumAuthorizationMilliseconds: 60_000, receiptCoverage: policy)
        }
        let bytes = try mount(policy).policy(nil)
        let value = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(value["readyProfile"] as? String == "bounded48MiBV1")
    }
    @Test func cohortBoundsAndExactEnrolledMetadataRefuse() throws {
        #expect(throws: (any Swift.Error).self) { try SyncRecoveryReceiptCohort(id: cohortID, revision: 0, namespaces: [namespaces[1]]) }
        #expect(throws: (any Swift.Error).self) { try SyncRecoveryReceiptCohort(id: cohortID, revision: 1, namespaces: []) }
        #expect(throws: (any Swift.Error).self) { try cohort([namespaces[1], namespaces[1]]) }
        let oversized = (0..<65).map { SyncRecoveryNamespace(namespaceID: "n\($0)", coverageID: "c", revision: 1) }
        #expect(throws: (any Swift.Error).self) { try cohort(oversized) }
        for member in [SyncRecoveryNamespace(namespaceID: "a", coverageID: "wrong", revision: 2),
                       .init(namespaceID: "a", coverageID: "a-v1", revision: 3),
                       .init(namespaceID: "missing", coverageID: "x", revision: 1), namespaces[2]] {
            let invalid = try cohort([member])
            #expect(throws: (any Swift.Error).self) { try mount(.registeredProducerV3(invalid)) }
        }
    }
    @Test func passiveFactDecoderRejectsWrongVersionBoundsOrderAndUuidSpelling() throws {
        let encoded = try JSONEncoder().encode(fact())
        let valid = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let wrong: [(String, Any)] = [("kind", "registeredProducer"), ("operationCodec", 2), ("cohortRevision", 0),
            ("cohortID", cohortID.uuidString), ("namespaces", ["b", "a"]), ("namespaces", ["a", "a"]),
            ("namespaces", [] as [String]), ("namespaces", [String(repeating: "x", count: 257)])]
        for (key, replacement) in wrong {
            var value = valid; value[key] = replacement
            let bytes = try JSONSerialization.data(withJSONObject: value)
            #expect(throws: (any Swift.Error).self) { try JSONDecoder().decode(Fact.self, from: bytes) }
        }
        let decoded = try JSONDecoder().decode(Fact.self, from: encoded)
        let expected = try fact()
        #expect(decoded == expected)
    }
    @Test func oldDescriptorAndDefaultAuthorizationOmitEveryNewKey() throws {
        let oldTurn = try turn()
        let oldSource = try JSONEncoder().encode(oldTurn.context.source)
        let decoded = try JSONDecoder().decode(SyncRecoverySourceDescriptor.self, from: oldSource)
        #expect(decoded.receiptCoverage == nil)
        let sourceObject = try #require(JSONSerialization.jsonObject(with: oldSource) as? [String: Any])
        #expect(sourceObject["receiptCoverage"] == nil)
        let encoded = try oldTurn.encode(answer(oldTurn))
        let root = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(Set(root.keys) == Set(["context", "authenticatedUserID", "peer", "source", "incomingScope", "authorizationRevision", "validForMilliseconds"]))
        #expect(root["receiptCoverage"] == nil)
        let prior: [String: Any] = ["context": try JSONSerialization.jsonObject(with: oldTurn.wire),
            "authenticatedUserID": user.uuidString, "peer": try object(oldTurn.context.declaredPeer),
            "source": try object(oldTurn.context.source), "incomingScope": try object(oldTurn.context.incomingScope),
            "authorizationRevision": "membership-7", "validForMilliseconds": 60_000]
        let priorBytes = try JSONSerialization.data(withJSONObject: prior, options: [.sortedKeys])
        #expect(encoded == priorBytes)
    }
    @Test func registeredAnswerUsesExplicitProducerAndLowercaseCohortWire() throws {
        let current = try turn(fact())
        let grant = SyncRecoveryReceiptCoverageAuthorization.registeredProducer(registration(), cohortID: cohortID, cohortRevision: 7)
        let encoded = try current.encode(answer(current, coverage: grant))
        let root = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let coverage = try #require(root["receiptCoverage"] as? [String: Any])
        #expect(Set(coverage.keys) == Set(["kind", "registrationID", "incarnation", "cohortID", "cohortRevision"]))
        #expect(coverage["kind"] as? String == "registeredProducer")
        #expect(coverage["registrationID"] as? String == "durable-store-registration")
        #expect(coverage["registrationID"] as? String != current.context.declaredPeer.replicaID)
        #expect(coverage["incarnation"] as? String == cohortID.uuidString.lowercased())
        #expect(coverage["cohortID"] as? String == cohortID.uuidString.lowercased())
        #expect(coverage["cohortRevision"] as? Int == 7)
        #expect(coverage["operationCodec"] == nil)
    }
    @Test func v2AndV3GrantModesCannotBeSubstituted() throws {
        let old = try turn(), current = try turn(fact())
        let grant = SyncRecoveryReceiptCoverageAuthorization.registeredProducer(registration(), cohortID: cohortID, cohortRevision: 7)
        #expect(throws: (any Swift.Error).self) { try old.encode(answer(old, coverage: grant)) }
        #expect(throws: (any Swift.Error).self) { try current.encode(answer(current)) }
        for wrong in [SyncRecoveryReceiptCoverageAuthorization.registeredProducer(registration(), cohortID: sourceID, cohortRevision: 7),
                      .registeredProducer(registration(), cohortID: cohortID, cohortRevision: 8),
                      .registeredProducer(registration(), cohortID: cohortID, cohortRevision: 0)] {
            #expect(throws: (any Swift.Error).self) { try current.encode(answer(current, coverage: wrong)) }
        }
    }
    @Test func registrationBoundsAndChangedActualContextAreRejected() throws {
        let current = try turn(fact())
        for id in ["", String(repeating: "é", count: 129), "lineage\0tail"] {
            let grant = SyncRecoveryReceiptCoverageAuthorization.registeredProducer(registration(id), cohortID: cohortID, cohortRevision: 7)
            #expect(throws: (any Swift.Error).self) { try current.encode(answer(current, coverage: grant)) }
        }
        let changedSource = SyncRecoverySourceDescriptor(authority: "another", sourceID: sourceID, epoch: epoch,
            scopeDigest: hash, schemaDigest: hash, receiptNamespace: "a", coverageID: "a-v1", coverageRevision: 2,
            descriptorDigest: hash, receiptCoverage: try fact())
        let changed = SyncRecoveryAuthorization(authenticatedUserID: user, peer: current.context.declaredPeer,
            source: changedSource, incomingScope: current.context.incomingScope, authorizationRevision: "membership-7",
            validForMilliseconds: 60_000, receiptCoverage: .registeredProducer(registration(), cohortID: cohortID, cohortRevision: 7))
        #expect(throws: (any Swift.Error).self) { try current.encode(changed) }
    }
    @Test func differentDeclaredPeersRequireTheirOwnAnswerButMayExplicitlyShareOneProducer() throws {
        let first = try turn(fact())
        let secondPeer = SyncRecoveryPeerIdentity(replicaID: "other-declared-peer", receiverIncarnation: epoch, channelIncarnation: sourceID)
        let second = try turn(fact(), declaredPeer: secondPeer)
        let explicit = SyncRecoveryReceiptCoverageAuthorization.registeredProducer(registration(), cohortID: cohortID, cohortRevision: 7)
        let firstBytes = try first.encode(answer(first, coverage: explicit))
        let secondBytes = try second.encode(answer(second, coverage: explicit))
        let firstRoot = try #require(JSONSerialization.jsonObject(with: firstBytes) as? [String: Any])
        let secondRoot = try #require(JSONSerialization.jsonObject(with: secondBytes) as? [String: Any])
        let firstCoverage = try #require(firstRoot["receiptCoverage"] as? [String: Any])
        let secondCoverage = try #require(secondRoot["receiptCoverage"] as? [String: Any])
        let firstClaim = try JSONSerialization.data(withJSONObject: firstCoverage, options: [.sortedKeys])
        let secondClaim = try JSONSerialization.data(withJSONObject: secondCoverage, options: [.sortedKeys])
        #expect(firstClaim == secondClaim)
        #expect(throws: (any Swift.Error).self) { try second.encode(answer(first, coverage: explicit)) }
        #expect(throws: (any Swift.Error).self) { try second.encode(answer(second)) }
    }
    @Test func immutableCohortDecodeCannotBypassValidationAndRegistrationCountsUtf8Bytes() throws {
        let valid = try cohort()
        let encoded = try JSONEncoder().encode(valid)
        let decoded = try JSONDecoder().decode(SyncRecoveryReceiptCohort.self, from: encoded)
        #expect(decoded == valid)
        var malformed = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        malformed["revision"] = 0
        let invalid = try JSONSerialization.data(withJSONObject: malformed)
        #expect(throws: (any Swift.Error).self) { try JSONDecoder().decode(SyncRecoveryReceiptCohort.self, from: invalid) }
        let current = try turn(fact())
        let boundary = registration(String(repeating: "é", count: 128))
        #expect(boundary.registrationID.utf8.count == 256)
        let bytes = try current.encode(answer(current, coverage: .registeredProducer(boundary, cohortID: cohortID, cohortRevision: 7)))
        #expect(!bytes.isEmpty)
    }
    @Test func receiverExpectationCarriesPassiveFactAndRejectsMissingSelectedNamespace() throws {
        func expectation(_ coverage: Fact?) throws -> Lattice.RecoverySourceExpectation {
            try .init(endpoint: URL(string: "wss://registered.example/sync")!,
                source: .init(authority: "coverage-service", sourceID: sourceID, epoch: epoch, scopeDigest: hash,
                    schemaDigest: hash, receiptNamespace: "a", coverageID: "a-v1", coverageRevision: 2,
                    descriptorDigest: hash, receiptCoverage: coverage),
                peer: .init(replicaID: "declared-peer", receiverIncarnation: sourceID, channelIncarnation: epoch),
                incomingScope: .init(models: [.init(table: "CoverageRow", incomingOperations: [.insert])],
                    relations: [], scopedLinkTables: [], catalogDigest: hash), channel: "channel-a", validForMilliseconds: 60_000)
        }
        let old = try expectation(nil), current = try expectation(fact())
        #expect(old != current)
        #expect(Set([old, current]).count == 2)
        let root = try #require(JSONSerialization.jsonObject(with: Data(current.nativePolicy.utf8)) as? [String: Any])
        let source = try #require(root["source"] as? [String: Any])
        let coverage = try #require(source["receiptCoverage"] as? [String: Any])
        #expect(coverage["namespaces"] as? [String] == ["a", "b"])
        let missing = try Fact(cohortID: cohortID, cohortRevision: 7, namespaces: ["b"])
        #expect(throws: (any Swift.Error).self) { try expectation(missing) }
    }
}

/// Passive SDK profile and migration-recipe checks only. These do not enroll
/// a source, migrate a file, or establish runtime automatic recovery.
@Suite struct ReadyLifecycleProfilePolicyTests {
    private let sourceID = UUID(uuidString: "A1000000-0000-4000-8000-000000000001")!
    private let epoch = UUID(uuidString: "A1000000-0000-4000-8000-000000000002")!
    private let cohortID = UUID(uuidString: "AB100000-0000-4000-8000-000000000003")!
    private var namespaces: [SyncRecoveryNamespace] { [
        .init(namespaceID: "local", coverageID: "local-v1", revision: 1),
        .init(namespaceID: "a", coverageID: "a-v1", revision: 2),
        .init(namespaceID: "b", coverageID: "b-v1", revision: 3)
    ] }
    private func cohort() throws -> SyncRecoveryReceiptCohort {
        try .init(id: cohortID, revision: 7, namespaces: [namespaces[1], namespaces[2]])
    }
    private func configuration(_ profile: SyncRecoveryReadyProfile,
                               coverage: SyncRecoveryReceiptCoveragePolicy = .singleNamespaceV2) throws -> SyncRecoveryMountConfiguration {
        try .init(authority: "coverage-service", sourceID: sourceID, epoch: epoch, localNamespace: "local",
            namespaces: namespaces, receiptNamespace: "a", models: ["CoverageRow"], durability: .walFull,
            maximumAuthorizationMilliseconds: 60_000, readyProfile: profile, receiptCoverage: coverage)
    }
    private func object(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private func encoded(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    private func mount(_ configuration: SyncRecoveryMountConfiguration) throws -> RecoveryRelayMount {
        try RecoveryRelayMount(configuration: configuration, upload: nil, authorize: { _, _ in
            throw SyncRecoveryConfigurationError.staleAuthorization
        })
    }
    private var channel: SyncChannel { .init(id: "channel-a", userId: sourceID) }

    @Test func oldExplicitLargeProfileKeepsExactBytesWithoutGrace() throws {
        let actual = try configuration(.bounded48MiBV1).policy(nil)
        let golden = #"{"authority":"coverage-service","epoch":"a1000000-0000-4000-8000-000000000002","localNamespace":"local","maximumAuthorizationMilliseconds":60000,"models":["CoverageRow"],"namespaces":[{"coverageID":"local-v1","namespaceID":"local","revision":1},{"coverageID":"a-v1","namespaceID":"a","revision":2},{"coverageID":"b-v1","namespaceID":"b","revision":3}],"readyProfile":"bounded48MiBV1","receiptNamespace":"a","sourceID":"a1000000-0000-4000-8000-000000000001","upload":{"maximumDeletes":256,"tables":[],"unlisted":"allow"},"version":1,"walFull":true}"#
        #expect(actual == Data(golden.utf8))
        #expect(try object(actual)["orphanResumeGraceMilliseconds"] == nil)
        let priorDefault = try object(configuration(.boundedV1).policy(nil))
        #expect(priorDefault["readyProfile"] == nil)
        #expect(priorDefault["orphanResumeGraceMilliseconds"] == nil)
    }
    @Test func explicitLifecycleBoundariesSerializeOnlyTheTwoIntendedPolicyChanges() throws {
        for grace in [Int64(1), 3_600_000] {
            for coverage in [SyncRecoveryReceiptCoveragePolicy.singleNamespaceV2, .registeredProducerV3(try cohort())] {
                let prior = try configuration(.bounded48MiBV1, coverage: coverage).policy(nil)
                let next = try configuration(.bounded48MiBOrphanV1(orphanResumeGraceMilliseconds: grace), coverage: coverage).policy(nil)
                var value = try object(next)
                #expect(value["readyProfile"] as? String == "bounded48MiBOrphanV1")
                #expect(value["orphanResumeGraceMilliseconds"] as? Int64 == grace)
                value["readyProfile"] = "bounded48MiBV1"
                value.removeValue(forKey: "orphanResumeGraceMilliseconds")
                #expect(try encoded(value) == prior)
            }
        }
    }
    @Test func invalidLifecycleGraceRefusesBeforeProducingAMountRecipe() throws {
        for grace in [Int64.min, -1, 0, 3_600_001, Int64.max] {
            for coverage in [SyncRecoveryReceiptCoveragePolicy.singleNamespaceV2, .registeredProducerV3(try cohort())] {
                #expect(throws: SyncRecoveryConfigurationError.self) {
                    try configuration(.bounded48MiBOrphanV1(orphanResumeGraceMilliseconds: grace), coverage: coverage)
                }
            }
        }
        #expect(throws: SyncRecoveryConfigurationError.self) {
            try configuration(.boundedV1, coverage: .registeredProducerV3(cohort()))
        }
    }
    @Test func legacyReceiptMigrationKeepsPriorAndTargetBytesAndNeverEnablesLifecycle() throws {
        let recipe = try cohort()
        let golden = #"{"authority":"coverage-service","epoch":"a1000000-0000-4000-8000-000000000002","localNamespace":"local","maximumAuthorizationMilliseconds":60000,"models":["CoverageRow"],"namespaces":[{"coverageID":"local-v1","namespaceID":"local","revision":1},{"coverageID":"a-v1","namespaceID":"a","revision":2},{"coverageID":"b-v1","namespaceID":"b","revision":3}],"readyProfile":"bounded48MiBV1","receiptCoverage":{"cohortID":"ab100000-0000-4000-8000-000000000003","cohortRevision":7,"kind":"registeredProducerV3","namespaces":["a","b"],"operationCodec":1},"receiptNamespace":"a","sourceID":"a1000000-0000-4000-8000-000000000001","upload":{"maximumDeletes":256,"tables":[],"unlisted":"allow"},"version":2,"walFull":true}"#
        for profile in [SyncRecoveryReadyProfile.boundedV1, .bounded48MiBV1] {
            let old = try configuration(profile)
            let relay = try mount(old)
            let (before, after, next) = try relay.migrationPolicies(channel, cohort: recipe)
            #expect(before == (try old.policy(nil)))
            #expect(after == Data(golden.utf8))
            #expect(after == (try next.policy(nil)))
            #expect(try object(after)["orphanResumeGraceMilliseconds"] == nil)
        }
    }
    @Test func explicitReceiptMigrationPreservesAlreadyEnrolledLifecycleGraceExactly() throws {
        for grace in [Int64(1), 60_000, 3_600_000] {
            let old = try configuration(.bounded48MiBOrphanV1(orphanResumeGraceMilliseconds: grace))
            let relay = try mount(old)
            let (before, after, next) = try relay.migrationPolicies(channel, cohort: cohort())
            #expect(before == (try old.policy(nil)))
            #expect(after == (try next.policy(nil)))
            let oldObject = try object(before)
            var nextObject = try object(after)
            #expect(nextObject["readyProfile"] as? String == "bounded48MiBOrphanV1")
            #expect(nextObject["orphanResumeGraceMilliseconds"] as? Int64 == grace)
            #expect(nextObject["version"] as? Int == 2)
            #expect(nextObject["receiptCoverage"] != nil)
            nextObject.removeValue(forKey: "receiptCoverage")
            nextObject["version"] = 1
            #expect(try encoded(nextObject) == encoded(oldObject))
        }
    }
    @Test func receiptMigrationCannotReconfigureAnExistingV3Source() throws {
        for profile in [SyncRecoveryReadyProfile.bounded48MiBV1, .bounded48MiBOrphanV1(orphanResumeGraceMilliseconds: 60_000)] {
            let existing = try configuration(profile, coverage: .registeredProducerV3(cohort()))
            let relay = try mount(existing)
            #expect(throws: SyncRecoveryConfigurationError.self) {
                try relay.migrationPolicies(channel, cohort: cohort())
            }
        }
    }
}


@Suite("Receipt administration declared open contract")
struct ReceiptAdministrativeOpenTests {
    private let intended = URL(fileURLWithPath: "/source-only-contract/intended.sqlite")
    @Test func declaredVersionIsExtractedWithoutCallingMigrationBodies() throws {
        let value = try RecoveryReceiptAdministrativeOpen.resolve(fileURL: intended) { url in
            .init(fileURL: url, migration: [2: Migration(), 7: Migration()], busyTimeoutMs: 123)
        }
        #expect(value.fileURL == intended); #expect(value.schemaVersion == 7); #expect(value.busyTimeoutMilliseconds == 123)
    }
    @Test func defaultVersionRetainsExistingMountContract() throws {
        let value = try RecoveryReceiptAdministrativeOpen.resolve(fileURL: intended, storeConfiguration: nil)
        #expect(value.schemaVersion == 1); #expect(value.fileURL == intended)
        #expect(value.busyTimeoutMilliseconds == Int32(SyncRelayApplyPolicy.busyTimeoutMs))
    }
    @Test func redirectedAndMemoryRecipesRefuseBeforeNativeIO() {
        #expect(throws: (any Error).self) {
            try RecoveryReceiptAdministrativeOpen.resolve(fileURL: intended) { _ in .init(fileURL: URL(fileURLWithPath: "/source-only-contract/other.sqlite")) }
        }
        #expect(throws: (any Error).self) {
            try RecoveryReceiptAdministrativeOpen.resolve(fileURL: intended) { _ in .init(storage: .memory()) }
        }
    }
    @Test func unrelatedRuntimeSettingsAreNotAdministrativeAuthority() {
        for setting in 0..<4 {
            #expect(throws: (any Error).self) {
                try RecoveryReceiptAdministrativeOpen.resolve(fileURL: intended) { url in
                    var value = Lattice.Configuration(fileURL: url)
                    if setting == 0 { value.isReadOnly = true }
                    if setting == 1 { value.wssEndpoint = URL(string: "wss://example.invalid/forbidden")! }
                    if setting == 2 { value.auditRetention = 1 }
                    if setting == 3 { value.busyTimeoutMs = 30_001 }
                    return value
                }
            }
        }
    }
    @Test func invalidDeclaredVersionIsNotClampedOrMigrated() {
        #expect(throws: (any Error).self) {
            try RecoveryReceiptAdministrativeOpen.resolve(fileURL: intended) { url in .init(fileURL: url, migration: [0: Migration()]) }
        }
        #expect(throws: (any Error).self) {
            try RecoveryReceiptAdministrativeOpen.resolve(fileURL: intended) { url in .init(fileURL: url, migration: [Int(Int32.max) + 1: Migration()]) }
        }
    }
}
