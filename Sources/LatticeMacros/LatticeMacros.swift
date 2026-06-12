import SwiftSyntaxMacros
import SwiftCompilerPlugin
import SwiftSyntax
import Foundation
import SwiftSyntaxBuilder   // gives you the convenient factory methods
import SwiftSyntaxMacroExpansion
import SwiftDiagnostics

/// Qualifies type references within a property type string.
/// For example, if the full type path is "MigrationV1.Person" and the property type is "Person?",
/// this returns "MigrationV1.Person?" to ensure correct type resolution.
private func qualifyTypeReferences(propertyType: String, fullTypePath: String, simpleTypeName: String) -> String {
    // If the full path equals the simple name, no qualification needed
    guard fullTypePath != simpleTypeName else { return propertyType }

    var result = propertyType

    // Pattern to match the simple type name as a standalone word (not part of another identifier)
    // We need to be careful to only match the exact type name, not substrings
    let patterns: [(String, String)] = [
        // Optional<Person> -> Optional<FullPath>
        ("Optional<\(simpleTypeName)>", "Optional<\(fullTypePath)>"),
        // Person? -> FullPath?
        ("\(simpleTypeName)?", "\(fullTypePath)?"),
        // Array<Person> -> Array<FullPath>
        ("Array<\(simpleTypeName)>", "Array<\(fullTypePath)>"),
        // [Person] -> [FullPath]
        ("[\(simpleTypeName)]", "[\(fullTypePath)]"),
        // List<Person> -> List<FullPath>
        ("List<\(simpleTypeName)>", "List<\(fullTypePath)>"),
        // VirtualList<Person> -> VirtualList<FullPath>
        ("VirtualList<\(simpleTypeName)>", "VirtualList<\(fullTypePath)>"),
        // Standalone Person (exact match only)
        (simpleTypeName, fullTypePath),
    ]

    for (pattern, replacement) in patterns {
        if result == pattern {
            result = replacement
            break
        }
    }

    return result
}

private struct MemberView {
    let name: String
    var mappedName: String?
    var codingKey: String?
    var isCodableIgnored: Bool = false
    let type: String
    let unwrappedType: String
    var isOptional: Bool = false
    var attributeKey: String?
    var isTransient: Bool {
        attributeKey == "@Transient"
    }
    var isRelation: Bool {
        attributeKey == "Relation"
    }
    var isFullText: Bool {
        attributeKey == "FullText"
    }
    var isIndexed: Bool {
        attributeKey == "Indexed"
    }
    var constraint: Constraint?
    var assignment: String?
    var isComputed: Bool = false       // Flag for computed properties
    var computedBlock: String? = nil    // Captures the computed accessor block if present
}

public struct Constraint {
    public var columns: [String]
    public var allowsUpsert: Bool
    public init(columns: [String], allowsUpsert: Bool = false) {
        self.columns = columns
        self.allowsUpsert = allowsUpsert
    }
}

// MARK: View Helper
private func view(for member: VariableDeclSyntax) -> MemberView? {
    let decl = member
    guard let binding = decl.bindings.first,
          let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier,
          let type = binding.typeAnnotation?.type else {
        return nil
    }

    // Unwrap implicitly unwrapped optionals (e.g., String! -> String)
    let isOptional = type.is(OptionalTypeSyntax.self)
    let unwrappedType: TypeSyntax
    if let optional = type.as(OptionalTypeSyntax.self) {
        unwrappedType = optional.wrappedType
    } else if let iuo = type.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) {
        unwrappedType = iuo.wrappedType
    } else {
        unwrappedType = type
    }

    var memberView = MemberView(name: "\(identifier.trimmed)", type: type.trimmedDescription, unwrappedType: unwrappedType.trimmedDescription, isOptional: isOptional, attributeKey: nil)

    // Extract attributeKey if available.
//    if let attribute = decl.attributes.first?.as(AttributeSyntax.self),
//       let firstArgument = attribute.arguments?.as(LabeledExprListSyntax.self)?.first,
//       let literal = firstArgument.expression.as(StringLiteralExprSyntax.self) {
//        memberView.attributeKey = "\(literal.segments)"
//    }
    if memberView.attributeKey == nil {
        if let attribute = decl.attributes.first?.as(AttributeSyntax.self) {
//            throw MacroError.message(attribute.debugDescription)
            memberView.attributeKey = attribute.attributeName.as(IdentifierTypeSyntax.self)!.name.text
            if memberView.attributeKey == "Unique" {
                var constraint = Constraint(columns: [memberView.name], allowsUpsert: false)
                if let arguments = attribute.arguments?.as(LabeledExprListSyntax.self) {
                    arguments.forEach {
                        if $0.label?.text == "compoundedWith" {
                            $0.expression.as(KeyPathExprSyntax.self).map {
                                constraint.columns.append("\($0.components.first!.component)")
                            }
                        } else if $0.label == nil {
                            $0.expression.as(KeyPathExprSyntax.self).map {
                                constraint.columns.append("\($0.components.first!.component)")
                            }

                        } else if $0.label?.text == "allowsUpsert" {

                            // named boolean argument
                            if let boolLit = $0.expression.as(BooleanLiteralExprSyntax.self) {
                                constraint.allowsUpsert = (boolLit.literal.text == "true")
                            }
                        }
                    }
                }
                memberView.constraint = constraint
            } else if memberView.attributeKey == "Property" {
                if let arguments = attribute.arguments?.as(LabeledExprListSyntax.self) {
                    arguments.forEach {
                        if $0.label?.text == "name" {
                            if let strLit = $0.expression.as(StringLiteralExprSyntax.self) {
                                memberView.mappedName = strLit.representedLiteralValue
                            }
                        }
                    }
                }
            }
        }
    }
    // Check for @CodingKey("...") and @CodableIgnored attributes
    for attr in decl.attributes {
        if let simpleAttr = attr.as(AttributeSyntax.self) {
            let attrName = simpleAttr.attributeName.as(IdentifierTypeSyntax.self)?.name.text
            if attrName == "CodingKey",
               let arguments = simpleAttr.arguments?.as(LabeledExprListSyntax.self),
               let firstArg = arguments.first,
               let strLit = firstArg.expression.as(StringLiteralExprSyntax.self) {
                memberView.codingKey = strLit.representedLiteralValue
            } else if attrName == "CodableIgnored" {
                memberView.isCodableIgnored = true
            }
        }
    }

    // Check if this property has an accessorBlock (i.e. it's computed)
    if let accessorBlock = binding.accessorBlock {
        switch accessorBlock.accessors {
        case .accessors(let accessors):
            // Only treat as computed if it has a get/set with a body.
            // didSet/willSet are property observers on stored properties — NOT computed.
            let hasComputedAccessor = accessors.contains(where: { accessor in
                let specifier = accessor.accessorSpecifier.text
                return (specifier == "get" || specifier == "set")
                    && accessor.body != nil
            })
            if hasComputedAccessor {
                memberView.isComputed = true
                memberView.computedBlock = "\(accessorBlock)"
            }
        case .getter(let getter):
            memberView.isComputed = true
            memberView.computedBlock = "\(accessorBlock)"
        }
    }
    if let initializerValue = binding.initializer?.value {
        // For stored properties, capture the initializer if present.
        memberView.assignment = "\(initializerValue)"
    }
    
    return memberView
}
private func view(for member: MemberBlockItemListSyntax.Element) throws -> MemberView? {
    guard let decl = member.decl.as(VariableDeclSyntax.self) else {
        return nil
    }
    return view(for: decl)
}

