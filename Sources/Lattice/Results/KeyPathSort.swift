import Foundation

/// A Lattice-native sort comparator that carries an already-resolved column
/// name and sort order.
///
/// Lattice sorts in SQL (the `compare` requirement is never invoked), so all we
/// need to carry across the result-builder plumbing is the column name. We store
/// this instead of a `Foundation.SortDescriptor` on the older-OS path because
/// `SortDescriptor.keyPath` — the only way to recover the key path from a
/// `SortDescriptor` — is iOS 16.0 / macOS 13.0... actually iOS 17 only. Resolving
/// the column from a key path at `sortedBy(_:order:)` call time avoids touching
/// that property entirely, so sorting works down to the iOS 15 floor.
///
/// It is stored through the existing `sortStatement: (any SortComparator)?`
/// fields, mirroring how `SortDescriptor` is stored as an existential there.
struct KeyPathSort<Compared>: SortComparator {
    let column: String
    var order: SortOrder

    // Never called — ordering happens in SQL — but required by SortComparator.
    func compare(_ lhs: Compared, _ rhs: Compared) -> ComparisonResult { .orderedSame }
}
