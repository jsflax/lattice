import Foundation
import SQLite3
import LatticeSwiftCppBridge
import LatticeSwiftModule
import CxxStdlib

public protocol StaticString {
    static var string: String { get }
}

public protocol StaticInt32 {
    static var int32: Int32 { get }
}

// MARK: - ModelStorage (hides CxxDynamicObjectRef from macro-generated code)

public struct ModelStorage: @unchecked Sendable {
    public var _ref: CxxDynamicObjectRef

    @inlinable public init(_ref: CxxDynamicObjectRef) { self._ref = _ref }

    public static func _default<M: Model>(_ type: M.Type) -> ModelStorage {
        ModelStorage(_ref: CxxDynamicObjectRef.wrap(_defaultCxxLatticeObject(type))!)
    }
}

public protocol CxxObject {
    func getInt(named name: borrowing std.string) -> lattice.int64_t
    func getString(named name: borrowing std.string) -> std.string
    func getBool(named name: borrowing std.string) -> Bool
    func getData(named name: borrowing std.string) -> lattice.ByteVector
    func getDouble(named name: borrowing std.string) -> Double
    func getFloat(named name: borrowing std.string) -> Float
    func getObject(named name: borrowing std.string) -> lattice.dynamic_object
    func getLinkList(named name: borrowing std.string) -> UnsafeMutablePointer<lattice.link_list>!
    
    mutating func setInt(named name: borrowing std.string, _ value: lattice.int64_t)
    mutating func setString(named name: borrowing std.string, _ value: borrowing std.string)
    mutating func setBool(named name: borrowing std.string, _ value: Bool)
    mutating func setData(named name: borrowing std.string, _ value: borrowing lattice.ByteVector)
    mutating func setDouble(named name: borrowing std.string, _ value: Double)
    mutating func setFloat(named name: borrowing std.string, _ value: Float)
    mutating func setObject(named name: borrowing std.string, _ value: inout lattice.dynamic_object)
    mutating func setNil(named name: borrowing std.string)
    
    func hasValue(named name: borrowing std.string) -> Bool
}

// CxxManaged - Marker for types that have a C++ managed<T> equivalent
// Uses conversion methods since CxxManagedSpecialization.SwiftType may differ from Self
public protocol CxxManaged {
//    associatedtype CxxManagedSpecialization: CxxManagedType

    static func getField(from storage: inout ModelStorage, named name: String) -> Self
    static func setField(on storage: inout ModelStorage, named name: String, _ value: Self)
}

public protocol CxxListManaged: CxxManaged {
    associatedtype CxxManagedListType: CxxManagedType
    
    static func getManagedList(from object: lattice.ManagedModel, name: std.string) -> Self.CxxManagedListType
}

extension lattice.OptionalManagedModel: OptionalProtocol {
    public func value() -> value_type {
        self.pointee
    }
    
    public func hasValue() -> Bool {
        self.__convertToBool()
    }
    
    public var pointee: lattice.ManagedModel {
        get {
            lattice.from_optional(self)
        }
        set {
            self = lattice.from_nonoptional(newValue)
        }
    }
}

// MARK: - CxxManaged Conformances for Swift types

extension String: CxxListManaged {
    public typealias CxxManagedSpecialization = lattice.ManagedString
    public typealias CxxManagedListType = lattice.ManagedStringList

    public static func fromCxxValue(_ value: std.string) -> String { String(value) }
    public func toCxxValue() -> std.string { std.string(self) }

    public static func getUnmanaged(from object: lattice.swift_dynamic_object, name: std.string) -> String {
        String(object.get_string(name))
    }
    public func setUnmanaged(to object: inout lattice.swift_dynamic_object, name: std.string) {
        object.set_string(name, std.string(self))
    }
    
