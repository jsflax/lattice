import Foundation

extension ClosedRange: EmbeddedModel, Codable, DefaultInitializable, CxxListManaged, CxxManaged, PrimitiveProperty, SchemaProperty, PersistableProperty where Bound: Numeric, Bound: CxxManaged, Bound: DefaultInitializable, Bound: Codable {
    private enum CodingKeys: String, CodingKey {
        case upperBound, lowerBound
    }
    
    public init() {
        self = Bound(exactly: 0)!...Bound(exactly: 1)!
    }
    
    init (from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let upperBound = try container.decode(Bound.self, forKey: .upperBound)
        let lowerBound = try container.decode(Bound.self, forKey: .lowerBound)
        self = lowerBound...upperBound
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.upperBound, forKey: .upperBound)
        try container.encode(self.lowerBound, forKey: .lowerBound)
    }
    
    public static func setField(on object: inout CxxDynamicObjectRef, named name: String, _ value: Self) {
        let jsonStr = String(data: try! JSONEncoder().encode(value), encoding: .utf8)!
        object.setString(named: std.string(name), std.string(jsonStr))
    }
    
    public static var defaultValue: Self {
        .init()
    }

    public static var anyPropertyKind: AnyProperty.Kind { .string }
}

#if canImport(MapKit)
import MapKit

extension CLLocationCoordinate2D: EmbeddedModel {
    private enum CodingKeys: String, CodingKey {
        case latitude, longitude
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let latitude = try container.decode(Double.self, forKey: .latitude)
        let longitude = try container.decode(Double.self, forKey: .longitude)
        self.init(latitude: latitude, longitude: longitude)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(latitude, forKey: .latitude)
        try container.encode(longitude, forKey: .longitude)
    }
    
    public static func setField(on object: inout CxxDynamicObjectRef, named name: String, _ value: Self) {
        let jsonStr = String(data: try! JSONEncoder().encode(value), encoding: .utf8)!
        object.setString(named: std.string(name), std.string(jsonStr))
    }
    
    public static var defaultValue: Self {
        .init()
    }

    public static var anyPropertyKind: AnyProperty.Kind { .string }
}

#endif
