import Foundation
import SQLite3
import LatticeSwiftCppBridge

public protocol StaticString {
    static var string: String { get }
}

public protocol StaticInt32 {
    static var int32: Int32 { get }
}

public protocol CxxBridgeable {
    associatedtype CxxType
}

// CxxManaged - Marker for types that have a C++ managed<T> equivalent
// Uses conversion methods since CxxManagedSpecialization.SwiftType may differ from Self
public protocol CxxManaged {
    associatedtype CxxManagedSpecialization: CxxManagedType

    /// Convert from C++ representation to Swift type
    static func fromCxxValue(_ value: CxxManagedSpecialization.SwiftType) -> Self

    /// Convert from Swift type to C++ representation
    func toCxxValue() -> CxxManagedSpecialization.SwiftType

    /// Get value from unmanaged swift_dynamic_object
    static func getUnmanaged(from object: lattice.swift_dynamic_object, name: std.string) -> Self

    /// Set value on unmanaged swift_dynamic_object
    func setUnmanaged(to object: inout lattice.swift_dynamic_object, name: std.string)
}

public protocol CxxListManaged: CxxManaged {
    associatedtype CxxManagedListType: CxxManagedType
}

public protocol CxxManagedType {
    associatedtype SwiftType
    
    func get() -> SwiftType
    mutating func set(_ newValue: SwiftType)
    static func getManagedField(from object: lattice.ManagedModel, with name: String) -> Self
}

// MARK: - CxxManagedType Conformances for C++ managed types
extension lattice.ManagedString: CxxManagedType {
    public typealias CxxManagedOptionalType = lattice.ManagedOptionalString
    
    public func get() -> String {
        return String(self.detach())
    }

    public mutating func set(_ newValue: String) {
        self.set_value(std.string(newValue))
    }
    
    public static func getManagedField(from object: lattice.ManagedModel, with name: String) -> Self {
        return object.get_managed_field(std.string(name))
    }
}

extension lattice.ManagedInt: CxxManagedType {
    public typealias CxxManagedOptionalType = lattice.ManagedOptionalInt
    
    public func get() -> Int {
        return Int(self.detach())
    }

    public mutating func set(_ newValue: Int) {
        var copy = self
        copy = Self(Int64(newValue))
    }
    
    public static func getManagedField(from object: lattice.ManagedModel, with name: String) -> Self {
        return object.get_managed_field(std.string(name))
    }
}

extension lattice.ManagedDouble: CxxManagedType {
    public typealias CxxManagedOptionalType = lattice.ManagedOptionalDouble
    
    public func get() -> Double {
        return self.detach()
    }

    public mutating func set(_ newValue: Double) {
        var copy = self
        copy = Self(newValue)
    }
    
    public static func getManagedField(from object: lattice.ManagedModel, with name: String) -> Self {
        return object.get_managed_field(std.string(name))
    }
}

extension lattice.ManagedBool: CxxManagedType {
    public typealias CxxManagedOptionalType = lattice.ManagedOptionalBool
    
    public func get() -> Bool {
        return self.detach()
    }

    public mutating func set(_ newValue: Bool) {
        var copy = self
        copy = Self(newValue)
    }
    
    public static func getManagedField(from object: lattice.ManagedModel, with name: String) -> Self {
        return object.get_managed_field(std.string(name))
    }
}

extension lattice.ManagedFloat: CxxManagedType {
    public func get() -> Float {
        return self.detach()
    }

    public mutating func set(_ newValue: Float) {
        var copy = self
        copy = Self(newValue)
    }
    
    public static func getManagedField(from object: lattice.ManagedModel, with name: String) -> Self {
        return object.get_managed_field(std.string(name))
    }
}

// MARK: - List Type CxxManagedType Conformances

extension lattice.ManagedStringList: CxxManagedType {
    public func get() -> [String] {
        let vec = self.detach()
        return vec.map { String($0) }
    }