    public static func getManaged(from object: lattice.ManagedModel, name: std.string) -> CxxManagedSpecialization {
        object.get_managed_field(name)
    }
    public static func getManagedList(from object: lattice.ManagedModel, name: std.string) -> CxxManagedListType {
        object.get_managed_field(name)
    }
    public static func getManagedOptional(from object: lattice.ManagedModel, name: std.string) -> CxxManagedSpecialization.OptionalType {
        object.get_managed_field(name)
    }
    public static func getField(from storage: inout ModelStorage, named name: String) -> String {
        String(storage._ref.getString(named: std.string(name)))
    }
    public static func setField(on storage: inout ModelStorage, named name: String, _ value: String) {
        storage._ref.setString(named: std.string(name), std.string(value))
    }
    public func setManaged(_ managed: CxxManagedSpecialization, lattice: Lattice) {}
}

extension Int: CxxListManaged, DefaultInitializable {
    public typealias CxxManagedSpecialization = lattice.ManagedInt
    public typealias CxxManagedListType = lattice.ManagedIntList

    public static func fromCxxValue(_ value: lattice.int64_t) -> Int { Int(value) }
    public func toCxxValue() -> lattice.int64_t { Int64(self) }

    public static func getField(from storage: inout ModelStorage, named name: String) -> Self {
        Int(storage._ref.getInt(named: std.string(name)))
    }
    public static func setField(on storage: inout ModelStorage, named name: String, _ value: Int) {
        storage._ref.setInt(named: std.string(name), Int64(value))
    }
    public static func getUnmanaged(from object: lattice.swift_dynamic_object, name: std.string) -> Int {
        Int(object.get_int(name))
    }
    public func setUnmanaged(to object: inout lattice.swift_dynamic_object, name: std.string) {
        object.set_int(name, Int64(self))
    }
    public static func getManaged(from object: lattice.ManagedModel, name: std.string) -> CxxManagedSpecialization {
        object.get_managed_field(name)
    }
    public static func getManagedList(from object: lattice.ManagedModel, name: std.string) -> CxxManagedListType {
        object.get_managed_field(name)
    }
    public static func getManagedOptional(from object: lattice.ManagedModel, name: std.string) -> CxxManagedSpecialization.OptionalType {
        object.get_managed_field(name)
    }
    public func setManaged(_ managed: CxxManagedSpecialization, lattice: Lattice) {}
}

extension Double: CxxListManaged {
    public typealias CxxManagedSpecialization = lattice.ManagedDouble
    public typealias CxxManagedListType = lattice.ManagedDoubleList

    public static func fromCxxValue(_ value: Double) -> Double { value }
    public func toCxxValue() -> Double { self }

    public static func getManaged(from object: lattice.ManagedModel, name: std.string) -> CxxManagedSpecialization {
        object.get_managed_field(name)
    }
    public static func getManagedList(from object: lattice.ManagedModel, name: std.string) -> CxxManagedListType {
        object.get_managed_field(name)
    }
    public static func getField(from storage: inout ModelStorage, named name: String) -> Double {
        storage._ref.getDouble(named: std.string(name))
    }
    public static func setField(on storage: inout ModelStorage, named name: String, _ value: Double) {
        storage._ref.setDouble(named: std.string(name), value)
    }
}

extension Bool: CxxListManaged {
    public typealias CxxManagedSpecialization = lattice.ManagedBool
    public typealias CxxManagedListType = lattice.ManagedBoolList

    public static func fromCxxValue(_ value: Bool) -> Bool { value }
    public func toCxxValue() -> Bool { self }

    public static func getUnmanaged(from object: lattice.swift_dynamic_object, name: std.string) -> Bool {
        object.get_bool(name)
    }
    public func setUnmanaged(to object: inout lattice.swift_dynamic_object, name: std.string) {
        object.set_bool(name, self)
    }
    public static func getManaged(from object: lattice.ManagedModel, name: std.string) -> CxxManagedSpecialization {
        object.get_managed_field(name)
    }
    public static func getManagedList(from object: lattice.ManagedModel, name: std.string) -> CxxManagedListType {
        object.get_managed_field(name)
    }
    public static func getManagedOptional(from object: lattice.ManagedModel, name: std.string) -> CxxManagedSpecialization.OptionalType {
        object.get_managed_field(name)
    }
    public static func getField(from storage: inout ModelStorage, named name: String) -> Bool {
        storage._ref.getBool(named: std.string(name))
    }
    public static func setField(on storage: inout ModelStorage, named name: String, _ value: Bool) {
        storage._ref.setBool(named: std.string(name), value)
    }
}

