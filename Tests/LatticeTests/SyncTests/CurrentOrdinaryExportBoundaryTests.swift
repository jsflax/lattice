import Foundation
import Testing
import LatticeSwiftCppBridge
import CxxStdlib
@testable import Lattice

@Suite("Current ordinary export boundary", .serialized)
struct CurrentOrdinaryExportBoundaryTests {
    @Test func defaultNativeValueAndFrameCannotMintAnExport() {
        let value = lattice.ordinary_sync_export_ref()
        #expect(!value.isValid())
        #expect(value.frameCount() == 0)
        let frame = value.frame(0)
        #expect(!frame.isValid())
        #expect(frame.byteCount() == 0)
        #expect(!frame.copyTo(nil, capacity: 0))
    }

    @Test func invalidScopeAndClosedOwnerRefuseNativeCapture() throws {
        let owner = try Lattice(isolation: nil, for: [SimpleSyncObject.self],
                                configuration: .init(storage: .memory()))
        defer { owner.close() }
        #expect(throws: OrdinarySyncExportError.self) {
            try owner.captureOrdinarySyncExport(models: [])
        }
        owner.close()
        var models = lattice.StringVector()
        models.push_back(std.string(SimpleSyncObject.entityName))
        let value = owner.cxxLatticeRef.captureOrdinaryExport(models: models)
        #expect(!value.isValid())
        #expect(value.frameCount() == 0)
        #expect(throws: OrdinarySyncExportError.self) { try owner.captureOrdinarySyncExport() }
    }

    @Test func lazyTableResultsAndLegacyJSONKeepTheirExistingContract() throws {
        let owner = try Lattice(isolation: nil, for: [SimpleSyncObject.self],
                                configuration: .init(storage: .memory()))
        defer { owner.close() }
        let query: TableResults<AuditLog> = owner.eventsAfter(globalId: nil)
        #expect(query.snapshot(limit: 10).isEmpty)
        try owner.add(SimpleSyncObject(value: 1, floatValue: 1))
        try owner.add(SimpleSyncObject(value: 2, floatValue: 2))
        let all = query.snapshot(limit: 10)
        #expect(all.count == 2)
        let first = try #require(all.first)
        let last = try #require(all.last)
        #expect(first.primaryKey < last.primaryKey)
        let firstID = try #require(first.globalId)
        #expect(owner.eventsAfter(id: first.primaryKey).snapshot(limit: 10).map(\.primaryKey) == [last.primaryKey])
        #expect(owner.eventsAfter(globalId: firstID).snapshot(limit: 10).map(\.primaryKey) == [last.primaryKey])
        #expect(owner.eventsAfter(globalId: UUID()).snapshot(limit: 10).count == 2)
        let json = try JSONEncoder().encode(ServerSentEvent.auditLog(owner.lateBindNoHistory(all)))
        let root = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect(root["auditLog"] != nil)
        #expect(root["latticeOrdinarySync"] == nil)
    }

    @Test func historicalFileCannotAcquireAuthorityFromTheSDKModelList() throws {
        let directory = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("localdev/lattice-ordinary-boundary-source-fixtures/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = Lattice.Configuration(fileURL: directory.appendingPathComponent("old.sqlite"))
        let first = try Lattice(isolation: nil, for: [SimpleSyncObject.self], configuration: configuration)
        try first.add(SimpleSyncObject(value: 1, floatValue: 1))
        let closed = first.closeChecked()
        #expect(!closed.failed && !closed.cleanupFailed && closed.cleanupComplete)
        let reopened = try Lattice(isolation: nil, for: [SimpleSyncObject.self], configuration: configuration)
        defer { reopened.close() }
        #expect(reopened.eventsAfter(globalId: nil).snapshot(limit: 10).count == 1)
        #expect(throws: OrdinarySyncExportError.self) { try reopened.captureOrdinarySyncExport() }
    }
}
