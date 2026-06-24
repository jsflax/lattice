import Foundation

// MARK: - DetachedResults: a fine-grained reactive collection of detached values
//
// The coarse `@LatticeQuery` wrapper full-refetches (`snapshot()`) and invalidates
// its ENTIRE owning view on every change. `DetachedResults` is the fine-grained
// counterpart: it observes a table once and, per `CollectionChange`, fetches +
// detaches only the changed row, publishing a `[D.DetachedRepr]` of **Sendable
// value snapshots** that SwiftUI can diff per-row (so only the changed row's view
// re-renders, and no live `@Model` ref ever reaches the view body).
//
// Threading (verified against `Lattice.observe`, Lattice.swift:1450): the observe
// block fires on a background `Task.detached` whose re-resolved `isolation` is
// `nil`, so the block runs OFF the main actor. It `yield`s the `Sendable`
// `CollectionChange` into an `AsyncStream`; one detached worker drains the stream
// IN ORDER, resolves its own lattice handle ONCE (not per-callback — the
// "races-under-load" footgun), and runs `object(primaryKey:)` + `_detached`
// off-main. `_detached` has no isolation requirement and yields a `Sendable`
// value (Backend.swift accessor contract), which is the only thing that crosses
// back to `@MainActor` to splice `items`.

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
@MainActor
@Observable
public final class DetachedResults<D: Model & Detachable> {
    /// The prepared snapshots, in sorted order. Each element is `D.DetachedRepr`
    /// (for a model: `DetachedRef<D.Detached>`) — read a field via `DetachedRef`'s
    /// `@dynamicMemberLookup` (`item.someField`) or the whole struct via `.value`.
    public private(set) var items: [D.DetachedRepr] = []

    /// Monotonic change counter. A downstream `@Observable` (e.g. a render-model)
    /// reads this to recompute a derived view of `items` exactly once per change
    /// (memoize on `version`) rather than on every SwiftUI body evaluation.
    public private(set) var version: Int = 0

    /// rowId (SQLite primary key, == `CollectionChange`'s associated value) →
    /// current index in `items`. Keyed off the change's rowId so we never read
    /// `primaryKey` back off the opaque `DetachedRepr` (which isn't possible
    /// generically — the protocol only promises `Sendable & Codable`).
    @ObservationIgnored private var indexByRow: [Int64: Int] = [:]
    @ObservationIgnored private let areInIncreasingOrder: (D.DetachedRepr, D.DetachedRepr) -> Bool

    // Cleanup handles touched from the (nonisolated) deinit as well as the main
    // actor; `nonisolated(unsafe)` is sound here because they're only mutated on
    // the main actor (init/stop) and read in deinit after the last ref is gone.
    @ObservationIgnored nonisolated(unsafe) private var observeToken: AnyCancellable?
    @ObservationIgnored nonisolated(unsafe) private var workerTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var continuation: AsyncStream<CollectionChange>.Continuation?

