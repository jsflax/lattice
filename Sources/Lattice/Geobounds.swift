import Foundation
import LatticeSwiftCppBridge

public protocol GeoboundsProperty: LatticeSchemaProperty {}

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
}

#if canImport(MapKit)
import MapKit

extension MKCoordinateRegion: CxxManaged, GeoboundsProperty {
    public static var anyPropertyKind: AnyProperty.Kind {
        .int
    }
    
    public static var defaultValue: Self {
        .init()
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
}

extension CLLocationCoordinate2D: CxxManaged, GeoboundsProperty {
    public static var anyPropertyKind: AnyProperty.Kind {
        .int
    }
    
    public static var defaultValue: Self {
        .init()
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
