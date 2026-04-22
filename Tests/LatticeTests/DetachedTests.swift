import Foundation
import Testing
import Lattice
import LatticeSwiftCppBridge

// TODO: drop @unchecked once C++ detach produces a self-owned dynamic_object
//   that is safe to conform to Sendable. dynamic_object is currently dual-mode
//   (managed/unmanaged), so the C++ type itself can't be blanket-Sendable —
//   the invariant "this one is detached" lives only at the Detached<T> type.
@dynamicMemberLookup struct Detached<T: Model>: @unchecked Sendable {
    var object: ModelStorage

    // Primitives, EmbeddedModel, Optional<primitive>, [primitive], Set, Dictionary.
    subscript<V>(dynamicMember keyPath: KeyPath<T, V>) -> V
        where V: PrimitiveProperty, V: CxxManaged {
        V.getField(from: object, named: T._nameForKeyPath(keyPath))
    }

    // One-to-one link: `var dog: Dog?` → `Detached<Dog>?`
    subscript<U>(dynamicMember keyPath: KeyPath<T, U?>) -> Detached<U>?
        where U: Model {
        guard let m: U = Optional<U>.getField(
            from: object,
            named: T._nameForKeyPath(keyPath)
        ) else {
            return nil
        }
        return Detached<U>(object: m._dynamicObject)
    }

    // Ordered one-to-many: `var dogs: List<Dog>` → `[Detached<Dog>]`
    subscript<U>(dynamicMember keyPath: KeyPath<T, List<U>>) -> [Detached<U>]
        where U: Model {
        List<U>.getField(from: object, named: T._nameForKeyPath(keyPath)).map {
            Detached<U>(object: $0._dynamicObject)
        }
    }

    // TODO: Union subscript dispatching through LatticeUnion.getField. Model-link
    //   case payloads may want further Detached<> wrapping rather than raw Model.
    // TODO: Array<Model> link collections if we still support that shape alongside List.
    // TODO: Vector<T> if detached vector reads are in scope.
}