    public mutating func set(_ newValue: [String]) {
        // Handled at Accessor level
    }
    
    public static func getManagedField(from object: lattice.ManagedModel, with name: String) -> Self {
        return object.get_managed_field(std.string(name))
    }
}

extension lattice.ManagedIntList: CxxManagedType {
    public func get() -> [Int] {
        let vec = self.detach()
        return vec.map { Int($0) }
    }

    public mutating func set(_ newValue: [Int]) {
        // Handled at Accessor level
    }
    
    public static func getManagedField(from object: lattice.ManagedModel, with name: String) -> Self {
        return object.get_managed_field(std.string(name))
    }
}

extension lattice.ManagedDoubleList: CxxManagedType {
    public func get() -> [Double] {
        let vec = self.detach()
        return Array(vec)
    }

    public mutating func set(_ newValue: [Double]) {
        // Handled at Accessor level
    }
    
    public static func getManagedField(from object: lattice.ManagedModel, with name: String) -> Self {
        return object.get_managed_field(std.string(name))
    }
}

extension lattice.ManagedBoolList: CxxManagedType {
    public func get() -> [Bool] {
        // std::vector<bool> is specialized in C++ - access by index to get proper Bool
        self.detach().map { $0.__convertToBool() }
    }

    public mutating func set(_ newValue: [Bool]) {
        // Handled at Accessor level
    }
    
    public static func getManagedField(from object: lattice.ManagedModel, with name: String) -> Self {
        return object.get_managed_field(std.string(name))
    }
}

extension lattice.ManagedFloatList: CxxManagedType {
    public func get() -> [Float] {
        let vec = self.detach()
        return Array(vec)
    }

    public mutating func set(_ newValue: [Float]) {
        // Handled at Accessor level
    }

    public static func getManagedField(from object: lattice.ManagedModel, with name: String) -> Self {
        return object.get_managed_field(std.string(name))
    }
}

// MARK: - Link List Type CxxManagedType Conformance

extension lattice.ManagedLinkList: CxxManagedType {
    public typealias SwiftType = [lattice.ManagedModel]

    public func get() -> [lattice.ManagedModel] {
        // TODO: Implement proper link list retrieval
        return []
    }

    public mutating func set(_ newValue: [lattice.ManagedModel]) {
        // Handled at Accessor level
    }

    public static func getManagedField(from object: lattice.ManagedModel, with name: String) -> Self {
        return object.get_managed_field(std.string(name))
    }
}

extension CxxManagedLatticeObject: CxxManagedType {
    public func get() -> Self {
        self
    }
    public mutating func set(_ newValue: Self) {
        self = newValue
    }
    
    public static func getManagedField(from object: lattice.ManagedModel, with name: String) -> Self {
        fatalError()
//        return object.get_managed_field(std.string(name))
    }
}

extension Optional: CxxManagedType where Wrapped: CxxManagedType {
    public func get() -> Self {
        self
    }
    public mutating func set(_ newValue: Self) {
        self = newValue
    }
    
    public static func getManagedField(from object: lattice.ManagedModel, with name: String) -> Self {
        guard object.has_property(std.string(name)) else {
            return nil
        }
        return Wrapped.getManagedField(from: object, with: name)
    }
}

// MARK: - CxxManaged Conformances for Swift types

extension String: CxxBridgeable, CxxListManaged {
    public typealias CxxType = std.string
    public typealias CxxManagedSpecialization = lattice.ManagedString
    public typealias CxxManagedListType = lattice.ManagedStringList

    public static func fromCxxValue(_ value: String) -> String { value }
    public func toCxxValue() -> String { self }

    public static func getUnmanaged(from object: lattice.swift_dynamic_object, name: std.string) -> String {
        String(object.get_string(name))
    }
    public func setUnmanaged(to object: inout lattice.swift_dynamic_object, name: std.string) {
        object.set_string(name, std.string(self))
    }
}

