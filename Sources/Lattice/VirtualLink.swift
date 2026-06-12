import Foundation
import LatticeSwiftCppBridge
import LatticeSwiftModule

/// Marker type for virtual link properties in the `properties` array.
/// The macro generates `("propName", VirtualLinkMarker.self)` since
/// `(any VirtualModelProtocol)?` can't conform to `SchemaProperty`.
public struct VirtualLinkMarker: SchemaProperty {
    public static var anyPropertyKind: AnyProperty.Kind { .string }
    public static var defaultValue: VirtualLinkMarker { .init() }
}

/// Called from macro-generated accessor. Reads a virtual link via link_list_ref.
public func _getVirtualLink<T>(from storage: inout ModelStorage, named name: String) -> T? {
    let ref = storage._ref.getLinkList(named: name)
    guard ref.size > 0, let objRef = ref.object(at: 0) else { return nil }
    let tableName = objRef.tableName
    guard let modelType = ModelTypeRegistry.shared.resolve(tableName) else {
        fatalError("Unknown model type for table: \(tableName).")
    }
    return modelType.init(objRef) as? T
}

/// Called from macro-generated accessor. Writes a virtual link via link_list_ref.
public func _setVirtualLink<T>(on storage: inout ModelStorage, named name: String, _ value: T?) {
    let ref = storage._ref.getLinkList(named: name)
    ref.clear()
    if let model = value as? any Model {
        ref.pushBack(model._dynamicObject._ref)
    }
}
