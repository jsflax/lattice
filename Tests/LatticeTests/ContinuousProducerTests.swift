import Foundation
import Testing
@testable import Lattice

private enum ContinuousSwiftV1 {
    @Model final class ContinuousSDKRow {
        var value: String = ""
        @NoHistory var note: String = ""
    }
}
private enum ContinuousSwiftChanged {
    @Model final class ContinuousSDKRow {
        var value: String = ""
        var note: String = ""
    }
}
@Model private final class ContinuousSDKLocal { var value: String = "" }

@Suite("Retained Swift continuous producer", .serialized)
@MainActor
struct ContinuousProducerTests {
    private func fixture() throws -> (URL, Lattice.Configuration) {
        let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("localdev/lattice-continuity-sdk-tests")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let container = root.appendingPathComponent(UUID().uuidString + ".lattice-continuous")
        var config = Lattice.Configuration(fileURL: container.appendingPathComponent("store.sqlite"), busyTimeoutMs: 100)
        config.resultsTuning.crossProcessBeltIntervalMs = nil
        return (container, config)
    }
    private func policy(owners: Int = 8) -> ContinuousProducerPolicy {
        .init(contributions: ["a", "b"].map { channel in
            .init(channel: channel, authority: "authority", source: "source", epoch: "epoch",
                  scope: "scope-" + channel, schema: "schema", profileDigest: "grant-" + channel,
                  receiptNamespace: "shared-receipts", models: ["ContinuousSDKRow"], incomingGrantClaim: Data([103]))
        }, routes: ["a", "b"].map { channel in
            .init(syncID: "wss:wss://continuous-sdk.invalid/" + channel, endpoint: "wss://continuous-sdk.invalid/" + channel)
        }, limits: .init(scopes: 4, records: 128, fieldBytes: 128, journalBytes: 2 * 1024 * 1024,
                        channels: 4, bindingFieldBytes: 128, bindingBytes: 8192,
                        profiles: 4, stamps: 128, producerFieldBytes: 128, manifestBytes: 1_048_576, producerBytes: 8 * 1024 * 1024,
                        owners: owners, physicalRoutes: 4, operations: 4, frozenEntries: 128, frozenBytes: 2 * 1024 * 1024))
    }
    private func open(_ config: Lattice.Configuration, owners: Int = 8) throws -> Lattice {
        try Lattice(for: [ContinuousSwiftV1.ContinuousSDKRow.self, ContinuousSDKLocal.self],
                    configuration: config, continuousProducer: policy(owners: owners))
    }
    private func insert(_ store: Lattice, value: String) throws {
        try store.withTransaction {
            let row = ContinuousSwiftV1.ContinuousSDKRow(); row.value = value; row.note = "private"
            try store.add(row)
        }
    }
    private func committed(_ value: ContinuousProducerSettlement) {
        #expect(value.phase == .committed)
        #expect(!value.hasError)
        #expect(!value.unexpectedCommitObserved)
    }
    @Test func actualORMAndTwoAdmittedFacadesShareRowsAndBarrier() throws {
        let (container, config) = try fixture()
        defer { try? FileManager.default.removeItem(at: container) }
        let first = try open(config), second = try open(config)
        defer { second.close(); first.close() }
        #expect(first.cxxLatticeRef.hash_value() != second.cxxLatticeRef.hash_value())
        try insert(first, value: "one"); try insert(second, value: "two")
        #expect(second.objects(ContinuousSwiftV1.ContinuousSDKRow.self).count == 2)
        #expect(first.objects(ContinuousSwiftV1.ContinuousSDKRow.self).first?.note == "private")
        let begun = try first.beginContinuousProducerBarrier(attempt: 1); committed(begun.settlement)
        let barrier = try #require(begun.barrier)
        #expect(throws: (any Error).self) { try insert(second, value: "refused") }
        try second.withTransaction { let local = ContinuousSDKLocal(); local.value = "allowed"; try second.add(local) }
        let done = barrier.finish(); committed(done.settlement)
        #expect(done.frozen); #expect(!done.waiting); #expect(done.localUnsentCount == 2)
        committed(barrier.cancel())
        try insert(second, value: "three")
        #expect(first.objects(ContinuousSwiftV1.ContinuousSDKRow.self).count == 3)
    }
    @Test func closedBarrierReopensWithExactSwiftCatalog() throws {
        let (container, config) = try fixture()
        defer { try? FileManager.default.removeItem(at: container) }
        do {
            let first = try open(config); defer { first.close() }
            try insert(first, value: "kept")
            let begun = try first.beginContinuousProducerBarrier(attempt: 1); committed(begun.settlement)
            let done = try #require(begun.barrier).finish(); committed(done.settlement)
            #expect(done.localUnsentCount == 1)
        }
        let reopened = try open(config); defer { reopened.close() }
        let inspected = try reopened.inspectContinuousProducer(); committed(inspected.settlement)
        let barrier = try #require(inspected.barrier)
        #expect(throws: (any Error).self) { try insert(reopened, value: "closed") }
        let frozen = barrier.finish(); committed(frozen.settlement); #expect(frozen.localUnsentCount == 1)
        committed(barrier.cancel()); try insert(reopened, value: "after")
        #expect(reopened.objects(ContinuousSwiftV1.ContinuousSDKRow.self).count == 2)
    }
    @Test func changedNoHistoryAndOrdinaryConstructorRefuseWithDataPreserved() throws {
        let (container, config) = try fixture()
        defer { try? FileManager.default.removeItem(at: container) }
        let store = try open(config); defer { store.close() }; try insert(store, value: "kept")
        #expect(throws: (any Error).self) {
            _ = try Lattice(for: [ContinuousSwiftChanged.ContinuousSDKRow.self, ContinuousSDKLocal.self],
                            configuration: config, continuousProducer: policy())
        }
        #expect(throws: (any Error).self) {
            _ = try Lattice(for: [ContinuousSwiftV1.ContinuousSDKRow.self, ContinuousSDKLocal.self], configuration: config)
        }
        #expect(store.objects(ContinuousSwiftV1.ContinuousSDKRow.self).first?.value == "kept")
        let begun = try store.beginContinuousProducerBarrier(attempt: 1); committed(begun.settlement)
        let done = try #require(begun.barrier).finish(); committed(done.settlement); #expect(done.localUnsentCount == 1)
        committed(try #require(done.barrier).cancel())
    }
    @Test func migrationRefusesBeforeCreatingContainer() throws {
        let (container, original) = try fixture(); var config = original; config.migration = [:]
        defer { try? FileManager.default.removeItem(at: container) }
        #expect(throws: ContinuousProducerError.self) { _ = try open(config) }
        #expect(!FileManager.default.fileExists(atPath: container.path))
    }
    @Test func publicationFailurePreservesKnownCommitForExplicitExactReopen() throws {
        let (container, original) = try fixture(); var config = original
        config.wssEndpoint = URL(string: "wss://continuous-sdk.invalid/a")!
        defer { try? FileManager.default.removeItem(at: container) }
        do {
            let unexpected = try open(config, owners: 1); unexpected.close()
            Issue.record("one-owner cap must refuse the additional configured WSS facade")
        } catch ContinuousProducerError.open(let result) {
            #expect(result.phase == .committed)
            #expect(result.primaryError == nil); #expect(result.postcommitError != nil)
        }
        #expect(FileManager.default.fileExists(atPath: container.appendingPathComponent("store.sqlite").path))
        let reopened = try open(original, owners: 1); defer { reopened.close() }
        try insert(reopened, value: "after known commit")
        #expect(reopened.objects(ContinuousSwiftV1.ContinuousSDKRow.self).count == 1)
    }
}
