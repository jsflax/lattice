import Foundation
import Lattice
#if canImport(Combine)
import Combine
#endif

// C-only shared declarations. This target is not a published product.
@Model public final class RecoveryProcessSharedRow {
    public var label: String = ""
    public var value: Int = 0
    public init(label: String, value: Int) { self.label = label; self.value = value }
}
@Model public final class RecoveryProcessLocalRow {
    public var value: String = ""
    public init(value: String) { self.value = value }
}

public enum RecoveryProcessFailure: String, Error, Codable, Sendable {
    case configuration, bounds, syntax, correlation, state, deadline, io, publicOpen, publicState, publicWrite, publicClose
}

public struct RecoveryProcessLimits: Codable, Equatable, Sendable {
    public let scopes, records, fieldBytes, journalBytes, channels, bindingFieldBytes, bindingBytes: Int
    public let profiles, stamps, producerFieldBytes, manifestBytes, producerBytes: Int
    public let owners, physicalRoutes, operations, frozenEntries, frozenBytes: Int
    public static let standard = Self(scopes: 4, records: 128, fieldBytes: 128, journalBytes: 2_097_152,
        channels: 4, bindingFieldBytes: 128, bindingBytes: 8192, profiles: 4, stamps: 128,
        producerFieldBytes: 128, manifestBytes: 1_048_576, producerBytes: 8_388_608,
        owners: 8, physicalRoutes: 8, operations: 8, frozenEntries: 128, frozenBytes: 2_097_152)
    public var policy: ContinuousProducerLimits {
        .init(scopes: scopes, records: records, fieldBytes: fieldBytes, journalBytes: journalBytes,
            channels: channels, bindingFieldBytes: bindingFieldBytes, bindingBytes: bindingBytes,
            profiles: profiles, stamps: stamps, producerFieldBytes: producerFieldBytes, manifestBytes: manifestBytes,
            producerBytes: producerBytes, owners: owners, physicalRoutes: physicalRoutes, operations: operations,
            frozenEntries: frozenEntries, frozenBytes: frozenBytes)
    }
}

public struct RecoveryProcessScope: Codable, Equatable, Sendable {
    public struct Model: Codable, Equatable, Sendable {
        public let table: String
        public let incomingOperations: [String]
    }
    public let models: [Model]
    public let relations, scopedLinkTables: [String]
    public let catalogDigest: String
    func validate() throws {
        guard models.count == 1, models[0].table == "RecoveryProcessSharedRow",
              models[0].incomingOperations.count == 3,
              Set(models[0].incomingOperations) == Set(["INSERT", "UPDATE", "DELETE"]),
              relations.isEmpty, scopedLinkTables.isEmpty, RecoveryProcessCodec.digest(catalogDigest)
        else { throw RecoveryProcessFailure.configuration }
    }
    var publicScope: Lattice.RecoverySourceExpectation.Scope {
        .init(models: models.map { .init(table: $0.table, incomingOperations: $0.incomingOperations.compactMap { .init(rawValue: $0) }) },
              relations: [], scopedLinkTables: [], catalogDigest: catalogDigest)
    }
}

public struct RecoveryProcessChannelConfiguration: Codable, Equatable, Sendable {
    public let endpoint, channel, profileDigest: String
    public let authority, sourceID, epoch, scopeDigest, schemaDigest, receiptNamespace: String
    public let coverageID, descriptorDigest: String
    public let coverageRevision: Int64
    public let receiptCoverage: Lattice.RecoverySourceExpectation.ReceiptCoverage
    public let replicaID, receiverIncarnation, channelIncarnation: String
    public let validForMilliseconds: Int64
    public let incomingScope: RecoveryProcessScope
    public let incomingGrantClaim: Data