enum MacroError: Error, DiagnosticMessage {
    case message(String)

    var severity: DiagnosticSeverity {
        .error
    }

    var message: String {
        switch self {
        case .message(let text):
            return text
        }
    }

    var diagnosticID: MessageID {
        MessageID(domain: "Lattice", id: "MacroError")
    }
}

class TransientMacro: PeerMacro {
    static func expansion(of node: SwiftSyntax.AttributeSyntax, providingPeersOf declaration: some SwiftSyntax.DeclSyntaxProtocol, in context: some SwiftSyntaxMacros.MacroExpansionContext) throws -> [SwiftSyntax.DeclSyntax] {
        []
    }
}

class FullTextMacro: PeerMacro {
    static func expansion(of node: SwiftSyntax.AttributeSyntax, providingPeersOf declaration: some SwiftSyntax.DeclSyntaxProtocol, in context: some SwiftSyntaxMacros.MacroExpansionContext) throws -> [SwiftSyntax.DeclSyntax] {
        []
    }
}

class IndexedMacro: PeerMacro {
    static func expansion(of node: SwiftSyntax.AttributeSyntax, providingPeersOf declaration: some SwiftSyntax.DeclSyntaxProtocol, in context: some SwiftSyntaxMacros.MacroExpansionContext) throws -> [SwiftSyntax.DeclSyntax] {
        []
    }
}

class CodingKeyMacro: PeerMacro {
    static func expansion(of node: SwiftSyntax.AttributeSyntax, providingPeersOf declaration: some SwiftSyntax.DeclSyntaxProtocol, in context: some SwiftSyntaxMacros.MacroExpansionContext) throws -> [SwiftSyntax.DeclSyntax] {
        []
    }
}

class CodableIgnoredMacro: PeerMacro {
    static func expansion(of node: SwiftSyntax.AttributeSyntax, providingPeersOf declaration: some SwiftSyntax.DeclSyntaxProtocol, in context: some SwiftSyntaxMacros.MacroExpansionContext) throws -> [SwiftSyntax.DeclSyntax] {
        []
    }
}
//
//class LatticeMemberMacro: PeerMacro {
//    static func expansion(of node: SwiftSyntax.AttributeSyntax,
//                          providingPeersOf declaration: some SwiftSyntax.DeclSyntaxProtocol,
//                          in context: some SwiftSyntaxMacros.MacroExpansionContext) throws -> [SwiftSyntax.DeclSyntax] {
//        guard
//          let varDecl = declaration.as(VariableDeclSyntax.self),
//          let binding = varDecl.bindings.first,
//          let typeAnn = binding.typeAnnotation
//        else {
//          return []
//        }
//
//        let originalType = typeAnn.type
//        let origType = typeAnn.type
//
//        let isShorthand = originalType.as(ArrayTypeSyntax.self) != nil
//        let isExplicit = (originalType.as(SimpleTypeIdentifierSyntax.self)?.name.text == "Array")
//                       && originalType.as(SimpleTypeIdentifierSyntax.self)?.genericArgumentClause != nil
//
//        guard isShorthand || isExplicit else {
//          return []
//        }
//        // 2) Extract the property name
//        guard
//            let idPattern = binding.pattern.as(IdentifierPatternSyntax.self)
//        else {
//            return []
//        }
//        let name = idPattern.identifier.text
//        let backingName = "_\(name)Storage"
//        let listType    = "\(origType).List"   // string‑literal embed
//        
//        // 3) Build the two decls via string interpolation
//        let privateDecl: DeclSyntax = DeclSyntax("""
//            private var \(raw: backingName): \(raw: listType) = \(raw: listType)()
//            """)
//        
//        let publicDecl: DeclSyntax = DeclSyntax("""
//            var \(raw: name): \(raw: listType) {
//              get { \(raw: backingName) }
//              set { \(raw: backingName) = newValue }
//            }
//            """)
//        return [
//            privateDecl, publicDecl
//        ]
//    }
//    
//    static func expansion(
//      of node: AttributeSyntax,
//      providingMembersOf declaration: some DeclGroupSyntax,
//      conformingTo protocols: [TypeSyntax],
//      in context: some MacroExpansionContext
//    ) throws -> [DeclSyntax] {
//        []
//    }
//}