extension Int: CxxListManaged {
    public typealias CxxManagedSpecialization = lattice.ManagedInt
    public typealias CxxManagedListType = lattice.ManagedIntList

    public static func fromCxxValue(_ value: Int) -> Int { value }
    public func toCxxValue() -> Int { self }

    public static func getUnmanaged(from object: lattice.swift_dynamic_object, name: std.string) -> Int {
        Int(object.get_int(name))
    }
    public func setUnmanaged(to object: inout lattice.swift_dynamic_object, name: std.string) {
        object.set_int(name, Int64(self))
    }
}

extension Double: CxxListManaged {
    public typealias CxxManagedSpecialization = lattice.ManagedDouble
    public typealias CxxManagedListType = lattice.ManagedDoubleList

    public static func fromCxxValue(_ value: Double) -> Double { value }
    public func toCxxValue() -> Double { self }

    public static func getUnmanaged(from object: lattice.swift_dynamic_object, name: std.string) -> Double {
        object.get_double(name)
    }
    public func setUnmanaged(to object: inout lattice.swift_dynamic_object, name: std.string) {
        object.set_double(name, self)
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
}

// Int64 uses ManagedInt since Swift Int is 64-bit on modern platforms
extension Int64: CxxManaged {
    public typealias CxxManagedSpecialization = lattice.ManagedInt

    public static func fromCxxValue(_ value: Int) -> Int64 { Int64(value) }
    public func toCxxValue() -> Int { Int(self) }

    public static func getUnmanaged(from object: lattice.swift_dynamic_object, name: std.string) -> Int64 {
        object.get_int(name)
    }
    public func setUnmanaged(to object: inout lattice.swift_dynamic_object, name: std.string) {
        object.set_int(name, self)
    }
}

// MARK: - Extended Types (Date, UUID, Data)

extension lattice.ManagedTimestamp: CxxManagedType {
    public func get() -> Date {
        // Convert chrono time_point to Date via seconds since epoch
        let duration = self.detach().time_since_epoch()
        let nanoseconds = Int64(duration.count())
        let seconds = Double(nanoseconds) / 1_000_000_000.0
        return Date(timeIntervalSince1970: seconds)
    }

    public mutating func set(_ newValue: Date) {
        // Handled at Accessor level for now
    }
    
    public static func getManagedField(from object: lattice.ManagedModel, with name: String) -> Self {
        return object.get_managed_field(std.string(name))
    }
}

extension Date: CxxManaged {
    public typealias CxxManagedSpecialization = lattice.ManagedTimestamp

    public static func fromCxxValue(_ value: Date) -> Date { value }
    public func toCxxValue() -> Date { self }

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
    public func setUnmanaged(to object: inout lattice.swift_dynamic_object, name: std.string) {
        object.set_double(name, self.timeIntervalSince1970)
    }
}

extension lattice.ManagedUUID: CxxManagedType {
    public func get() -> UUID {
        let str = String(self.to_string())
        return UUID(uuidString: str) ?? UUID()
    }

    public mutating func set(_ newValue: UUID) {
        // Handled at Accessor level for now
    }
    
    public static func getManagedField(from object: lattice.ManagedModel, with name: String) -> Self {
        return object.get_managed_field(std.string(name))
    }
}

extension UUID: CxxManaged {
    public typealias CxxManagedSpecialization = lattice.ManagedUUID

    public static func fromCxxValue(_ value: UUID) -> UUID { value }
    public func toCxxValue() -> UUID { self }

    public static func getUnmanaged(from object: lattice.swift_dynamic_object, name: std.string) -> UUID {
        let str = String(object.get_string(name))
        return UUID(uuidString: str) ?? UUID()
    }
    public func setUnmanaged(to object: inout lattice.swift_dynamic_object, name: std.string) {
        object.set_string(name, std.string(self.uuidString))
    }
}

extension lattice.ManagedData: CxxManagedType {
    public func get() -> Data {
        let vec = self.detach()
        return Data(vec)
    }