    public init(expectation: Lattice.RecoverySourceExpectation, incomingGrantClaim: Data,
                profileDigest: String = "receiver-kill-public-v1") throws {
        guard let coverage = expectation.source.receiptCoverage else { throw RecoveryProcessFailure.configuration }
        endpoint = expectation.endpoint.absoluteString; channel = expectation.channel; self.profileDigest = profileDigest
        let s = expectation.source, p = expectation.peer
        authority = s.authority; sourceID = s.sourceID; epoch = s.epoch; scopeDigest = s.scopeDigest; schemaDigest = s.schemaDigest
        receiptNamespace = s.receiptNamespace; coverageID = s.coverageID; coverageRevision = s.coverageRevision
        descriptorDigest = s.descriptorDigest; receiptCoverage = coverage
        replicaID = p.replicaID; receiverIncarnation = p.receiverIncarnation; channelIncarnation = p.channelIncarnation
        validForMilliseconds = expectation.validForMilliseconds
        incomingScope = try RecoveryProcessCodec.decode(RecoveryProcessScope.self, from: incomingGrantClaim)
        self.incomingGrantClaim = incomingGrantClaim
        guard try RecoveryProcessCodec.encode(expectation.incomingScope) == incomingGrantClaim else { throw RecoveryProcessFailure.configuration }
        try validate()
    }
    public func validate() throws {
        guard let url = URL(string: endpoint), url.absoluteString == endpoint, channel == "wss:" + endpoint,
              channel.utf8.count <= 64, profileDigest == "receiver-kill-public-v1",
              [sourceID, epoch, receiverIncarnation, channelIncarnation].allSatisfy(RecoveryProcessCodec.uuid),
              [scopeDigest, schemaDigest, descriptorDigest].allSatisfy(RecoveryProcessCodec.digest),
              [authority, receiptNamespace, coverageID, replicaID].allSatisfy({ RecoveryProcessCodec.text($0, cap: 128) }),
              coverageRevision > 0, validForMilliseconds == 600_000,
              incomingScope.catalogDigest == schemaDigest,
              incomingGrantClaim.count <= 8192,
              try RecoveryProcessCodec.encode(incomingScope) == incomingGrantClaim else { throw RecoveryProcessFailure.configuration }
        try incomingScope.validate()
        _ = try expectation()
    }
    public func expectation() throws -> Lattice.RecoverySourceExpectation {
        guard let url = URL(string: endpoint), let source = UUID(uuidString: sourceID), let epochID = UUID(uuidString: epoch),
              let receiver = UUID(uuidString: receiverIncarnation), let channelID = UUID(uuidString: channelIncarnation)
        else { throw RecoveryProcessFailure.configuration }
        return try .init(endpoint: url, source: .init(authority: authority, sourceID: source, epoch: epochID,
            scopeDigest: scopeDigest, schemaDigest: schemaDigest, receiptNamespace: receiptNamespace,
            coverageID: coverageID, coverageRevision: coverageRevision, descriptorDigest: descriptorDigest, receiptCoverage: receiptCoverage),
            peer: .init(replicaID: replicaID, receiverIncarnation: receiver, channelIncarnation: channelID),
            incomingScope: incomingScope.publicScope, channel: channel, validForMilliseconds: validForMilliseconds)
    }
    var contribution: ContinuousProducerContribution {
        .init(channel: channel, authority: authority, source: sourceID, epoch: epoch, scope: scopeDigest, schema: schemaDigest,
              profileDigest: profileDigest, receiptNamespace: receiptNamespace, models: ["RecoveryProcessSharedRow"], incomingGrantClaim: incomingGrantClaim)
    }
}

public struct RecoveryProcessConfiguration: Codable, Equatable, Sendable {
    public let version: Int
    public let nonce: String
    public let deadlineNanoseconds: UInt64
    public let storeDirectory, authorizationToken, recovery: String
    public let modelNames: [String]
    public let channels: [RecoveryProcessChannelConfiguration]
    public let limits: RecoveryProcessLimits
    public init(nonce: UUID, deadlineNanoseconds: UInt64, storeDirectory: String,
                authorizationToken: String, channels: [RecoveryProcessChannelConfiguration]) throws {
        version = 1; self.nonce = nonce.uuidString.lowercased(); self.deadlineNanoseconds = deadlineNanoseconds
        self.storeDirectory = storeDirectory; self.authorizationToken = authorizationToken; self.channels = channels
        recovery = "automatic"; modelNames = ["RecoveryProcessSharedRow", "RecoveryProcessLocalRow"]; limits = .standard
        try validate()
    }
    public func validate() throws {
        guard version == 1, RecoveryProcessCodec.uuid(nonce), deadlineNanoseconds > 0, deadlineNanoseconds <= UInt64(Int64.max),
              storeDirectory == "receiver-a.lattice-continuous" || storeDirectory == "receiver-b.lattice-continuous",
              RecoveryProcessCodec.text(authorizationToken, cap: 256), recovery == "automatic", limits == .standard,
              modelNames == ["RecoveryProcessSharedRow", "RecoveryProcessLocalRow"], channels.count == 2
        else { throw RecoveryProcessFailure.configuration }
        for channel in channels { try channel.validate() }
        let a = channels[0], b = channels[1]
        guard a.channel != b.channel, a.endpoint != b.endpoint, a.channelIncarnation != b.channelIncarnation,
              a.receiptNamespace != b.receiptNamespace, Set(a.receiptCoverage.namespaces) == Set([a.receiptNamespace, b.receiptNamespace]),
              a.replicaID == b.replicaID, a.receiverIncarnation == b.receiverIncarnation,
              a.authority == b.authority, a.sourceID == b.sourceID, a.epoch == b.epoch,
              a.scopeDigest == b.scopeDigest, a.schemaDigest == b.schemaDigest,
              a.incomingGrantClaim == b.incomingGrantClaim, a.receiptCoverage == b.receiptCoverage
        else { throw RecoveryProcessFailure.configuration }
    }
    public func validateDeadline(now: UInt64) throws {
        guard deadlineNanoseconds > now, deadlineNanoseconds - now <= 120_000_000_000 else { throw RecoveryProcessFailure.deadline }
    }
    public var policy: ContinuousProducerPolicy {
        .init(contributions: channels.map(\.contribution), routes: channels.map { .init(syncID: $0.channel, endpoint: $0.endpoint) },
              limits: limits.policy, recovery: .automatic)
    }
}

