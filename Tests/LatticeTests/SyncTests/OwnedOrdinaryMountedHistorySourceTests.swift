import Foundation
import Testing
@_spi(LatticeServer) import Lattice

@Model private class MountedScopeA { var value: String; init(_ value: String) { self.value = value } }
@Model private class MountedScopeB { var value: String; init(_ value: String) { self.value = value } }
@Model private class MountedScopeC { var value: String; init(_ value: String) { self.value = value } }
@Model private class MountedScopeD { var value: String; init(_ value: String) { self.value = value } }
@Model private class MountedScopeE { var value: String; init(_ value: String) { self.value = value } }
@Model private class MountedScopeF { var value: String; init(_ value: String) { self.value = value } }

/// Actual native Swift catalog/store tests. The SPI is the trusted local mount
/// boundary; this suite does not forge a server authorization, managed launch,
/// receiver final install, cross-source winner or real paired runtime witness.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct OwnedOrdinaryMountedHistorySourceTests {
    private var full: [any Model.Type] { [MountedScopeA.self, MountedScopeB.self, MountedScopeC.self, MountedScopeD.self, MountedScopeE.self, MountedScopeF.self] }
    private var selected: [any Model.Type] { [MountedScopeA.self, MountedScopeB.self, MountedScopeC.self] }
    private func url() throws -> URL {
        let directory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("localdev/lattice-mounted-history-source-tests")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(UUID().uuidString).sqlite")
    }
    private func store(_ url: URL) throws -> Lattice { try Lattice(isolation: nil, for: full, configuration: .init(fileURL: url)) }
    private func close(_ owner: Lattice) {
        let result = owner.closeChecked()
        #expect(!result.failed && !result.cleanupFailed && result.cleanupComplete)
    }
    private func refused(_ operation: () throws -> Void) {
        do { try operation(); Issue.record("expected actual native issuer refusal") } catch {}
    }
    private func body(_ export: OwnedOrdinaryHistoryExport, at index: Int = 0) throws -> [String: Any] {
        let root = try #require(try JSONSerialization.jsonObject(with: export.page(at: index).data()) as? [String: Any])
        return try #require(root["latticeOrdinarySync"] as? [String: Any])
    }
    @Test func legacyReopenedSixMountIssuesOnlyThreeRowsAndNoInventedOldSource() throws {
        let path = try url()
        do {
            let original = try store(path)
            try original.add(MountedScopeA("selected-current"))
            try original.add(MountedScopeD("excluded-secret-marker"))
            close(original)
        }
        let owner = try store(path); defer { close(owner) }
        refused { _ = try owner.captureOrdinaryHistoryExport(models: selected) } // old generic historical refusal is preserved
        let mounted = try owner.registerOrdinaryMountedHistorySource(models: full)
        let cut = try mounted.capture(models: selected)
        #expect(cut.priorMountedSource == nil && cut.cut == 1)
        let header = try body(cut)
        #expect(header["models"] as? [String] == selected.map { $0.entityName }.sorted())
        #expect(header["rows"] as? String == "1")
        for index in 0..<cut.frameCount {
            let bytes = try cut.page(at: index).data()
            #expect(!String(decoding: bytes, as: UTF8.self).contains("excluded-secret-marker"))
        }
        #expect(owner.count(MountedScopeD.self) == 1 && owner.count(MountedScopeA.self) == 1)
    }
    @Test func actualOldSixCutIsObservedWithoutRelabellingItsSourceOrReceipt() throws {
        let owner = try store(try url()); defer { close(owner) }
        try owner.add(MountedScopeA("new-three")); try owner.add(MountedScopeF("old-six-only"))
        var old: OwnedOrdinaryHistoryExport? = try owner.captureOrdinaryHistoryExport(models: full)
        let oldSource = try #require(old).sourceID, oldEpoch = try #require(old).epoch, frontier = try #require(old).cut
        old = nil
        let mounted = try owner.registerOrdinaryMountedHistorySource(models: full)
        let cut = try mounted.capture(models: selected)
        let observation = try #require(cut.priorMountedSource)
        #expect(observation.sourceID == oldSource && observation.epoch == oldEpoch && observation.issuedFrontier == frontier)
        #expect(cut.sourceID != oldSource && cut.cut == 1)
        #expect(try body(cut)["models"] as? [String] == selected.map { $0.entityName }.sorted())
        #expect(try body(cut)["rows"] as? String == "1")
        #expect(owner.count(MountedScopeF.self) == 1 && !Array(owner.eventsAfter(globalId: nil)).isEmpty)
        // The observed frontier is an issued source cut, not proof this receiver
        // ever accepted it. No receiver receipt/baseline is manufactured here.
    }
    @Test func incompleteMountAndUnregisteredSelectedRootsRefuseOnActualCatalog() throws {
        let owner = try store(try url()); defer { close(owner) }
        refused { _ = try owner.registerOrdinaryMountedHistorySource(models: selected) }
        refused { _ = try owner.registerOrdinaryMountedHistorySource(models: full + [MountedScopeA.self]) }
        let mounted = try owner.registerOrdinaryMountedHistorySource(models: full)
        refused { _ = try mounted.capture(models: [SimpleSyncObject.self]) }
        refused { _ = try mounted.capture(models: [MountedScopeA.self, MountedScopeA.self]) }
        refused { _ = try mounted.capture(models: []) }
        let cut = try mounted.capture(models: selected)
        #expect(cut.cut == 1 && cut.priorMountedSource == nil)
        refused { _ = try mounted.capture(models: selected) } // same actual cut must die before another is admitted
        withExtendedLifetime(cut) {}
    }
    @Test func mountedCutAndLastPageRetainTheOneCommonSlotAfterParentClose() throws {
        let owner = try store(try url()), competitor = try store(try url())
        defer { close(competitor) }
        try owner.add(MountedScopeA("retained"))
        var scalar: [OwnedOrdinarySyncExport] = []
        for _ in 0..<3 { scalar.append(try competitor.captureOrdinarySyncExport(models: selected)) }
        var mounted: OwnedOrdinaryMountedHistorySource? = try owner.registerOrdinaryMountedHistorySource(models: full)
        var cut: OwnedOrdinaryHistoryExport? = try #require(mounted).capture(models: selected)
        var page: OwnedOrdinaryHistoryPage? = try #require(cut).page(at: 0)
        var alias = page
        let bytes = try #require(alias).data()
        close(owner); mounted = nil; cut = nil; page = nil
        do {
            _ = try competitor.captureOrdinarySyncExport(models: selected)
            Issue.record("last native page must retain the common fourth slot")
        } catch OrdinarySyncExportError.exportCapacity {} catch { Issue.record("expected actual typed capacity: \(error)") }
        #expect(try #require(alias).data() == bytes)
        withExtendedLifetime(alias) {}; alias = nil
        let successor = try competitor.captureOrdinarySyncExport(models: selected)
        #expect(successor.frameCount > 0)
        withExtendedLifetime((scalar, successor)) {}
    }
    private func lineageFacts(_ cut: OwnedOrdinaryHistoryExport) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: cut.mountedSourceRelationObservation()) as? [String: Any])
    }
    private func sameIssuedHeader(_ cut: OwnedOrdinaryHistoryExport, _ facts: [String: Any]) throws {
        let current = try #require(facts["current"] as? [String: Any]), header = try body(cut)
        for key in ["source", "epoch", "cut", "stage", "scope", "schema", "captureDevice", "captureInode", "contentDigest"] {
            #expect(current[key] as? String == header[key] as? String)
        }
        #expect(current["headerDigest"] as? String == header["digest"] as? String)
    }
    @Test func actualSixToThreeRelationObservesOldFullBeforeIssuingNewSelectedCut() throws {
        let owner = try store(try url()); defer { close(owner) }
        try owner.add(MountedScopeA("current-three")); try owner.add(MountedScopeF("old-full-only"))
        var old: OwnedOrdinaryHistoryExport? = try owner.captureOrdinaryHistoryExport(models: full)
        let oldSource = try #require(old).sourceID, oldEpoch = try #require(old).epoch, oldCut = try #require(old).cut
        let oldHeader = try body(try #require(old)); old = nil
        let mounted = try owner.registerOrdinaryMountedHistorySource(models: full)
        let next = try mounted.captureWithLineageObservation(models: selected)
        let facts = try lineageFacts(next), predecessor = try #require(facts["mountedPredecessor"] as? [String: Any])
        #expect(predecessor["source"] as? String == oldSource && predecessor["epoch"] as? String == String(oldEpoch))
        #expect(predecessor["issuedFrontier"] as? String == String(oldCut))
        for key in ["scope", "schema", "captureDevice", "captureInode"] { #expect(predecessor[key] as? String == oldHeader[key] as? String) }
        #expect(facts["selectedPredecessor"] is NSNull && next.sourceID != oldSource && next.cut == 1)
        try sameIssuedHeader(next, facts)
        #expect(owner.count(MountedScopeF.self) == 1)
        // No receiver's exact old receipt/digest/baseline was supplied or issued.
    }
    @Test func actualSameScopeGroupPredecessorIsObservedBeforeMonotonicCutAdvance() throws {
        let owner = try Lattice(isolation: nil, for: selected, configuration: .init(fileURL: try url())); defer { close(owner) }
        try owner.add(MountedScopeA("group-current"))
        var old: OwnedOrdinaryHistoryExport? = try owner.captureOrdinaryHistoryExport(models: selected)
        let oldSource = try #require(old).sourceID, oldCut = try #require(old).cut, oldEpoch = try #require(old).epoch
        let oldHeader = try body(try #require(old)); old = nil
        let mounted = try owner.registerOrdinaryMountedHistorySource(models: selected)
        let next = try mounted.captureWithLineageObservation(models: selected), facts = try lineageFacts(next)
        let full = try #require(facts["mountedPredecessor"] as? [String: Any]), prior = try #require(facts["selectedPredecessor"] as? [String: Any])
        for key in ["scope", "source", "epoch", "issuedFrontier", "schema", "captureDevice", "captureInode"] { #expect(full[key] as? String == prior[key] as? String) }
        #expect(prior["source"] as? String == oldSource && prior["issuedFrontier"] as? String == String(oldCut))
        #expect(next.sourceID == oldSource && next.epoch == oldEpoch && next.cut == oldCut + 1)
        #expect(prior["scope"] as? String == oldHeader["scope"] as? String)
        #expect(next.priorMountedSource == nil) // Old differing-scope getter stays exact; nil is not receiver absence.
        try sameIssuedHeader(next, facts)
    }
    @Test func defaultCaptureAndLegacyNoPredecessorDoNotInventAnOldReceiverReceipt() throws {
        let path = try url()
        do { let legacy = try store(path); try legacy.add(MountedScopeA("unreceipted")); close(legacy) }
        let owner = try store(path); defer { close(owner) }
        let mounted = try owner.registerOrdinaryMountedHistorySource(models: full)
        var first: OwnedOrdinaryHistoryExport? = try mounted.capture(models: selected)
        refused { _ = try #require(first).mountedSourceRelationObservation() } // Default capture does not render new facts.
        let firstSource = try #require(first).sourceID, firstCut = try #require(first).cut; first = nil
        let next = try mounted.captureWithLineageObservation(models: selected), facts = try lineageFacts(next)
        #expect(facts["mountedPredecessor"] is NSNull)
        let prior = try #require(facts["selectedPredecessor"] as? [String: Any])
        #expect(prior["source"] as? String == firstSource && prior["issuedFrontier"] as? String == String(firstCut))
        #expect(next.cut == firstCut + 1 && owner.count(MountedScopeA.self) == 1)
        try sameIssuedHeader(next, facts)
        // Both null and observed predecessors are passive source facts, never
        // proof this legacy receiver accepted anything or may discard edits.
    }
}
