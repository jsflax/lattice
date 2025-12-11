import Foundation
import SQLite3
import LatticeSwiftCppBridge

/// A fixed-size vector of floating-point values optimized for vector search with sqlite-vec.
///
/// Vectors are stored as packed binary BLOBs compatible with sqlite-vec's `vec_f32()` format.
/// This enables efficient ANN (Approximate Nearest Neighbor) queries using the vec0 virtual table.
///
/// Example usage:
/// ```swift
/// @Model
/// class Document {
///     var title: String
///     var embedding: Vector<Float>  // 1536-dim OpenAI embedding
///
///     init(title: String, embedding: [Float]) {
///         self.title = title
///         self.embedding = Vector(embedding)
///     }
/// }
/// ```
public struct Vector<Element: BinaryFloatingPoint & PrimitiveProperty & Sendable>: Hashable, Sendable {
    public var elements: [Element]

    public init(_ elements: [Element] = []) {
        self.elements = elements
    }

    public init(dimensions: Int, repeating value: Element = 0) {
        self.elements = Array(repeating: value, count: dimensions)
    }

    /// Number of dimensions in this vector
    public var dimensions: Int { elements.count }

    /// Access individual elements
    public subscript(index: Int) -> Element {
        get { elements[index] }
        set { elements[index] = newValue }
    }
}

// MARK: - Collection Conformance

extension Vector: RandomAccessCollection, MutableCollection {
    public var startIndex: Int { elements.startIndex }
    public var endIndex: Int { elements.endIndex }

    public func index(after i: Int) -> Int { elements.index(after: i) }
    public func index(before i: Int) -> Int { elements.index(before: i) }
}

// MARK: - VectorElement Protocol

/// Protocol for types that can be elements of a Vector
public protocol VectorElement: BinaryFloatingPoint, PrimitiveProperty {
    static var byteSize: Int { get }
}

extension Float: VectorElement {
    public static var byteSize: Int { MemoryLayout<Float>.size }
}

extension Double: VectorElement {
    public static var byteSize: Int { MemoryLayout<Double>.size }
}

// MARK: - Generic Binary Serialization

extension Vector where Element: VectorElement {
    /// Convert to raw bytes for sqlite-vec
    public func toData() -> Data {
        var data = Data(capacity: elements.count * Element.byteSize)
        for element in elements {
            var value = element
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Create from raw bytes
    public init(fromData data: Data) {
        let count = data.count / Element.byteSize
        var elements = [Element](repeating: 0, count: count)
        data.withUnsafeBytes { buffer in
            for i in 0..<count {
                let offset = i * Element.byteSize
                var value: Element = 0
                withUnsafeMutableBytes(of: &value) { dest in
                    dest.copyMemory(from: UnsafeRawBufferPointer(
                        start: buffer.baseAddress?.advanced(by: offset),
                        count: Element.byteSize
                    ))
                }
                elements[i] = value
            }
        }
        self.elements = elements
    }
}

// MARK: - PrimitiveProperty Conformance

extension Vector: SchemaProperty where Element: VectorElement {
    public typealias DefaultValue = Self

    public static var defaultValue: Vector<Element> { Vector() }

    public static var anyPropertyKind: AnyProperty.Kind { .data }
}

extension Vector: PersistableProperty where Element: VectorElement {}

extension Vector: PrimitiveProperty where Element: VectorElement {
    // Store as BLOB for sqlite-vec compatibility
    public static var sqlType: String { "BLOB" }

    public init(from statement: OpaquePointer?, with columnId: Int32) {
        guard let blob = sqlite3_column_blob(statement, columnId) else {
            self.elements = []
            return
        }
        let bytes = sqlite3_column_bytes(statement, columnId)
        let data = Data(bytes: blob, count: Int(bytes))
        self = Vector(fromData: data)
    }

    public func encode(to statement: OpaquePointer?, with columnId: Int32) {
        let data = toData()
        _ = data.withUnsafeBytes { buffer in
            sqlite3_bind_blob(statement, columnId, buffer.baseAddress, Int32(buffer.count), nil)
        }
    }
}

// MARK: - CxxManaged Conformance

extension Vector: CxxManaged where Element: VectorElement {
    public typealias CxxManagedSpecialization = lattice.ManagedData

    public static func fromCxxValue(_ value: Data) -> Vector<Element> {
        Vector(fromData: value)
    }

    public func toCxxValue() -> Data {
        toData()
    }

    public static func getUnmanaged(from object: lattice.swift_dynamic_object, name: std.string) -> Vector<Element> {
        let blob = object.get_blob(name)
        guard !blob.isEmpty else {
            return Vector()
        }
        return Vector(fromData: Data(blob))
    }

    public func setUnmanaged(to object: inout lattice.swift_dynamic_object, name: std.string) {
        let data = toData()
        var vec = lattice.ByteVector()
        for byte in data {
            vec.push_back(byte)
        }
        object.set_blob(name, vec)
    }
}

// MARK: - Codable

extension Vector: Codable where Element: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.elements = try container.decode([Element].self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(elements)
    }
}

// MARK: - ExpressibleByArrayLiteral

extension Vector: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: Element...) {
        self.elements = elements
    }
}

// MARK: - Distance Functions (CPU fallback when not using vec0)

extension Vector where Element: BinaryFloatingPoint {
    /// Euclidean (L2) distance squared - faster than L2 when you only need relative ordering
    public func l2DistanceSquared(to other: Vector<Element>) -> Element {
        precondition(dimensions == other.dimensions, "Vector dimensions must match")
        var sum: Element = 0
        for i in 0..<dimensions {
            let diff = elements[i] - other.elements[i]
            sum += diff * diff
        }
        return sum
    }

    /// Euclidean (L2) distance
    public func l2Distance(to other: Vector<Element>) -> Element {
        Element(sqrt(Double(l2DistanceSquared(to: other))))
    }

    /// Cosine distance (1 - cosine similarity)
    public func cosineDistance(to other: Vector<Element>) -> Element {
        precondition(dimensions == other.dimensions, "Vector dimensions must match")
        var dot: Element = 0
        var normA: Element = 0
        var normB: Element = 0
        for i in 0..<dimensions {
            dot += elements[i] * other.elements[i]
            normA += elements[i] * elements[i]
            normB += other.elements[i] * other.elements[i]
        }
        let denom = Element(sqrt(Double(normA)) * sqrt(Double(normB)))
        guard denom > 0 else { return 1 }
        return 1 - (dot / denom)
    }

    /// Dot product (inner product)
    public func dot(_ other: Vector<Element>) -> Element {
        precondition(dimensions == other.dimensions, "Vector dimensions must match")
        var result: Element = 0
        for i in 0..<dimensions {
            result += elements[i] * other.elements[i]
        }
        return result
    }

    /// Normalize to unit length
    public func normalized() -> Vector<Element> {
        var sumSquares: Element = 0
        for e in elements {
            sumSquares += e * e
        }
        let norm = Element(sqrt(Double(sumSquares)))
        guard norm > 0 else { return self }
        return Vector(elements.map { $0 / norm })
    }
}

// MARK: - Type Aliases for Convenience

/// A vector of 32-bit floats (most common for embeddings)
public typealias FloatVector = Vector<Float>

/// A vector of 64-bit doubles
public typealias DoubleVector = Vector<Double>