public struct RecoveryProcessRow: Codable, Equatable, Sendable {
    public let id: UUID
    public let label: String
    public let value: Int
    public init(id: UUID, label: String, value: Int) { self.id = id; self.label = label; self.value = value }
}
public struct RecoveryProcessOriginal: Codable, Equatable, Sendable {
    public let id, target: UUID
    public let table, operation: String
    public let fields: Data
    public let names: [String?]?
    public init(id: UUID, target: UUID, table: String, operation: String, fields: Data, names: [String?]?) {
        self.id = id; self.target = target; self.table = table; self.operation = operation; self.fields = fields; self.names = names
    }
}
public struct RecoveryProcessImage: Codable, Equatable, Sendable {
    public let rows: [RecoveryProcessRow]
    public let localValues: [String]
    public let originals: [RecoveryProcessOriginal]
    public init(rows: [RecoveryProcessRow], localValues: [String], originals: [RecoveryProcessOriginal]) {
        self.rows = rows; self.localValues = localValues; self.originals = originals
    }
    public func validate() throws {
        guard rows.count <= 16, localValues.count <= 4, originals.count <= 128,
              Set(rows.map(\.id)).count == rows.count, Set(rows.map(\.label)).count == rows.count,
              rows.allSatisfy({ RecoveryProcessCodec.text($0.label, cap: 64) }),
              localValues.allSatisfy({ RecoveryProcessCodec.text($0, cap: 128) }),
              Set(originals.map(\.id)).count == originals.count else { throw RecoveryProcessFailure.bounds }
        for original in originals {
            guard ["RecoveryProcessSharedRow", "RecoveryProcessLocalRow"].contains(original.table),
                  ["INSERT", "UPDATE", "DELETE"].contains(original.operation), original.fields.count <= 4096,
                  (original.names?.count ?? 0) <= 32,
                  original.names?.allSatisfy({ $0.map { RecoveryProcessCodec.text($0, cap: 64) } ?? true }) ?? true
            else { throw RecoveryProcessFailure.bounds }
        }
    }
}

