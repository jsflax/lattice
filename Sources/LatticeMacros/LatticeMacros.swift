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
    let type: String
    var attributeKey: String?
    var isTransient: Bool {
        attributeKey == "@Transient"
    }
    var isRelation: Bool {
        attributeKey == "Relation"
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
    let unwrappedType: TypeSyntax
    if let iuo = type.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) {
        unwrappedType = iuo.wrappedType
    } else {
        unwrappedType = type
    }

    var memberView = MemberView(name: "\(identifier.trimmed)", type: unwrappedType.trimmedDescription, attributeKey: nil)

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
                if let arguments = attribute.arguments?.as(LabeledExprListSyntax.self) {
                    var constraint = Constraint(columns: [memberView.name], allowsUpsert: false)
                    
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
                    memberView.constraint = constraint
                }
            } else if memberView.attributeKey == "Property" {
                if let arguments = attribute.arguments?.as(LabeledExprListSyntax.self) {
                    let constraint = Constraint(columns: [memberView.name], allowsUpsert: false)
                    
                    arguments.forEach {
                        if $0.label?.text == "name" {
                            if let strLit = $0.expression.as(StringLiteralExprSyntax.self) {
                                memberView.mappedName = strLit.representedLiteralValue
                            }
                        }
                    }
                    memberView.constraint = constraint
                }
            }
        }
    }
    // Check if this property has an accessorBlock (i.e. it's computed)
    if let accessorBlock = binding.accessorBlock {
        switch accessorBlock.accessors {
        case .accessors(let accessors):
            // Only treat as computed if it has a get/set/didSet/willSet with a body
            // Skip if it's just access level modifiers like private(set)
            let hasComputedAccessor = accessors.contains(where: { accessor in
                let specifier = accessor.accessorSpecifier.text
                return (specifier == "get" || specifier == "set" || specifier == "didSet" || specifier == "willSet")
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
                _$observationRegistrar.access(self, keyPath: \\.\(id.identifier))
                return \(raw: property.type).getField(from: &_dynamicObject, named: "\(raw: property.mappedName ?? property.name)")
            }
            set {
                _$observationRegistrar.withMutation(of: self, keyPath: \\.\(id.identifier)) {
                    \(raw: property.type).setField(on: &_dynamicObject, named: "\(raw: property.mappedName ?? property.name)", newValue)
                }
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
            !$0.isTransient && !$0.isComputed
        }
        
        return [
            """
            enum CodingKeys: String, CodingKey {
                \(raw: members.map { member in
                    """
                    case \(member.name) = "\(member.mappedName ?? member.name)"
                    """
                }.joined(separator: "\n\t\t"))
                case __globalId = "globalId"
            }

            public required init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.__globalId = try container.decode(UUID.self, forKey: .__globalId)
                \(raw: members.map { member in
                    """
                    self.\(member.name) = try container.decode(\(member.type).self, forKey: .\(member.name))
                    """
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
            if let simpleAttr = attr.as(AttributeSyntax.self),
               simpleAttr.attributeName.description.trimmingCharacters(in: .whitespacesAndNewlines) == "Property"
                || simpleAttr.attributeName.description.trimmingCharacters(in: .whitespacesAndNewlines) == "Transient" ||
                simpleAttr.attributeName.as(IdentifierTypeSyntax.self)?.name.text == "Relation" {
                // Already has @Property or is ignored as @Transient; do nothing.
                return []
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

                    // Otherwise check if it's computed
                    let hasComputedAccessor = accessors.contains(where: { accessor in
                        let specifier = accessor.accessorSpecifier.text
                        return (specifier == "get" || specifier == "set" || specifier == "didSet" || specifier == "willSet")
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
                    "_\(member.name)Accessor = .init(columnId: \(idx + 1), name: \"\(member.name)\", unmanagedValue: \(assignment))"
                } else {
                    "_\(member.name)Accessor = .init(columnId: \(idx + 1), name: \"\(member.name)\")"
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
            public var lattice: Lattice?
            @Property(name: "id")
            public var primaryKey: Int64?
            private var isolation: (any Actor)?
            public var _objectWillChange: ObservableObjectPublisher = .init()
            
            public var _dynamicObject: CxxDynamicObjectRef = {
                var obj = CxxDynamicObjectRef.wrap(_defaultCxxLatticeObject(\(name.trimmed).self).make_shared())!
                \(raw: allowedMembers.filter { $0.assignment != nil }.map { "\($0.type).setField(on: &obj, named: \"\($0.mappedName ?? $0.name)\", \($0.assignment ?? ".defaultValue"))" }.joined(separator: "\n\t\t"))
                return obj
            }()
            
            public required init(isolation: isolated (any Actor)? = #isolation) {
                self.isolation = isolation
                // self._dynamicObject = _defaultCxxLatticeObject(\(name.trimmed).self)
                
            }
            private struct __GlobalIdName: StaticString { static var string: String { "globalId" } }
            private struct __GlobalIdKey: StaticInt32 { static var int32: Int32 { 1 } }
            
            @Property(name: "globalId")
            public var __globalId: UUID?
            
            public let _$observationRegistrar = Observation.ObservationRegistrar()
            public var _lastKeyPathUsed: String?
            
            internal nonisolated func access<_M>(
                keyPath: KeyPath<\(name), _M>
            ) {
              _$observationRegistrar.access(self, keyPath: keyPath)
            }

            internal nonisolated func withMutation<_M, _MR>(
              keyPath: KeyPath<\(name), _M>,
              _ mutation: () throws -> _MR
            ) rethrows -> _MR {
              try _$observationRegistrar.withMutation(of: self, keyPath: keyPath, mutation)
            }
            
            public func _objectWillChange_send() { _objectWillChange.send() } 
            
            public func _triggerObservers_send(keyPath: String) {
                switch keyPath {
                    \(raw: allowedMembers.map {
                        """
                        case "\($0.name)": _$observationRegistrar.willSet(self, keyPath: \\\(name).\($0.name))
                        """
                    }.joined(separator: "\n\t\t"))
                    default: print("❌ Could not send key path \\(keyPath) to observer"); break
                }
            }
            public static func _nameForKeyPath(_ keyPath: AnyKeyPath) -> String {
                switch keyPath {
                    \(raw: allowedMembers.map {
                        """
                        case \\\(name).\($0.name): "\($0.name)"
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
            
            // deinit {           
            //    self.primaryKey.map { id in
            //        lattice?.dbPtr.removeModelObserver(tableName: Self.entityName, primaryKey: id)
            //    }
            // }
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
                let qualifiedType = qualifyTypeReferences(propertyType: member.type, fullTypePath: fullTypePath, simpleTypeName: typeName)
                return "(\"\(member.name)\", \(qualifiedType).self)"
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
        dtoInheritedTypes.append(InheritedTypeSyntax(type: TypeSyntax("Sendable")))
            return [
                ExtensionDeclSyntax(
                    extendedType: type,
                    inheritanceClause: .init(inheritedTypes: .init(arrayLiteral: InheritedTypeSyntax(type: TypeSyntax("Lattice.Model")))),
                    memberBlock: """
                    {
                        public typealias CxxManagedSpecialization = CxxManagedModel
                    
                        public static var constraints: [Constraint] {
                            [\(raw: constraints.joined(separator: ","))]
                        }
                        public static var entityName: String {
                            "\(raw: typeName)"
                        }

                        public static var properties: [(String, any LatticeSchemaProperty.Type)] {
                            [\(raw: modelProperties)]
                        }

                        public static func fromCxxValue(_ value: CxxManagedSpecialization.SwiftType) -> Self {
                            fatalError()
                        }
                    
                        public static func getManaged(from object: CxxManagedLatticeObject, name: std.string) -> CxxManagedSpecialization {
                            fatalError()
                            // object.get_managed_field(name)
                        }
                        public static func getManagedOptional(from object: CxxManagedLatticeObject, name: std.string) -> CxxManagedSpecialization.OptionalType {
                            object.get_managed_field(name)
                        }
                    }
                    """
                )
            ]
        }
}

class EnumMacro: ExtensionMacro {
    static func expansion(of node: SwiftSyntax.AttributeSyntax, attachedTo declaration: some SwiftSyntax.DeclGroupSyntax, providingExtensionsOf type: some SwiftSyntax.TypeSyntaxProtocol, conformingTo protocols: [SwiftSyntax.TypeSyntax], in context: some SwiftSyntaxMacros.MacroExpansionContext) throws -> [SwiftSyntax.ExtensionDeclSyntax] {
        return [
            ExtensionDeclSyntax(
                extendedType: type,
                inheritanceClause: .init(inheritedTypes: .init(arrayLiteral: InheritedTypeSyntax(type: TypeSyntax("LatticeEnum")))),
                memberBlock: """
                {
                    public typealias CxxManagedSpecialization = RawValue.CxxManagedSpecialization

                    public static func fromCxxValue(_ value: CxxManagedSpecialization.SwiftType) -> Self {
                        fatalError()
                    }
                
                    public static func getManaged(from object: CxxManagedLatticeObject, name: std.string) -> CxxManagedSpecialization {
                        object.get_managed_field(name)
                    }
                
                    public static func getManagedOptional(from object: CxxManagedLatticeObject, name: std.string) -> CxxManagedSpecialization.OptionalType {
                        object.get_managed_field(name)
                    }
                }
                """
            )
        ]
    }
}

class EmbeddedModelMacro: MemberMacro {
    static func expansion(of node: AttributeSyntax, providingMembersOf declaration: some DeclGroupSyntax, in context: some MacroExpansionContext) throws -> [DeclSyntax] {
        [
            """
            public typealias CxxManagedSpecialization = RawValue.CxxManagedSpecialization

            public static func fromCxxValue(_ value: CxxManagedSpecialization.SwiftType) -> Self {
                fatalError()
            }
            
            public static func getManaged(from object: CxxManagedLatticeObject, name: std.string) -> CxxManagedSpecialization {
                object.get_managed_field(name)
            }
            
            public static func getManagedOptional(from object: CxxManagedLatticeObject, name: std.string) -> CxxManagedSpecialization.OptionalType {
                object.get_managed_field(name)
            }
            """
        ]
    }
}

class VirtualModelMacro: ExtensionMacro {
    static func expansion(of node: AttributeSyntax, attachedTo declaration: some DeclGroupSyntax, providingExtensionsOf type: some TypeSyntaxProtocol, conformingTo protocols: [TypeSyntax], in context: some MacroExpansionContext) throws -> [ExtensionDeclSyntax] {
        guard let protocolDecl = declaration.as(ProtocolDeclSyntax.self) else {
            throw MacroError.message("Expected a protocol declaration")
        }
        return [
            ExtensionDeclSyntax(
                extendedType: TypeSyntax(stringLiteral: "_Query"),
                memberBlock: """
                {
                    typealias M = Self.T
                    public subscript<V>(dynamicMember member: KeyPath<Self.T, V>) -> Query<V> where Self.T == any \(protocolDecl.name) {
                        // not the best hack to get around witness tables
                        if let self = self as? Query<T> {
                            return self[dynamicMember: member]
                        } else if let self = self as? any VirtualQuery<T> {
                            return self[dynamicMember: member]
                        }
                        else {
                            fatalError()
                        }
                    }
                }
                """
            )
        ]
    }
}

@main
struct LatticeMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        ModelMacro.self, TransientMacro.self, PropertyMacro.self,
//        LatticeMemberMacro.self,
        UniqueMacro.self, CodableMacro.self, EnumMacro.self, EmbeddedModelMacro.self,
        VirtualModelMacro.self
    ]
}