class PropertyMacro: AccessorMacro, MemberMacro {
    static func expansion(
      of node: AttributeSyntax,
      providingMembersOf declaration: some DeclGroupSyntax,
      conformingTo protocols: [TypeSyntax],
      in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
    
    
    static func expansion(of node: SwiftSyntax.AttributeSyntax,
                          providingAccessorsOf declaration: some SwiftSyntax.DeclSyntaxProtocol,
                          in context: some SwiftSyntaxMacros.MacroExpansionContext) throws -> [SwiftSyntax.AccessorDeclSyntax] {
//        throw MacroError.message("\(declaration.debugDescription)")
        guard let declaration = declaration.as(VariableDeclSyntax.self) else {
            return []
        }
        guard
          let binding = declaration.bindings.first,
          let typeAnn = binding.typeAnnotation
        else {
          return []
        }
        
        guard let property = view(for: declaration) else {
            fatalError()
        }
//        /Users/jason/Documents/Zephyr/Tests/ZephyrTests/ZephyrTests.swift:5:5 Message("VariableDeclSyntax\n├─attributes: AttributeListSyntax\n│ ╰─[0]: AttributeSyntax\n│   ├─atSign: atSign\n│   ╰─attributeName: IdentifierTypeSyntax\n│     ╰─name: identifier(\"Property\")\n├─modifiers: DeclModifierListSyntax\n├─bindingSpecifier: keyword(SwiftSyntax.Keyword.var)\n╰─bindings: PatternBindingListSyntax\n  ╰─[0]: PatternBindingSyntax\n    ├─pattern: IdentifierPatternSyntax\n    │ ╰─identifier: identifier(\"name\")\n    ╰─typeAnnotation: TypeAnnotationSyntax\n      ├─colon: colon\n      ╰─type: IdentifierTypeSyntax\n        ╰─name: identifier(\"String\")") (from macro 'Property ')

        guard let binding = declaration.bindings.first,
              let id = binding.pattern.as( IdentifierPatternSyntax.self) else {
            throw MacroError.message("\(declaration.debugDescription)")
        }
//        var members = try declaration.
        
        let originalType = typeAnn.type

        // ← NEW: detect [T]
        let isArrayShorthand = originalType.as(ArrayTypeSyntax.self) != nil

        // ← NEW: detect Array<T>
        let isExplicitArray: Bool = {
          // SimpleTypeIdentifierSyntax is the node for e.g. `Array<Int>`
          guard
            let simpleID = originalType.as(IdentifierTypeSyntax.self),
            simpleID.name.text == "Array",
            simpleID.genericArgumentClause != nil
          else {
            return false
          }
          return true
        }()
        
        // bail unless it’s either form
//        guard isArrayShorthand || isExplicitArray else {
//          return []
//        }

//
//        let listType = SyntaxRefactoringProvider
//          .MemberAccessExpr(
//            base: originalType,
//            dot: .periodToken(),
//            name: .identifier("List")
//          )

        
        return [
            """
            get {
                _lastKeyPathUsed = "\(raw: property.mappedName ?? property.name)"
                if #available(iOS 17, macOS 14, tvOS 17, watchOS 10, *) {
                    _$observationRegistrar.access(self, keyPath: \\.\(id.identifier))
                }
                return \(raw: property.type).getField(from: _dynamicObject, named: "\(raw: property.mappedName ?? property.name)")
            }
            set {
                // ObservableObject contract: objectWillChange fires BEFORE the
                // mutation, on every OS (Observation handles 17+ SwiftUI
                // tracking; the unconditional send keeps direct Combine
                // subscribers working identically across OS versions).
                _objectWillChange.send()
                if #available(iOS 17, macOS 14, tvOS 17, watchOS 10, *) {
                    _$observationRegistrar.withMutation(of: self, keyPath: \\.\(id.identifier)) {
                        \(raw: property.type).setField(on: &_dynamicObject, named: "\(raw: property.mappedName ?? property.name)", newValue)
                    }
                } else {
                    \(raw: property.type).setField(on: &_dynamicObject, named: "\(raw: property.mappedName ?? property.name)", newValue)
                }
                _notifyOtherInstances(propertyName: "\(raw: property.name)")
            }
            """
        ]
    }
}

class VirtualLinkPropertyMacro: AccessorMacro {
    static func expansion(of node: AttributeSyntax,
                          providingAccessorsOf declaration: some DeclSyntaxProtocol,
                          in context: some MacroExpansionContext) throws -> [AccessorDeclSyntax] {
        guard let declaration = declaration.as(VariableDeclSyntax.self),
              let binding = declaration.bindings.first,
              let id = binding.pattern.as(IdentifierPatternSyntax.self) else { return [] }
        guard let property = view(for: declaration) else { fatalError() }
        let name = property.mappedName ?? property.name

        return [
            """
            get {
                _lastKeyPathUsed = "\(raw: name)"
                if #available(iOS 17, macOS 14, tvOS 17, watchOS 10, *) {
                    _$observationRegistrar.access(self, keyPath: \\.\(id.identifier))
                }
                return _getVirtualLink(from: &_dynamicObject, named: "\(raw: name)")
            }
            set {
                // See PropertyMacro's setter: willChange before the mutation,
                // unconditionally, for one Combine contract across OS versions.
                _objectWillChange.send()
                if #available(iOS 17, macOS 14, tvOS 17, watchOS 10, *) {
                    _$observationRegistrar.withMutation(of: self, keyPath: \\.\(id.identifier)) {
                        _setVirtualLink(on: &_dynamicObject, named: "\(raw: name)", newValue)
                    }
                } else {
                    _setVirtualLink(on: &_dynamicObject, named: "\(raw: name)", newValue)
                }
                _notifyOtherInstances(propertyName: "\(raw: property.name)")
            }
            """
        ]
    }
}

class UniqueMacro: PeerMacro {
    static func expansion(of node: SwiftSyntax.AttributeSyntax, providingPeersOf declaration: some SwiftSyntax.DeclSyntaxProtocol, in context: some SwiftSyntaxMacros.MacroExpansionContext) throws -> [SwiftSyntax.DeclSyntax] {
        []
    }
}

class CodableMacro: ExtensionMacro, MemberMacro {
    static func expansion(of node: AttributeSyntax,
                          providingMembersOf declaration: some DeclGroupSyntax,
                          conformingTo protocols: [TypeSyntax],
                          in context: some MacroExpansionContext) throws -> [DeclSyntax] {
        let members = try declaration.memberBlock.members.compactMap(view(for:)).filter {
            !$0.isTransient && !$0.isComputed && !$0.isCodableIgnored
        }

        return [
            """
            enum CodingKeys: String, CodingKey {
                \(raw: members.map { member in
                    """
                    case \(member.name) = "\(member.codingKey ?? member.mappedName ?? member.name)"
                    """
                }.joined(separator: "\n\t\t"))
                case __globalId = "globalId"
            }

            public required init(from decoder: Decoder) throws {
                if #available(iOS 17, macOS 14, tvOS 17, watchOS 10, *) {
                    _$observationRegistrarBox = Observation.ObservationRegistrar()
                }
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.__globalId = try container.decodeIfPresent(UUID.self, forKey: .__globalId)
                \(raw: members.map { member in
                    if member.isOptional {
                        return "self.\(member.name) = try container.decodeIfPresent(\(member.unwrappedType).self, forKey: .\(member.name))"
                    } else {
                        return "self.\(member.name) = try container.decode(\(member.type).self, forKey: .\(member.name))"
                    }
                }.joined(separator: "\n\t\t"))
            }

            public func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(__globalId, forKey: .__globalId)
                \(raw: members.map { member in
                    """
                    try container.encode(\(member.name), forKey: .\(member.name))
                    """
                }.joined(separator: "\n\t\t"))
            }
            """
        ]
    }
    
