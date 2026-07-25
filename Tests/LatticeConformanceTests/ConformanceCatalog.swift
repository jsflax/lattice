import Foundation
import Lattice
#if canImport(MapKit)
import MapKit
#endif

// MARK: - The compiled catalog
//
// The corpus declares schemas inline; this statically-typed runner
// pre-compiles one @Model per catalog table + shape and validates each
// scenario's inline declaration against the compiled shape (name + property
// set + version) before running it — a mismatch is a hard error, never a
// silent skip. Table names carry the corpus's `Cf` prefix so they cannot
// collide with host-process test models (registries key on entity name).

@Model final class CfPerson {
    var name: String = ""
    var age: Int = 0
    var score: Double = 0
    var active: Bool = false
    var nickname: String?
    var city: String = ""
}

@Model final class CfPet {
    var name: String = ""
    var kind: String = ""
}

@Model final class CfOwner {
    var name: String = ""
    var pet: CfPet?
    var pets: List<CfPet> = .init()
}

@Model final class CfCard {
    @Unique var code: String = ""
    var note: String = ""
}

@Model final class CfArticle {
    var title: String = ""
    @FullText var content: String = ""
}

@Model final class CfDoc {
    var title: String = ""
    var kind: String = ""
    var embedding: FloatVector = .init()
}

#if canImport(MapKit)
@Model final class CfPlace {
    var name: String = ""
    var kind: String = ""
    var location: CLLocationCoordinate2D = .init()
}
#endif

@Model final class CfCounter {
    var label: String = ""
    var hits: Int = 0
}

protocol CfNoteworthy: VirtualModel {
    var label: String { get set }
}

@Model final class CfNoteA: CfNoteworthy {
    var label: String = ""
    var extra_a: Int = 0
}

@Model final class CfNoteB: CfNoteworthy {
    var label: String = ""
    var extra_b: String = ""
}

@Model final class CfBinder {
    var title: String = ""
    var main: (any CfNoteworthy)? = nil
    var notes: VirtualList<any CfNoteworthy> = .init()
}

// Migration sources (schema version 1 shapes). Nested for namespacing —
// entity names stay the bare class names, so `ConfV1.CfWidget` and
// `CfWidget` share one table across a versioned reopen.
final class ConfV1 {
    @Model final class CfWidget {
        var label: String = ""
    }
    @Model final class CfMigPerson {
        var name: String = ""
        var age: String = ""
    }
    @Model final class CfBlobDoc {
        var label: String = ""
        var payload: Data = Data()
    }
}

// Migration targets (schema version 2 shapes).
@Model final class CfWidget {
    var label: String = ""
    var count: Int = 0
    var note: String?
}

@Model final class CfMigPerson {
    var name: String = ""
    var age: Int = 0
}

@Model final class CfBlobDoc {
    var label: String = ""
    var payload: Data = Data()
    var stars: Int = 0
}

// Second v2 shape of CfBlobDoc (the blob-explicit-failure scenario adds
// `tag` and requests a row transform).
final class ConfV2T {
    @Model final class CfBlobDoc {
        var label: String = ""
        var payload: Data = Data()
        var tag: String = ""
    }
}

// MARK: - FieldSpec: per-column typed operations
//
// Everything the interpreter needs to do with a column, captured as typed
// closures at compile time so the runtime interpreter stays fully dynamic
// while every Lattice call goes through the public *typed* API.

// @unchecked Sendable: value struct of immutable closures over immutable
// keypaths, built once at static-let init and never mutated afterwards.
struct FieldSpec<M: Model & AnyObject>: @unchecked Sendable {
    var get: ((M) -> JV)?
    var set: ((M, JV, ScenarioEnv?) throws -> Void)?
    var predicate: ((Query<M>, String, JV) throws -> Query<Bool>)?
    var sort: ((TableResults<M>, Bool) -> TableResults<M>)?
    var distinct: ((TableResults<M>) -> TableResults<M>)?
    var ftsKeyPath: KeyPath<M, String>?
    var vectorKeyPath: KeyPath<M, FloatVector>?
    var geoWithin: ((TableResults<M>, Double, Double, Double, Double) -> TableResults<M>)?
    var traverse: ((M) -> (any Model)?)?
    var listAppend: ((M, any Model) throws -> Void)?
    var listRemoveAt: ((M, Int) -> Void)?
    var listSize: ((M) -> Int)?
    var listElements: ((M) -> [any Model])?

