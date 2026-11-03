/// Explicit, descriptive metadata supplied by a Codable implementation's owner.
/// It does not decode data, construct values, or provide a row-creation default.
public enum EmbeddedCodecMetadata: Sendable, Equatable {
    case unavailable
    case available(EmbeddedCodecDescriptor)

    public func validatedDescriptor() throws -> EmbeddedCodecDescriptor? {
        guard case .available(let descriptor) = self else { return nil }
        return try descriptor.validated()
    }
}

public struct EmbeddedCodecDescriptor: Sendable, Equatable {
    public let schemaID: String
    public let version: Int
    public let root: EmbeddedCodecShape
    public let definitions: [EmbeddedCodecDefinition]

    public init(schemaID: String, version: Int, root: EmbeddedCodecShape,
                definitions: [EmbeddedCodecDefinition] = []) {
        self.schemaID = schemaID
        self.version = version
        self.root = root
        self.definitions = definitions
    }

    /// Validates the declaration graph, not values accepted by the actual codec.
    /// References are checked by ID, never expanded or resolved by constructing values.
    public func validated() throws -> Self {
        guard !schemaID.isEmpty, version > 0 else {
            throw EmbeddedCodecMetadataError.invalidDescriptor(schemaID)
        }
        var ids: Set<String> = [schemaID]
        for definition in definitions {
            guard !definition.id.isEmpty else {
                throw EmbeddedCodecMetadataError.invalidDescriptor(definition.id)
            }
            guard ids.insert(definition.id).inserted else {
                throw EmbeddedCodecMetadataError.duplicateSchemaID(definition.id)
            }
        }
        try root.validate(references: ids)
        for definition in definitions { try definition.shape.validate(references: ids) }
        return self
    }
}

public struct EmbeddedCodecDefinition: Sendable, Equatable {
    public let id: String
    public let shape: EmbeddedCodecShape
    public init(id: String, shape: EmbeddedCodecShape) {
        self.id = id
        self.shape = shape
    }
}

public enum EmbeddedUnknownKeys: Sendable, Equatable {
    case unavailable, ignore, reject
}

public indirect enum EmbeddedCodecShape: Sendable, Equatable {
    case null
    case boolean
    case integer(bits: Int, signed: Bool)
    case number
    case string
    case stringEnum([String])
    /// Validation references name additional codec-owned rules. They are descriptive;
    /// a consumer cannot assume that this structural shape implements those rules.
    case object(fields: [EmbeddedCodecField], unknownKeys: EmbeddedUnknownKeys,
                validation: [String])
    case dictionary(value: EmbeddedCodecShape)
    case array(element: EmbeddedCodecShape)
    case reference(String)

    fileprivate func validate(references: Set<String>) throws {
        switch self {
        case .reference(let id):
            guard references.contains(id) else {
                throw EmbeddedCodecMetadataError.unresolvedReference(id)
            }
        case .integer(let bits, _):
            guard [8, 16, 32, 64].contains(bits) else {
                throw EmbeddedCodecMetadataError.invalidDescriptor("integer width")
            }
        case .stringEnum(let values):
            guard !values.isEmpty, Set(values).count == values.count else {
                throw EmbeddedCodecMetadataError.invalidDescriptor("string enum")
            }
        case .object(let fields, _, let validation):
            guard validation.allSatisfy({ !$0.isEmpty }) else {
                throw EmbeddedCodecMetadataError.invalidDescriptor("validation reference")
            }
            var keys: Set<String> = []
            for field in fields {
                guard keys.insert(field.key).inserted else {
                    throw EmbeddedCodecMetadataError.duplicateField(field.key)
                }
                guard !(field.requiredOnDecode && field.missingValue != nil),
                      field.missingValue != .null || field.nullableOnDecode else {
                    throw EmbeddedCodecMetadataError.invalidDescriptor(field.key)
                }
                try field.shape.validate(references: references)
            }
        case .dictionary(let value), .array(let value):
            try value.validate(references: references)
        case .null, .boolean, .number, .string:
            break
        }
    }
}

public struct EmbeddedCodecField: Sendable, Equatable {
    public let key: String
    public let shape: EmbeddedCodecShape
    public let requiredOnDecode: Bool
    public let nullableOnDecode: Bool
    /// Only an explicitly known decoder behavior when the key is absent.
    /// `nil` means no default is described; it does not mean a decoded null.
    /// This is separate from authored property initializers and storage fallback.
    public let missingValue: EmbeddedCodecLiteral?

    public init(_ key: String, shape: EmbeddedCodecShape, requiredOnDecode: Bool,
                nullableOnDecode: Bool, missingValue: EmbeddedCodecLiteral? = nil) {
        self.key = key
        self.shape = shape
        self.requiredOnDecode = requiredOnDecode
        self.nullableOnDecode = nullableOnDecode
        self.missingValue = missingValue
    }
}

/// A deliberately small set of explicit decoder-default facts. Numeric spelling
/// stays exact and is never converted through Double. Other defaults remain undescribed.
public enum EmbeddedCodecLiteral: Sendable, Equatable {
    case null
    case boolean(Bool)
    case string(String)
    case integer(decimal: String)
    case emptyArray
    case emptyObject
}

public enum EmbeddedCodecMetadataError: Error, Sendable, Equatable {
    case invalidDescriptor(String)
    case duplicateSchemaID(String)
    case duplicateField(String)
    case unresolvedReference(String)
}
