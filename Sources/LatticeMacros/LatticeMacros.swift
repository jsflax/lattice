import SwiftSyntaxMacros
import SwiftCompilerPlugin
import SwiftSyntax
import Foundation

private struct MemberView {
    let name: String
    let type: String
    var attributeKey: String?
    var isTransient: Bool {
        attributeKey == "@Transient"
    }
    var assignment: String?
    var isComputed: Bool = false       // Flag for computed properties
    var computedBlock: String? = nil    // Captures the computed accessor block if present
}

private func view(for member: MemberBlockItemListSyntax.Element) throws -> MemberView? {
    guard let decl = member.decl.as(VariableDeclSyntax.self),
          let binding = decl.bindings.first,
          let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier,
          let type = binding.typeAnnotation?.type else {
        return nil
    }
    
    var memberView = MemberView(name: "\(identifier)", type: "\(type)", attributeKey: nil)

    // Extract attributeKey if available.
    if let attribute = decl.attributes.first?.as(AttributeSyntax.self),
       let firstArgument = attribute.arguments?.as(LabeledExprListSyntax.self)?.first,
       let literal = firstArgument.expression.as(StringLiteralExprSyntax.self) {
        memberView.attributeKey = "\(literal.segments)"
    }

    // Check if this property has an accessorBlock (i.e. it's computed)
    if let accessorBlock = binding.accessorBlock {
        memberView.isComputed = true
        memberView.computedBlock = "\(accessorBlock)"
    } else if let initializerValue = binding.initializer?.value {
        // For stored properties, capture the initializer if present.
        memberView.assignment = "\(initializerValue)"
    }
    
    return memberView
}

enum MacroError: Error {
    case message(String)
}

class TransientMacro: PeerMacro {
    static func expansion(of node: SwiftSyntax.AttributeSyntax, providingPeersOf declaration: some SwiftSyntax.DeclSyntaxProtocol, in context: some SwiftSyntaxMacros.MacroExpansionContext) throws -> [SwiftSyntax.DeclSyntax] {
        []
    }
}