    private static func unsupported(_ what: String) -> ConformanceError {
        .corpus("operator \(what) is not valid for this column type")
    }

    static func int(_ kp: ReferenceWritableKeyPath<M, Int>) -> FieldSpec {
        var f = FieldSpec()
        f.get = { .int(Int64($0[keyPath: kp])) }
        f.set = { m, v, _ in m[keyPath: kp] = Int(try v.requireInt()) }
        f.predicate = { q, op, v in
            let col = q[dynamicMember: kp]
            switch op {
            case "eq": return col == Int(try v.requireInt())
            case "ne": return col != Int(try v.requireInt())
            case "lt": return col < Int(try v.requireInt())
            case "le": return col <= Int(try v.requireInt())
            case "gt": return col > Int(try v.requireInt())
            case "ge": return col >= Int(try v.requireInt())
            case "in": return col.in(try v.requireArray().map { Int(try $0.requireInt()) })
            case "between":
                let low = Int(try (v["low"] ?? .null).requireInt())
                let high = Int(try (v["high"] ?? .null).requireInt())
                return col.contains(low...high)
            default: throw unsupported(op)
            }
        }
        f.sort = { $0.sortedBy(kp, order: $1 ? .forward : .reverse) }
        return f
    }

    static func double(_ kp: ReferenceWritableKeyPath<M, Double>) -> FieldSpec {
        var f = FieldSpec()
        f.get = { .double($0[keyPath: kp]) }
        f.set = { m, v, _ in m[keyPath: kp] = try v.requireDouble() }
        f.predicate = { q, op, v in
            let col = q[dynamicMember: kp]
            switch op {
            case "eq": return col == (try v.requireDouble())
            case "ne": return col != (try v.requireDouble())
            case "lt": return col < (try v.requireDouble())
            case "le": return col <= (try v.requireDouble())
            case "gt": return col > (try v.requireDouble())
            case "ge": return col >= (try v.requireDouble())
            default: throw unsupported(op)
            }
        }
        f.sort = { $0.sortedBy(kp, order: $1 ? .forward : .reverse) }
        return f
    }

    static func bool(_ kp: ReferenceWritableKeyPath<M, Bool>) -> FieldSpec {
        var f = FieldSpec()
        f.get = { .bool($0[keyPath: kp]) }
        f.set = { m, v, _ in m[keyPath: kp] = try v.requireBool() }
        f.predicate = { q, op, v in
            let col = q[dynamicMember: kp]
            switch op {
            case "eq": return col == (try v.requireBool())
            case "ne": return col != (try v.requireBool())
            default: throw unsupported(op)
            }
        }
        return f
    }

    static func string(_ kp: ReferenceWritableKeyPath<M, String>) -> FieldSpec {
        var f = FieldSpec()
        f.get = { .string($0[keyPath: kp]) }
        f.set = { m, v, _ in m[keyPath: kp] = try v.requireString() }
        f.predicate = { q, op, v in
            let col = q[dynamicMember: kp]
            switch op {
            case "eq": return col == (try v.requireString())
            case "ne": return col != (try v.requireString())
            case "contains": return col.contains(try v.requireString())
            case "starts_with": return col.starts(with: try v.requireString())
            case "ends_with": return col.ends(with: try v.requireString())
            case "like": return col.like(try v.requireString())
            case "in": return col.in(try v.requireArray().map { try $0.requireString() })
            default: throw unsupported(op)
            }
        }
        f.sort = { $0.sortedBy(kp, order: $1 ? .forward : .reverse) }
        f.distinct = { $0.distinct(by: kp) }
        f.ftsKeyPath = kp
        return f
    }

    static func optString(_ kp: ReferenceWritableKeyPath<M, String?>) -> FieldSpec {
        var f = FieldSpec()
        f.get = { m in m[keyPath: kp].map { .string($0) } ?? .null }
        f.set = { m, v, _ in m[keyPath: kp] = v.isNull ? nil : (try v.requireString()) }
        f.predicate = { q, op, v in
            let col = q[dynamicMember: kp]
            switch op {
            case "eq": return v.isNull ? (col == String?.none) : (col == (try v.requireString()))
            case "ne": return v.isNull ? (col != String?.none) : (col != (try v.requireString()))
            case "is_null": return col == String?.none
            case "is_not_null": return col != String?.none
            default: throw unsupported(op)
            }
        }
        return f
    }

