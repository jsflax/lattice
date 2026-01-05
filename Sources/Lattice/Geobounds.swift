import Foundation
import LatticeSwiftCppBridge

public protocol GeoboundsProperty: LatticeSchemaProperty {
    static func _trace<V>(keyPath: KeyPath<Self, V>) -> String
}

extension GeoboundsProperty where Self: LinkListable {
    public static func getLinkListField(from object: inout CxxDynamicObjectRef, named name: String) -> lattice.geo_bounds_list_ref {
        object.getGeoBoundsList(named: std.string(name))
    }
}
/// Unit for geographic distance measurements
public enum DistanceUnit: Sendable {
    case meters
    case kilometers
    case miles
    case feet

    /// Conversion factor from this unit to meters
    public var toMeters: Double {
        switch self {
        case .meters: return 1.0
        case .kilometers: return 1000.0
        case .miles: return 1609.344
        case .feet: return 0.3048
        }
    }

    /// Convert a value in meters to this unit
    public func fromMeters(_ meters: Double) -> Double {
        meters / toMeters
    }
}

extension Optional: GeoboundsProperty where Wrapped: GeoboundsProperty {
//    public typealias Ref = lattice.geo_bounds_list_ref
//    
//    public var asRefType: lattice.geo_bounds_ref {
//        if let self = self {
//            return self.asRefType
//        } else {
//            return std.nullopt_t.init() as! lattice.geo_bounds_ref
//        }
//    }
//    
//    public init(_ bounds: lattice.geo_bounds_ref) {
//        Wrapped.init(bounds as! Wrapped.Ref.RefType)
//    }
    public static func _trace<V>(keyPath: KeyPath<Optional<Wrapped>, V>) -> String {
        Wrapped._trace(keyPath: keyPath as! KeyPath<Wrapped, V>)
    }
}

#if canImport(MapKit)
import MapKit

extension MKCoordinateRegion: CxxManaged, GeoboundsProperty, LinkListable {
    public static var anyPropertyKind: AnyProperty.Kind {
        .int
    }
    
    public static var defaultValue: Self {
        .init()
    }
    
    public var asRefType: lattice.geo_bounds_ref {
        let bbox = boundingBox
        return .init(.init(bbox.minLat, bbox.maxLat, bbox.minLon, bbox.maxLon))
    }
    
    public init(_ bounds: lattice.geo_bounds_ref) {
        let bounds = bounds.shared().pointee
        let center = CLLocationCoordinate2D(latitude: bounds.center_lat(), longitude: bounds.center_lon())
        let span = MKCoordinateSpan(latitudeDelta: bounds.lat_span(), longitudeDelta: bounds.lon_span())
        self.init(center: center, span: span)
    }
    
    public static func getField(from object: inout CxxDynamicObjectRef, named name: String) -> MKCoordinateRegion {
        let bounds = object.getGeoBounds(named: std.string(name))
        let center = CLLocationCoordinate2D(latitude: bounds.center_lat(), longitude: bounds.center_lon())
        let span = MKCoordinateSpan(latitudeDelta: bounds.lat_span(), longitudeDelta: bounds.lon_span())
        return .init(center: center, span: span)
    }
    
    public static func setField(on object: inout CxxDynamicObjectRef,
                                named name: String,
                                _ value: MKCoordinateRegion) {
        let bbox: (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double) =
        (minLat: value.center.latitude - value.span.latitudeDelta / 2,
         maxLat: value.center.latitude + value.span.latitudeDelta / 2,
         minLon: value.center.longitude - value.span.longitudeDelta / 2,
         maxLon: value.center.longitude + value.span.longitudeDelta / 2)
        object.setGeoBounds(named: std.string(name), minLat: bbox.minLat, maxLat: bbox.maxLat, minLon: bbox.minLon, maxLon: bbox.maxLon)
    }
    
    public var boundingBox: (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double) {
        (minLat: center.latitude - span.latitudeDelta / 2,
         maxLat: center.latitude + span.latitudeDelta / 2,
         minLon: center.longitude - span.longitudeDelta / 2,
         maxLon: center.longitude + span.longitudeDelta / 2)
    }
    
    public static func _trace<V>(keyPath: KeyPath<MKCoordinateRegion, V>) -> String {
        switch keyPath {
        case \.center: return "center"
        case \.span: return "span"
        default: preconditionFailure()
        }
    }
}

public struct CLLocationCoordinate2DCompat: EmbeddedModel {
    public let latitude: Double = 0
    public let longitude: Double = 0
    
    public init() {}
}

extension CLLocationCoordinate2D: CxxManaged, GeoboundsProperty, LinkListable {
    public var asRefType: lattice.geo_bounds_ref {
        .init(.init(latitude, latitude, longitude, longitude))
    }
    
    public init(_ refType: lattice.geo_bounds_ref) {
        let bounds = refType.shared().pointee
        self.init(latitude: bounds.center_lat(), longitude: bounds.center_lon())
    }
    
    public static var anyPropertyKind: AnyProperty.Kind {
        .int
    }
    
    public static var defaultValue: Self {
        kCLLocationCoordinate2DInvalid
    }
    
    public static func _trace<V>(keyPath: KeyPath<Self, V>) -> String {
        switch keyPath {
        case \.latitude: return "minLat"
        case \.longitude: return "minLon"
        default: preconditionFailure()
        }
    }
    
    public static func getField(from object: inout CxxDynamicObjectRef, named name: String) -> CLLocationCoordinate2D {
        let bounds = object.getGeoBounds(named: std.string(name))
        return CLLocationCoordinate2D(latitude: bounds.center_lat(), longitude: bounds.center_lon())
    }
    
    public static func setField(on object: inout CxxDynamicObjectRef,
                                named name: String, _ value: CLLocationCoordinate2D) {
        object.setGeoBounds(named: std.string(name), minLat: value.latitude,
                            maxLat: value.latitude, minLon: value.longitude,
                            maxLon: value.longitude)
    }
}

#endif