class ModelMacro: MemberMacro, ExtensionMacro, AccessorMacro, MemberAttributeMacro {
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
                || simpleAttr.attributeName.description.trimmingCharacters(in: .whitespacesAndNewlines) == "Transient" {
                // Already has @Property or is ignored as @Transient; do nothing.
                return []
            }
        }
        
        // Optionally, ensure that you only attach to stored properties.
        // For each binding, check if it has an accessor (meaning it might be computed)
        for binding in variableDecl.bindings {
            if binding.accessor != nil {
                // It appears to be a computed property; skip attaching @Property.
                return []
            }
        }
        
        // If all checks pass, then create and return the @Property attribute.
        // You can construct the attribute using SwiftSyntaxBuilder.
        return ["@Property"]
    }
    
    static func expansion(of node: SwiftSyntax.AttributeSyntax,
                          providingAccessorsOf declaration: some SwiftSyntax.DeclSyntaxProtocol,
                          in context: some SwiftSyntaxMacros.MacroExpansionContext) throws -> [SwiftSyntax.AccessorDeclSyntax] {
//        throw MacroError.message("\(declaration.debugDescription)")
        guard let declaration = declaration.as(VariableDeclSyntax.self) else {
            return []
        }
//        /Users/jason/Documents/Zephyr/Tests/ZephyrTests/ZephyrTests.swift:5:5 Message("VariableDeclSyntax\n├─attributes: AttributeListSyntax\n│ ╰─[0]: AttributeSyntax\n│   ├─atSign: atSign\n│   ╰─attributeName: IdentifierTypeSyntax\n│     ╰─name: identifier(\"Property\")\n├─modifiers: DeclModifierListSyntax\n├─bindingSpecifier: keyword(SwiftSyntax.Keyword.var)\n╰─bindings: PatternBindingListSyntax\n  ╰─[0]: PatternBindingSyntax\n    ├─pattern: IdentifierPatternSyntax\n    │ ╰─identifier: identifier(\"name\")\n    ╰─typeAnnotation: TypeAnnotationSyntax\n      ├─colon: colon\n      ╰─type: IdentifierTypeSyntax\n        ╰─name: identifier(\"String\")") (from macro 'Property ')

        guard let binding = declaration.bindings.first,
              let id = binding.pattern.as( IdentifierPatternSyntax.self) else {
            throw MacroError.message("\(declaration.debugDescription)")
        }
//        var members = try declaration.
        
        return [
            """
            get {
                _$observationRegistrar.access(self, keyPath: \\.\(id.identifier))
                return _\(raw: id.identifier)Accessor.value
            }
            set {
                _$observationRegistrar.withMutation(of: self, keyPath: \\.\(id.identifier)) {
                    _\(raw: id.identifier)Accessor.value = newValue
                }
            }
            """
        ]
    }
    
    static func expansion(of node: AttributeSyntax, providingMembersOf declaration: some DeclGroupSyntax, conformingTo protocols: [TypeSyntax], in context: some MacroExpansionContext) throws -> [DeclSyntax] {
        
        // Gather the members defined in the type.
        var members = try declaration.memberBlock.members.compactMap(view(for:))
        
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
            if member.type.starts(with: "[") {
//                throw MacroError.message(member.type)
            }
        }
        // Build the DTO properties (include both computed and stored properties)
        let dtoProperties = members.filter { !$0.isComputed }.map { member in
            "private var _\(member.name)Accessor: Accessor<\(member.type)>"
        }.joined(separator: "\n")
        let defaultInitMapping = members.filter { !$0.isComputed }
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
            \(raw: dtoProperties)
            public var lattice: Lattice?
            public var primaryKey: Int64?
            
            public required init() {
                \(raw: defaultInitMapping)
            }
            
            public let _$observationRegistrar = Observation.ObservationRegistrar()

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
                    \(raw: members.map {
                        """
                        case "\($0.name)": try _$observationRegistrar.willSet(self, keyPath: \\\(name).\($0.name))
                        """
                    }.joined(separator: "\n\t\t"))
                    default: break
                }
            }
            public static func _nameForKeyPath(_ keyPath: AnyKeyPath) -> String {
                switch keyPath {
                    \(raw: members.map {
                        """
                        case \\\(name).\($0.name): "\($0.name)"
                        """
                    }.joined(separator: "\n\t\t"))
                    case \\\(name).primaryKey: "id"
                    case \\(any Model).primaryKey: "id"
                    default: fatalError()
                }
            }
            
            deinit {
                self.primaryKey.map { id in
                    Lattice.observationRegistrar[Self.entityName, default: [:]][id] = nil
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
        
        var members = try declaration.memberBlock.members.compactMap(view(for:))
        
        // Check for the @Model attribute.
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
            .filter { !$0.isTransient }
            .map { "(\"\($0.name)\", \($0.type).self)" }
            .joined(separator: ", ")
        let accessors = members.filter { !$0.isComputed }
            .filter { !$0.isTransient }
            .map { "self._\($0.name)Accessor" }
//            .joined(separator: ", ")
        var dtoInheritedTypes = inheritedTypes
        dtoInheritedTypes.append(InheritedTypeSyntax(type: TypeSyntax("Sendable")))
            return [
                ExtensionDeclSyntax(
                    extendedType: type,
                    inheritanceClause: .init(inheritedTypes: .init(arrayLiteral: InheritedTypeSyntax(type: TypeSyntax("Model")))),
                    memberBlock: """
                    {
                        public static var entityName: String {
                            "\(raw: type)"
                        }
                    
                        public static var properties: [(String, any Property.Type)] {
                            [\(raw: modelProperties)]
                        }
                    
                        public func _assign(lattice: Lattice?, statement: OpaquePointer?) {
                            self.lattice = lattice
                            \(raw: accessors.map({
                                """
                                \($0).lattice = lattice
                                \($0).parent = self
                                """
                            }).joined(separator: "\n\t\t"))
                        }
                    
                        public func _encode(statement: OpaquePointer?) {
                            \(raw: accessors.map({
                                """
                                \($0).encode(to: statement, with: \($0).columnId)
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
        ModelMacro.self, TransientMacro.self
    ]
}