extension Float: CxxListManaged {
    public typealias CxxManagedSpecialization = lattice.ManagedFloat
    public typealias CxxManagedListType = lattice.ManagedFloatList

    public static func fromCxxValue(_ value: Float) -> Float { value }
    public func toCxxValue() -> Float { self }

    public static func getUnmanaged(from object: lattice.swift_dynamic_object, name: std.string) -> Float {
        Float(object.get_double(name))
    }
    public func setUnmanaged(to object: inout lattice.swift_dynamic_object, name: std.string) {
        object.set_double(name, Double(self))
    }
    public static func getManaged(from object: lattice.ManagedModel, name: std.string) -> CxxManagedSpecialization {
        object.get_managed_field(name)
    }
    public static func getManagedList(from object: lattice.ManagedModel, name: std.string) -> CxxManagedListType {
        object.get_managed_field(name)
    }
    public static func getManagedOptional(from object: lattice.ManagedModel, name: std.string) -> CxxManagedSpecialization.OptionalType {
        object.get_managed_field(name)
    }
    public func setManaged(_ managed: CxxManagedSpecialization, lattice: Lattice) {}
    public static func getField(from storage: inout ModelStorage, named name: String) -> Float {
        storage._ref.getFloat(named: std.string(name))
    }
    public static func setField(on storage: inout ModelStorage, named name: String, _ value: Float) {
        storage._ref.setFloat(named: std.string(name), value)
    }
}

// Int64 uses ManagedInt since Swift Int is 64-bit on modern platforms
extension Int64: CxxListManaged {
    public typealias CxxManagedListType = lattice.ManagedIntList
    public typealias CxxManagedSpecialization = lattice.ManagedInt

    public static func fromCxxValue(_ value: lattice.int64_t) -> Int64 { Int64(value) }
    public func toCxxValue() -> lattice.int64_t { self }

    public static func getUnmanaged(from object: lattice.swift_dynamic_object, name: std.string) -> Int64 {
        object.get_int(name)
    }
    public func setUnmanaged(to object: inout lattice.swift_dynamic_object, name: std.string) {
        object.set_int(name, self)
    }
    public static func getManaged(from object: lattice.ManagedModel, name: std.string) -> CxxManagedSpecialization {
        object.get_managed_field(name)
    }
    public static func getManagedList(from object: lattice.ManagedModel, name: std.string) -> CxxManagedListType {
        object.get_managed_field(name)
    }
    public static func getManagedOptional(from object: lattice.ManagedModel, name: std.string) -> CxxManagedSpecialization.OptionalType {
        object.get_managed_field(name)
    }
    public func setManaged(_ managed: CxxManagedSpecialization, lattice: Lattice) {}
    public static func getField(from storage: inout ModelStorage, named name: String) -> Int64 {
        Int64(storage._ref.getInt(named: std.string(name)))
    }
    public static func setField(on storage: inout ModelStorage, named name: String, _ value: Int64) {
        storage._ref.setInt(named: std.string(name), value)
    }
}

// MARK: - Extended Types (Date, UUID, Data)

//extension lattice.ManagedTimestamp: CxxManagedType {
//    public typealias CxxManagedOptionalType = Self
//    public func get() -> Date {
//        // Convert chrono time_point to Date via seconds since epoch
//        let duration = self.detach().time_since_epoch()
//        let nanoseconds = Int64(duration.count())
//        let seconds = Double(nanoseconds) / 1_000_000_000.0
//        return Date(timeIntervalSince1970: seconds)
//    }
//
//    public mutating func set(_ newValue: Date) {
//        // Handled at Accessor level for now
//    }
//    
//    public static func getManagedField(from object: lattice.ManagedModel, with name: String) -> Self {
//        return object.get_managed_field(std.string(name))
//    }
//}