    public mutating func set(_ newValue: Data) {
        // Handled at Accessor level for now
    }
    
    public static func getManagedField(from object: lattice.ManagedModel, with name: String) -> Self {
        return object.get_managed_field(std.string(name))
    }
}

extension Data: CxxManaged {
    public typealias CxxManagedSpecialization = lattice.ManagedData

    public static func fromCxxValue(_ value: Data) -> Data {
        value
    }
    public func toCxxValue() -> Data {
        self
    }

    public static func getUnmanaged(from object: lattice.swift_dynamic_object, name: std.string) -> Data {
        let blob = object.get_blob(name)
        return Data(blob)
    }

    public func setUnmanaged(to object: inout lattice.swift_dynamic_object, name: std.string) {
        var vec = lattice.ByteVector()
        for byte in self {
            vec.push_back(byte)
        }
        object.set_blob(name, vec)
    }
}

// MARK: - Link Types

extension lattice.ManagedLink: CxxManagedType {
    public typealias SwiftType = lattice.ManagedModel?

    public func get() -> lattice.ManagedModel? {
        // Returns the linked model's C++ representation
        // TODO: Implement proper link retrieval
        return nil
    }

    public mutating func set(_ newValue: lattice.ManagedModel?) {
        // Set the linked model
    }

    public static func getManagedField(from object: lattice.ManagedModel, with name: String) -> Self {
        return object.get_managed_field(std.string(name))
    }
}

// MARK: - Optional conformance

// Optional<T> conforms to CxxManaged when T does, using the same specialization
// Conversion wraps/unwraps the optional around T's conversion
extension Optional: CxxManaged where Wrapped: CxxManaged {
    public typealias CxxManagedSpecialization = Wrapped.CxxManagedSpecialization

    public static func fromCxxValue(_ value: Wrapped.CxxManagedSpecialization.SwiftType) -> Optional<Wrapped> {
        // The C++ side doesn't distinguish nil - for now, always wrap
        return Wrapped.fromCxxValue(value)
    }

    public func toCxxValue() -> Wrapped.CxxManagedSpecialization.SwiftType {
        guard let self else {
            // For nil, we need a default value - use Wrapped's default if available
            // This is a limitation - nil handling needs special support in C++
            fatalError()
        }
        return self.toCxxValue()
    }

    public static func getUnmanaged(from object: lattice.swift_dynamic_object, name: std.string) -> Optional<Wrapped> {
        // Check if the value exists/is non-empty before getting
        // For now, try to get the wrapped value and return it
        guard object.has_value(name) else {
            return nil
        }
        return Wrapped.getUnmanaged(from: object, name: name)
    }

    public func setUnmanaged(to object: inout lattice.swift_dynamic_object, name: std.string) {
        if let self {
            self.setUnmanaged(to: &object, name: name)
        }
        // For nil, we don't set anything - the C++ side will have default/empty value
    }
}

// For Optional<Model> - also conforms to CxxBridgeable for the C++ pointer type
extension Optional: CxxBridgeable where Wrapped: Model {
    public typealias CxxType = UnsafePointer<lattice.swift_dynamic_object>
}

// For Array of CxxListManaged types
extension Array: CxxManaged where Element: CxxListManaged {
    public typealias CxxManagedSpecialization = Element.CxxManagedListType

    public static func fromCxxValue(_ value: Element.CxxManagedListType.SwiftType) -> [Element] {
        // The list type's SwiftType should be [Element], so this is identity-like
        // But we need to cast since Swift doesn't know they're the same
        return value as! [Element]
    }

    public func toCxxValue() -> Element.CxxManagedListType.SwiftType {
        return self as! Element.CxxManagedListType.SwiftType
    }

