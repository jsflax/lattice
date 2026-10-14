import Foundation
import Testing
import Lattice

@Suite(.serialized, .timeLimit(.minutes(1)))
struct OwnedOrdinaryHistoryExportTests {
    private func store() throws -> Lattice {
        let directory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("localdev/lattice-ordinary-history-export-tests")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try Lattice(isolation: nil, SimpleSyncObject.self,
                           configuration: .init(fileURL: directory.appendingPathComponent("\(UUID().uuidString).sqlite")))
    }
    private func refused(_ operation: () throws -> Void) {
        do { try operation(); Issue.record("expected genuine history refusal") } catch {}
    }
    private func close(_ store: Lattice) {
        let result = store.closeChecked()
        #expect(!result.failed && !result.cleanupFailed && result.cleanupComplete)
    }
    @Test func explicitHistoryPolicyKeepsRealPreopenWSSRefusalAndDistinctConfigurationIdentity() throws {
        let path = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("localdev/lattice-ordinary-history-export-tests/invalid-\(UUID().uuidString).sqlite")
        var configuration = Lattice.Configuration(fileURL: path)
        let legacy = configuration
        configuration.ordinarySyncPolicy = .orderedHistoryRequired
        #expect(configuration != legacy)
        var scalar = legacy; scalar.ordinarySyncPolicy = .orderedRequired
        #expect(configuration != scalar && scalar != legacy)
        configuration.ordinaryModelProfile = try OrdinarySyncModelProfile("selected-simple-v1")
        do {
            _ = try Lattice(isolation: nil, SimpleSyncObject.self, configuration: configuration)
            Issue.record("history without actual WSS must refuse before open")
        } catch OrdinarySyncExportError.invalidPolicy {} catch { Issue.record("expected actual preopen invalidPolicy: \(error)") }
        #expect(!FileManager.default.fileExists(atPath: path.path))
    }
    @Test func realTypedCaptureRequiresExplicitScopeAndIssuedCoordinates() throws {
        let source = try store(); defer { close(source) }
        try source.add(SimpleSyncObject(value: 1, floatValue: 1.25))
        refused { _ = try source.captureOrdinaryHistoryExport(models: []) }
        let export = try source.captureOrdinaryHistoryExport(models: [SimpleSyncObject.self])
        let page = try export.page(at: 0)
        let data = try page.data()
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let header = try #require(root["latticeOrdinarySync"] as? [String: Any])
        #expect(header["profile"] as? String == "paged-history-v1")
        #expect(header["kind"] as? String == "historyCut")
        #expect(header["source"] as? String == export.sourceID && header["stage"] as? String == export.stageID)
        #expect(header["epoch"] as? String == String(export.epoch) && header["cut"] as? String == String(export.cut))
        #expect(export.frameCount > 1 && export.durableBytes > 0)
        #expect(data.count == page.byteCount && page.byteCount <= 4_194_304)
    }
    @Test func actualDistinctPageAdmissionStaysHeldThroughAliasAfterParentClose() throws {
        let source = try store()
        try source.add(SimpleSyncObject(value: 2, floatValue: 2.25))
        let export = try source.captureOrdinaryHistoryExport(models: [SimpleSyncObject.self])
        var page: OwnedOrdinaryHistoryPage? = try export.page(at: 0)
        var alias = page
        let header = try #require(page).data()
        refused { _ = try export.page(at: 1) }
        close(source)
        page = nil
        #expect(try #require(alias).data() == header)
        refused { _ = try export.page(at: 1) }
        withExtendedLifetime(alias) {}
        alias = nil
        #expect(!(try export.page(at: 1).data()).isEmpty)
    }
    @Test func completeIssuedCutRetainsOriginalBytesAcrossLaterRealCommit() throws {
        let source = try store(); defer { close(source) }
        try source.add(SimpleSyncObject(value: 3, floatValue: 3.25))
        let original = try source.captureOrdinaryHistoryExport(models: [SimpleSyncObject.self])
        func frames(_ cut: OwnedOrdinaryHistoryExport) throws -> [Data] {
            var result: [Data] = []
            for index in 0..<cut.frameCount { result.append(try cut.page(at: index).data()) }
            return result
        }
        let before = try frames(original)
        try source.add(SimpleSyncObject(value: 4, floatValue: 4.25))
        #expect(try frames(original) == before)
        let successor = try source.captureOrdinaryHistoryExport(models: [SimpleSyncObject.self])
        #expect(successor.sourceID == original.sourceID && successor.epoch == original.epoch)
        #expect(successor.cut > original.cut && successor.stageID != original.stageID)
        // Both are real local issued cuts; this test does not install a receiver,
        // create a managed route or assert canonical/ACK/product authority.
    }
    @Test func historyAndOriginalScalarCutsShareActualNativeExportCapacity() throws {
        let source = try store(); defer { close(source) }
        try source.add(SimpleSyncObject(value: 5, floatValue: 5.25))
        var held: [OwnedOrdinarySyncExport] = []
        for _ in 0..<4 { held.append(try source.captureOrdinarySyncExport(models: [SimpleSyncObject.self])) }
        do {
            _ = try source.captureOrdinaryHistoryExport(models: [SimpleSyncObject.self])
            Issue.record("history must not create a separate fifth native export pool")
        } catch OrdinarySyncExportError.exportCapacity {} catch { Issue.record("expected typed actual capacity refusal: \(error)") }
        held.removeLast()
        let actual = try source.captureOrdinaryHistoryExport(models: [SimpleSyncObject.self])
        #expect(actual.frameCount > 1)
        withExtendedLifetime((held, actual)) {}
    }
}
