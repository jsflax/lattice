@_spi(LatticeInternals) import Lattice

func explicitDebugSPI(_ object: DynamicObject) throws {
    let _: Int64? = try object.debugPrimaryKey()
    let _: [String: Any] = try object.debugJSON()
    let _: DynamicDebugReadError = .queryFailed("diagnostic fixture")
}
