import Foundation
import Testing
import Lattice

// Declaration metadata must not take the model-construction/default-value path.
private func authoredInitializerMustNotRun() -> String {
    fatalError("Reading authored metadata evaluated a user initializer")
}

@LatticeEnum enum AuthoredMetadataMode: String {
    case ready
    static var computed: Self { fatalError("Symbolic metadata evaluated a property") }
}

@Union enum AuthoredMetadataAction {
    case noop
    case text(value: String)
    static var computed: Self { fatalError("Union metadata evaluated a property") }
}

@Model final class AuthoredMetadataProbe {
    @Property(name: "mapped_value") var mapped: Int64 = 9_007_199_254_740_993
    var minimum: Int64 = -9_223_372_036_854_775_808
    var narrow: Int = -0x7f
    var negativeZero: Float = -0.0
    var hexadecimal: Double = 0x1.fp-3
    var integerFloat: Double = 1
    var enabled: Bool = true
    var text: String = "line\n\"quoted\""
    var absent: String?
    var explicitNil: String? = nil
    var identifier: UUID = UUID()
    var created: Date = Date()
    var arbitrary: String = authoredInitializerMustNotRun()
    var interpolation: String = "value: \(authoredInitializerMustNotRun())"
    var collection: [String] = []
    var mode: AuthoredMetadataMode = .ready
    var computedMode: AuthoredMetadataMode = .computed
    var action: AuthoredMetadataAction = .noop
    var qualifiedAction: AuthoredMetadataAction = AuthoredMetadataAction.noop
    var payload: AuthoredMetadataAction = .text(value: "hello")
    var computedAction: AuthoredMetadataAction = .computed
    @Transient var scratch: String = "not persisted"
    var computed: String { "not persisted" }
}

/// Deliberately manual/old-style Model conformance: no new metadata witness.
/// Instance-only requirements trap, proving the default witness needs no value.
private final class ManualInitializerMetadataModel: Model {
    init(isolation: isolated (any Actor)?) { fatalError("Manual model instantiated") }
    static var entityName: String { "ManualInitializerMetadataModel" }
    static var properties: [(String, any LatticeSchemaProperty.Type)] { [("value", String.self)] }
    static var constraints: [Constraint] { [] }
    static func _nameForKeyPath(_ keyPath: AnyKeyPath) -> String { fatalError() }
    var primaryKey: Int64?
    var globalId: UUID? { nil }
    var _lastKeyPathUsed: String?
    var _instanceObservers: [_ModelObserver] = []
    var _dynamicObject: ModelStorage {
        get { fatalError("Metadata read model storage") }
        set { fatalError("Metadata wrote model storage") }
    }
    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    var _$observationRegistrar: Observation.ObservationRegistrar { fatalError() }
    #if canImport(Combine)
    var _objectWillChange: Combine.ObservableObjectPublisher { fatalError() }
    #else
    var _objectWillChange: ObservableObjectPublisher { fatalError() }
    #endif
    func _objectWillChange_send() { fatalError() }
    func _triggerObservers_send(keyPath: String) { fatalError() }
}

@Suite("Authored initializer metadata")
struct AuthoredInitializerMetadataTests {
    @Test func exactStoredCoverageUsesMappedNames() throws {
        let metadata = try AuthoredMetadataProbe.validatedAuthoredInitializers()
        let entries = try #require(metadata)
        let expected = AuthoredMetadataProbe.properties.map(\.0).filter { $0 != "id" && $0 != "globalId" }
        #expect(entries.map(\.name) == expected)
        #expect(entries.count == 21)
        #expect(entries.contains { $0.name == "mapped_value" && $0.declaredType == "Int64" })
        #expect(!entries.contains { ["id", "globalId", "mapped", "scratch", "computed"].contains($0.name) })
    }

