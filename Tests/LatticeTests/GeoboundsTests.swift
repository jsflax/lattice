import Foundation
import Testing
import SwiftUI
import Lattice
import Observation
import MapKit

@Model
private class Restaurant {
    var name: String
    var category: String
    var location: CLLocationCoordinate2D
}

@Model
private class Destination {
    var name: String
    var region: MKCoordinateRegion
}

@Suite("Geobounds Tests")
class GeoboundsTests: BaseTest {

    // MARK: - Basic Storage Tests

    @Test
    func test_CLLocationCoordinate2D_Storage() async throws {
        let lattice = try testLattice(Restaurant.self)

        let sf = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
        let restaurant = Restaurant()
        restaurant.name = "Test Restaurant"
        restaurant.category = "cafe"
        restaurant.location = sf

        lattice.add(restaurant)

        let restaurants = lattice.objects(Restaurant.self).snapshot()
        #expect(restaurants.count == 1)

        let retrieved = restaurants.first!
        #expect(retrieved.name == "Test Restaurant")
        #expect(Swift.abs(retrieved.location.latitude - 37.7749) < 0.0001)
        #expect(Swift.abs(retrieved.location.longitude - (-122.4194)) < 0.0001)
    }

    @Test
    func test_MKCoordinateRegion_Storage() async throws {
        let lattice = try testLattice(Destination.self)

        let center = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
        let span = MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
        let dest = Destination()
        dest.name = "SF Bay Area"
        dest.region = MKCoordinateRegion(center: center, span: span)

        lattice.add(dest)

        let destinations = lattice.objects(Destination.self).snapshot()
        #expect(destinations.count == 1)

        let retrieved = destinations.first!
        #expect(retrieved.name == "SF Bay Area")
        #expect(Swift.abs(retrieved.region.center.latitude - 37.7749) < 0.0001)
        #expect(Swift.abs(retrieved.region.span.latitudeDelta - 0.1) < 0.0001)
    }

    // MARK: - Within Bounds Tests

    @Test
    func test_WithinBounds_BasicQuery() async throws {
        let lattice = try testLattice(Restaurant.self)

        // Create restaurants in different locations
        let locations: [(String, Double, Double)] = [
            ("SF Restaurant", 37.7749, -122.4194),
            ("Oakland Restaurant", 37.8044, -122.2712),
            ("San Jose Restaurant", 37.3382, -121.8863),
            ("LA Restaurant", 34.0522, -118.2437),
            ("NYC Restaurant", 40.7128, -74.0060),
        ]

        for (name, lat, lon) in locations {
            let r = Restaurant()
            r.name = name
            r.category = "restaurant"
            r.location = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            lattice.add(r)
        }

        // Query for Bay Area (should include SF, Oakland, San Jose)
        let bayAreaPlaces = lattice.objects(Restaurant.self)
            .withinBounds(\.location,
                         minLat: 37.0, maxLat: 38.0,
                         minLon: -123.0, maxLon: -121.5)

        #expect(bayAreaPlaces.count == 3)
        let names = Set(bayAreaPlaces.map { $0.name })
        #expect(names.contains("SF Restaurant"))
        #expect(names.contains("Oakland Restaurant"))
        #expect(names.contains("San Jose Restaurant"))
        #expect(!names.contains("LA Restaurant"))
        #expect(!names.contains("NYC Restaurant"))
    }

    // MARK: - Nearest Tests

    @Test
    func test_Nearest_BasicQuery() async throws {
        let lattice = try testLattice(Restaurant.self)

        // Create restaurants at known distances from SF
        let sf = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
        let locations: [(String, Double, Double)] = [
            ("SF Restaurant", 37.7749, -122.4194),           // 0km
            ("Oakland Restaurant", 37.8044, -122.2712),     // ~13km
            ("Berkeley Restaurant", 37.8716, -122.2727),    // ~16km
            ("San Jose Restaurant", 37.3382, -121.8863),    // ~70km
            ("LA Restaurant", 34.0522, -118.2437),          // ~560km
        ]

        for (name, lat, lon) in locations {
            let r = Restaurant()
            r.name = name
            r.category = "restaurant"
            r.location = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            lattice.add(r)
        }

        // Find 3 nearest restaurants to SF within 100km
        let nearest = lattice.objects(Restaurant.self)
            .nearest(to: (latitude: sf.latitude, longitude: sf.longitude),
                    on: \.location, maxDistance: 100, unit: .kilometers, limit: 3)

        #expect(nearest.count == 3)

        // Should be sorted by distance
        for i in 0..<(nearest.count - 1) {
            #expect(nearest[i].distance <= nearest[i + 1].distance)
        }

        // SF should be first (distance ~0)
        #expect(nearest[0].object.name == "SF Restaurant")
        #expect(nearest[0].distance < 1) // Less than 1km

        print("Nearest to SF:")
        for match in nearest {
            print("  \(match.object.name): \(match.distance) km")
        }

        // LA should not be in results (> 100km)
        let names = nearest.map { $0.object.name }
        #expect(!names.contains("LA Restaurant"))
    }