    static func expansion(of node: SwiftSyntax.AttributeSyntax,
                          attachedTo declaration: some SwiftSyntax.DeclGroupSyntax,
                          providingExtensionsOf type: some SwiftSyntax.TypeSyntaxProtocol,
                          conformingTo protocols: [SwiftSyntax.TypeSyntax],
                          in context: some SwiftSyntaxMacros.MacroExpansionContext) throws -> [SwiftSyntax.ExtensionDeclSyntax] {
        let members = try declaration.memberBlock.members.compactMap(view(for:)).filter {
            !$0.isTransient
        }
        
        return [
            ExtensionDeclSyntax(
                extendedType: type,
                inheritanceClause: .init(inheritedTypes: .init(arrayLiteral: InheritedTypeSyntax(type: TypeSyntax("Codable")))),
                memberBlock: """
                {
                }
                """
            )
        ]
    }
}

private func isOptionalExistential(_ type: TypeSyntax) -> Bool {
    // Check X? where X is (any Protocol)
    if let optionalType = type.as(OptionalTypeSyntax.self) {
        let wrapped = optionalType.wrappedType
        // Direct: any Protocol?
        if wrapped.as(SomeOrAnyTypeSyntax.self)?.someOrAnySpecifier.text == "any" {
            return true
        }
        // Parenthesized: (any Protocol)?
        if let tuple = wrapped.as(TupleTypeSyntax.self),
           tuple.elements.count == 1,
           tuple.elements.first?.type.as(SomeOrAnyTypeSyntax.self)?.someOrAnySpecifier.text == "any" {
            return true
        }
    }
    return false
}

private func isOptionalExistentialString(_ typeStr: String) -> Bool {
    // Matches patterns like "(any Animal)?", "any Animal?", "(any X.Y)?"
    let trimmed = typeStr.trimmingCharacters(in: .whitespaces)
    if trimmed.hasSuffix("?") {
        let inner = String(trimmed.dropLast())
        // (any X)?
        if inner.hasPrefix("(") && inner.hasSuffix(")") {
            let unwrapped = String(inner.dropFirst().dropLast())
            return unwrapped.hasPrefix("any ")
        }
        // any X?
        return inner.hasPrefix("any ")
    }
    return false
}

class ModelMacro: MemberMacro, ExtensionMacro, MemberAttributeMacro {
    static func expansion(of node: SwiftSyntax.AttributeSyntax, attachedTo declaration: some SwiftSyntax.DeclGroupSyntax, providingAttributesFor member: some SwiftSyntax.DeclSyntaxProtocol, in context: some SwiftSyntaxMacros.MacroExpansionContext) throws -> [SwiftSyntax.AttributeSyntax] {
        // Try to cast the member to a variable declaration.
        guard let variableDecl = member.as(VariableDeclSyntax.self) else {
            // Not a property; do not attach @Property.
            return []
        }

        // Check for reserved property names
        var propertyName: String?
        for binding in variableDecl.bindings {
            if let pattern = binding.pattern.as(IdentifierPatternSyntax.self) {
                propertyName = pattern.identifier.text
                if propertyName == "id" || propertyName == "globalId" {
                    context.diagnose(Diagnostic(
                        node: Syntax(pattern.identifier),
                        message: MacroError.message("Property name '\(propertyName!)' is reserved by Lattice. The 'id' and 'globalId' columns are automatically created. Use a different name like 'identifier' or 'uniqueId'.")
                    ))
                    return []
                }
            }
        }

        // Check for SQL reserved keywords that fail in CREATE TABLE column definitions.
        // SQLite is lenient with most keywords as column names, but these cause parse errors.
        // Only checked when no explicit @Property(name:) mapping is provided.
        let hasMappedProperty = variableDecl.attributes.contains(where: { attr in
            guard let simpleAttr = attr.as(AttributeSyntax.self),
                  simpleAttr.attributeName.description.trimmingCharacters(in: .whitespacesAndNewlines) == "Property",
                  let args = simpleAttr.arguments?.as(LabeledExprListSyntax.self),
                  args.contains(where: { $0.label?.text == "name" }) else { return false }
            return true
        })
        if !hasMappedProperty, let propertyName {
            // Keywords that SQLite rejects as unquoted column names in CREATE TABLE
            let sqlReserved: Set<String> = [
                "add", "alter", "and", "as", "between", "case", "check", "collate",
                "column", "constraint", "create", "default", "delete", "distinct",
                "drop", "else", "end", "escape", "except", "exists", "for", "foreign",
                "from", "group", "having", "if", "in", "index", "indexed", "insert",
                "intersect", "into", "is", "join", "limit", "not", "null", "on",
                "or", "order", "primary", "references", "select", "set", "table",
                "then", "to", "union", "unique", "update", "using", "values", "when",
                "where", "with",
            ]
            if sqlReserved.contains(propertyName.lowercased()) {
                context.diagnose(Diagnostic(
                    node: variableDecl,
                    message: MacroError.message("Property name '\(propertyName)' is a SQL reserved keyword and cannot be used as a column name. Add @Property(name: \"<columnName>\") to map it to a different column name.")
                ))
                return []
            }
        }
        guard let propertyName else {
            context.diagnose(Diagnostic(
                node: variableDecl,
                message: MacroError.message("Missing property name.")
            ))
            return []
        }
        // Check if the variable already has the @Property attribute.
        let attributes = variableDecl.attributes
        for attr in attributes {
            if let simpleAttr = attr.as(AttributeSyntax.self) {
                let attrName = simpleAttr.attributeName.description.trimmingCharacters(in: .whitespacesAndNewlines)
                if attrName == "Property" || attrName == "VirtualLinkProperty"
                    || attrName == "Transient"
                    || simpleAttr.attributeName.as(IdentifierTypeSyntax.self)?.name.text == "Relation" {
                    // Already has @Property/@VirtualLinkProperty or is ignored as @Transient; do nothing.
                    return []
                }
            }
        }
        
        // Optionally, ensure that you only attach to stored properties.
        // For each binding, check if it has an accessor (meaning it might be computed)
        for binding in variableDecl.bindings {
            if let accessorBlock = binding.accessorBlock {
                switch accessorBlock.accessors {
                case .accessors(let accessors):
                    // Allow private(set) - it only has a 'set' accessor with no body
                    let isPrivateSet = accessors.count == 1
                        && accessors.first?.accessorSpecifier.text == "set"
                        && accessors.first?.body == nil

                    if isPrivateSet {
                        // This is private(set), treat as stored property
                        break
                    }

                    // Otherwise check if it's computed (get/set only, not didSet/willSet observers)
                    let hasComputedAccessor = accessors.contains(where: { accessor in
                        let specifier = accessor.accessorSpecifier.text
                        return (specifier == "get" || specifier == "set")
                            && accessor.body != nil
                    })
                    if hasComputedAccessor {
                        return []
                    }
                case .getter(let getter):
                    return []
                }
            }
        }

        // Check if this is an optional existential type: (any X)? or any X?
        // These need @VirtualLinkProperty instead of @Property
        if let binding = variableDecl.bindings.first,
           let typeAnn = binding.typeAnnotation {
            if isOptionalExistential(typeAnn.type) {
                return ["@VirtualLinkProperty(name: \"\(raw: propertyName)\")"]
            }
        }

        // If all checks pass, then create and return the @Property attribute.
        // You can construct the attribute using SwiftSyntaxBuilder.
        return ["@Property(name: \"\(raw: propertyName)\")"]
    }
    