    static func bytes(_ kp: ReferenceWritableKeyPath<M, Data>) -> FieldSpec {
        var f = FieldSpec()
        f.get = { .bytes($0[keyPath: kp]) }
        f.set = { m, v, _ in m[keyPath: kp] = try v.requireBytes() }
        return f
    }

    static func vector(_ kp: ReferenceWritableKeyPath<M, FloatVector>) -> FieldSpec {
        var f = FieldSpec()
        f.get = { .array($0[keyPath: kp].elements.map { .double(Double($0)) }) }
        f.set = { m, v, _ in
            m[keyPath: kp] = FloatVector(try v.requireArray().map { Float(try $0.requireDouble()) })
        }
        f.vectorKeyPath = kp
        return f
    }

    static func link<T: Model>(_ kp: ReferenceWritableKeyPath<M, T?>) -> FieldSpec {
        var f = FieldSpec()
        f.set = { m, v, env in
            if v.isNull {
                m[keyPath: kp] = nil
                return
            }
            m[keyPath: kp] = try Self.resolveRef(v, env: env, as: T.self)
        }
        f.traverse = { $0[keyPath: kp] }
        return f
    }

    static func list<T: Model>(_ kp: ReferenceWritableKeyPath<M, List<T>>) -> FieldSpec {
        var f = FieldSpec()
        f.listAppend = { m, item in
            guard let typed = item as? T else {
                throw ConformanceError.corpus("list item is not a \(T.entityName)")
            }
            var l = m[keyPath: kp]
            l.append(typed)
        }
        f.listRemoveAt = { m, idx in
            var l = m[keyPath: kp]
            l.remove(at: idx)
        }
        f.listSize = { $0[keyPath: kp].count }
        f.listElements = { m in m[keyPath: kp].map { $0 as any Model } }
        return f
    }

    static func virtualLink<P>(_ kp: ReferenceWritableKeyPath<M, P?>) -> FieldSpec {
        var f = FieldSpec()
        f.set = { m, v, env in
            if v.isNull {
                m[keyPath: kp] = nil
                return
            }
            let target = try Self.resolveAnyRef(v, env: env)
            guard let typed = target as? P else {
                throw ConformanceError.corpus("\(type(of: target)) does not conform to the virtual protocol")
            }
            m[keyPath: kp] = typed
        }
        f.traverse = { $0[keyPath: kp] as? any Model }
        return f
    }

    static func virtualList<P>(_ kp: ReferenceWritableKeyPath<M, VirtualList<P>>) -> FieldSpec {
        var f = FieldSpec()
        f.listAppend = { m, item in
            guard let typed = item as? P else {
                throw ConformanceError.corpus("\(type(of: item)) does not conform to the virtual protocol")
            }
            var l = m[keyPath: kp]
            l.append(typed)
        }
        f.listRemoveAt = { m, idx in
            var l = m[keyPath: kp]
            l.remove(at: idx)
        }
        f.listSize = { $0[keyPath: kp].count }
        f.listElements = { m in m[keyPath: kp].compactMap { $0 as? any Model } }
        return f
    }

