// MapKitCompat.swift
// Provides CLLocationCoordinate2D and MKCoordinateRegion stubs on Linux
// so geobounds and combined query tests can run without MapKit.

#if !canImport(MapKit)

import Foundation
@testable import Lattice  // asCxxObjectRef (internal) — mirrors Sources/Lattice/Geobounds.swift

// MARK: - CLLocationCoordinate2D

public struct CLLocationCoordinate2D: CxxManaged, GeoboundsProperty, LinkListable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double = 0, longitude: Double = 0) {
        self.latitude = latitude
        self.longitude = longitude
    }

    // MARK: SchemaProperty

    public static var anyPropertyKind: AnyProperty.Kind { .int }
    public static var defaultValue: Self { .init(latitude: 0, longitude: 0) }

    // MARK: GeoboundsProperty

    public static func _trace<V>(keyPath: KeyPath<CLLocationCoordinate2D, V>) -> String {
        switch keyPath {
        case \.latitude: return "minLat"
        case \.longitude: return "minLon"
        default: preconditionFailure()
        }
    }

    // MARK: CxxManaged

    public static func getField(from storage: borrowing ModelStorage, named name: String) -> CLLocationCoordinate2D {
        let bounds = storage._ref.asCxxObjectRef!.getGeoBounds(named: std.string(name))
        return CLLocationCoordinate2D(latitude: bounds.center_lat(), longitude: bounds.center_lon())
    }

    public static func setField(on storage: inout ModelStorage, named name: String, _ value: CLLocationCoordinate2D) {
        storage._ref.asCxxObjectRef!.setGeoBounds(named: std.string(name),
                                  minLat: value.latitude, maxLat: value.latitude,
                                  minLon: value.longitude, maxLon: value.longitude)
    }

    // MARK: LinkListable

    public static func _makeLinkList(from storage: borrowing ModelStorage, named name: String) -> GeoBoundsLinkListRef<CLLocationCoordinate2D> {
        GeoBoundsLinkListRef(
            _ref: storage._ref.asCxxObjectRef!.getGeoBoundsList(named: std.string(name)),
            fromRef: { CLLocationCoordinate2D($0) },
            toRef: { $0.asRefType }
        )
    }

    // MARK: C++ bridge

    public var asRefType: lattice.geo_bounds_ref {
        .init(.init(latitude, latitude, longitude, longitude))
    }

    public init(_ refType: lattice.geo_bounds_ref) {
        let bounds = refType.shared().pointee
        self.init(latitude: bounds.center_lat(), longitude: bounds.center_lon())
    }
}

// MARK: - MKCoordinateSpan

public struct MKCoordinateSpan {
    public var latitudeDelta: Double
    public var longitudeDelta: Double

    public init(latitudeDelta: Double = 0, longitudeDelta: Double = 0) {
        self.latitudeDelta = latitudeDelta
        self.longitudeDelta = longitudeDelta
    }
}

// MARK: - MKCoordinateRegion

public struct MKCoordinateRegion: CxxManaged, GeoboundsProperty, LinkListable {
    public var center: CLLocationCoordinate2D
    public var span: MKCoordinateSpan

    public init(center: CLLocationCoordinate2D = .init(), span: MKCoordinateSpan = .init()) {
        self.center = center
        self.span = span
    }

    // MARK: SchemaProperty

    public static var anyPropertyKind: AnyProperty.Kind { .int }
    public static var defaultValue: Self { .init() }

    // MARK: GeoboundsProperty

    public static func _trace<V>(keyPath: KeyPath<MKCoordinateRegion, V>) -> String {
        switch keyPath {
        case \.center: return "center"
        case \.span: return "span"
        default: preconditionFailure()
        }
    }

    // MARK: CxxManaged

    public static func getField(from storage: borrowing ModelStorage, named name: String) -> MKCoordinateRegion {
        let bounds = storage._ref.asCxxObjectRef!.getGeoBounds(named: std.string(name))
        let center = CLLocationCoordinate2D(latitude: bounds.center_lat(), longitude: bounds.center_lon())
        let span = MKCoordinateSpan(latitudeDelta: bounds.lat_span(), longitudeDelta: bounds.lon_span())
        return .init(center: center, span: span)
    }

    public static func setField(on storage: inout ModelStorage, named name: String, _ value: MKCoordinateRegion) {
        let bbox = value.boundingBox
        storage._ref.asCxxObjectRef!.setGeoBounds(named: std.string(name),
                                  minLat: bbox.minLat, maxLat: bbox.maxLat,
                                  minLon: bbox.minLon, maxLon: bbox.maxLon)
    }

    // MARK: LinkListable

    public static func _makeLinkList(from storage: borrowing ModelStorage, named name: String) -> GeoBoundsLinkListRef<MKCoordinateRegion> {
        GeoBoundsLinkListRef(
            _ref: storage._ref.asCxxObjectRef!.getGeoBoundsList(named: std.string(name)),
            fromRef: { MKCoordinateRegion($0) },
            toRef: { $0.asRefType }
        )
    }

    // MARK: C++ bridge

    public var asRefType: lattice.geo_bounds_ref {
        let bbox = boundingBox
        return .init(.init(bbox.minLat, bbox.maxLat, bbox.minLon, bbox.maxLon))
    }

    public init(_ bounds: lattice.geo_bounds_ref) {
        let b = bounds.shared().pointee
        let center = CLLocationCoordinate2D(latitude: b.center_lat(), longitude: b.center_lon())
        let span = MKCoordinateSpan(latitudeDelta: b.lat_span(), longitudeDelta: b.lon_span())
        self.init(center: center, span: span)
    }

    public var boundingBox: (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double) {
        (minLat: center.latitude - span.latitudeDelta / 2,
         maxLat: center.latitude + span.latitudeDelta / 2,
         minLon: center.longitude - span.longitudeDelta / 2,
         maxLon: center.longitude + span.longitudeDelta / 2)
    }
}

#endif // !canImport(MapKit)
