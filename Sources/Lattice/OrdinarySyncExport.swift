import Foundation
import LatticeSwiftCppBridge
import CxxStdlib
#if canImport(Combine)
import Combine
#endif

/// Explicit compatibility policy. Legacy callers keep their existing behavior;
/// required mode must finish authenticated ordinary-v2 negotiation before data.
public enum OrdinarySyncPolicy: Sendable, Hashable {
    case legacyProvisional
    case orderedRequired
    /// Explicit paged-history effect. Durable progress remains passive staging;
    /// canonical installation still requires the real private managed installer.
    case orderedHistoryRequired
}

public enum OrdinarySyncExportError: Error, Sendable {
    case unsupportedBackend
    case invalidScope
    case captureRefused(String)
    case exportCapacity
    case invalidFrame
    case invalidPolicy
    case observationCapacity
    case observationRefused(String)
}

/// An immutable, native-issued server cut. It has no JSON/array initializer.
/// Native reservation and captured data survive source close. Frame Data is a
/// caller-owned copy; a relay must charge and retain it through actual send
/// completion, and retain this export until its whole transfer settles.
public final class OwnedOrdinarySyncExport: @unchecked Sendable {
    private let value: lattice.ordinary_sync_export_ref
    public let frameCount: Int

    fileprivate init(_ value: lattice.ordinary_sync_export_ref) throws {
        if value.capacityExhausted() { throw OrdinarySyncExportError.exportCapacity }
        guard value.isValid(), let count = Int(exactly: value.frameCount()), (1...770).contains(count) else {
            throw OrdinarySyncExportError.captureRefused(String(value.failure()))
        }
        self.value = value
        self.frameCount = count
    }

    public func frame(at index: Int) throws -> Data {
        guard index >= 0, index < frameCount else { throw OrdinarySyncExportError.invalidFrame }
        let page = value.frame(index)
        guard page.isValid(), let count = Int(exactly: page.byteCount()),
              (1...4_194_304).contains(count) else { throw OrdinarySyncExportError.invalidFrame }
        // One synchronous native copy, avoiding C++ collection witnesses and
        // per-byte bridge calls. The actual page retains its exact cut here.
        var data = Data(count: count)
        let copied = data.withUnsafeMutableBytes { bytes in
            page.copyTo(bytes.baseAddress, capacity: bytes.count)
        }
        guard copied else { throw OrdinarySyncExportError.invalidFrame }
        return data
    }
}

/// Actual source custody for the submitted original versions. This is not a
/// projected-value application claim or a canonical-cut receipt. Construction
/// is restricted to the checked native receive result below.
public final class OrdinarySyncUploadAcceptance: @unchecked Sendable {
    // Immutable native value; merges return new values and never mutate a
    // value shared with another lane. Native-issued results own their budget.
    private let actual: lattice.ordinary_upload_acknowledgment_result
    public let ids: [UUID]
    public let acknowledgmentByteCount: Int
    fileprivate init(_ actual: lattice.ordinary_upload_acknowledgment_result) throws {
        guard actual.isValid() else { throw OrdinarySyncExportError.invalidFrame }
        guard let idCount = Int(exactly: actual.idCount()), (0...64).contains(idCount) else {
            throw OrdinarySyncExportError.invalidFrame
        }
        var ids: [UUID] = []; ids.reserveCapacity(idCount)
        for index in 0..<idCount {
            guard let id = UUID(uuidString: String(actual.idAt(index))), !ids.contains(id) else { throw OrdinarySyncExportError.invalidFrame }
            ids.append(id)
        }
        guard let count = Int(exactly: actual.acknowledgmentByteCount()),
              (ids.isEmpty ? count == 0 : (1...4_194_304).contains(count)) else { throw OrdinarySyncExportError.invalidFrame }
        self.actual = actual; self.ids = ids; self.acknowledgmentByteCount = count
    }
    /// Merge only actual native acceptance values from retries of this input.
    /// Conflicting versions refuse; no submitted JSON can mint an accepted pair.
    public func merging(_ other: OrdinarySyncUploadAcceptance) throws -> OrdinarySyncUploadAcceptance {
        try .init(actual.merged(other.actual))
    }
    /// Caller charges the Data copy plus transport storage before this call.
    public func acknowledgmentData() throws -> Data {
        var acknowledgment = Data(count: acknowledgmentByteCount)
        let copied = acknowledgment.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
            actual.copyAcknowledgmentTo(out.baseAddress, out.count)
        }
        guard copied else { throw OrdinarySyncExportError.invalidFrame }
        return acknowledgment
    }
}