    #if canImport(MapKit)
    static func geo(_ kp: ReferenceWritableKeyPath<M, CLLocationCoordinate2D>) -> FieldSpec {
        var f = FieldSpec()
        f.get = { m in
            let c = m[keyPath: kp]
            return .object(["lat": .double(c.latitude), "lon": .double(c.longitude)])
        }
        f.set = { m, v, _ in
            let lat = try (v["lat"] ?? .null).requireDouble()
            let lon = try (v["lon"] ?? .null).requireDouble()
            m[keyPath: kp] = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        f.geoWithin = { r, minLat, maxLat, minLon, maxLon in
            r.withinBounds(kp, minLat: minLat, maxLat: maxLat, minLon: minLon, maxLon: maxLon)
        }
        return f
    }
    #endif

    // Ref resolution helpers

    static func resolveRef<T: Model>(_ v: JV, env: ScenarioEnv?, as type: T.Type) throws -> T {
        let any = try resolveAnyRef(v, env: env)
        guard let typed = any as? T else {
            throw ConformanceError.corpus("handle is a \(Swift.type(of: any)), expected \(T.entityName)")
        }
        return typed
    }

    static func resolveAnyRef(_ v: JV, env: ScenarioEnv?) throws -> any Model {
        guard let name = v["$ref"]?.description, case .string(let ref)? = v["$ref"] else {
            throw ConformanceError.corpus("expected {\"$ref\": ...}, got \(v)")
        }
        _ = name
        guard let env, let handle = env.handles[ref] else {
            throw ConformanceError.corpus("unknown handle \(ref)")
        }
        return handle
    }
}

// MARK: - ConfModel

protocol ConfModel: Model {
    static var confFields: [String: FieldSpec<Self>] { get }
}

extension CfPerson: ConfModel {
    static let confFields: [String: FieldSpec<CfPerson>] = [
        "name": .string(\.name),
        "age": .int(\.age),
        "score": .double(\.score),
        "active": .bool(\.active),
        "nickname": .optString(\.nickname),
        "city": .string(\.city),
    ]
}

extension CfPet: ConfModel {
    static let confFields: [String: FieldSpec<CfPet>] = [
        "name": .string(\.name),
        "kind": .string(\.kind),
    ]
}

extension CfOwner: ConfModel {
    static let confFields: [String: FieldSpec<CfOwner>] = [
        "name": .string(\.name),
        "pet": .link(\.pet),
        "pets": .list(\.pets),
    ]
}

extension CfCard: ConfModel {
    static let confFields: [String: FieldSpec<CfCard>] = [
        "code": .string(\.code),
        "note": .string(\.note),
    ]
}

extension CfArticle: ConfModel {
    static let confFields: [String: FieldSpec<CfArticle>] = [
        "title": .string(\.title),
        "content": .string(\.content),
    ]
}

extension CfDoc: ConfModel {
    static let confFields: [String: FieldSpec<CfDoc>] = [
        "title": .string(\.title),
        "kind": .string(\.kind),
        "embedding": .vector(\.embedding),
    ]
}

#if canImport(MapKit)
extension CfPlace: ConfModel {
    static let confFields: [String: FieldSpec<CfPlace>] = [
        "name": .string(\.name),
        "kind": .string(\.kind),
        "location": .geo(\.location),
    ]
}
#endif

extension CfCounter: ConfModel {
    static let confFields: [String: FieldSpec<CfCounter>] = [
        "label": .string(\.label),
        "hits": .int(\.hits),
    ]
}

extension CfNoteA: ConfModel {
    static let confFields: [String: FieldSpec<CfNoteA>] = [
        "label": .string(\.label),
        "extra_a": .int(\.extra_a),
    ]
}

extension CfNoteB: ConfModel {
    static let confFields: [String: FieldSpec<CfNoteB>] = [
        "label": .string(\.label),
        "extra_b": .string(\.extra_b),
    ]
}

extension CfBinder: ConfModel {
    static let confFields: [String: FieldSpec<CfBinder>] = [
        "title": .string(\.title),
        "main": .virtualLink(\.main),
        "notes": .virtualList(\.notes),
    ]
}

extension ConfV1.CfWidget: ConfModel {
    static let confFields: [String: FieldSpec<ConfV1.CfWidget>] = [
        "label": .string(\.label),
    ]
}

extension ConfV1.CfMigPerson: ConfModel {
    static let confFields: [String: FieldSpec<ConfV1.CfMigPerson>] = [
        "name": .string(\.name),
        "age": .string(\.age),
    ]
}

extension ConfV1.CfBlobDoc: ConfModel {
    static let confFields: [String: FieldSpec<ConfV1.CfBlobDoc>] = [
        "label": .string(\.label),
        "payload": .bytes(\.payload),
    ]
}

extension CfWidget: ConfModel {
    static let confFields: [String: FieldSpec<CfWidget>] = [
        "label": .string(\.label),
        "count": .int(\.count),
        "note": .optString(\.note),
    ]
}

extension CfMigPerson: ConfModel {
    static let confFields: [String: FieldSpec<CfMigPerson>] = [
        "name": .string(\.name),
        "age": .int(\.age),
    ]
}

extension CfBlobDoc: ConfModel {
    static let confFields: [String: FieldSpec<CfBlobDoc>] = [
        "label": .string(\.label),
        "payload": .bytes(\.payload),
        "stars": .int(\.stars),
    ]
}

extension ConfV2T.CfBlobDoc: ConfModel {
    static let confFields: [String: FieldSpec<ConfV2T.CfBlobDoc>] = [
        "label": .string(\.label),
        "payload": .bytes(\.payload),
        "tag": .string(\.tag),
    ]
}