    public static func getUnmanaged(from object: lattice.swift_dynamic_object, name: std.string) -> [Element] {
        // For primitive list types, we can get elements individually
        // But for now, return empty - lists need special handling
        return []
    }

    public func setUnmanaged(to object: inout lattice.swift_dynamic_object, name: std.string) {
        // Lists need special handling - for now, do nothing for unmanaged
    }
}

// For Array of Optional CxxListManaged types (e.g., [String?])
extension Optional: CxxListManaged where Wrapped: CxxListManaged {
    public typealias CxxManagedListType = Wrapped.CxxManagedListType
}

// MARK: - Dictionary Support (JSON serialized as String)
// Dictionaries are stored as JSON text
extension Dictionary: CxxManaged where Key == String, Value: Codable {
    public typealias CxxManagedSpecialization = lattice.ManagedString

    public static func fromCxxValue(_ value: String) -> [String: Value] {
        guard let data = value.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: Value].self, from: data) else {
            return [:]
        }
        return dict
    }

    public func toCxxValue() -> String {
        guard let data = try? JSONEncoder().encode(self),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    public static func getUnmanaged(from object: lattice.swift_dynamic_object, name: std.string) -> [String: Value] {
        let str = String(object.get_string(name))
        guard let data = str.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: Value].self, from: data) else {
            return [:]
        }
        return dict
    }

    public func setUnmanaged(to object: inout lattice.swift_dynamic_object, name: std.string) {
        guard let data = try? JSONEncoder().encode(self),
              let json = String(data: data, encoding: .utf8) else {
            object.set_string(name, std.string("{}"))
            return
        }
        object.set_string(name, std.string(json))
    }
}

@propertyWrapper public struct Property<Value> where Value: CxxManaged,
                                                        Value: SchemaProperty {
    public var wrappedValue: Value
    private var managedValue: Value.CxxManagedSpecialization?
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
    public mutating func pushDefaultToStorage(_ storage: inout _ModelStorage) {
        if case .unmanaged(var cxxObject) = storage {
            wrappedValue.setUnmanaged(to: &cxxObject, name: std.string(name))
            storage = .unmanaged(cxxObject)
        }
    }

    public static subscript<M: Model>(
        _enclosingInstance object: M,
        wrapped wrappedKeyPath: ReferenceWritableKeyPath<M, Value>,
        storage storageKeyPath: ReferenceWritableKeyPath<M, Property<Value>>
    ) -> Value {
        get {
            let nameStr = object[keyPath: storageKeyPath].name
            object._lastKeyPathUsed = nameStr
            let name = std.string(nameStr)
            switch object._storage {
            case .unmanaged(let cxxObject):
                return Value.getUnmanaged(from: cxxObject, name: name)
            case .managed(let cxxObject):
                let managed: Value.CxxManagedSpecialization = Value.CxxManagedSpecialization.getManagedField(from: cxxObject, with: String(name))
                return Value.fromCxxValue(managed.get())
            }
        }
        set {
            let name = std.string(object[keyPath: storageKeyPath].name)
            switch object._storage {
            case .unmanaged(var cxxObject):
                newValue.setUnmanaged(to: &cxxObject, name: name)
                object._storage = .unmanaged(cxxObject)
            case .managed(let cxxObject):
                var managed: Value.CxxManagedSpecialization = Value.CxxManagedSpecialization.getManagedField(from: cxxObject, with: String(name))
                managed.set(newValue.toCxxValue())
            }
        }
    }
}

func fn() {
    @Property(name: "test") var test: String = ""
}
// MARK: - LatticeEnum Support
// LatticeEnum inherits CxxManaged from its protocol definition in Property.swift
// The typealias CxxManagedSpecialization = RawValue.CxxManagedSpecialization is provided there

