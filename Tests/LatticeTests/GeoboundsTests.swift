import Foundation
import Testing
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

@Model
private class Route {
    var name: String
    var waypoints: Lattice.List<CLLocationCoordinate2D>
}

@Model
private class TravelPlan {
    var name: String
    var regions: Lattice.List<MKCoordinateRegion>
}

@Model
private class Trip {
    var name: String
    var startLocation: CLLocationCoordinate2D  // Single geo_bounds property
    var stops: Lattice.List<CLLocationCoordinate2D>  // List of geo_bounds
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

        // Distances are computed (even when not sorted)
        for match in unsorted {
            #expect(match.distance > 0, "Distance should be computed")
            #expect(match.distance < 10, "Distance should be within maxDistance (in km)")
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

    // MARK: - List Tests

    @Test
    func test_List_CLLocationCoordinate2D() async throws {
        let lattice = try testLattice(Route.self)

        let route = Route()
        route.name = "Bay Area Tour"

        // Add waypoints
        let sf = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
        let oakland = CLLocationCoordinate2D(latitude: 37.8044, longitude: -122.2712)
        let berkeley = CLLocationCoordinate2D(latitude: 37.8716, longitude: -122.2727)

        lattice.add(route)

        route.waypoints.append(sf)
        route.waypoints.append(oakland)
        route.waypoints.append(berkeley)

        #expect(route.waypoints.count == 3)

        // Verify coordinates
        #expect(Swift.abs(route.waypoints[0].latitude - 37.7749) < 0.0001)
        #expect(Swift.abs(route.waypoints[0].longitude - (-122.4194)) < 0.0001)
        #expect(Swift.abs(route.waypoints[1].latitude - 37.8044) < 0.0001)
        #expect(Swift.abs(route.waypoints[2].latitude - 37.8716) < 0.0001)

        // Test iteration
        var count = 0
        for waypoint in route.waypoints {
            #expect(waypoint.latitude > 37.0)
            count += 1
        }
        #expect(count == 3)

        // Test remove
        _ = route.waypoints.remove(at: 1) // Remove Oakland
        #expect(route.waypoints.count == 2)
        #expect(Swift.abs(route.waypoints[0].latitude - 37.7749) < 0.0001) // SF
        #expect(Swift.abs(route.waypoints[1].latitude - 37.8716) < 0.0001) // Berkeley
    }

    @Test
    func test_List_MKCoordinateRegion() async throws {
        let lattice = try testLattice(TravelPlan.self)

        let plan = TravelPlan()
        plan.name = "California Trip"

        lattice.add(plan)

        // Add regions
        let bayArea = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
            span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
        )
        let la = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 34.0522, longitude: -118.2437),
            span: MKCoordinateSpan(latitudeDelta: 0.3, longitudeDelta: 0.3)
        )
        let sandiego = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 32.7157, longitude: -117.1611),
            span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2)
        )

        plan.regions.append(bayArea)
        plan.regions.append(la)
        plan.regions.append(sandiego)

        #expect(plan.regions.count == 3)

        // Verify regions
        #expect(Swift.abs(plan.regions[0].center.latitude - 37.7749) < 0.0001)
        #expect(Swift.abs(plan.regions[0].span.latitudeDelta - 0.5) < 0.0001)
        #expect(Swift.abs(plan.regions[1].center.latitude - 34.0522) < 0.0001)
        #expect(Swift.abs(plan.regions[2].center.latitude - 32.7157) < 0.0001)

        // Test iteration
        var totalSpan = 0.0
        for region in plan.regions {
            totalSpan += region.span.latitudeDelta
        }
        #expect(Swift.abs(totalSpan - 1.0) < 0.0001) // 0.5 + 0.3 + 0.2

        // Test remove
        _ = plan.regions.remove(at: 1) // Remove LA
        #expect(plan.regions.count == 2)
        #expect(Swift.abs(plan.regions[0].center.latitude - 37.7749) < 0.0001) // Bay Area
        #expect(Swift.abs(plan.regions[1].center.latitude - 32.7157) < 0.0001) // San Diego
    }

    @Test
    func test_List_GeoBounds_Persistence() async throws {
        let path = "\(String.random(length: 32)).sqlite"
        defer {
            try? Lattice.delete(for: .init(fileURL: FileManager.default.temporaryDirectory.appending(path: path)))
        }

        // Create and populate
        try autoreleasepool {
            let lattice = try Lattice(Route.self, configuration: .init(fileURL: FileManager.default.temporaryDirectory.appending(path: path)))
            let route = Route()
            route.name = "Test Route"
            lattice.add(route)

            route.waypoints.append(CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194))
            route.waypoints.append(CLLocationCoordinate2D(latitude: 34.0522, longitude: -118.2437))

            #expect(route.waypoints.count == 2)
        }

        // Reopen and verify
        try autoreleasepool {
            let lattice = try Lattice(Route.self, configuration: .init(fileURL: FileManager.default.temporaryDirectory.appending(path: path)))
            let routes = lattice.objects(Route.self).snapshot()
            #expect(routes.count == 1)

            let route = routes.first!
            #expect(route.name == "Test Route")
            #expect(route.waypoints.count == 2)
            #expect(Swift.abs(route.waypoints[0].latitude - 37.7749) < 0.0001)
            #expect(Swift.abs(route.waypoints[1].latitude - 34.0522) < 0.0001)
        }
    }

    @Test
    func test_List_GeoBounds_AppendContentsOf() async throws {
        let lattice = try testLattice(Route.self)
        let route = Route()
        route.name = "Multi-Stop Route"
        lattice.add(route)

        let stops = [
            CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
            CLLocationCoordinate2D(latitude: 37.8044, longitude: -122.2712),
            CLLocationCoordinate2D(latitude: 37.8716, longitude: -122.2727),
            CLLocationCoordinate2D(latitude: 37.3382, longitude: -121.8863),
        ]

        route.waypoints.append(contentsOf: stops)
        #expect(route.waypoints.count == 4)

        for (i, stop) in stops.enumerated() {
            #expect(Swift.abs(route.waypoints[i].latitude - stop.latitude) < 0.0001)
            #expect(Swift.abs(route.waypoints[i].longitude - stop.longitude) < 0.0001)
        }
    }

    @Test
    func test_List_GeoBounds_DoesNotIncludeSingleProperty() async throws {
        // Test that a single geo_bounds property doesn't end up in the list
        let lattice = try testLattice(Trip.self)

        let trip = Trip()
        trip.name = "Road Trip"

        // Set the single start location (NOT in the list)
        let startPoint = CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060) // NYC
        trip.startLocation = startPoint

        lattice.add(trip)

        // Add some stops to the list
        let stop1 = CLLocationCoordinate2D(latitude: 39.9526, longitude: -75.1652) // Philadelphia
        let stop2 = CLLocationCoordinate2D(latitude: 38.9072, longitude: -77.0369) // Washington DC

        trip.stops.append(stop1)
        trip.stops.append(stop2)

        // Verify the list only has 2 items (the stops), NOT 3 (which would include startLocation)
        #expect(trip.stops.count == 2)

        // Verify the start location is NOT in the list
        for stop in trip.stops {
            // NYC coords should not appear in stops
            let isNYC = Swift.abs(stop.latitude - 40.7128) < 0.0001 &&
                       Swift.abs(stop.longitude - (-74.0060)) < 0.0001
            #expect(!isNYC, "startLocation should not be in the stops list")
        }

        // Verify the actual stops are correct
        #expect(Swift.abs(trip.stops[0].latitude - 39.9526) < 0.0001) // Philly
        #expect(Swift.abs(trip.stops[1].latitude - 38.9072) < 0.0001) // DC

        // Verify startLocation is still correct and separate
        #expect(Swift.abs(trip.startLocation.latitude - 40.7128) < 0.0001)
        #expect(Swift.abs(trip.startLocation.longitude - (-74.0060)) < 0.0001)
    }

    @Test
    func test_GeoBounds_ReopenWithoutMigration() async throws {
        // Test that reopening a database with geo_bounds doesn't unnecessarily repopulate rtrees
        let uniquePath = "geobounds_reopen_\(String.random(length: 16)).sqlite"
        let fileURL = FileManager.default.temporaryDirectory.appending(path: uniquePath)
        defer {
            try? Lattice.delete(for: .init(fileURL: fileURL))
        }

        // First open - create database and add data
        do {
            let lattice = try Lattice(Restaurant.self, configuration: .init(fileURL: fileURL))

            let restaurant = Restaurant()
            restaurant.name = "Test Restaurant"
            restaurant.category = "Italian"
            restaurant.location = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
            lattice.add(restaurant)

            // Verify data is there
            #expect(lattice.objects(Restaurant.self).count == 1)

            // Close by releasing reference
        }

        print("=== REOPENING DATABASE (should NOT repopulate rtree) ===")

        // Second open - no schema changes, should NOT repopulate rtree
        do {
            let lattice = try Lattice(Restaurant.self, configuration: .init(fileURL: fileURL))

            // Verify data persisted
            let restaurants = lattice.objects(Restaurant.self)
            #expect(restaurants.count == 1)
            #expect(restaurants.first?.name == "Test Restaurant")

            // Verify spatial query still works
            let nearby = lattice.objects(Restaurant.self)
                .nearest(to: (latitude: 37.77, longitude: -122.42),
                        on: \.location, maxDistance: 10, unit: .kilometers, limit: 10)
            #expect(nearby.count == 1)
        }
    }

    // MARK: - Group By with Proximity

    @Test
    func test_GroupBy_WithNearestQuery() async throws {
        let lattice = try testLattice(Restaurant.self)

        // Add restaurants in SF area with different categories
        let sfCenter = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)

        // Multiple Italian restaurants nearby
        let r1 = Restaurant()
        r1.name = "Italian Place 1"
        r1.category = "Italian"
        r1.location = CLLocationCoordinate2D(latitude: 37.775, longitude: -122.419)
        lattice.add(r1)

        let r2 = Restaurant()
        r2.name = "Italian Place 2"
        r2.category = "Italian"
        r2.location = CLLocationCoordinate2D(latitude: 37.776, longitude: -122.420)
        lattice.add(r2)

        // Multiple Mexican restaurants nearby
        let r3 = Restaurant()
        r3.name = "Mexican Place 1"
        r3.category = "Mexican"
        r3.location = CLLocationCoordinate2D(latitude: 37.774, longitude: -122.418)
        lattice.add(r3)

        let r4 = Restaurant()
        r4.name = "Mexican Place 2"
        r4.category = "Mexican"
        r4.location = CLLocationCoordinate2D(latitude: 37.773, longitude: -122.417)
        lattice.add(r4)

        // One Chinese restaurant
        let r5 = Restaurant()
        r5.name = "Chinese Place"
        r5.category = "Chinese"
        r5.location = CLLocationCoordinate2D(latitude: 37.772, longitude: -122.416)
        lattice.add(r5)

        // Without group by - should get all 5
        let allNearby = lattice.objects(Restaurant.self)
            .nearest(to: (sfCenter.latitude, sfCenter.longitude),
                    on: \.location, maxDistance: 5, unit: .kilometers)
            .snapshot()
        #expect(allNearby.count == 5)

        // With group by category - should get 3 (one per category)
        let groupedNearby = lattice.objects(Restaurant.self)
            .nearest(to: (sfCenter.latitude, sfCenter.longitude),
                    on: \.location, maxDistance: 5, unit: .kilometers)
            .group(by: \.category)
            .snapshot()
        #expect(groupedNearby.count == 3)

        // Verify we got one from each category
        let categories = Set(groupedNearby.map { $0.category })
        #expect(categories == Set(["Italian", "Mexican", "Chinese"]))
    }

    @Test
    func test_GroupBy_WithBoundsQuery() async throws {
        let lattice = try testLattice(Restaurant.self)

        // Add restaurants in SF bounding box
        let r1 = Restaurant()
        r1.name = "Cafe 1"
        r1.category = "Cafe"
        r1.location = CLLocationCoordinate2D(latitude: 37.78, longitude: -122.41)
        lattice.add(r1)

        let r2 = Restaurant()
        r2.name = "Cafe 2"
        r2.category = "Cafe"
        r2.location = CLLocationCoordinate2D(latitude: 37.79, longitude: -122.42)
        lattice.add(r2)

        let r3 = Restaurant()
        r3.name = "Bar 1"
        r3.category = "Bar"
        r3.location = CLLocationCoordinate2D(latitude: 37.77, longitude: -122.40)
        lattice.add(r3)

        // Query within bounds, then group
        let grouped = lattice.objects(Restaurant.self)
            .withinBounds(\.location, minLat: 37.75, maxLat: 37.80, minLon: -122.45, maxLon: -122.38)
            .group(by: \.category)
            .snapshot()

        #expect(grouped.count == 2) // Cafe and Bar
        let categories = Set(grouped.map { $0.category })
        #expect(categories == Set(["Cafe", "Bar"]))
    }
}