extension Date: CxxListManaged {
    public typealias CxxManagedListType = lattice.ManagedListTimestamp
    
    public typealias CxxManagedSpecialization = lattice.ManagedTimestamp

    public static func fromCxxValue(_ value: lattice.ManagedTimestamp.SwiftType) -> Date {
        let duration = value.time_since_epoch()
        let nanoseconds = Int64(duration.count())
        let seconds = Double(nanoseconds) / 1_000_000_000.0
        return Date(timeIntervalSince1970: seconds)
    }
    
    public func toCxxValue() -> lattice.ManagedTimestamp.SwiftType {
        lattice.ManagedTimestamp.SwiftType.init(.init(.seconds(self.timeIntervalSince1970)))
    }

    public static func getUnmanaged(from object: lattice.swift_dynamic_object, name: std.string) -> Date {
        // Stored as ISO8601 string or timestamp
        let str = String(object.get_string(name))
        if let date = ISO8601DateFormatter().date(from: str) {
            return date
        }
        // Try as timestamp
        let timestamp = object.get_double(name)
        return Date(timeIntervalSince1970: timestamp)
    }
    public static func getField(from storage: inout ModelStorage, named name: String) -> Date {
        // Stored as ISO8601 string or timestamp
//        let str = String(storage._ref.getString(named: std.string(name)))
//        if let date = ISO8601DateFormatter().date(from: str) {
//            return date
//        }
        // Try as timestamp
        let timestamp = storage._ref.getDouble(named: std.string(name))
        return Date(timeIntervalSince1970: timestamp)
    }
    public static func setField(on storage: inout ModelStorage, named name: String, _ value: Date) {
        storage._ref.setDouble(named: std.string(name), value.timeIntervalSince1970)
    }
    
    public func setUnmanaged(to object: inout lattice.swift_dynamic_object, name: std.string) {
        object.set_double(name, self.timeIntervalSince1970)
    }
    public static func getManaged(from object: lattice.ManagedModel, name: std.string) -> CxxManagedSpecialization {
        object.get_managed_field(name)
    }
    public static func getManagedList(from object: lattice.ManagedModel, name: std.string) -> CxxManagedListType {
        object.get_managed_field(name)
    }
    public static func getManagedOptional(from object: lattice.ManagedModel, name: std.string) -> CxxManagedSpecialization.OptionalType {
        object.get_managed_field(name)
    }
    public func setManaged(_ managed: CxxManagedSpecialization, lattice: Lattice) {}
}

extension UUID: CxxListManaged {
    public typealias CxxManagedListType = lattice.ManagedListUUID
    public typealias CxxManagedSpecialization = lattice.ManagedUUID

    public static func fromCxxValue(_ value: lattice.uuid_t) -> UUID {
        let str = String(value.to_string())
        return UUID(uuidString: str) ?? UUID()
    }
    public func toCxxValue() -> lattice.uuid_t {
        lattice.uuid_t.from_string(std.string(self.uuidString))
    }

    public static func getUnmanaged(from object: lattice.swift_dynamic_object, name: std.string) -> UUID {
        let str = String(object.get_string(name))
        return UUID(uuidString: str) ?? UUID()
    }
    public func setUnmanaged(to object: inout lattice.swift_dynamic_object, name: std.string) {
        object.set_string(name, std.string(self.uuidString))
    }
    public static func getManaged(from object: lattice.ManagedModel, name: std.string) -> CxxManagedSpecialization {
        object.get_managed_field(name)
    }
    public static func getManagedList(from object: lattice.ManagedModel, name: std.string) -> CxxManagedListType {
        object.get_managed_field(name)
    }
    public static func getManagedOptional(from object: lattice.ManagedModel, name: std.string) -> CxxManagedSpecialization.OptionalType {
        object.get_managed_field(name)
    }
    public func setManaged(_ managed: CxxManagedSpecialization, lattice: Lattice) {}
    public static func getField(from storage: inout ModelStorage, named name: String) -> UUID {
        UUID(uuidString: String(storage._ref.getString(named: std.string(name)))) ?? UUID()
    }
    public static func setField(on storage: inout ModelStorage, named name: String, _ value: UUID) {
        storage._ref.setString(named: std.string(name), std.string(value.uuidString))
    }
}