public struct Accessor<T, SS, SI>: @unchecked Sendable where SS: StaticString, SI: StaticInt32, T: CxxManaged {
    public var columnId: Int32 {
        SI.int32
    }
    public var name: String {
        SS.string
    }
//    private var cxxObject: lattice.swift_dynamic_object
    public var lattice: Lattice?
    public weak var parent: (any Model)?
    private var unmanagedValue: T
    private var managedValue: T.CxxManagedSpecialization?
    
    public init(columnId: Int32, name: String, lattice: Lattice? = nil,
                parent: (any Model)? = nil,
                unmanagedValue: T = T()) where T: ListProperty {
        self.lattice = lattice
        self.parent = parent
        self.unmanagedValue = unmanagedValue
    }
    
    public init(columnId: Int32, name: String, lattice: Lattice? = nil,
                parent: (any Model)? = nil,
                unmanagedValue: T = T.defaultValue) where T: PrimitiveProperty {
        self.lattice = lattice
        self.parent = parent
        self.unmanagedValue = unmanagedValue
    }
    
//    public init(columnId: Int32, name: String, lattice: Lattice? = nil,
//                parent: (any Model)? = nil,
//                unmanagedValue: T = nil) where T: OptionalProtocol, T.Wrapped: EmbeddedModel {
//        self.lattice = lattice
//        self.parent = parent
//        self.unmanagedValue = unmanagedValue
//    }
    
    public init(columnId: Int32, name: String, lattice: Lattice? = nil,
                parent: (any Model)? = nil,
                unmanagedValue: T = nil) where T: OptionalProtocol, T.Wrapped: Model {
        self.lattice = lattice
        self.parent = parent
        self.unmanagedValue = unmanagedValue
    }
    
    public init<M: Model>(columnId: Int32, name: String, lattice: Lattice? = nil,
                          parent: (any Model)? = nil,
                          unmanagedValue: T = []) where T == Array<M> {
        self.lattice = lattice
        self.parent = parent
        self.unmanagedValue = unmanagedValue
    }
    
    public func get(isolation: isolated (any Actor)? = #isolation) -> T {
        guard let managedValue else {
            return unmanagedValue
        }
        return T.fromCxxValue(managedValue.get())
    }
    
    public mutating func set(isolation: isolated (any Actor)? = #isolation, _ newValue: T) {
        guard var managedValue else {
            unmanagedValue = newValue
            return
        }
        managedValue.set(newValue.toCxxValue())
    }
}

extension Accessor where T: PrimitiveProperty {
    public func get(isolation: isolated (any Actor)? = #isolation) -> T {
        guard let parent, let lattice, let primaryKey = parent.primaryKey else {
            return unmanagedValue
        }
        return T._get(name: name, parent: parent, lattice: lattice, primaryKey: primaryKey) ?? unmanagedValue
    }
    public mutating func set(isolation: isolated (any Actor)? = #isolation, _ newValue: T) {
        guard let parent, let lattice, let primaryKey = parent.primaryKey else {
            unmanagedValue = newValue
            return
        }
//            lattice.transaction {
            T._set(name: name, parent: parent, lattice: lattice, primaryKey: primaryKey, newValue: newValue)
//            }
    }
    public var value: T {
        get {
            guard let parent, let lattice, let primaryKey = parent.primaryKey else {
                return unmanagedValue
            }
            return T._get(name: name, parent: parent, lattice: lattice, primaryKey: primaryKey) ?? unmanagedValue
        }
        set {
            guard let parent, let lattice, let primaryKey = parent.primaryKey else {
                unmanagedValue = newValue
                return
            }
//            lattice.transaction {
                T._set(name: name, parent: parent, lattice: lattice, primaryKey: primaryKey, newValue: newValue)
//            }
        }
    }
    
    public func encode(to statement: OpaquePointer?, with columnId: inout Int32) {
        value.encode(to: statement, with: columnId)
    }
    
