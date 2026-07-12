#if canImport(os)
import os
#endif
import Foundation
import LatticeSwiftCppBridge
import LatticeSwiftModule

public protocol DefaultInitializable {
    init()
}

public typealias CxxManagedStringList = lattice.ManagedStringList
public typealias CxxManagedString = lattice.ManagedString

public protocol EmbeddedModel: Codable, PrimitiveProperty, CxxListManaged, DefaultInitializable, UnionProperty where CxxManagedListType == CxxManagedStringList {
}

extension EmbeddedModel {
    public static func getManagedList(from object: lattice.ManagedModel, name: std.string) -> CxxManagedStringList {
        fatalError()
    }
    
    public static func getField(from storage: borrowing ModelStorage, named name: String) -> Self {
        // Read path is tolerant: stored JSON is data (it may have been written
        // by an older schema or another process), so decode failure degrades
        // to the default value instead of trapping.
        let jsonStr = storage._ref.getString(named: name)
        guard !jsonStr.isEmpty, let data = jsonStr.data(using: .utf8) else {
            Logger.db.warning("EmbeddedModel \(String(describing: Self.self)): empty/undecodable JSON for field '\(name)' — returning default value")
            return .init()
        }
        do {
            return try JSONDecoder().decode(Self.self, from: data)
        } catch {
            Logger.db.error("EmbeddedModel \(String(describing: Self.self)): failed to JSON-decode field '\(name)' (\(String(describing: error))) — returning default value")
            return .init()
        }
    }

    public static func setField(on storage: inout ModelStorage, named name: String, _ value: Self) {
        // Write path traps: an in-memory value that cannot JSON-encode is a
        // programmer error in the EmbeddedModel's Codable conformance.
        let jsonData: Data
        do {
            jsonData = try JSONEncoder().encode(value)
        } catch {
            fatalError("EmbeddedModel \(String(describing: Self.self)) failed to JSON-encode for field '\(name)': \(error)")
        }
        storage._ref.setString(named: name, String(data: jsonData, encoding: .utf8)!)
    }

    public static var defaultValue: Self {
        .init()
    }

    public static var anyPropertyKind: AnyProperty.Kind { .string }
}

// MARK: - UnionProperty conformance for EmbeddedModel (stored as JSON TEXT)

extension EmbeddedModel where Self: UnionProperty {
    public static func getField(from uv: lattice.union_value, named name: String) -> Self {
        // Tolerant read — stored JSON is data; decode failure degrades to the
        // default value instead of trapping (see getField(from:named:) above).
        let json = String(uv.getString(std.string(name)))
        if !json.isEmpty, let data = json.data(using: .utf8) {
            do {
                return try JSONDecoder().decode(Self.self, from: data)
            } catch {
                Logger.db.error("EmbeddedModel \(String(describing: Self.self)): failed to JSON-decode union field '\(name)' (\(String(describing: error))) — returning default value")
            }
        }
        return Self.init()
    }

    public static func setField(on uv: inout lattice.union_value, named name: String, _ value: Self) {
        // Write path traps: unencodable in-memory value = programmer error.
        let jsonData: Data
        do {
            jsonData = try JSONEncoder().encode(value)
        } catch {
            fatalError("EmbeddedModel \(String(describing: Self.self)) failed to JSON-encode for union field '\(name)': \(error)")
        }
        uv.setString(std.string(name), std.string(String(data: jsonData, encoding: .utf8)!))
    }
}

#if DEBUG
private struct TestEmbedded: EmbeddedModel {
    var foo = ""
}
#endif