public enum RecoveryProcessOperation: String, Codable, Sendable { case start, settle, offlineEdit, reconnect, postWrite, close }
public enum RecoveryProcessRole: String, Codable, Sendable { case initial, reopened }
public struct RecoveryProcessCommand: Codable, Equatable, Sendable {
    public let version: Int
    public let nonce: String
    public let sequence: Int
    public let operation: RecoveryProcessOperation
    public let role: RecoveryProcessRole?
    public let expected: RecoveryProcessImage?
    public init(nonce: String, sequence: Int, operation: RecoveryProcessOperation,
                role: RecoveryProcessRole? = nil, expected: RecoveryProcessImage? = nil) {
        version = 1; self.nonce = nonce; self.sequence = sequence; self.operation = operation; self.role = role; self.expected = expected
    }
    public func validate() throws {
        guard version == 1, RecoveryProcessCodec.uuid(nonce), (1...16).contains(sequence),
              (operation == .start) == (role != nil), (operation == .settle) == (expected != nil)
        else { throw RecoveryProcessFailure.correlation }
        try expected?.validate()
    }
}
public struct RecoveryProcessReply: Codable, Equatable, Sendable {
    public let version: Int
    public let nonce: String
    public let sequence: Int
    public let operation: RecoveryProcessOperation
    public let failure: RecoveryProcessFailure?
    public let image: RecoveryProcessImage?
    public let createdShared: [RecoveryProcessOriginal]?
    public let committedOpen: Bool?
    public init(command: RecoveryProcessCommand, failure: RecoveryProcessFailure? = nil,
                image: RecoveryProcessImage? = nil, createdShared: [RecoveryProcessOriginal]? = nil, committedOpen: Bool? = nil) {
        version = 1; nonce = command.nonce; sequence = command.sequence; operation = command.operation
        self.failure = failure; self.image = image; self.createdShared = createdShared; self.committedOpen = committedOpen
    }
    public func validate(for command: RecoveryProcessCommand) throws {
        guard version == 1, nonce == command.nonce, sequence == command.sequence, operation == command.operation else { throw RecoveryProcessFailure.correlation }
        if failure != nil {
            guard image == nil, createdShared == nil, committedOpen == nil else { throw RecoveryProcessFailure.correlation }; return
        }
        let carriesImage = operation == .settle || operation == .offlineEdit || operation == .postWrite
        guard carriesImage == (image != nil), (operation == .offlineEdit) == (createdShared != nil),
              (operation == .settle) == (committedOpen != nil), committedOpen == nil || committedOpen == true
        else { throw RecoveryProcessFailure.correlation }
        try image?.validate()
        if operation == .settle {
            guard let expected = command.expected, let image,
                  image.rows == expected.rows.sorted(by: { $0.label < $1.label }), image.localValues == expected.localValues.sorted(),
                  expected.originals.allSatisfy({ original in image.originals.filter { $0.id == original.id } == [original] })
            else { throw RecoveryProcessFailure.correlation }
        }
        if let createdShared {
            guard createdShared.count == 3, Set(createdShared.map(\.id)).count == 3,
                  Set(createdShared.map(\.operation)) == Set(["UPDATE", "DELETE", "INSERT"]),
                  createdShared.allSatisfy({ $0.table == "RecoveryProcessSharedRow" && image!.originals.contains($0) })
            else { throw RecoveryProcessFailure.correlation }
        }
    }
}
public struct RecoveryProcessHello: Codable, Equatable, Sendable {
    public let version: Int
    public let nonce, configurationSHA256, instanceID: String
    public let processID: Int32
    public init(nonce: String, configurationSHA256: String, processID: Int32) {
        version = 1; self.nonce = nonce; self.configurationSHA256 = configurationSHA256
        instanceID = UUID().uuidString.lowercased(); self.processID = processID
    }
    public func validate(nonce: String, hash: String, pid: Int32) throws {
        guard version == 1, self.nonce == nonce, configurationSHA256 == hash,
              RecoveryProcessCodec.uuid(instanceID), processID == pid, pid > 0 else { throw RecoveryProcessFailure.correlation }
    }
}

public struct RecoveryProcessCommandState: Sendable {
    public enum Phase: Sendable { case unopened, connected, settled, offlineClosed, closed }
    public private(set) var phase: Phase = .unopened
    public private(set) var lastSequence = 0
    public private(set) var role: RecoveryProcessRole?
    private var edited = false, reconnected = false, wrote = false
    public init() {}
    public mutating func accept(_ command: RecoveryProcessCommand, nonce: String) throws {
        try command.validate()
        guard command.nonce == nonce, command.sequence == lastSequence + 1 else { throw RecoveryProcessFailure.correlation }
        switch command.operation {
        case .start:
            guard phase == .unopened else { throw RecoveryProcessFailure.state }; role = command.role; phase = .connected
        case .settle:
            guard phase == .connected || phase == .settled, !reconnected else { throw RecoveryProcessFailure.state }; phase = .settled
        case .offlineEdit:
            guard phase == .settled, role == .initial, !edited else { throw RecoveryProcessFailure.state }; edited = true; phase = .offlineClosed
        case .reconnect:
            guard phase == .offlineClosed, role == .initial, !reconnected else { throw RecoveryProcessFailure.state }; reconnected = true; phase = .connected
        case .postWrite:
            guard phase == .settled, role == .reopened, !wrote else { throw RecoveryProcessFailure.state }; wrote = true; phase = .connected
        case .close:
            guard phase == .settled, role == .reopened, wrote else { throw RecoveryProcessFailure.state }; phase = .closed
        }
        lastSequence = command.sequence
    }
}