    public func _didEncode(parent: some Model, lattice: borrowing Lattice, primaryKey: Int64) {
    }
}
//extension Accessor where T: OptionalProtocol, T.Wrapped: EmbeddedModel {
//    public var value: T {
//        get {
//            guard let parent, let lattice, let primaryKey = parent.primaryKey else {
//                return unmanagedValue
//            }
////            return T._get(name: name, parent: parent, lattice: lattice, primaryKey: primaryKey)
//            fatalError()
//        }
//        set {
//            guard let parent, let lattice, let primaryKey = parent.primaryKey else {
//                unmanagedValue = newValue
//                return
//            }
////            T._set(name: name, parent: parent, lattice: lattice, primaryKey: primaryKey, newValue: newValue)
//        }
//    }
//    
//    public func encode(to statement: OpaquePointer?, with columnId: Int32) {
//        value.encode(to: statement, with: columnId)
//    }
//}

extension Accessor where T: EmbeddedModel {
    public var value: T {
        get {
            guard let parent, let lattice, let primaryKey = parent.primaryKey else {
                return unmanagedValue
            }
            return T._get(name: name, parent: parent, lattice: lattice, primaryKey: primaryKey) ?? unmanagedValue
        }
        set {
            guard let parent, let lattice, let primaryKey = parent.primaryKey else {
                unmanagedValue = newValue
                return
            }
            T._set(name: name, parent: parent, lattice: lattice, primaryKey: primaryKey, newValue: newValue)
        }
    }
    
    public func encode(to statement: OpaquePointer?, with columnId: inout Int32) {
        unmanagedValue.encode(to: statement, with: columnId)
    }
    
    public func _didEncode(parent: some Model, lattice: borrowing Lattice, primaryKey: Int64) {
    }
}

extension Accessor where T: ListProperty & LinkProperty {
    public func get(isolation: isolated (any Actor)? = #isolation) -> T {
        guard let parent, let lattice, let primaryKey = parent.primaryKey else {
            return unmanagedValue
        }
        return T._get(name: name, parent: parent, lattice: lattice, primaryKey: primaryKey) ?? unmanagedValue
    }
    public mutating func set(isolation: isolated (any Actor)? = #isolation, _ newValue: T) {
        fatalError()
//            }
    }
    public var value: T {
        get {
            guard let parent, let lattice, let primaryKey = parent.primaryKey else {
                return unmanagedValue
            }
            return T._get(name: name, parent: parent, lattice: lattice, primaryKey: primaryKey)
        }
        set {
            fatalError()
        }
    }
    
    public func encode(to statement: OpaquePointer?, with columnId: inout Int32) {
        // decrement the column id in an encode since this is skipped
        columnId -= 1
    }
    
    public func _didEncode(parent: some Model, lattice: borrowing Lattice, primaryKey: Int64) {
        T._set(name: name,
               parent: parent,
               lattice: lattice,
               primaryKey: primaryKey,
               newValue: unmanagedValue)
    }
}

extension Accessor where T: LinkProperty {
    public func get(isolation: isolated (any Actor)? = #isolation) -> T {
        guard let parent, let lattice, let primaryKey = parent.primaryKey else {
            return unmanagedValue
        }
        return T._get(name: name, parent: parent, lattice: lattice, primaryKey: primaryKey) ?? unmanagedValue
    }
    public mutating func set(isolation: isolated (any Actor)? = #isolation, _ newValue: T) {
        guard let parent, let lattice, let primaryKey = parent.primaryKey else {
            unmanagedValue = newValue
            return
        }
//            lattice.transaction {
            T._set(name: name, parent: parent, lattice: lattice, primaryKey: primaryKey, newValue: newValue)
//            }
    }
    
    public var value: T {
        get {
            guard let parent, let lattice, let primaryKey = parent.primaryKey else {
                return unmanagedValue
            }
            return T._get(name: name, parent: parent, lattice: lattice, primaryKey: primaryKey)
        }
        set {
            guard let parent, let lattice, let primaryKey = parent.primaryKey else {
                unmanagedValue = newValue
                return
            }
            T._set(name: name, parent: parent, lattice: lattice, primaryKey: primaryKey, newValue: newValue)
        }
    }
    
