import SwiftSyntaxMacros
import SwiftCompilerPlugin
import SwiftSyntax
import Foundation
import SwiftSyntaxBuilder   // gives you the convenient factory methods
import SwiftSyntaxMacroExpansion

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
    
    var memberView = MemberView(name: "\(identifier)", type: "\(type)", attributeKey: nil)

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
                    var constraint = Constraint(columns: [memberView.name], allowsUpsert: false)
                    
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
            if accessors.contains(where: {
                $0.accessorSpecifier.text == "get" || $0.accessorSpecifier.text == "set"
            }) {
                memberView.isComputed = true
            }
        case .getter(let getter):
            memberView.isComputed = true
        }
        
        memberView.computedBlock = "\(accessorBlock)"
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

enum MacroError: Error {
    case message(String)
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
                if let isolation = self.isolation {
                    return isolation.assumeIsolated { [_\(raw: id.identifier)Accessor] iso in
                        return _\(raw: id.identifier)Accessor.get()
                    }
                }
                return _\(raw: id.identifier)Accessor.get()
            }
            set {
                _$observationRegistrar.withMutation(of: self, keyPath: \\.\(id.identifier)) {
                    _\(raw: id.identifier)Accessor.set(newValue)
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
                    if accessors.contains(where: {
                        $0.accessorSpecifier.text == "get" || $0.accessorSpecifier.text == "set"
                    }) {
                        return []
                    }
                case .getter(let getter):
                    return []
                }
            }
        }

        // If all checks pass, then create and return the @Property attribute.
        // You can construct the attribute using SwiftSyntaxBuilder.
        return ["@Property"]
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
                private struct \(ssName): StaticString { static var string: String { "\(member.name)" } }
                private struct \(siName): StaticInt32 { static var int32: Int32 { \(idx + 1) } }
                private var _\(member.name)Accessor: Accessor<\(member.type), \(ssName), \(siName)> = .init(columnId: \(idx + 1), name: \"\(member.name)\", unmanagedValue: \(assignment))
                """
            } else {
                return """
                private struct \(ssName): StaticString { static var string: String { "\(member.name)" } }
                private struct \(siName): StaticInt32 { static var int32: Int32 { \(idx + 1) } }
                private var _\(member.name)Accessor: Accessor<\(member.type), \(ssName), \(siName)> = .init(columnId: \(idx + 1), name: \"\(member.name)\")
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
            public var primaryKey: Int64?
            private var isolation: (any Actor)?
            
            public required init(isolation: isolated (any Actor)? = #isolation) {
                self.isolation = isolation
            }
            private struct __GlobalIdName: StaticString { static var string: String { "globalId" } }
            private struct __GlobalIdKey: StaticInt32 { static var int32: Int32 { 1 } }
            private var ___globalIdAccessor: Accessor<UUID, __GlobalIdName, __GlobalIdKey> = .init(columnId: 1, name: \"globalId\", unmanagedValue: UUID())
            @Property(name: "globalId")
            package var __globalId: UUID
            
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
            
            public func _objectWillChange_send() { objectWillChange.send() } 
            
            public func _triggerObservers_send(keyPath: String) {
                switch keyPath {
                    \(raw: allowedMembers.map {
                        """
                        case "\($0.name)": try _$observationRegistrar.willSet(self, keyPath: \\\(name).\($0.name))
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
                    case \\(any Model).primaryKey: "id"
                    default: {        
                        let input = String(reflecting: keyPath)
                        let components = input.split(separator: ".")
                        return components.dropFirst().joined(separator: ".")
                    }()
                }
            }
            
            deinit {           
                self.primaryKey.map { id in
                    lattice?.dbPtr.removeModelObserver(tableName: Self.entityName, primaryKey: id)
                }
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
        let modelProperties = members.filter { !$0.isComputed }
            .filter { !$0.isTransient && !$0.isRelation }
            .map { "(\"\($0.name)\", \($0.type).self)" }
            .joined(separator: ", ")
        let accessors = members.filter { !$0.isComputed }
            .filter { !$0.isTransient && !$0.isRelation }
            .map { "self._\($0.name)Accessor" }
//            .joined(separator: ", ")
        var dtoInheritedTypes = inheritedTypes
        let typeName = if let type = type.as(IdentifierTypeSyntax.self) {
            type.name.text
        } else if let type = type.as(MemberTypeSyntax.self) {
            type.name.text
        } else {
            throw MacroError.message(type.debugDescription)
        }
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
                    inheritanceClause: .init(inheritedTypes: .init(arrayLiteral: InheritedTypeSyntax(type: TypeSyntax("Model")))),
                    memberBlock: """
                    {
                        public static var constraints: [Constraint] {
                            [\(raw: constraints.joined(separator: ","))]
                        }
                        public static var entityName: String {
                            "\(raw: typeName)"
                        }
                    
                        public static var properties: [(String, any Property.Type)] {
                            [\(raw: modelProperties)]
                        }
                    
                        public func _assign(lattice: Lattice?) {
                            self.lattice = lattice
                            self.___globalIdAccessor.lattice = lattice
                            self.___globalIdAccessor.parent = self
                            \(raw: accessors.map({
                                """
                                \($0).lattice = lattice
                                \($0).parent = self
                                """
                            }).joined(separator: "\n\t\t"))
                        }
                    
                        public func _encode(statement: OpaquePointer?) {
                            var columnId = Int32(1)
                            \(raw: accessors.map({
                                """
                                \($0).encode(to: statement, with: &columnId)
                                columnId += 1
                                """
                            }).joined(separator: "\n\t\t"))
                        }
                    
                        public func _didEncode() {
                            \(raw: accessors.map({
                                """
                                \($0)._didEncode(parent: self, lattice: lattice!, primaryKey: primaryKey!) 
                                """
                            }).joined(separator: "\n\t\t"))
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
        UniqueMacro.self, CodableMacro.self
    ]
}