    @Test func literalSpellingPreservesWidthLargeIntegersAndNegativeZero() throws {
        let metadata = try AuthoredMetadataProbe.validatedAuthoredInitializers()
        let entries = try #require(metadata)
        let values = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0.initializer) })
        #expect(values["mapped_value"] == .literal(.integer(swift: "9_007_199_254_740_993")))
        #expect(values["minimum"] == .literal(.integer(swift: "-9_223_372_036_854_775_808")))
        #expect(values["narrow"] == .literal(.integer(swift: "-0x7f")))
        #expect(entries.first { $0.name == "narrow" }?.declaredType == "Int")
        // Int8 has no current model storage accessor; its metadata classifier remains testable without a value.
        #expect(AuthoredInitializer._literal(.integer(swift: "-0x7f"), type: Int8.self, source: "-0x7f")
            == .literal(.integer(swift: "-0x7f")))
        #expect(values["negativeZero"] == .literal(.floatingPoint(swift: "-0.0")))
        #expect(entries.first { $0.name == "negativeZero" }?.declaredType == "Float")
        #expect(values["hexadecimal"] == .literal(.floatingPoint(swift: "0x1.fp-3")))
        #expect(values["integerFloat"] == .literal(.floatingPoint(swift: "1")))
        #expect(values["enabled"] == .literal(.boolean(true)))
        #expect(values["text"] == .literal(.string("line\n\"quoted\"")))
    }

    @Test func absentNilAndDynamicDoNotEvaluateAnyInitializer() throws {
        // The fixture's arbitrary and interpolated initializers trap if invoked.
        // UUID/Date remain syntax and repeated reads cannot generate fresh values.
        let first = AuthoredMetadataProbe.authoredInitializers
        #expect(first == AuthoredMetadataProbe.authoredInitializers)
        let metadata = try AuthoredMetadataProbe.validatedAuthoredInitializers()
        let entries = try #require(metadata)
        let values = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0.initializer) })
        #expect(values["absent"] == .absent)
        #expect(values["explicitNil"] == .literal(.nilLiteral))
        #expect(values["identifier"] == .dynamic(source: "UUID()"))
        #expect(values["created"] == .dynamic(source: "Date()"))
        #expect(values["arbitrary"] == .dynamic(source: "authoredInitializerMustNotRun()"))
        #expect(values["interpolation"] == .dynamic(source: #""value: \(authoredInitializerMustNotRun())""#))
        #expect(values["collection"] == .dynamic(source: "[]"))
    }

    @Test func symbolicMembersRequireExistingZeroPayloadCaseDescriptor() throws {
        let metadata = try AuthoredMetadataProbe.validatedAuthoredInitializers()
        let entries = try #require(metadata)
        let values = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0.initializer) })
        #expect(values["action"] == .literal(.unionCase(name: "noop")))
        #expect(values["qualifiedAction"] == .literal(.unionCase(name: "noop")))
        #expect(values["payload"] == .dynamic(source: ".text(value: \"hello\")"))
        #expect(values["computedAction"] == .dynamic(source: ".computed"))
        #expect(values["mode"] == .dynamic(source: ".ready"))
        #expect(values["computedMode"] == .dynamic(source: ".computed"))
    }

    @Test func manualModelDefaultIsUnavailableNotAbsent() throws {
        #expect(ManualInitializerMetadataModel.authoredInitializers == .unavailable)
        let unavailable = try ManualInitializerMetadataModel.validatedAuthoredInitializers()
        #expect(unavailable == nil)
        let empty = try AuthoredInitializers.available([]).validated(propertyNames: [])
        #expect(empty == [])
    }

    @Test func exporterCoverageRejectsMissingExtraAndDuplicateNames() throws {
        let entry = AuthoredPropertyInitializer(name: "value", declaredType: "String", initializer: .absent)
        #expect(throws: AuthoredInitializerMetadataError.coverageMismatch(expected: ["value"], actual: [])) {
            try AuthoredInitializers.available([]).validated(propertyNames: ["value"])
        }
        #expect(throws: AuthoredInitializerMetadataError.coverageMismatch(expected: [], actual: ["value"])) {
            try AuthoredInitializers.available([entry]).validated(propertyNames: [])
        }
        #expect(throws: AuthoredInitializerMetadataError.duplicateProperty("value")) {
            try AuthoredInitializers.available([entry, entry]).validated(propertyNames: ["value"])
        }
        #expect(throws: AuthoredInitializerMetadataError.duplicateProperty("value")) {
            try AuthoredInitializers.available([entry]).validated(propertyNames: ["value", "value"])
        }
    }

    @Test func existingDetachedMetadataKeepsCreationAndStorageSeparate() throws {
        let metadata = try DPerson.validatedAuthoredInitializers()
        let entries = try #require(metadata)
        let values = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0.initializer) })
        #expect(values["name"] == .literal(.string("")))
        #expect(values["age"] == .literal(.integer(swift: "0")))
        #expect(values["nickname"] == .literal(.nilLiteral))
        #expect(values["dog"] == .absent)
        #expect(values["dogs"] == .dynamic(source: ".init()"))
        #expect(values["tags"] == .dynamic(source: "[]"))
    }
}