    /// - Parameters:
    ///   - lattice: the (main-actor) handle used for the synchronous initial load;
    ///     a private worker resolves its own handle from `lattice.sendableReference`.
    ///   - predicate: optional row filter (else the whole table).
    ///   - maxDepth: detach depth for each row (see `@Detached`).
    ///   - areInIncreasingOrder: sort comparator over the detached reprs (e.g. by
    ///     a `createdAt` field read through `DetachedRef`'s dynamic member).
    public init(lattice: Lattice,
                where predicate: LatticePredicate<D>? = nil,
                maxDepth: Int = 5,
                sortedBy areInIncreasingOrder: @escaping (D.DetachedRepr, D.DetachedRepr) -> Bool) {
        self.areInIncreasingOrder = areInIncreasingOrder

        // (1) Arm observation FIRST and buffer (.unbounded) — so a write that lands
        //     during the initial snapshot below is queued, not lost; the rowId→index
        //     map makes its later application idempotent against the snapshot.
        var cont: AsyncStream<CollectionChange>.Continuation!
        let stream = AsyncStream<CollectionChange>(bufferingPolicy: .unbounded) { cont = $0 }
        self.continuation = cont
        self.observeToken = lattice.observe(D.self, where: predicate) { [cont] change in
            cont?.yield(change)
        }

        // (2) Synchronous initial load on the caller's (main) lattice — avoids an
        //     empty first frame (parity with @LatticeQuery's synchronous fetch).
        let base = (predicate.map { lattice.objects(D.self).where($0) } ?? lattice.objects(D.self)).snapshot()
        var initial: [(rowId: Int64, repr: D.DetachedRepr)] = []
        initial.reserveCapacity(base.count)
        for m in base {
            guard let pk = m.primaryKey else { continue }
            var visited: Set<DetachKey> = []
            initial.append((pk, m._detached(remainingDepth: maxDepth, visited: &visited)))
        }
        initial.sort { areInIncreasingOrder($0.repr, $1.repr) }
        self.items = initial.map(\.repr)
        self.indexByRow = Dictionary(uniqueKeysWithValues: initial.enumerated().map { ($1.rowId, $0) })

        // (3) Drain the buffered + live stream off-main on a single worker.
        let ref = lattice.sendableReference
        self.workerTask = Task.detached(priority: .utility) { [weak self] in
            guard let workerLattice = ref.resolve() else { return }   // resolved off-main → isolation nil
            for await change in stream {
                if Task.isCancelled { break }
                // Invariant: the fetch + detach must NOT run on the main thread (that's the whole point —
                // a deep detach off a streaming row shouldn't block the UI). Checked in debug + tests.
                assert(!Thread.isMainThread, "DetachedResults: reads/detach must run off the main thread")
                guard let update = Self.computeUpdate(change, on: workerLattice, maxDepth: maxDepth) else { continue }
                await self?.apply(update)
            }
        }
    }

    deinit {
        observeToken?.cancel()
        workerTask?.cancel()
        continuation?.finish()
    }

    /// Cancel observation + the worker. Owners call this on teardown (e.g.
    /// `RoomRuntime.deleteRoom`, for symmetry with `orchestrator.stop()`); the
    /// handles also auto-cancel on deinit.
    public func stop() {
        observeToken?.cancel(); observeToken = nil
        workerTask?.cancel(); workerTask = nil
        continuation?.finish(); continuation = nil
    }

    // MARK: Off-main fetch + detach (runs on the worker; never touches `self`)

    private enum RowUpdate: Sendable {
        case upsert(rowId: Int64, repr: D.DetachedRepr)
        case remove(rowId: Int64)
    }

    nonisolated private static func computeUpdate(_ change: CollectionChange,
                                                  on lattice: Lattice, maxDepth: Int) -> RowUpdate? {
        switch change {
        case .insert(let rowId), .update(let rowId):
            guard let model = lattice.object(D.self, primaryKey: rowId) else {
                return .remove(rowId: rowId)   // row vanished between notification and fetch
            }
            var visited: Set<DetachKey> = []
            return .upsert(rowId: rowId, repr: model._detached(remainingDepth: maxDepth, visited: &visited))
        case .delete(let rowId):
            return .remove(rowId: rowId)
        }
    }

    // MARK: Splice (main actor; cheap pure-value work)

    /// Apply one delta. In-place on UPDATE assumes the SORT KEY is stable across
    /// updates (true for the chat's `createdAt`); a re-sort would be needed if a
    /// sort-key column could mutate.
    private func apply(_ update: RowUpdate) {
        switch update {
        case .upsert(let rowId, let repr):
            if let idx = indexByRow[rowId] {
                items[idx] = repr
            } else {
                let pos = items.firstIndex(where: { areInIncreasingOrder(repr, $0) }) ?? items.count
                items.insert(repr, at: pos)
                for (k, v) in indexByRow where v >= pos { indexByRow[k] = v + 1 }
                indexByRow[rowId] = pos
            }
        case .remove(let rowId):
            guard let idx = indexByRow.removeValue(forKey: rowId) else { return }
            items.remove(at: idx)
            for (k, v) in indexByRow where v > idx { indexByRow[k] = v - 1 }
        }
        version &+= 1
    }
}
