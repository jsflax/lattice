import Foundation
import LatticeSwiftCppBridge
import CxxStdlib

/// Genuine native page lease. Retain this owner through actual transport return
/// and completion. data() copies into storage the caller must already charge;
/// copied bytes or coordinates can never construct another issued page/cut.
public final class OwnedOrdinaryHistoryPage: @unchecked Sendable {
    private let value: lattice.ordinary_history_page_result
    public let byteCount: Int
    fileprivate init(_ value: lattice.ordinary_history_page_result) throws {
        guard value.isValid(), let count = Int(exactly: value.byteCount()),
              (1...4_194_304).contains(count) else { throw OrdinarySyncExportError.invalidFrame }
        self.value = value; byteCount = count
    }
    public func data() throws -> Data {
        var data = Data(count: byteCount)
        let copied = data.withUnsafeMutableBytes { value.copyTo($0.baseAddress, capacity: $0.count) }
        guard copied else { throw OrdinarySyncExportError.invalidFrame }
        return data
    }
}

/// A complete source-issued durable history cut, owning an actual native child
/// and the existing shared export reservation. These read-only coordinates are
/// copied for correlation; they confer no route/currentness/install authority.
public final class OwnedOrdinaryHistoryExport: @unchecked Sendable {
    private let value: lattice.ordinary_history_export_ref
    public let sourceID: String, stageID: String
    public let epoch: Int64, cut: Int64
    public let frameCount: Int
    public let durableBytes: UInt64
    /// Observed old issued-source frontier; no old receipt or rebind authority.
    public struct PriorMountedSource: Sendable {
        public let scope, sourceID, schemaDigest: String
        public let epoch, issuedFrontier: Int64
    }
    public let priorMountedSource: PriorMountedSource?
    fileprivate init(_ value: lattice.ordinary_history_export_ref) throws {
        if value.capacityExhausted() { throw OrdinarySyncExportError.exportCapacity }
        guard value.isValid(), let count = Int(exactly: value.frameCount()),
              (1...65_537).contains(count) else { throw OrdinarySyncExportError.captureRefused(String(value.failure())) }
        let source = String(value.sourceID()), stage = String(value.stageID())
        let epoch = value.epoch(), cut = value.cut(), bytes = value.durableBytes()
        guard source.utf8.count == 36, UUID(uuidString: source) != nil,
              stage.utf8.count == 36, UUID(uuidString: stage) != nil,
              epoch > 0, cut > 0, bytes > 0, bytes <= 2_147_483_648 else { throw OrdinarySyncExportError.invalidFrame }
        if value.hasPriorMountedSource() {
            let scope = String(value.priorScope()), oldSource = String(value.priorSourceID()), schema = String(value.priorSchemaDigest())
            let oldEpoch = value.priorEpoch(), frontier = value.priorIssuedFrontier()
            guard !scope.isEmpty, scope.utf8.count <= 66_560,
                  oldSource.utf8.count == 36, UUID(uuidString: oldSource) != nil,
                  schema.utf8.count == 64, schema.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  oldEpoch > 0, frontier >= 0 else { throw OrdinarySyncExportError.invalidFrame }
            priorMountedSource = .init(scope: scope, sourceID: oldSource, schemaDigest: schema, epoch: oldEpoch, issuedFrontier: frontier)
        } else { priorMountedSource = nil }
        self.value = value; sourceID = source; stageID = stage
        self.epoch = epoch; self.cut = cut; frameCount = count; durableBytes = bytes
    }
    /// Caller must hold the existing staging grant before copying/parsing these
    /// bounded passive facts. Only a fresh native mounted capture supplies them;
    /// a generic/resumed cut never fabricates a predecessor observation.
    @_spi(LatticeServer) public func mountedSourceRelationObservation() throws -> Data {
        let observed = String(value.mountedSourceRelationObservation())
        guard !observed.isEmpty, observed.utf8.count <= 262_144 else { throw OrdinarySyncExportError.invalidFrame }
        return Data(observed.utf8)
    }
    public func page(at index: Int) throws -> OwnedOrdinaryHistoryPage {
        guard index >= 0, index < frameCount else { throw OrdinarySyncExportError.invalidFrame }
        return try .init(value.page(UInt64(index)))
    }
}

extension Lattice {
    /// Trusted owning capture for an explicit typed model set. Unlike the legacy
    /// scalar convenience API this path has no nil/full-store fallback. Core
    /// still proves actual model declarations, source/cohort and writer custody.
    public func captureOrdinaryHistoryExport(models: [any Model.Type]) throws -> OwnedOrdinaryHistoryExport {
        guard !models.isEmpty, models.count <= 256 else { throw OrdinarySyncExportError.invalidScope }
        let names = models.map { $0.entityName }.sorted()
        guard Set(names).count == names.count,
              names.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }) else { throw OrdinarySyncExportError.invalidScope }
        guard let native = backend.asCxxLatticeRef else { throw OrdinarySyncExportError.unsupportedBackend }
        var requested = lattice.StringVector()
        for name in names { requested.push_back(std.string(name)) }
        return try .init(native.captureOrdinaryHistoryExport(models: requested))
    }
}

/// Native-issued actual mounted source, retaining its common slot and real
/// owning store. ServerKit supplies only its already authenticated typed mount;
/// native checks equality with its immutable actual Swift catalog. This grants
/// no receiver restart, accepted policy, current-cut or rebind permission.
@_spi(LatticeServer) public final class OwnedOrdinaryMountedHistorySource: @unchecked Sendable {
    private let value: lattice.ordinary_mounted_history_source_ref
    fileprivate init(_ value: lattice.ordinary_mounted_history_source_ref) throws {
        if value.capacityExhausted() { throw OrdinarySyncExportError.exportCapacity }
        guard value.isValid() else { throw OrdinarySyncExportError.captureRefused(String(value.failure())) }
        self.value = value
    }
    public func captureWithLineageObservation(models: [any Model.Type]) throws -> OwnedOrdinaryHistoryExport {
        guard !models.isEmpty, models.count <= 256 else { throw OrdinarySyncExportError.invalidScope }
        let names = models.map { $0.entityName }.sorted()
        guard Set(names).count == names.count, names.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }) else { throw OrdinarySyncExportError.invalidScope }
        var selected = lattice.StringVector(); for name in names { selected.push_back(std.string(name)) }
        return try .init(value.captureWithLineageObservation(models: selected))
    }
    public func capture(models: [any Model.Type]) throws -> OwnedOrdinaryHistoryExport {
        guard !models.isEmpty, models.count <= 256 else { throw OrdinarySyncExportError.invalidScope }
        let names = models.map { $0.entityName }.sorted()
        guard Set(names).count == names.count, names.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }) else { throw OrdinarySyncExportError.invalidScope }
        var selected = lattice.StringVector(); for name in names { selected.push_back(std.string(name)) }
        return try .init(value.capture(models: selected))
    }
}
extension Lattice {
    @_spi(LatticeServer) public func registerOrdinaryMountedHistorySource(models: [any Model.Type]) throws -> OwnedOrdinaryMountedHistorySource {
        guard !models.isEmpty, models.count <= 256 else { throw OrdinarySyncExportError.invalidScope }
        let names = models.map { $0.entityName }.sorted()
        guard Set(names).count == names.count, names.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }) else { throw OrdinarySyncExportError.invalidScope }
        guard let native = backend.asCxxLatticeRef else { throw OrdinarySyncExportError.unsupportedBackend }
        var mounted = lattice.StringVector(); for name in names { mounted.push_back(std.string(name)) }
        return try .init(native.registerOrdinaryMountedHistorySource(models: mounted))
    }
}