// MARK: - Fixtures (top-level so sibling links don't need namespace qualification)

@Model @Detached
final class DDog {
    var name: String = ""
    var owner: DPerson?     // back-edge → used for cycle tests
    var buddy: DDog?        // self-link → used for depth/fan-out tests
}

@Model @Detached
final class DPerson {
    var name: String = ""
    var age: Int = 0
    var nickname: String? = nil
    var tags: [String] = []
    var dog: DDog?
    var dogs: List<DDog> = .init()
}

@Suite("@Detached")
final class DetachedTests: BaseTest {

    // 1. Scalars/value-arrays mirror exactly and are a true value copy.
    @Test func valueCopyIsIndependentOfLaterMutation() throws {
        let lattice = try testLattice(DPerson.self, DDog.self)
        let p = DPerson()
        p.name = "Ada"; p.age = 36; p.nickname = "A"; p.tags = ["x", "y"]
        try lattice.add(p)

        let snap = p.detached()
        #expect(snap.name == "Ada")
        #expect(snap.age == 36)
        #expect(snap.nickname == "A")
        #expect(snap.tags == ["x", "y"])
        #expect(snap.globalId == p.globalId)

        // Mutating the live model must not change the detached value.
        p.name = "Grace"; p.age = 0; p.tags = []
        #expect(snap.name == "Ada")
        #expect(snap.age == 36)
        #expect(snap.tags == ["x", "y"])
    }

    @Test func optionalScalarNilVsSet() throws {
        let lattice = try testLattice(DPerson.self, DDog.self)
        let p = DPerson(); p.name = "NoNick"
        try lattice.add(p)
        #expect(p.detached().nickname == nil)

        p.nickname = "Set"
        #expect(p.detached().nickname == "Set")
    }

    // 2. To-one + to-many expand within depth.
    @Test func toOneAndToManyExpand() throws {
        let lattice = try testLattice(DPerson.self, DDog.self)
        let p = DPerson(); p.name = "Ada"; try lattice.add(p)
        let rex = DDog(); rex.name = "Rex"; try lattice.add(rex)
        let fido = DDog(); fido.name = "Fido"; try lattice.add(fido)
        p.dog = rex
        p.dogs.append(rex)
        p.dogs.append(fido)

        let snap = p.detached(maxDepth: 5)
        #expect(snap.dog.value?.name == "Rex")
        #expect(snap.dog.name == "Rex")                       // @dynamicMemberLookup ergonomics
        #expect(snap.dogs.count == 2)
        #expect(snap.dogs.compactMap { $0.value?.name } == ["Rex", "Fido"])
    }

    // 3. At the depth boundary, links drop to nil / empty.
    @Test func depthBoundaryCutsLinks() throws {
        let lattice = try testLattice(DPerson.self, DDog.self)
        let p = DPerson(); p.name = "Ada"; try lattice.add(p)
        let rex = DDog(); rex.name = "Rex"; try lattice.add(rex)
        p.dog = rex
        p.dogs.append(rex)

        let snap = p.detached(maxDepth: 1)
        #expect(snap.name == "Ada")          // self always expands
        #expect(snap.dog.value == nil)        // to-one cut → .none
        #expect(snap.dogs.isEmpty)            // to-many cut → []
    }

    // 3b. Cycles terminate and cut the back-edge.
    @Test func cycleIsCut() throws {
        let lattice = try testLattice(DPerson.self, DDog.self)
        let p = DPerson(); p.name = "Ada"; try lattice.add(p)
        let rex = DDog(); rex.name = "Rex"; try lattice.add(rex)
        p.dog = rex
        rex.owner = p                 // Ada → Rex → Ada cycle

        let snap = p.detached(maxDepth: 10)
        #expect(snap.dog.value?.name == "Rex")
        #expect(snap.dog.value?.owner.value == nil)   // back-edge to Ada cut
    }