extension Lattice {
    /// Required-v2 intake. Native pairs only the exact decoded versions whose
    /// originals committed (or whose identical originals were already held).
    /// The result retains native custody; callers charge a later Data/transport
    /// copy before asking it to expose acknowledgment bytes.
    public func receiveOrdinarySyncUploadWithAcknowledgment(_ data: Data, models: [any Model.Type]? = nil) throws -> OrdinarySyncUploadAcceptance {
        guard !data.isEmpty, data.count <= 4_194_304 else { throw OrdinarySyncExportError.invalidFrame }
        let selected = models ?? modelTypes
        guard !selected.isEmpty, selected.count <= 256 else { throw OrdinarySyncExportError.invalidScope }
        let names = selected.map { $0.entityName }.sorted()
        guard Set(names).count == names.count, names.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }) else { throw OrdinarySyncExportError.invalidScope }
        guard let native = backend.asCxxLatticeRef else { throw OrdinarySyncExportError.unsupportedBackend }
        var requested = lattice.StringVector()
        for name in names { requested.push_back(std.string(name)) }
        let actual = native.receiveOrdinaryUploadWithAcknowledgment(data: data.toCxxValue(), models: requested)
        // The immutable Native outcome controls validity; shared error text cannot replace it.
        return try .init(actual)
    }
    /// Trusted local server operation. Core validates actual source enrollment,
    /// complete model declarations and physical writer ownership; names alone
    /// never confer authority. It refuses unsupported shapes, caller-owned
    /// transactions and historical stores without actual managed issuance.
    /// Receives a negotiated provisional upload at this actual source store.
    /// It preserves committed original bytes; returned IDs mean applied peer
    /// custody, never a canonical receipt or source grant.
    public func receiveOrdinarySyncUpload(_ data: Data, models: [any Model.Type]? = nil) throws -> [UUID] {
        guard !data.isEmpty, data.count <= 4_194_304 else { throw OrdinarySyncExportError.invalidFrame }
        let selected = models ?? modelTypes
        guard !selected.isEmpty, selected.count <= 256 else { throw OrdinarySyncExportError.invalidScope }
        let names = selected.map { $0.entityName }.sorted()
        guard Set(names).count == names.count, names.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }) else { throw OrdinarySyncExportError.invalidScope }
        guard let native = backend.asCxxLatticeRef else { throw OrdinarySyncExportError.unsupportedBackend }
        var requested = lattice.StringVector()
        for name in names { requested.push_back(std.string(name)) }
        let actual = native.receiveOrdinaryUpload(data: data.toCxxValue(), models: requested)
        guard actual.isValid() else {
            let failure = String(actual.failure())
            throw LatticeError.syncReceiveFailed(failure.isEmpty ? "Ordinary source upload failed" : failure)
        }
        guard let count = Int(exactly: actual.idCount()), (0...64).contains(count) else {
            throw OrdinarySyncExportError.invalidFrame
        }
        // Each accessor copies one actual ID; the Native result shares its retained vector.
        var result: [UUID] = []; result.reserveCapacity(count)
        for index in 0..<count {
            guard let id = UUID(uuidString: String(actual.idAt(index))), !result.contains(id) else {
                throw OrdinarySyncExportError.invalidFrame
            }
            result.append(id)
        }
        return result
    }
    public func captureOrdinarySyncExport(models: [any Model.Type]? = nil) throws -> OwnedOrdinarySyncExport {
        let selected = models ?? modelTypes
        guard !selected.isEmpty, selected.count <= 256 else { throw OrdinarySyncExportError.invalidScope }
        let names = selected.map { $0.entityName }.sorted()
        guard Set(names).count == names.count,
              names.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }) else { throw OrdinarySyncExportError.invalidScope }
        guard let native = backend.asCxxLatticeRef else { throw OrdinarySyncExportError.unsupportedBackend }
        var requested = lattice.StringVector()
        for name in names { requested.push_back(std.string(name)) }
        return try OwnedOrdinarySyncExport(native.captureOrdinaryExport(models: requested))
    }
}

// One fixed logical selection reservation per live observer, including callbacks
// already copied by Core at cancellation. This bounds 64 * 8448 native table
// registrations. Cumulative selected name bytes are checked separately; this
// count bound is not a claim about container overhead or process RSS.
private final class OrdinarySyncObservationState: @unchecked Sendable {
    private static let used = UnfairLock<Int>(initialState: 0)
    private let active = UnfairLock<Bool>(initialState: true)
    private let block: @Sendable () -> Void
    init(_ block: @escaping @Sendable () -> Void) throws {
        guard Self.used.withLockUnchecked({ count in
            guard count < 64 else { return false }; count += 1; return true
        }) else { throw OrdinarySyncExportError.observationCapacity }
        self.block = block
    }
    func fire() { if active.withLockUnchecked({ $0 }) { block() } }
    func stop() { active.withLockUnchecked { $0 = false } }
    deinit { Self.used.withLockUnchecked { $0 -= 1 } }
}