extension Data: CxxManaged {
    public typealias CxxManagedSpecialization = lattice.ManagedData

    public static func fromCxxValue(_ value: CxxManagedSpecialization.SwiftType) -> Data {
        Data(value.map { $0 })
    }
    public func toCxxValue() -> CxxManagedSpecialization.SwiftType {
        CxxManagedSpecialization.SwiftType(self)
    }
    
    public static func getField(from storage: inout ModelStorage, named name: String) -> Data {
        Data(storage._ref.getData(named: std.string(name)))
    }
    public static func setField(on storage: inout ModelStorage, named name: String, _ value: Data) {
        storage._ref.setData(named: std.string(name), value.reduce(into: lattice.ByteVector(), { $0.push_back($1) }))
    }
    public func setUnmanaged(to object: inout lattice.swift_dynamic_object, name: std.string) {
        var vec = lattice.ByteVector()
        for byte in self {
            vec.push_back(byte)
        }
        object.set_blob(name, vec)
    }
    public static func getManaged(from object: lattice.ManagedModel, name: std.string) -> CxxManagedSpecialization {
        object.get_managed_field(name)
    }
    public static func getManagedOptional(from object: lattice.ManagedModel, name: std.string) -> CxxManagedSpecialization.OptionalType {
        object.get_managed_field(name)
    }
    public func setManaged(_ managed: CxxManagedSpecialization, lattice: Lattice) {}
}

// MARK: - Optional conformance
extension lattice.ManagedOptionalInt.SwiftType: OptionalProtocol {
    public init(_ wrapped: consuming value_type) {
        self.init()
        self.pointee = wrapped
    }
    
    public func value() -> value_type {
        self.pointee
    }
    
    public func hasValue() -> Bool {
        self.has_value()
    }
}
extension lattice.ManagedOptionalDouble.SwiftType: OptionalProtocol {
    public init(_ wrapped: consuming value_type) {
        self.init()
        self.pointee = wrapped
    }
    
    public func value() -> value_type {
        self.pointee
    }
    
    public func hasValue() -> Bool {
        self.has_value()
    }
}
extension lattice.ManagedOptionalUUID.SwiftType: OptionalProtocol {
    public init(_ wrapped: consuming value_type) {
        self.init()
        self.pointee = wrapped
    }
    
    public func value() -> value_type {
        self.pointee
    }
    
    public func hasValue() -> Bool {
        self.has_value()
    }
}
extension lattice.ManagedOptionalString.SwiftType: OptionalProtocol {
    public init(_ wrapped: consuming value_type) {
        self.init()
        self.pointee = wrapped
    }
    
    public func value() -> value_type {
        self.pointee
    }
    
    public func hasValue() -> Bool {
        self.__convertToBool()
    }
}
extension lattice.ManagedOptionalTimestamp.SwiftType: OptionalProtocol {
    public init(_ wrapped: consuming value_type) {
        self.init()
        self.pointee = wrapped
    }
    public func value() -> value_type {
        self.pointee
    }
    
    public func hasValue() -> Bool {
        self.__convertToBool()
    }
}
extension lattice.ManagedOptionalStringList.SwiftType: OptionalProtocol {
    public init(_ wrapped: consuming value_type) {
        self.init()
        self.pointee = wrapped
    }
    public func value() -> value_type {
        self.pointee
    }
    
    public func hasValue() -> Bool {
        self.__convertToBool()
    }
}