    // 3c. A shared node reached twice (diamond, not a cycle) still expands both times.
    @Test func diamondStillExpands() throws {
        let lattice = try testLattice(DPerson.self, DDog.self)
        let p = DPerson(); p.name = "Ada"; try lattice.add(p)
        let rex = DDog(); rex.name = "Rex"; try lattice.add(rex)
        p.dog = rex
        p.dogs.append(rex)            // same Rex via two paths

        let snap = p.detached(maxDepth: 5)
        #expect(snap.dog.value?.name == "Rex")
        #expect(snap.dogs.count == 1)
        #expect(snap.dogs[0].value?.name == "Rex")   // path-set, not global-visited
    }

    // 4. Depth fan-out: every sibling expands to the SAME depth (guards the
    //    order-dependent shallow-cut regression from a shared depth counter).
    @Test func toManySiblingsExpandToEqualDepth() throws {
        let lattice = try testLattice(DPerson.self, DDog.self)
        let p = DPerson(); p.name = "Ada"; try lattice.add(p)
        let d1 = DDog(); d1.name = "D1"; try lattice.add(d1)
        let d2 = DDog(); d2.name = "D2"; try lattice.add(d2)
        let b1 = DDog(); b1.name = "B1"; try lattice.add(b1)
        let b2 = DDog(); b2.name = "B2"; try lattice.add(b2)
        d1.buddy = b1; d2.buddy = b2
        p.dogs.append(d1); p.dogs.append(d2)

        let snap = p.detached(maxDepth: 3)
        #expect(snap.dogs.count == 2)
        #expect(snap.dogs[0].value?.buddy.value?.name == "B1")
        #expect(snap.dogs[1].value?.buddy.value?.name == "B2")   // not cut despite being the 2nd sibling
    }

    // 5. Sendable: a detached value crosses an isolation boundary on its own.
    @Test func detachedValueIsSendableAcrossTask() async throws {
        let lattice = try testLattice(DPerson.self, DDog.self)
        let p = DPerson(); p.name = "Ada"; try lattice.add(p)
        let rex = DDog(); rex.name = "Rex"; try lattice.add(rex)
        p.dog = rex

        let snap = p.detached()
        let pulled = await Task.detached { "\(snap.name)/\(snap.dog.value?.name ?? "-")" }.value
        #expect(pulled == "Ada/Rex")
    }

    // 6. Codable round-trip preserves present/absent links.
    @Test func codableRoundTrip() throws {
        let lattice = try testLattice(DPerson.self, DDog.self)
        let p = DPerson(); p.name = "Ada"; p.tags = ["t1"]; try lattice.add(p)
        let rex = DDog(); rex.name = "Rex"; try lattice.add(rex)
        p.dog = rex
        p.dogs.append(rex)

        let snap = p.detached(maxDepth: 5)
        let data = try JSONEncoder().encode(snap)
        let back = try JSONDecoder().decode(DPerson.Detached.self, from: data)
        #expect(back.name == "Ada")
        #expect(back.tags == ["t1"])
        #expect(back.dog.value?.name == "Rex")
        #expect(back.dog.value?.owner.value == nil)
        #expect(back.dogs.count == 1)
        #expect(back.dogs[0].value?.name == "Rex")
    }

    // 7. detached() defaults to maxDepth: 5.
    @Test func defaultDepthIsFive() throws {
        let lattice = try testLattice(DDog.self, DPerson.self)
        // Build a buddy chain c0 → c1 → … → c6.
        var chain: [DDog] = []
        for i in 0...6 {
            let d = DDog(); d.name = "C\(i)"; try lattice.add(d)
            chain.append(d)
        }
        for i in 0..<6 { chain[i].buddy = chain[i + 1] }

        // Count buddy hops expanded from c0. (Deterministic — avoids comparing
        // raw JSON bytes, whose key order is non-deterministic without .sortedKeys.)
        func expandedHops(_ snap: DDog.Detached) -> Int {
            var depth = 0
            var cur: DDog.Detached? = snap
            while let next = cur?.buddy.value { depth += 1; cur = next }
            return depth
        }

        let viaDefault = expandedHops(chain[0].detached())
        let viaFive = expandedHops(chain[0].detached(maxDepth: 5))
        let viaFour = expandedHops(chain[0].detached(maxDepth: 4))
        #expect(viaDefault == viaFive)   // default param is 5
        #expect(viaFive > viaFour)        // a deeper limit expands more hops
    }
}