    static func expansion(
      of node: AttributeSyntax,
      providingMembersOf declaration: some DeclGroupSyntax,
      in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
    
    static func expansion(of node: AttributeSyntax, providingMembersOf declaration: some DeclGroupSyntax, conformingTo protocols: [TypeSyntax], in context: some MacroExpansionContext) throws -> [DeclSyntax] {
        
        // Gather the members defined in the type.
        var members = try declaration.memberBlock.members.compactMap(view(for:)).filter {
            !$0.isRelation
        }
        
        // Check if the type is annotated with @Model (from SwiftData)
        var isModel = false
        if let structDecl = declaration.as(StructDeclSyntax.self) {
            isModel = structDecl.attributes.contains(where: {
                $0.as(AttributeSyntax.self)?.attributeName == "Model"
            }) ?? false
        } else if let classDecl = declaration.as(ClassDeclSyntax.self) {
            isModel = classDecl.attributes.contains(where: {
                $0.as(AttributeSyntax.self)?.attributeName == "Model"
            }) ?? false
        }
        
//        for member in members {
//            if member.isRelation {
//                throw MacroError.message(member.attributeKey ?? "")
//            }
//        }
        
        // If it's a model and there's no "id" property, add one.
        if isModel, !members.contains(where: { $0.name == "id" }) {
            let idMember = MemberView(name: "id",
                                      type: "UUID",
                                      unwrappedType: "UUID",
                                      attributeKey: nil,
                                      assignment: nil,
                                      isComputed: false,
                                      computedBlock: nil)
            members.insert(idMember, at: 0)
        }
        guard let name = declaration.as(ClassDeclSyntax.self)?.name else {
            fatalError()
        }
        for member in members {
            if member.attributeKey == "Relation" {
//                throw MacroError.message(member.type)
                members.remove(at: members.firstIndex(where: { $0.name == member.name })!)
            }
        }
        let allowedMembers = members.filter { !$0.isComputed && !$0.isTransient && !$0.isRelation }
        // Build the DTO properties (include both computed and stored properties)
        let dtoProperties = members.filter {
            !$0.isComputed && !$0.isTransient && !$0.isRelation
        }.enumerated().map { idx, member in
            let ssName = context.makeUniqueName(member.name)
            let siName = context.makeUniqueName(member.name)
            if let assignment = member.assignment {
                return """
                """
            } else {
                return """
                """
            }
        }.joined(separator: "\n")
        let defaultInitMapping = members.filter { !$0.isComputed && !$0.isTransient && !$0.isRelation }
            .enumerated()
            .map { idx, member in
                if let assignment = member.assignment {
                    "_\(member.name)Accessor = .init(columnId: \(idx + 1), name: \"\(member.mappedName ?? member.name)\", unmanagedValue: \(assignment))"
                } else {
                    "_\(member.name)Accessor = .init(columnId: \(idx + 1), name: \"\(member.mappedName ?? member.name)\")"
                }
            }
            .joined(separator: "\n")
        // If the declaration is an enum, opt out.
        if declaration is EnumDeclSyntax {
            return []
        }
        return [
            """
            
            public typealias DefaultValue = Optional<\(name)>
            \(raw: dtoProperties)
            @Property(name: "id")
            public var primaryKey: Int64?
            private var isolation: (any Actor)?
            public var _objectWillChange: ObservableObjectPublisher = .init()
            
            public var _dynamicObject: ModelStorage = {
                var obj = ModelStorage._default(\(name.trimmed).self)
                \(raw: allowedMembers.filter { $0.assignment != nil && !isOptionalExistentialString($0.type) }.map { "\($0.type).setField(on: &obj, named: \"\($0.mappedName ?? $0.name)\", \($0.assignment ?? ".defaultValue"))" }.joined(separator: "\n\t\t"))
                return obj
            }()
            
            public required init(isolation: isolated (any Actor)? = #isolation) {
                self.isolation = isolation
                if #available(iOS 17, macOS 14, tvOS 17, watchOS 10, *) {
                    _$observationRegistrarBox = Observation.ObservationRegistrar()
                }
            }
            private struct __GlobalIdName: StaticString { static var string: String { "globalId" } }
            private struct __GlobalIdKey: StaticInt32 { static var int32: Int32 { 1 } }
            
            @Property(name: "globalId")
            public var __globalId: UUID?

            public var globalId: UUID? { __globalId }
            
            public var _instanceObservers: [_ModelObserver] = []
            // Untyped box for the iOS-17 ObservationRegistrar (a stored property
            // of a 17-only type can't exist at the iOS-15 floor). Eagerly filled
            // in the generated inits so the getter is a pure read; the lazy
            // fallback only covers exotic init paths.
            private var _$observationRegistrarBox: Any? = nil
            @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
            public var _$observationRegistrar: Observation.ObservationRegistrar {
                if let r = _$observationRegistrarBox as? Observation.ObservationRegistrar { return r }
                let r = Observation.ObservationRegistrar()
                _$observationRegistrarBox = r
                return r
            }
            public var _lastKeyPathUsed: String?
            
            @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
            internal nonisolated func access<_M>(
                keyPath: KeyPath<\(name), _M>
            ) {
              _$observationRegistrar.access(self, keyPath: keyPath)
            }

            @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
            internal nonisolated func withMutation<_M, _MR>(
              keyPath: KeyPath<\(name), _M>,
              _ mutation: () throws -> _MR
            ) rethrows -> _MR {
              try _$observationRegistrar.withMutation(of: self, keyPath: keyPath, mutation)
            }
            
            public func _objectWillChange_send() {
                _objectWillChange.send()
            } 
            
            public func _triggerObservers_send(keyPath: String) {
                switch keyPath {
                    \(raw: allowedMembers.map {
                        """
                        case "\($0.mappedName ?? $0.name)":
                            if #available(iOS 17, macOS 14, tvOS 17, watchOS 10, *) {
                                _$observationRegistrar.willSet(self, keyPath: \\\(name).\($0.name))
                                _$observationRegistrar.didSet(self, keyPath: \\\(name).\($0.name))
                            }
                        """
                    }.joined(separator: "\n\t\t"))
                    default: break
                }
                _fireObservers(propertyName: keyPath)
            }
            public static func _nameForKeyPath(_ keyPath: AnyKeyPath) -> String {
                switch keyPath {
                    \(raw: allowedMembers.map {
                        """
                        case \\\(name).\($0.name): "\($0.mappedName ?? $0.name)"
                        """
                    }.joined(separator: "\n\t\t"))
                    case \\\(name).primaryKey: "id"
                    case \\(any Lattice.Model).primaryKey: "id"
                    default: {        
                        let input = String(reflecting: keyPath)
                        let components = input.split(separator: ".")
                        return components.dropFirst().joined(separator: ".")
                    }()
                }
            }
            
            deinit {
                _deregisterFromInstanceRegistry()
            }
            """
        ]
    }
    