extension lattice.ManagedOptionalBool: OptionalProtocol {
    public init(_ wrapped: consuming Bool) {
        self.init()
        self.pointee = wrapped
    }
    public func value() -> Bool {
        self.pointee
    }
    
    public func hasValue() -> Bool {
        self.__convertToBool()
    }
}

// Optional<T> conforms to CxxManaged when T does, using the same specialization
// Conversion wraps/unwraps the optional around T's conversion
extension Optional: CxxManaged where Wrapped: CxxManaged {
//    public typealias CxxManagedSpecialization = Wrapped.CxxManagedSpecialization.OptionalType

    public static func getField(from storage: inout ModelStorage, named name: String) -> Optional<Wrapped> {
        guard storage._ref.hasValue(named: std.string(name)) else {
            return nil
        }
        return Wrapped.getField(from: &storage, named: name)
    }

    public static func setField(on storage: inout ModelStorage, named name: String, _ value: Optional<Wrapped>) {
        if let value {
            Wrapped.setField(on: &storage, named: name, value)
        } else {
            storage._ref.setNil(named: std.string(name))
        }
    }
}

// For Array of CxxListManaged types
extension Array: CxxManaged where Element: CxxListManaged, Element: Codable {
    public typealias CxxManagedSpecialization = Element.CxxManagedListType

    public static func fromCxxValue(_ value: Element.CxxManagedListType.SwiftType) -> [Element] {
        // The list type's SwiftType should be [Element], so this is identity-like
        // But we need to cast since Swift doesn't know they're the same
        return value as! [Element]
    }

    public func toCxxValue() -> Element.CxxManagedListType.SwiftType {
        return self as! Element.CxxManagedListType.SwiftType
    }

    public func setManaged(_ managed: CxxManagedSpecialization, lattice: Lattice) {}
    
    public static func getField(from storage: inout ModelStorage, named name: String) -> Array<Element> {
        guard let data = String(storage._ref.getString(named: std.string(name))).data(using: .utf8) else {
            return []
        }
        do {
            return try JSONDecoder().decode(Self.self, from: data)
        } catch {
            return []
        }
    }

    public static func setField(on storage: inout ModelStorage, named name: String, _ value: Array<Element>) {
        try! storage._ref.setString(named: std.string(name),
                              std.string(String(data: JSONEncoder().encode(value), encoding: .utf8)!))
    }
}

extension Set: CxxManaged where Element: CxxListManaged, Element: Codable {
    public typealias CxxManagedSpecialization = Element.CxxManagedListType

    public static func fromCxxValue(_ value: Element.CxxManagedListType.SwiftType) -> [Element] {
        // The list type's SwiftType should be [Element], so this is identity-like
        // But we need to cast since Swift doesn't know they're the same
        return value as! [Element]
    }

    public func toCxxValue() -> Element.CxxManagedListType.SwiftType {
        return self as! Element.CxxManagedListType.SwiftType
    }

    public static func getManaged(from object: lattice.ManagedModel, name: std.string) -> CxxManagedSpecialization {
        Element.getManagedList(from: object, name: name)
    }
    public static func getManagedOptional(from object: lattice.ManagedModel, name: std.string) -> Element.CxxManagedListType.OptionalType {
        fatalError()
    }
    public func setManaged(_ managed: CxxManagedSpecialization, lattice: Lattice) {}
    
    public static func getField(from storage: inout ModelStorage, named name: String) -> Set<Element> {
        guard let data = String(storage._ref.getString(named: std.string(name))).data(using: .utf8) else {
            return []
        }
        do {
            return try JSONDecoder().decode(Self.self, from: data)
        } catch {
            return []
        }
    }

    public static func setField(on storage: inout ModelStorage, named name: String, _ value: Set<Element>) {
        try! storage._ref.setString(named: std.string(name),
                              std.string(String(data: JSONEncoder().encode(value), encoding: .utf8)!))
    }
}

