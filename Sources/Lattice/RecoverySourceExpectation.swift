import Foundation

extension Lattice {
    /// Explicit trusted application registration. These values are expectations,
    /// not a TLS certificate, receipt, READY lease, or installation permission.
    /// Source binding also requires the actual system-verified WSS connection.
    public struct RecoverySourceExpectation: Sendable, Hashable {
        public enum ConfigurationError: Swift.Error { case invalidEndpoint, invalidIdentity, invalidScope, invalidBounds }
        public enum Operation: String, Sendable, Codable, Hashable { case insert = "INSERT", update = "UPDATE", delete = "DELETE" }
        /// Passive immutable fact from the enrolled source. This value does
        /// not authorize a producer or migrate an existing receipt store.
        public struct ReceiptCoverage: Sendable, Codable, Hashable {
            public let kind: String
            public let cohortID: String
            public let cohortRevision: Int64
            public let operationCodec: Int
            public let namespaces: [String]
            public init(cohortID: UUID, cohortRevision: Int64, namespaces: [String]) throws {
                guard cohortRevision > 0, (1...64).contains(namespaces.count),
                      namespaces.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.contains("\0") }),
                      Set(namespaces.map { Data($0.utf8) }).count == namespaces.count
                else { throw ConfigurationError.invalidBounds }
                kind = "registeredProducerV3"; self.cohortID = cohortID.uuidString.lowercased()
                self.cohortRevision = cohortRevision; operationCodec = 1
                self.namespaces = namespaces.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            }
            private enum CodingKeys: String, CodingKey { case kind, cohortID, cohortRevision, operationCodec, namespaces }
            public init(from decoder: any Decoder) throws {
                let value = try decoder.container(keyedBy: CodingKeys.self)
                let kind = try value.decode(String.self, forKey: .kind)
                let id = try value.decode(String.self, forKey: .cohortID)
                let revision = try value.decode(Int64.self, forKey: .cohortRevision)
                let codec = try value.decode(Int.self, forKey: .operationCodec)
                let names = try value.decode([String].self, forKey: .namespaces)
                guard kind == "registeredProducerV3", codec == 1,
                      let uuid = UUID(uuidString: id), uuid.uuidString.lowercased() == id
                else { throw ConfigurationError.invalidIdentity }
                try self.init(cohortID: uuid, cohortRevision: revision, namespaces: names)
                guard self.namespaces.map({ Data($0.utf8) }) == names.map({ Data($0.utf8) })
                else { throw ConfigurationError.invalidIdentity }
            }
            public static func == (lhs: Self, rhs: Self) -> Bool {
                lhs.cohortID == rhs.cohortID && lhs.cohortRevision == rhs.cohortRevision &&
                    lhs.namespaces.map({ Data($0.utf8) }) == rhs.namespaces.map({ Data($0.utf8) })
            }
            public func hash(into hasher: inout Hasher) {
                hasher.combine(cohortID); hasher.combine(cohortRevision); hasher.combine(namespaces.count)
                for namespace in namespaces { hasher.combine(Data(namespace.utf8)) }
            }
        }
        public struct Source: Sendable, Encodable, Hashable {
            public let authority: String, sourceID: String, epoch: String
            public let scopeDigest: String, schemaDigest: String, receiptNamespace: String
            public let coverageID: String, coverageRevision: Int64, descriptorDigest: String
            public let receiptCoverage: ReceiptCoverage?
            public init(authority: String, sourceID: UUID, epoch: UUID, scopeDigest: String, schemaDigest: String,
                        receiptNamespace: String, coverageID: String, coverageRevision: Int64, descriptorDigest: String,
                        receiptCoverage: ReceiptCoverage? = nil) {
                self.authority = authority; self.sourceID = sourceID.uuidString.lowercased(); self.epoch = epoch.uuidString.lowercased()
                self.scopeDigest = scopeDigest; self.schemaDigest = schemaDigest; self.receiptNamespace = receiptNamespace
                self.coverageID = coverageID; self.coverageRevision = coverageRevision; self.descriptorDigest = descriptorDigest
                self.receiptCoverage = receiptCoverage
            }
        }
        public struct Peer: Sendable, Encodable, Hashable {
            public let replicaID: String, receiverIncarnation: String, channelIncarnation: String
            public init(replicaID: String, receiverIncarnation: UUID, channelIncarnation: UUID) {
                self.replicaID = replicaID; self.receiverIncarnation = receiverIncarnation.uuidString.lowercased()
                self.channelIncarnation = channelIncarnation.uuidString.lowercased()
            }
        }
        public struct Model: Sendable, Encodable, Hashable {
            public let table: String, incomingOperations: [Operation]
            public init(table: String, incomingOperations: [Operation]) { self.table = table; self.incomingOperations = incomingOperations }
        }
        public struct Relation: Sendable, Encodable, Hashable {
            public let table: String, lhsModel: String, rhsModel: String, incomingOperations: [Operation]
            public init(table: String, lhsModel: String, rhsModel: String, incomingOperations: [Operation]) {
                self.table = table; self.lhsModel = lhsModel; self.rhsModel = rhsModel; self.incomingOperations = incomingOperations
            }
        }
        public struct Scope: Sendable, Encodable, Hashable {
            public let models: [Model], relations: [Relation], scopedLinkTables: [String], catalogDigest: String
            public init(models: [Model], relations: [Relation], scopedLinkTables: [String], catalogDigest: String) {
                self.models = models; self.relations = relations; self.scopedLinkTables = scopedLinkTables; self.catalogDigest = catalogDigest
            }
        }
        public let endpoint: URL, source: Source, peer: Peer, incomingScope: Scope, channel: String
        public let validForMilliseconds: Int64
        // Immutable bounded bytes enter the actual native owner's cache key and
        // sync configuration. No public method can turn them into a source grant.
        internal let nativePolicy: String
        public init(endpoint: URL, source: Source, peer: Peer, incomingScope: Scope, channel: String,
                    validForMilliseconds: Int64) throws {
            func text(_ s: String, _ cap: Int = 256) -> Bool { !s.isEmpty && s.utf8.count <= cap && !s.contains("\0") }
            func digest(_ s: String) -> Bool { s.utf8.count == 64 && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
            guard PlatformTLSEndpoint(endpoint) != nil, endpoint.absoluteString.hasPrefix("wss://"),
                  endpoint.absoluteString.utf8.count <= 4096,
                  let components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { throw ConfigurationError.invalidEndpoint }
            for item in (components.percentEncodedQuery ?? "").split(separator: "&") {
                let key = item.split(separator: "=", maxSplits: 1).first.map(String.init) ?? ""
                guard !key.contains("%"), !key.hasPrefix("recovery-"), key != "last-event-id" else { throw ConfigurationError.invalidEndpoint }
            }
            guard text(source.authority), text(source.receiptNamespace), text(source.coverageID), source.coverageRevision > 0,
                  digest(source.scopeDigest), digest(source.schemaDigest), digest(source.descriptorDigest),
                  text(peer.replicaID), text(channel, 64), (1...3_600_000).contains(validForMilliseconds) else { throw ConfigurationError.invalidIdentity }
            if let coverage = source.receiptCoverage {
                guard coverage.namespaces.contains(where: { $0.utf8.elementsEqual(source.receiptNamespace.utf8) })
                else { throw ConfigurationError.invalidIdentity }
            }
            let scope = incomingScope, tables = scope.models.map(\.table) + scope.relations.map(\.table)
            func ops(_ values: [Operation]) -> Bool { values.count <= 3 && Set(values).count == values.count }
            guard (1...256).contains(scope.models.count), scope.relations.count <= 256, scope.scopedLinkTables.count <= 256,
                  tables.allSatisfy({ text($0, 64) }), Set(tables).count == tables.count, digest(scope.catalogDigest),
                  scope.models.allSatisfy({ ops($0.incomingOperations) }),
                  scope.relations.allSatisfy({ text($0.lhsModel, 64) && text($0.rhsModel, 64) && ops($0.incomingOperations) }),
                  Set(scope.scopedLinkTables).count == scope.scopedLinkTables.count,
                  scope.scopedLinkTables.allSatisfy({ tables.contains($0) }) else { throw ConfigurationError.invalidScope }
            struct Policy: Encodable {
                let endpoint: String, source: Source, incomingScope: Scope, peer: Peer, channel: String
                let validForMilliseconds: Int64
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(Policy(endpoint: endpoint.absoluteString, source: source, incomingScope: scope,
                                                peer: peer, channel: channel, validForMilliseconds: validForMilliseconds))
            guard data.count <= 65_536, let policy = String(data: data, encoding: .utf8) else { throw ConfigurationError.invalidBounds }
            self.endpoint = endpoint; self.source = source; self.peer = peer; self.incomingScope = scope; self.channel = channel
            self.validForMilliseconds = validForMilliseconds; nativePolicy = policy
        }
    }
}
