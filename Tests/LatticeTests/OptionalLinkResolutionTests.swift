import Foundation
import Testing
@testable import Lattice

@Model private final class OptionalLinkChild {
    var name: String = ""
}

@Model private final class OptionalLinkParent {
    var child: OptionalLinkChild?
    var note: String?
}

@Suite("Optional link resolution", .serialized)
struct OptionalLinkResolutionTests {
    private func withStore(_ body: (Lattice, Lattice.Configuration) throws -> Void) throws {
        let configuration = Lattice.Configuration(fileURL: testTemporaryDirectory
            .appendingPathComponent("optional-link-\(UUID().uuidString).sqlite"))
        let store = try Lattice(OptionalLinkParent.self, OptionalLinkChild.self,
                                configuration: configuration)
        defer { store.close(); try? Lattice.delete(for: configuration) }
        try body(store, configuration)
    }

    private func addPair(to store: Lattice) throws -> (OptionalLinkParent, OptionalLinkChild) {
        let child = OptionalLinkChild()
        child.name = "linked value"
        let parent = OptionalLinkParent()
        parent.child = child
        parent.note = "primitive value"
        try store.add(child)
        try store.add(parent)
        return (parent, child)
    }

    @Test func remoteTargetDeletionLeavesAnAbsentTypedLink() throws {
        try withStore { store, _ in
            let (parent, child) = try addPair(to: store)
            #expect(parent.child?.name == "linked value")
            let childID = try #require(child.globalId)
            let eventID = UUID()
            let frame = try JSONSerialization.data(withJSONObject: [
                "kind": "auditLog",
                "auditLog": [[
                    "globalId": eventID.uuidString,
                    "globalRowId": childID.uuidString,
                    "tableName": "OptionalLinkChild",
                    "operation": "DELETE",
                    "rowId": 1,
                    "changedFields": [String: Any](),
                    "changedFieldsNames": [String](),
                    "timestamp": "2026-11-01T00:00:00Z"
                ]]
            ])
            #expect(try store.receive(frame) == [eventID])
            #expect(store.objects(OptionalLinkChild.self).count == 0)
            // Remote row deletion does not cascade the incoming junction.
            #expect(parent._dynamicObject._ref.hasValue(named: "child"))
            let resolved = parent.child
            #expect(resolved == nil)
            #expect(resolved?.name == nil)
            #expect(parent.note == "primitive value")
        }
    }

    @Test func anUnlinkBetweenPresenceAndResolutionReturnsNil() throws {
        try withStore { store, configuration in
            let (parent, _) = try addPair(to: store)
            let other = try Lattice(independentFor: [OptionalLinkParent.self, OptionalLinkChild.self],
                                    configuration: configuration)
            defer { other.close() }
            #expect(store.backend.identityHash != other.backend.identityHash)
            let otherParent = try #require(other.objects(OptionalLinkParent.self).first)
            let backend = UnlinkAfterPresenceBackend(base: parent._dynamicObject._ref) {
                otherParent.child = nil
            }
            parent._dynamicObject._ref = backend

            // The real second connection commits after the presence read,
            // before the first connection resolves the same link.
            let resolved = parent.child
            #expect(backend.observedPresent)
            #expect(backend.unlinkCount == 1)
            #expect(backend.resolutionCount == 1)
            #expect(otherParent.child == nil)
            #expect(resolved == nil)
            #expect(resolved?.name == nil)
        }
    }

    @Test func aStagedUnmanagedChildRemainsReadableBeforeAndAfterInsertion() throws {
        try withStore { store, _ in
            let child = OptionalLinkChild()
            child.name = "staged value"
            let parent = OptionalLinkParent()
            parent.child = child
            #expect(!parent.isManaged)
            #expect(parent.child != nil)
            #expect(parent.child?.isManaged == false)
            #expect(parent.child?.name == "staged value")
            try store.add(parent)
            #expect(parent.isManaged)
            #expect(parent.child?.isManaged == true)
            #expect(parent.child?.name == "staged value")
        }
    }
}

// Forward every operation to a real store. Intercept only the gap between
// presence and resolution, avoiding sleeps or a probabilistic thread race.
private final class UnlinkAfterPresenceBackend: ObjectBackend, @unchecked Sendable {
    let base: any ObjectBackend
    private var unlink: (() -> Void)?
    private(set) var observedPresent = false
    private(set) var unlinkCount = 0
    private(set) var resolutionCount = 0

    init(base: any ObjectBackend, unlink: @escaping () -> Void) {
        self.base = base
        self.unlink = unlink
    }

    var tableName: String { base.tableName }
    var lattice: (any LatticeBackend)? { base.lattice }
    var hasLattice: Bool { base.hasLattice }
    func hasValue(named name: String) -> Bool {
        let present = base.hasValue(named: name)
        if name == "child", let unlink {
            self.unlink = nil
            observedPresent = present
            unlinkCount += 1
            unlink()
        }
        return present
    }
    func getObject(named name: String) -> any ObjectBackend {
        if name == "child" { resolutionCount += 1 }
        return base.getObject(named: name)
    }
    func setNull(named name: String) { base.setNull(named: name) }
    func getInt(named name: String) -> Int64 { base.getInt(named: name) }
    func getDouble(named name: String) -> Double { base.getDouble(named: name) }
    func getFloat(named name: String) -> Float { base.getFloat(named: name) }
    func getBool(named name: String) -> Bool { base.getBool(named: name) }
    func getString(named name: String) -> String { base.getString(named: name) }
    func getData(named name: String) -> Data { base.getData(named: name) }
    func setInt(named name: String, _ value: Int64) { base.setInt(named: name, value) }
    func setDouble(named name: String, _ value: Double) { base.setDouble(named: name, value) }
    func setFloat(named name: String, _ value: Float) { base.setFloat(named: name, value) }
    func setBool(named name: String, _ value: Bool) { base.setBool(named: name, value) }
    func setString(named name: String, _ value: String) { base.setString(named: name, value) }
    func setData(named name: String, _ value: Data) { base.setData(named: name, value) }
    func setObject(named name: String, _ value: any ObjectBackend) { base.setObject(named: name, value) }
    func getLinkList(named name: String) -> any ObjectListBackend { base.getLinkList(named: name) }
    func debugDescription() -> String { base.debugDescription() }
}