// For Array of Optional CxxListManaged types (e.g., [String?]?)
extension Optional: CxxListManaged where Wrapped: CxxListManaged {
    public typealias CxxManagedListType = Wrapped.CxxManagedListType
    
    public static func getManagedList(from object: lattice.ManagedModel, name: std.string) -> Wrapped.CxxManagedListType {
        Wrapped.getManagedList(from: object, name: name)
    }
    
}

extension String: @retroactive RawRepresentable {
    public init?(rawValue: String) {
        self = rawValue
    }
    
    public var rawValue: String {
        self
    }
}

// MARK: - Dictionary Support (JSON serialized as String)
// Dictionaries are stored as JSON text
extension Dictionary: CxxManaged where Key: RawRepresentable, Value: Codable, Key.RawValue == String, Key: Codable {
    public typealias CxxManagedSpecialization = lattice.ManagedString

    public static func getUnmanaged(from object: lattice.swift_dynamic_object, name: std.string) -> [Key: Value] {
        let str = String(object.get_string(name))
        guard let data = str.data(using: .utf8),
              let dict = try? JSONDecoder().decode([Key: Value].self, from: data) else {
            return [:]
        }
        return dict
    }

    public static func getField(from storage: inout ModelStorage, named name: String) -> Dictionary<Key, Value> {
        let str = String(storage._ref.getString(named: std.string(name)))
        guard let data = str.data(using: .utf8),
              let dict = try? JSONDecoder().decode([Key: Value].self, from: data) else {
            return [:]
        }
        return dict
    }
    public static func setField(on storage: inout ModelStorage, named name: String, _ value: Dictionary<Key, Value>) {
        guard let data = try? JSONEncoder().encode(value),
              let json = String(data: data, encoding: .utf8) else {
            storage._ref.setString(named: std.string(name), std.string("{}"))
            return
        }
        storage._ref.setString(named: std.string(name), std.string(json))
    }
    
    public static func getManaged(from object: lattice.ManagedModel, name: std.string) -> CxxManagedSpecialization {
        object.get_managed_field(name)
    }
    public static func getManagedOptional(from object: lattice.ManagedModel, name: std.string) -> CxxManagedSpecialization.OptionalType {
        object.get_managed_field(name)
    }
    public func setManaged(_ managed: CxxManagedSpecialization, lattice: Lattice) {}
}

@propertyWrapper public struct Property<Value> where Value: CxxManaged,
                                                        Value: SchemaProperty {
    public var wrappedValue: Value
//    private var managedValue: Value.CxxManagedSpecialization?
    var name: String
    
    public init(name: String) {
        self.name = name
        self.wrappedValue = Value.defaultValue
    }
    
    public init(wrappedValue: Value, name: String) {
        self.name = name
        self.wrappedValue = wrappedValue
    }

    /// Push the default value into unmanaged storage
    public mutating func pushDefaultToStorage(_ storage: inout ModelStorage) {
        Value.setField(on: &storage, named: name, wrappedValue)
    }

    public static subscript<M: Model>(
        _enclosingInstance object: M,
        wrapped wrappedKeyPath: ReferenceWritableKeyPath<M, Value>,
        storage storageKeyPath: ReferenceWritableKeyPath<M, Property<Value>>
    ) -> Value {
        get {
            let nameStr = object[keyPath: storageKeyPath].name
            object._lastKeyPathUsed = nameStr
            return Value.getField(from: &object._dynamicObject, named: nameStr)
        }
        set {
            Value.setField(on: &object._dynamicObject, named: object[keyPath: storageKeyPath].name, newValue)
        }
    }
}

/// Push the default value into unmanaged storage
public func _pushDefaultToStorage<Value: CxxManaged>(_ storage: inout ModelStorage,
                                                     name: String,
                                                     value: Value) {
    Value.setField(on: &storage, named: name, value)
}
// MARK: - LatticeEnum Support
// LatticeEnum inherits CxxManaged from its protocol definition in Property.swift
// The typealias CxxManagedSpecialization = RawValue.CxxManagedSpecialization is provided there