    static func expansion(of node: SwiftSyntax.AttributeSyntax,
                          attachedTo declaration: some SwiftSyntax.DeclGroupSyntax,
                          providingExtensionsOf type: some SwiftSyntax.TypeSyntaxProtocol,
                          conformingTo protocols: [SwiftSyntax.TypeSyntax],
                          in context: some SwiftSyntaxMacros.MacroExpansionContext) throws -> [SwiftSyntax.ExtensionDeclSyntax] {
        
        var members = try declaration.memberBlock.members.compactMap(view(for:)).filter {
            !$0.isTransient
        }
        
        // Check for the @Model attribute.
        var isModel = false
        if let structDecl = declaration.as(StructDeclSyntax.self) {
            isModel = structDecl.attributes.contains(where: {
                $0.as(AttributeSyntax.self)?.attributeName == "Model"
            })
        } else if let classDecl = declaration.as(ClassDeclSyntax.self) {
            isModel = classDecl.attributes.contains(where: {
                $0.as(AttributeSyntax.self)?.attributeName == "Model"
            })
        }
        
//        var members = try declaration.memberBlock.members.compactMap(view(for:))
        // Insert an id property if this is a model and it's missing.
        if isModel, !members.contains(where: { $0.name == "id" }) {
            let idMember = MemberView(name: "id",
                                      type: "UUID",
                                      unwrappedType: "UUID",
                                      attributeKey: nil,
                                      assignment: nil,
                                      isComputed: false,
                                      computedBlock: nil)
            members.insert(idMember, at: 0)
        }
        
        // Copy over inherited protocols from the original declaration.
        var inheritedTypes: [InheritedTypeSyntax] = []
        // Always add "Transferable"
        inheritedTypes.append(InheritedTypeSyntax(type: TypeSyntax("Transferable")))
        
        if let inheritanceClause = (declaration.as(StructDeclSyntax.self)?.inheritanceClause ??
                                    declaration.as(ClassDeclSyntax.self)?.inheritanceClause) {
            var typesToCopy: [InheritedTypeSyntax]
            if declaration is ClassDeclSyntax,
               
                !inheritanceClause.inheritedTypes.isEmpty {
                // For classes, assume the first inherited type is the superclass and skip it.
                let inheritedList = inheritanceClause.inheritedTypes
                typesToCopy = Array(inheritedList)
            } else {
                typesToCopy = inheritanceClause.inheritedTypes.map { $0 }
            }
            if let modelIdx = typesToCopy.map(\.description).firstIndex(of: "Model") {
                typesToCopy.remove(at: modelIdx)
            }
            inheritedTypes.append(contentsOf: typesToCopy)
        }
        
        // Gather any "required" initializer declarations from the original type.
        
        // If the declaration is an enum, opt out.
        if declaration is EnumDeclSyntax {
            return []
        }
        // Get full type path for qualifying self-referential types
        let fullTypePath = type.trimmedDescription
        let typeName = if let type = type.as(IdentifierTypeSyntax.self) {
            type.name.text
        } else if let type = type.as(MemberTypeSyntax.self) {
            type.name.text
        } else {
            throw MacroError.message(type.debugDescription)
        }

        // Include globalId first (synthesized by macro), then user-defined properties
        // Filter out globalId from user properties since it's added explicitly
        // Qualify type references to handle nested types (e.g., MigrationV1.Person)
        let userProperties = members.filter { !$0.isComputed }
            .filter { !$0.isTransient && !$0.isRelation }
            .filter { $0.name != "globalId" }
            .map { member in
                let qualifiedType: String
                if isOptionalExistentialString(member.type) {
                    qualifiedType = "VirtualLinkMarker"
                } else {
                    qualifiedType = qualifyTypeReferences(propertyType: member.type, fullTypePath: fullTypePath, simpleTypeName: typeName)
                }
                return "(\"\(member.mappedName ?? member.name)\", \(qualifiedType).self)"
            }
        let modelProperties = (["(\"globalId\", UUID.self)"] + userProperties).joined(separator: ", ")
        let accessors = members.filter { !$0.isComputed }
            .filter { !$0.isTransient && !$0.isRelation }
            .map { "self._\($0.name)Accessor" }
//            .joined(separator: ", ")
        var dtoInheritedTypes = inheritedTypes
        let constraints = members.compactMap {
            $0.constraint
        }.map {
            """
            Constraint(columns: \($0.columns), allowsUpsert: \($0.allowsUpsert))
            """
        }
        if members.compactMap({
            $0.constraint
        }).filter({
            $0.allowsUpsert
        }).count > 1 {
            throw MacroError.message("Only allow one constraint with allowsUpsert set to true.")
        }
        let fullTextNames = members.filter { $0.isFullText && !$0.isComputed }
            .map { "\"\($0.mappedName ?? $0.name)\"" }
        let fullTextSet = fullTextNames.joined(separator: ", ")
        let indexedNames = members.filter { $0.isIndexed && !$0.isComputed }
            .map { "\"\($0.mappedName ?? $0.name)\"" }
        let indexedSet = indexedNames.joined(separator: ", ")
        dtoInheritedTypes.append(InheritedTypeSyntax(type: TypeSyntax("Sendable")))
            return [
                ExtensionDeclSyntax(
                    extendedType: type,
                    inheritanceClause: .init(inheritedTypes: .init(arrayLiteral: InheritedTypeSyntax(type: TypeSyntax("Lattice.Model")))),
                    memberBlock: """
                    {
                        public static var constraints: [Constraint] {
                            [\(raw: constraints.joined(separator: ","))]
                        }
                        public static var entityName: String {
                            "\(raw: typeName)"
                        }

                        public static var properties: [(String, any LatticeSchemaProperty.Type)] {
                            [\(raw: modelProperties)]
                        }

                        public static var fullTextProperties: Set<String> {
                            [\(raw: fullTextSet)]
                        }

                        public static var indexedProperties: Set<String> {
                            [\(raw: indexedSet)]
                        }
                    }
                    """
                ),
                // Observation.Observable conformance is iOS 17+. Adding it
                // per-model behind @available keeps the Model protocol (and thus
                // iOS 15 builds) free of the Observable refinement, while
                // preserving SwiftUI Observation/@Bindable support on iOS 17+.
                DeclSyntax(
                    """
                    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
                    extension \(type.trimmed): Observation.Observable {}
                    """
                ).cast(ExtensionDeclSyntax.self)
            ]
        }
}

class EnumMacro: ExtensionMacro {
    static func expansion(of node: SwiftSyntax.AttributeSyntax, attachedTo declaration: some SwiftSyntax.DeclGroupSyntax, providingExtensionsOf type: some SwiftSyntax.TypeSyntaxProtocol, conformingTo protocols: [SwiftSyntax.TypeSyntax], in context: some SwiftSyntaxMacros.MacroExpansionContext) throws -> [SwiftSyntax.ExtensionDeclSyntax] {
        guard let enumDecl = declaration.as(EnumDeclSyntax.self) else {
            throw MacroError.message("@LatticeEnum can only be applied to enums")
        }

        var firstCaseName: String?
        for member in enumDecl.memberBlock.members {
            if let caseDecl = member.decl.as(EnumCaseDeclSyntax.self),
               let firstElement = caseDecl.elements.first {
                firstCaseName = firstElement.name.text
                break
            }
        }

        guard let caseName = firstCaseName else {
            throw MacroError.message("@LatticeEnum requires at least one case")
        }

        return [
            ExtensionDeclSyntax(
                extendedType: type,
                inheritanceClause: .init(inheritedTypes: .init(arrayLiteral: InheritedTypeSyntax(type: TypeSyntax("LatticeEnum")))),
                memberBlock: """
                {
                    public static var defaultValue: Self { .\(raw: caseName) }
                }
                """
            )
        ]
    }
}

class UnionMacro: ExtensionMacro {
    struct CaseInfo {
        let name: String
        struct Field {
            let label: String   // empty for unlabeled single values
            var typeName: String
        }
        var fields: [Field]
    }

