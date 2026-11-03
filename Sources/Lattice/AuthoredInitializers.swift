/// Declaration metadata, not a factory or a storage default. Reading it never
/// constructs a model or evaluates its authored initializer expressions.
public enum AuthoredInitializers: Sendable, Equatable {
    /// Old macros and manual conformers do not promise declaration coverage.
    case unavailable
    /// Exactly one entry per declared persisted property, excluding id/globalId.
    case available([AuthoredPropertyInitializer])

    /// Exporters must check coverage before treating metadata as complete.
    /// `nil` means unavailable, whereas an empty array describes an empty model.
    public func validated(propertyNames: [String]) throws -> [AuthoredPropertyInitializer]? {
        guard case .available(let entries) = self else { return nil }
        var expected = Set<String>()
        for name in propertyNames {
            guard expected.insert(name).inserted else {
                throw AuthoredInitializerMetadataError.duplicateProperty(name)
            }
        }
        var actual = Set<String>()
        for entry in entries {
            guard actual.insert(entry.name).inserted else {
                throw AuthoredInitializerMetadataError.duplicateProperty(entry.name)
            }
        }
        guard actual == expected else {
            throw AuthoredInitializerMetadataError.coverageMismatch(
                expected: expected.sorted(), actual: actual.sorted())
        }
        return entries
    }
}

public enum AuthoredInitializerMetadataError: Error, Sendable, Equatable {
    case duplicateProperty(String)
    case coverageMismatch(expected: [String], actual: [String])
}

public struct AuthoredPropertyInitializer: Sendable, Equatable {
    /// The same persisted/mapped name used by Model.properties.
    public let name: String
    /// Authored Swift type spelling, including optionality and integer width.
    /// Storage type/constraints remain authoritative in Model.properties.
    public let declaredType: String
    public let initializer: AuthoredInitializer

    public init(name: String, declaredType: String, initializer: AuthoredInitializer) {
        self.name = name
        self.declaredType = declaredType
        self.initializer = initializer
    }
}

public enum AuthoredInitializer: Sendable, Equatable {
    /// No initializer was written. This does not imply a nullable/omissible field.
    case absent
    case literal(AuthoredInitializerLiteral)
    /// Descriptive Swift syntax only; never execute this string to create a value.
    case dynamic(source: String)

    /// Macro support: check the actual metatype, so a shadowed built-in name or
    /// a custom ExpressibleBy… type does not imply built-in literal semantics.
    /// The value expression is never passed here or evaluated.
    public static func _literal(_ literal: AuthoredInitializerLiteral,
                                type: Any.Type, source: String) -> Self {
        let valueType = (type as? any _AuthoredOptionalType.Type)?.wrappedType ?? type
        switch literal {
        case .nilLiteral:
            if type is any _AuthoredOptionalType.Type { return .literal(literal) }
        case .boolean:
            if valueType == Bool.self { return .literal(literal) }
        case .string:
            if valueType == String.self { return .literal(literal) }
        case .integer(let spelling):
            let integerTypes: [Any.Type] = [Int.self, Int8.self, Int16.self, Int32.self, Int64.self,
                                          UInt.self, UInt8.self, UInt16.self, UInt32.self, UInt64.self]
            if integerTypes.contains(where: { $0 == valueType }) { return .literal(literal) }
            if valueType == Float.self || valueType == Double.self {
                return .literal(.floatingPoint(swift: spelling))
            }
        case .floatingPoint:
            if valueType == Float.self || valueType == Double.self { return .literal(literal) }
        case .unionCase:
            break // Only _member may classify a descriptor-backed case.
        }
        return .dynamic(source: source)
    }

    /// A symbolic member is literal only when an existing union descriptor
    /// proves it is a unique zero-payload case. No case value/default is read.
    /// LatticeEnum currently has no case descriptor: its members stay dynamic.
    public static func _member(_ name: String, type: Any.Type, source: String) -> Self {
        // Optional.none is not a union case even if Wrapped has a case named
        // `none`. Conservatively keep optional member shorthand descriptive.
        if type is any _AuthoredOptionalType.Type { return .dynamic(source: source) }
        if let union = type as? any LatticeUnion.Type {
            let matches = union.unionCases.filter { $0.name == name }
            if matches.count == 1, matches[0].fields.isEmpty {
                return .literal(.unionCase(name: name))
            }
        }
        return .dynamic(source: source)
    }
}

public enum AuthoredInitializerLiteral: Sendable, Equatable {
    case nilLiteral
    case boolean(Bool)
    case string(String)
    /// Exact Swift token spelling (including sign/radix/separators). Never a
    /// JSON Number: consumers must retain the enclosing declared type and must
    /// not silently round Int64/UInt64 through binary64.
    case integer(swift: String)
    /// Exact Swift spelling and declared type retain the rounding input and
    /// negative zero. This is NOT an evaluated/rounded runtime floating value.
    case floatingPoint(swift: String)
    case unionCase(name: String)
}

private protocol _AuthoredOptionalType {
    static var wrappedType: Any.Type { get }
}

extension Optional: _AuthoredOptionalType {
    fileprivate static var wrappedType: Any.Type { Wrapped.self }
}