    public func encode(to statement: OpaquePointer?, with columnId: inout Int32) {
        // decrement the column id in an encode since this is skipped
        columnId -= 1
    }
    
    public func _didEncode(parent: some Model, lattice: borrowing Lattice, primaryKey: Int64) {
        T._set(name: name,
               parent: parent,
               lattice: lattice,
               primaryKey: primaryKey,
               newValue: unmanagedValue)
    }
}

extension Accessor: Codable where T: Codable, T: PrimitiveProperty {
    public init(from decoder: any Decoder) throws {
        self.unmanagedValue = try decoder.singleValueContainer().decode(T.self)
    }
    
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
    
    public func _didEncode(parent: some Model, lattice: borrowing Lattice, primaryKey: Int64) {
    }
}
//extension Accessor where T: PrimitiveProperty & Codable {
//    
//}
//
//extension Accessor where T: OptionalProtocol, T.Wrapped: EmbeddedModel {
//    public var value: T {
//        get {
//            guard let parent, let lattice, let primaryKey = parent.primaryKey else {
//                return unmanagedValue
//            }
//            let queryStatementString = "SELECT \(name) FROM \(type(of: parent).entityName) WHERE id = ?;"
//            var queryStatement: OpaquePointer?
//            
//            defer {
//                sqlite3_finalize(queryStatement)
//            }
//            if sqlite3_prepare_v2(lattice.db, queryStatementString, -1, &queryStatement, nil) == SQLITE_OK {
//                // Bind the provided id to the statement.
//                sqlite3_bind_int64(queryStatement, 1, primaryKey)
//                
//                if sqlite3_step(queryStatement) == SQLITE_ROW {
//                    // Extract id, name, and age from the row.
//                    return try! JSONDecoder().decode(T.Wrapped.self, from: String(from: queryStatement, with: 0).data(using: .utf8)!) as! T
//                } else {
//                    print("No person found with id \(primaryKey).")
//                }
//            } else {
//                print("SELECT statement could not be prepared.")
//            }
//            return unmanagedValue
//        }
//        set {
//            guard let parent, let lattice, let primaryKey = parent.primaryKey else {
//                unmanagedValue = newValue
//                return
//            }
//            let updateStatementString = "UPDATE \(type(of: parent).entityName) SET \(name) = ? WHERE id = ?;"
//            var updateStatement: OpaquePointer?
//            
//            if sqlite3_prepare_v2(lattice.db, updateStatementString, -1, &updateStatement, nil) == SQLITE_OK {
//                if let newValue = (newValue as? Optional<T.Wrapped>) {
//                    let text = String(data: try! JSONEncoder().encode(newValue), encoding: .utf8)!
//                    sqlite3_bind_text(updateStatement, 1, (text as NSString).utf8String, -1, nil)
//                } else {
//                    sqlite3_bind_null(updateStatement, 1)
//                }
//                sqlite3_bind_int64(updateStatement, 2, primaryKey)
//                
//                if sqlite3_step(updateStatement) == SQLITE_DONE {
//                    print("Successfully updated person with id \(primaryKey) to name: \(newValue).")
//                } else {
//                    print("Could not update person with id \(primaryKey).")
//                }
//            } else {
//                print("UPDATE statement could not be prepared.")
//            }
//            sqlite3_finalize(updateStatement)
//        }
//    }
//    
//    
//    public func encode(to statement: OpaquePointer?, with columnId: Int32) {
//        if let value = value as? Optional<T.Wrapped> {
//            let text = String(data: try! JSONEncoder().encode(value), encoding: .utf8)!
//            sqlite3_bind_text(statement, columnId, (text as NSString).utf8String, -1, nil)
//        } else {
//            sqlite3_bind_null(statement, columnId)
//        }
//    }
//}