    static func expansion(of node: AttributeSyntax, attachedTo declaration: some DeclGroupSyntax,
                           providingExtensionsOf type: some TypeSyntaxProtocol,
                           conformingTo protocols: [TypeSyntax],
                           in context: some MacroExpansionContext) throws -> [ExtensionDeclSyntax] {
        guard let enumDecl = declaration.as(EnumDeclSyntax.self) else {
            throw MacroError.message("@Union can only be applied to enums")
        }

        // Gather all cases
        var cases: [CaseInfo] = []
        for member in enumDecl.memberBlock.members {
            guard let caseDecl = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
            for element in caseDecl.elements {
                let caseName = element.name.text
                var fields: [CaseInfo.Field] = []
                if let params = element.parameterClause?.parameters {
                    for param in params {
                        let typeStr = param.type.trimmedDescription
                        // v1 validation: reject unsupported types
                        if typeStr.hasPrefix("List<") || typeStr.hasPrefix("[") ||
                           typeStr.hasPrefix("Vector<") {
                            throw MacroError.message("@Union cases cannot contain List, Array, or Vector types (case '\(caseName)')")
                        }
                        let label = param.firstName?.text ?? ""
                        fields.append(.init(label: label, typeName: typeStr))
                    }
                }
                cases.append(.init(name: caseName, fields: fields))
            }
        }

        guard !cases.isEmpty else {
            throw MacroError.message("@Union requires at least one case")
        }

        let fullTypeName = type.trimmedDescription
        let simpleTypeName = fullTypeName.split(separator: ".").last.map(String.init) ?? fullTypeName
        let tableName = "_\(simpleTypeName)"


        // Generate defaultValue from first case
        let firstCase = cases[0]
        let defaultExpr: String
        if firstCase.fields.isEmpty {
            defaultExpr = ".\(firstCase.name)"
        } else {
            let args = firstCase.fields.map { field in
                if field.label.isEmpty {
                    return ".defaultValue"
                } else {
                    return "\(field.label): .defaultValue"
                }
            }.joined(separator: ", ")
            defaultExpr = ".\(firstCase.name)(\(args))"
        }

        // Generate unionCases
        let casesArray = cases.map { c in
            let fieldsArray = c.fields.map { f in
                "(label: \"\(f.label)\", type: \(f.typeName).self)"
            }.joined(separator: ", ")
            return "UnionCaseDescriptor(name: \"\(c.name)\", fields: [\(fieldsArray)])"
        }.joined(separator: ",\n                ")

        // Generate _toCxxUnionValue
        var encodeCases: [String] = []
        for c in cases {
            if c.fields.isEmpty {
                encodeCases.append("""
                    case .\(c.name):
                        uv.case_name = std.string("\(c.name)")
                """)
            } else {
                let bindings = c.fields.enumerated().map { i, f in
                    f.label.isEmpty ? "let _\(i)" : "let \(f.label)"
                }.joined(separator: ", ")
                var setters: [String] = []
                for (i, f) in c.fields.enumerated() {
                    let varName = f.label.isEmpty ? "_\(i)" : f.label
                    let key = f.label.isEmpty ? "_\(i)" : f.label
                    setters.append("                    \(f.typeName).setField(on: &uv, named: \"\(key)\", \(varName))")
                }
                encodeCases.append("""
                    case .\(c.name)(\(bindings)):
                        uv.case_name = std.string("\(c.name)")
                \(setters.joined(separator: "\n"))
                """)
            }
        }

        // Generate _fromCxxUnionValue
        var decodeCases: [String] = []
        for c in cases {
            if c.fields.isEmpty {
                decodeCases.append("""
                        case "\(c.name)": return .\(c.name)
                """)
            } else {
                let args = c.fields.enumerated().map { i, f in
                    let key = f.label.isEmpty ? "_\(i)" : f.label
                    let argLabel = f.label.isEmpty ? "" : "\(f.label): "
                    return "\(argLabel)\(f.typeName).getField(from: value, named: \"\(key)\")"
                }.joined(separator: ",\n                        ")
                decodeCases.append("""
                        case "\(c.name)": return .\(c.name)(
                            \(args))
                """)
            }
        }

        // Generate query enum cases
        var queryEnumCases: [String] = []
        for c in cases {
            if c.fields.isEmpty {
                // Bare case — include in query enum without associated values
                queryEnumCases.append("case \(c.name)")
            } else if c.fields.count == 1 && c.fields[0].label.isEmpty {
                // Single unlabeled: case dog(Query<Type>)
                queryEnumCases.append("case \(c.name)(Query<\(c.fields[0].typeName)>)")
            } else {
                // Multi/labeled: case note(name: Query<String>, date: Query<Int>)
                let params = c.fields.map { f in
                    "\(f.label): Query<\(f.typeName)>"
                }.joined(separator: ", ")
                queryEnumCases.append("case \(c.name)(\(params))")
            }
        }
        queryEnumCases.append("case _empty")

        // Generate _makeQueryVariants
        var variantEntries: [String] = []
        for c in cases {
            if c.fields.isEmpty { continue }
            if c.fields.count == 1 && c.fields[0].label.isEmpty {
                // Single unlabeled: column = caseName
                variantEntries.append("""
                            ("\(c.name)", .\(c.name)(._column( "\(c.name)")))
                """)
            } else {
                let args = c.fields.map { f in
                    let colName = "\(c.name)__\(f.label)"
                    return "\(f.label): ._column(\"\(colName)\")"
                }.joined(separator: ", ")
                variantEntries.append("""
                            ("\(c.name)", .\(c.name)(\(args)))
                """)
            }
        }

        let queryEnumName = "\(simpleTypeName)_Query"

        return [
            ExtensionDeclSyntax(
                extendedType: type,
                inheritanceClause: .init(inheritedTypes: .init(arrayLiteral:
                    InheritedTypeSyntax(type: TypeSyntax("LatticeUnion"))
                )),
                memberBlock: """
                {
                    public static var unionTableName: String { "\(raw: tableName)" }

                    public static var unionCases: [UnionCaseDescriptor] {
                        [\(raw: casesArray)]
                    }

                    public static var defaultValue: Self { \(raw: defaultExpr) }

                    public enum \(raw: queryEnumName): _LatticeUnionQueryEnum {
                        \(raw: queryEnumCases.joined(separator: "\n            "))

                        public init() { self = ._empty }
                    }

                    public typealias QueryEnum = \(raw: queryEnumName)

                    public static func _makeQueryVariants(parentKeyPath: [String]) -> [(caseName: String, variant: \(raw: queryEnumName))] {
                        [
                \(raw: variantEntries.joined(separator: ",\n"))
                        ]
                    }

                    public func _toCxxUnionValue() -> lattice.union_value {
                        var uv = lattice.union_value()
                        switch self {
                \(raw: encodeCases.joined(separator: "\n"))
                        }
                        return uv
                    }

                    public static func _fromCxxUnionValue(_ value: lattice.union_value) -> Self {
                        let caseName = String(value.case_name)
                        switch caseName {
                \(raw: decodeCases.joined(separator: "\n"))
                        default: return .defaultValue
                        }
                    }
                }
                """
            )
        ]
    }
}

class EmbeddedModelMacro: MemberMacro {
    static func expansion(of node: AttributeSyntax, providingMembersOf declaration: some DeclGroupSyntax, in context: some MacroExpansionContext) throws -> [DeclSyntax] {
        []
    }
}

class VirtualModelMacro: ExtensionMacro {
    static func expansion(of node: AttributeSyntax, attachedTo declaration: some DeclGroupSyntax, providingExtensionsOf type: some TypeSyntaxProtocol, conformingTo protocols: [TypeSyntax], in context: some MacroExpansionContext) throws -> [ExtensionDeclSyntax] {
        guard declaration.is(ProtocolDeclSyntax.self) else {
            throw MacroError.message("Expected a protocol declaration")
        }
        // Intentionally emits nothing. The macro used to emit an
        // `extension _Query` with a per-protocol dynamicMember subscript, but
        // SE-0402 extension macros attach their extensions to the ANNOTATED
        // type — the emission became `extension <Protocol> { … Self.T … }`,
        // which never compiled for any consumer. The generic `_Query`
        // dynamicMember subscripts in VirtualModel.swift (routing through the
        // `_virtualMember` witness, iOS-15-safe) already provide the intended
        // behavior for every `VirtualModel`-conforming protocol, annotated or
        // not. The attribute is kept as a harmless marker for source
        // compatibility.
        return []
    }
}

@main
struct LatticeMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        ModelMacro.self, TransientMacro.self, PropertyMacro.self,
//        LatticeMemberMacro.self,
        UniqueMacro.self, CodableMacro.self, EnumMacro.self, UnionMacro.self, EmbeddedModelMacro.self,
        VirtualModelMacro.self, FullTextMacro.self, IndexedMacro.self,
        VirtualLinkPropertyMacro.self, CodingKeyMacro.self, CodableIgnoredMacro.self
    ]
}
