import Foundation

public protocol ListProperty {
    static func _get(name: String, parent: some Model, lattice: Lattice, primaryKey: Int64) -> Self
    static func _set(name: String,
                     parent: some Model, lattice: Lattice, primaryKey: Int64, newValue: Self)
    
    init()
}