extension Lattice {
    /// Payload-free wake for the actual selected model projection, including
    /// generated logical link/union tables. Registration validates schema but
    /// never issues export authority. Register before the first capture, then
    /// coalesce signals and re-query on an owning IO lane. The callback runs on
    /// Core's observation lane and must only schedule work; it must not run SQL.
    /// Same-process commits retain the existing table delivery contract. Foreign
    /// process notifications remain best effort; use relay reconciliation for
    /// missed signals. Cancellation may race a callback already admitted.
    public func observeOrdinarySyncChanges(models: [any Model.Type]? = nil,
        _ block: @escaping @Sendable () -> Void) throws -> AnyCancellable {
        let state = try OrdinarySyncObservationState(block)
        let selected = models ?? modelTypes
        guard !selected.isEmpty, selected.count <= 256 else { throw OrdinarySyncExportError.invalidScope }
        let names = selected.map { $0.entityName }.sorted()
        guard Set(names).count == names.count,
              names.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }) else { throw OrdinarySyncExportError.invalidScope }
        guard let native = backend.asCxxLatticeRef else { throw OrdinarySyncExportError.unsupportedBackend }
        var requested = lattice.StringVector()
        for name in names { requested.push_back(std.string(name)) }
        let selection = native.ordinarySyncObservationTables(models: requested)
        guard selection.isValid(), let count = Int(exactly: selection.tableCount()),
              (1...8_448).contains(count) else {
            throw OrdinarySyncExportError.observationRefused(String(selection.failure()))
        }
        var tokens: [TableObservationToken] = []
        tokens.reserveCapacity(count)
        var completed = false
        defer { if !completed { state.stop(); for token in tokens { token.cancel() } } }
        var retainedNameBytes = 0
        for index in 0..<count {
            let table = selection.table(index)
            let name = String(table)
            guard !name.isEmpty, name.utf8.count <= 256 else {
                throw OrdinarySyncExportError.observationRefused("invalid projected table name")
            }
            retainedNameBytes += name.utf8.count
            guard retainedNameBytes <= 4_194_304 else { throw OrdinarySyncExportError.observationCapacity }
            // The native wrapper consumes this retained context even if its
            // registration fails. Swift never performs a second release.
            let context = Unmanaged.passRetained(state).toOpaque()
            let id = native.add_payload_free_table_observer(table, context, { context in
                guard let context else { return }
                Unmanaged<OrdinarySyncObservationState>.fromOpaque(context).takeUnretainedValue().fire()
            }, { context in
                guard let context else { return }
                Unmanaged<OrdinarySyncObservationState>.fromOpaque(context).release()
            })
            guard id != 0 else { throw OrdinarySyncExportError.observationRefused("table registration refused") }
            tokens.append(TableObservationToken(backend: backend, tableName: name, observerId: id))
        }
        completed = true
        return AnyCancellable {
            state.stop()
            for token in tokens { token.cancel() }
        }
    }
}

// Only a retry hint. Never owns a source/cut and never performs SQL in a native
// destructor callback. Consumers register before capture and recheck lifetime.
private final class OrdinaryExportCapacityCallback: @unchecked Sendable {
    let active = UnfairLock<Bool>(initialState: true)
    let block: @Sendable () -> Void
    init(_ block: @escaping @Sendable () -> Void) { self.block = block }
    func fire() { if active.withLockUnchecked({ $0 }) { block() } }
    func stop() { active.withLockUnchecked { $0 = false } }
}
private final class OrdinaryExportCapacityToken: @unchecked Sendable {
    private let value: UnfairLock<lattice.ordinary_sync_export_capacity_ref?>
    init(_ native: lattice.ordinary_sync_export_capacity_ref) { value = .init(initialState: native) }
    func cancel() {
        var retained = value.withLockUnchecked { current in let old = current; current = nil; return old }
        retained?.cancel() // callback/context destruction only after the Swift lock is released
    }
    deinit { cancel() }
}
extension Lattice {
    public static func observeOrdinaryExportCapacity(_ block: @escaping @Sendable () -> Void) throws -> AnyCancellable {
        let state = OrdinaryExportCapacityCallback(block)
        let context = Unmanaged.passRetained(state).toOpaque()
        let native = lattice.ordinary_sync_export_capacity_ref.observe(context, notify: { context in
            guard let context else { return }
            Unmanaged<OrdinaryExportCapacityCallback>.fromOpaque(context).takeUnretainedValue().fire()
        }, release: { context in
            guard let context else { return }
            Unmanaged<OrdinaryExportCapacityCallback>.fromOpaque(context).release()
        })
        guard native.isValid() else { state.stop(); throw OrdinarySyncExportError.observationCapacity }
        let token = OrdinaryExportCapacityToken(native)
        return AnyCancellable { state.stop(); token.cancel() }
    }
}