    @Test
    func test_Nearest_WithFilter() async throws {
        let lattice = try testLattice(Restaurant.self)

        let sf = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
        let places: [(String, String, Double, Double)] = [
            ("Blue Bottle Coffee", "cafe", 37.7751, -122.4180),
            ("Tartine Bakery", "cafe", 37.7614, -122.4241),
            ("City Hall", "landmark", 37.7793, -122.4193),
            ("Ferry Building", "landmark", 37.7956, -122.3935),
        ]

        for (name, category, lat, lon) in places {
            let r = Restaurant()
            r.name = name
            r.category = category
            r.location = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            lattice.add(r)
        }

        // Find nearest cafes only
        let nearestCafes = lattice.objects(Restaurant.self)
            .where { $0.category == "cafe" }
            .nearest(to: (latitude: sf.latitude, longitude: sf.longitude),
                    on: \.location, maxDistance: 5, unit: .kilometers, limit: 10)

        #expect(nearestCafes.count == 2)
        let categories = Set(nearestCafes.map { $0.object.category })
        #expect(categories == ["cafe"])

        print("Nearest cafes to SF:")
        for match in nearestCafes {
            print("  \(match.object.name): \(match.distance) km")
        }
    }

    @Test
    func test_Nearest_DistanceUnits() async throws {
        let lattice = try testLattice(Restaurant.self)

        // SF and Oakland are ~13km apart
        let sf = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
        let oakland = CLLocationCoordinate2D(latitude: 37.8044, longitude: -122.2712)

        let r1 = Restaurant()
        r1.name = "SF"
        r1.category = "test"
        r1.location = sf
        lattice.add(r1)

        let r2 = Restaurant()
        r2.name = "Oakland"
        r2.category = "test"
        r2.location = oakland
        lattice.add(r2)

        // Query in meters
        let metersResult = lattice.objects(Restaurant.self)
            .nearest(to: (latitude: sf.latitude, longitude: sf.longitude),
                    on: \.location, maxDistance: 20000, unit: .meters, limit: 10)
        #expect(metersResult.count == 2)
        let oaklandMeters = metersResult.first { $0.object.name == "Oakland" }!.distance
        print("SF to Oakland: \(oaklandMeters) meters")
        #expect(oaklandMeters > 10000 && oaklandMeters < 20000)

        // Query in kilometers
        let kmResult = lattice.objects(Restaurant.self)
            .nearest(to: (latitude: sf.latitude, longitude: sf.longitude),
                    on: \.location, maxDistance: 20, unit: .kilometers, limit: 10)
        let oaklandKm = kmResult.first { $0.object.name == "Oakland" }!.distance
        print("SF to Oakland: \(oaklandKm) km")
        #expect(oaklandKm > 10 && oaklandKm < 20)

        // Query in miles
        let milesResult = lattice.objects(Restaurant.self)
            .nearest(to: (latitude: sf.latitude, longitude: sf.longitude),
                    on: \.location, maxDistance: 15, unit: .miles, limit: 10)
        let oaklandMiles = milesResult.first { $0.object.name == "Oakland" }!.distance
        print("SF to Oakland: \(oaklandMiles) miles")
        #expect(oaklandMiles > 6 && oaklandMiles < 12)

        // Verify unit conversion consistency
        #expect(Swift.abs(oaklandMeters / 1000 - oaklandKm) < 0.1)
        #expect(Swift.abs(oaklandKm / 1.609344 - oaklandMiles) < 0.1)
    }

    @Test
    func test_Nearest_UnsortedQuery() async throws {
        let lattice = try testLattice(Restaurant.self)

        let sf = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
        let locations: [(String, Double, Double)] = [
            ("Place A", 37.78, -122.42),
            ("Place B", 37.77, -122.41),
            ("Place C", 37.79, -122.43),
        ]

        for (name, lat, lon) in locations {
            let r = Restaurant()
            r.name = name
            r.category = "test"
            r.location = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            lattice.add(r)
        }

        // Query without sorting - should still return objects within radius
        let unsorted = lattice.objects(Restaurant.self)
            .nearest(to: (latitude: sf.latitude, longitude: sf.longitude),
                    on: \.location, maxDistance: 10, unit: .kilometers,
                    limit: 10, sortedByDistance: false)

        #expect(unsorted.count == 3)

        // Distances should all be 0 when not sorted (no Haversine computed)
        for match in unsorted {
            #expect(match.distance == 0)
        }
    }

    @Test
    func test_Nearest_MaxDistanceFilter() async throws {
        let lattice = try testLattice(Restaurant.self)

        let sf = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
        let locations: [(String, Double, Double)] = [
            ("Very Close", 37.7750, -122.4195),  // ~10m
            ("Close", 37.780, -122.420),          // ~500m
            ("Medium", 37.80, -122.40),           // ~3km
            ("Far", 37.90, -122.30),              // ~15km
        ]

        for (name, lat, lon) in locations {
            let r = Restaurant()
            r.name = name
            r.category = "test"
            r.location = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            lattice.add(r)
        }

        // Query with 1km radius
        let within1km = lattice.objects(Restaurant.self)
            .nearest(to: (latitude: sf.latitude, longitude: sf.longitude),
                    on: \.location, maxDistance: 1, unit: .kilometers, limit: 100)

        #expect(within1km.count == 2) // Very Close and Close
        let names1km = Set(within1km.map { $0.object.name })
        #expect(names1km.contains("Very Close"))
        #expect(names1km.contains("Close"))
        #expect(!names1km.contains("Medium"))
        #expect(!names1km.contains("Far"))

        // Query with 5km radius
        let within5km = lattice.objects(Restaurant.self)
            .nearest(to: (latitude: sf.latitude, longitude: sf.longitude),
                    on: \.location, maxDistance: 5, unit: .kilometers, limit: 100)

        #expect(within5km.count == 3) // Very Close, Close, Medium
        let names5km = Set(within5km.map { $0.object.name })
        #expect(names5km.contains("Medium"))
        #expect(!names5km.contains("Far"))
    }
}
