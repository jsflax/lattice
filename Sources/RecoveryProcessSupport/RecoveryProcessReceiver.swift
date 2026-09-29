import Foundation
import Lattice

/// Public-API-only C receiver, usable by the dedicated child and parent B.
/// Every managed object/result is copied and retired on this actor.
@MainActor public final class RecoveryProcessReceiver {
    public let configuration: RecoveryProcessConfiguration
    public let file: URL
    private var owners: [Lattice] = []
    public init(configuration: RecoveryProcessConfiguration, caseDirectory: URL) throws {
        try configuration.validate(); self.configuration = configuration
        file = caseDirectory.appendingPathComponent(configuration.storeDirectory).appendingPathComponent("store.sqlite")
    }
    public func open(connected: Bool) throws {
        guard owners.isEmpty else { throw RecoveryProcessFailure.state }
        do {
            for index in 0..<(connected ? 2 : 1) {
                var config = Lattice.Configuration(fileURL: file, busyTimeoutMs: 100)
                config.resultsTuning.crossProcessBeltIntervalMs = nil
                if connected {
                    let expectation = try configuration.channels[index].expectation()
                    config.wssEndpoint = expectation.endpoint; config.authorizationToken = configuration.authorizationToken
                    config.recoverySourceExpectation = expectation
                }
                owners.append(try Lattice(for: [RecoveryProcessSharedRow.self, RecoveryProcessLocalRow.self],
                    configuration: config, continuousProducer: configuration.policy))
            }
        } catch { try? close(); throw RecoveryProcessFailure.publicOpen }
    }
    public func close() throws {
        var valid = true
        for owner in owners.reversed() {
            let result = owner.closeChecked()
            valid = valid && result.cleanupComplete && !result.failed && !result.cleanupFailed &&
                result.errorMessage == nil && !result.errorMessageUnavailable &&
                ![.deadlinePending, .reentrantPending, .failed, .unavailable].contains(result.sync)
        }
        owners.removeAll()
        guard valid else { throw RecoveryProcessFailure.publicClose }
    }
    private func owner() throws -> Lattice {
        guard let owner = owners.first else { throw RecoveryProcessFailure.state }; return owner
    }
    public func image() throws -> RecoveryProcessImage {
        let owner = try owner()
        let result = owner.objects(RecoveryProcessSharedRow.self)
        guard result.count <= 16 else { throw RecoveryProcessFailure.bounds }
        let rows = try Array(result).map { object -> RecoveryProcessRow in
            guard let id = object.globalId else { throw RecoveryProcessFailure.publicState }
            return .init(id: id, label: object.label, value: object.value)
        }.sorted { $0.label < $1.label }
        let local = owner.objects(RecoveryProcessLocalRow.self)
        guard local.count <= 4 else { throw RecoveryProcessFailure.bounds }
        let image = RecoveryProcessImage(rows: rows, localValues: Array(local).map(\.value).sorted(), originals: try originals())
        try image.validate(); return image
    }
    private func originals() throws -> [RecoveryProcessOriginal] {
        let events = try owner().eventsAfter(globalId: nil)
        guard events.count <= 128 else { throw RecoveryProcessFailure.bounds }
        return try Array(events).map { event in
            guard let id = event.globalId, let target = event.globalRowId else { throw RecoveryProcessFailure.publicState }
            return .init(id: id, target: target, table: event.tableName, operation: event.operation.rawValue,
                fields: try RecoveryProcessCodec.encode(event.changedFields), names: event.changedFieldsNames)
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }
    public func isSettled(expected: RecoveryProcessImage) throws -> Bool {
        try expected.validate()
        let actual = try image()
        guard actual.rows == expected.rows.sorted(by: { $0.label < $1.label }), actual.localValues == expected.localValues.sorted(),
              expected.originals.allSatisfy({ original in actual.originals.filter { $0.id == original.id } == [original] }) else { return false }
        let inspection = try owner().inspectContinuousProducer()
        return inspection.settlement.phase == .committed && !inspection.settlement.hasError &&
            !inspection.settlement.unexpectedCommitObserved && inspection.barrier == nil
    }
    public func settle(expected: RecoveryProcessImage) async throws -> RecoveryProcessImage {
        while true {
            guard DispatchTime.now().uptimeNanoseconds < configuration.deadlineNanoseconds else { throw RecoveryProcessFailure.deadline }
            if try isSettled(expected: expected) { return try image() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private func edit() throws -> (RecoveryProcessImage, [RecoveryProcessOriginal]) {
        let owner = try owner(), before = Set(try originals().map(\.id))
        let rows = Array(owner.objects(RecoveryProcessSharedRow.self))
        guard rows.count == 6, let changed = rows.first(where: { $0.label == "r1" }),
              let removed = rows.first(where: { $0.label == "r2" }), let changedID = changed.globalId, let removedID = removed.globalId
        else { throw RecoveryProcessFailure.publicState }
        let inserted = RecoveryProcessSharedRow(label: "a-insert", value: 101)
        try owner.withTransaction {
            changed.value = 101
            guard owner.delete(removed) else { throw RecoveryProcessFailure.publicWrite }
            try owner.add(inserted); try owner.add(RecoveryProcessLocalRow(value: "receiver-a-local"))
        }
        guard let insertedID = inserted.globalId else { throw RecoveryProcessFailure.publicWrite }
        let after = try image()
        let own = after.originals.filter { !before.contains($0.id) && $0.table == "RecoveryProcessSharedRow" }
        guard own.count == 3, Set(own.map(\.id)).count == 3,
              own.filter({ $0.operation == "UPDATE" && $0.target == changedID }).count == 1,
              own.filter({ $0.operation == "DELETE" && $0.target == removedID }).count == 1,
              own.filter({ $0.operation == "INSERT" && $0.target == insertedID }).count == 1,
              after.rows.count == 6, after.localValues == ["receiver-a-local"] else { throw RecoveryProcessFailure.publicWrite }
        for original in own {
            let fields = try JSONDecoder().decode([String: AnyProperty].self, from: original.fields)
            if original.operation != "DELETE" {
                guard original.names?.contains("value") == true, let value = fields["value"] else { throw RecoveryProcessFailure.publicWrite }
                switch value {
                case .int(let number): guard number == 101 else { throw RecoveryProcessFailure.publicWrite }
                case .int64(let number): guard number == 101 else { throw RecoveryProcessFailure.publicWrite }
                default: throw RecoveryProcessFailure.publicWrite
                }
            }
            if original.operation == "INSERT" {
                guard case .string(let label)? = fields["label"], label == "a-insert" else { throw RecoveryProcessFailure.publicWrite }
            }
        }
        return (after, own)
    }
    public func offlineEdit() throws -> (RecoveryProcessImage, [RecoveryProcessOriginal]) {
        try close(); try open(connected: false)
        do {
            // edit's managed locals retire before this checked close.
            let result = try edit(); try close(); return result
        } catch { try? close(); throw error }
    }
    public func postWrite() throws -> RecoveryProcessImage {
        let owner = try owner()
        guard !(try image().rows.contains { $0.label == "post" }) else { throw RecoveryProcessFailure.publicState }
        try owner.withTransaction { try owner.add(RecoveryProcessSharedRow(label: "post", value: 99)) }
        return try image()
    }
    public func execute(_ command: RecoveryProcessCommand) async throws -> RecoveryProcessReply {
        guard DispatchTime.now().uptimeNanoseconds < configuration.deadlineNanoseconds else { throw RecoveryProcessFailure.deadline }
        switch command.operation {
        case .start, .reconnect:
            try open(connected: true)
            // No inspection/SQL following reconnect: the parent observes the
            // real source cutpoint while this actor resumes its normal work.
            return .init(command: command)
        case .settle:
            guard let expected = command.expected else { throw RecoveryProcessFailure.correlation }
            return .init(command: command, image: try await settle(expected: expected), committedOpen: true)
        case .offlineEdit:
            let (image, originals) = try offlineEdit(); return .init(command: command, image: image, createdShared: originals)
        case .postWrite: return .init(command: command, image: try postWrite())
        case .close: try close(); return .init(command: command)
        }
    }
}
