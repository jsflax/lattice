import Foundation
import Testing
import Lattice
import MapKit

// MARK: - Test Models

/// A place with both location and semantic embedding
@Model
private class Place {
    var name: String
    var category: String
    var location: CLLocationCoordinate2D
    var embedding: FloatVector

    init(name: String = "", category: String = "",
         lat: Double = 0, lon: Double = 0,
         embedding: [Float] = []) {
        self.name = name
        self.category = category
        self.location = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        self.embedding = FloatVector(embedding)
    }
}

/// A product with multiple embeddings (image and text)
@Model
private class Product {
    var name: String
    var imageEmbedding: FloatVector
    var textEmbedding: FloatVector

    init(name: String = "", imageEmbedding: [Float] = [], textEmbedding: [Float] = []) {
        self.name = name
        self.imageEmbedding = FloatVector(imageEmbedding)
        self.textEmbedding = FloatVector(textEmbedding)
    }
}

/// A warehouse with location and inventory embedding
@Model
private class Warehouse {
    var name: String
    var location: CLLocationCoordinate2D
    var inventoryEmbedding: FloatVector

    init(name: String = "", lat: Double = 0, lon: Double = 0, inventory: [Float] = []) {
        self.name = name
        self.location = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        self.inventoryEmbedding = FloatVector(inventory)
    }
}

// MARK: - Combined Query Tests

@Suite("Combined Query Tests")
class CombinedQueryTests: BaseTest {

    // MARK: - Use Case 1: Local search with semantic matching
    // "Restaurants near me matching 'cozy Italian dinner'"

    @Test
    func test_GeoAndVectorSearch_RestaurantsNearMe() async throws {
        let lattice = try testLattice(Place.self)

        // Create restaurants with locations and semantic embeddings
        // Embedding direction: [italian, cozy, fast-food]
        let places = [
            // Near SF (37.7749, -122.4194)
            Place(name: "Trattoria Roma", category: "restaurant",
                  lat: 37.7751, lon: -122.4180,
                  embedding: [0.9, 0.8, 0.1]),  // Very Italian, cozy
            Place(name: "Quick Bites", category: "restaurant",
                  lat: 37.7760, lon: -122.4170,
                  embedding: [0.1, 0.2, 0.9]),  // Fast food
            Place(name: "Casa Bella", category: "restaurant",
                  lat: 37.7755, lon: -122.4190,
                  embedding: [0.8, 0.9, 0.1]),  // Italian, very cozy

            // Far from SF (Oakland)
            Place(name: "Pasta Palace", category: "restaurant",
                  lat: 37.8044, lon: -122.2712,
                  embedding: [1.0, 0.9, 0.0]),  // Most Italian, most cozy, but far
        ]

        lattice.add(contentsOf: places)

        let sfLocation = (latitude: 37.7749, longitude: -122.4194)
        let cozyItalianQuery = FloatVector([0.9, 0.9, 0.0])  // Italian + cozy

        // Find nearby restaurants matching "cozy Italian"
        let results = lattice.objects(Place.self)
            .nearest(to: sfLocation, on: \.location, maxDistance: 2, unit: .kilometers)
            .nearest(to: cozyItalianQuery, on: \.embedding, limit: 10)
            .snapshot()

        print("Nearby Italian restaurants:")
        for match in results {
            print("  \(match.name): geo=\(match.distances["location"] ?? -1), vec=\(match.distances["embedding"] ?? -1)")
        }

        // Should only return places within 2km (excludes Pasta Palace in Oakland)
        let names = results.map { $0.name }
        #expect(!names.contains("Pasta Palace"), "Oakland restaurant should be excluded by geo filter")

        // Should include the Italian places near SF
        #expect(names.contains("Trattoria Roma") || names.contains("Casa Bella"))
    }

    // MARK: - Use Case 2: Image search in a region
    // "Houses in this neighborhood that look like this photo"

    @Test
    func test_BoundsAndVectorSearch_HousesInRegion() async throws {
        let lattice = try testLattice(Place.self)

        // Create houses with locations and image embeddings
        // Embedding: [modern, victorian, colonial]
        let houses = [
            // In target region (SF Mission District)
            Place(name: "Modern Loft", category: "house",
                  lat: 37.760, lon: -122.420,
                  embedding: [0.9, 0.1, 0.1]),
            Place(name: "Victorian Home", category: "house",
                  lat: 37.758, lon: -122.418,
                  embedding: [0.1, 0.9, 0.2]),
            Place(name: "Mixed Style", category: "house",
                  lat: 37.762, lon: -122.422,
                  embedding: [0.5, 0.5, 0.3]),

            // Outside region (Pacific Heights)
            Place(name: "Grand Victorian", category: "house",
                  lat: 37.792, lon: -122.435,
                  embedding: [0.0, 1.0, 0.1]),  // Most Victorian, but outside bounds
        ]

        lattice.add(contentsOf: houses)

        // Query for Victorian-style houses in Mission District
        let victorianQuery = FloatVector([0.1, 0.9, 0.1])

        let results = lattice.objects(Place.self)
            .withinBounds(\.location,
                         minLat: 37.755, maxLat: 37.765,
                         minLon: -122.425, maxLon: -122.415)
            .nearest(to: victorianQuery, on: \.embedding, limit: 10)
            .sortedBy(.vectorDistance(.forward))  // Sort by vector distance ascending
            .snapshot()

        print("Victorian houses in region:")
        for match in results {
            print("  \(match.name): distance=\(match.distance)")
        }

        // Should exclude Grand Victorian (outside bounds)
        let names = results.map { $0.name }
        #expect(!names.contains("Grand Victorian"))

        // Victorian Home should be closest match within bounds (after sorting by vector distance)
        #expect(results.first?.name == "Victorian Home")
    }

    // MARK: - Use Case 3: Multi-modal search
    // "Products matching both this image AND description"

    @Test
    func test_MultiVectorSearch_ProductsMatchingImageAndText() async throws {
        let lattice = try testLattice(Product.self)

        // Products with image and text embeddings
        // Image embedding: [red, round, tall]
        // Text embedding: [electronics, furniture, clothing]
        let products = [
            Product(name: "Red Chair",
                   imageEmbedding: [0.9, 0.3, 0.2],      // Red, not round, not tall
                   textEmbedding: [0.1, 0.9, 0.1]),      // Furniture
            Product(name: "Red Ball",
                   imageEmbedding: [0.9, 0.9, 0.1],      // Red, round, not tall
                   textEmbedding: [0.3, 0.2, 0.1]),      // Neither
            Product(name: "Red Lamp",
                   imageEmbedding: [0.8, 0.2, 0.9],      // Red, not round, tall
                   textEmbedding: [0.5, 0.8, 0.1]),      // Electronics/Furniture
            Product(name: "Blue Lamp",
                   imageEmbedding: [0.1, 0.2, 0.9],      // Not red, not round, tall
                   textEmbedding: [0.5, 0.8, 0.1]),      // Electronics/Furniture
        ]

        lattice.add(contentsOf: products)

        // Query: red item (image) that's furniture (text)
        let imageQuery = FloatVector([0.9, 0.0, 0.0])  // Red
        let textQuery = FloatVector([0.1, 0.9, 0.1])   // Furniture

        let results = lattice.objects(Product.self)
            .nearest(to: imageQuery, on: \.imageEmbedding, limit: 10)
            .nearest(to: textQuery, on: \.textEmbedding, limit: 10)
            .sortedBy(.vectorDistance(.forward))  // Sort by first vector distance
            .snapshot()

        print("Products matching red + furniture:")
        for match in results {
            let imgDist = match.distances["imageEmbedding"] ?? -1
            let txtDist = match.distances["textEmbedding"] ?? -1
            print("  \(match.name): image=\(imgDist), text=\(txtDist)")
        }

        // Red Chair should be best match (red + furniture) - lowest image distance
        // Blue Lamp should be ranked last (worst image match)
        let names = results.map { $0.name }
        #expect(names.contains("Red Chair"))
        #expect(results.first?.name == "Red Chair", "Red Chair should be first (best image match)")
        #expect(results.last?.name == "Blue Lamp", "Blue Lamp should be last (worst image match)")
    }

    // MARK: - Use Case 4: Multi-geo nearest
    // "Convenient from both home and work"

    @Test
    func test_MultiGeoSearch_ConvenientFromBothLocations() async throws {
        let lattice = try testLattice(Place.self)

        // Home: SF (37.7749, -122.4194)
        // Work: Oakland (37.8044, -122.2712)
        // Looking for gym convenient from both

        let gyms = [
            // Close to SF, far from Oakland
            Place(name: "SF Fitness", category: "gym",
                  lat: 37.7760, lon: -122.4180,
                  embedding: []),
            // Close to Oakland, far from SF
            Place(name: "Oakland Gym", category: "gym",
                  lat: 37.8050, lon: -122.2700,
                  embedding: []),
            // Between SF and Oakland (Berkeley/Emeryville area)
            Place(name: "Bay Bridge Fitness", category: "gym",
                  lat: 37.7900, lon: -122.3500,
                  embedding: []),
            // Close to both (theoretically - near midpoint)
            Place(name: "Central Gym", category: "gym",
                  lat: 37.7850, lon: -122.3400,
                  embedding: []),
        ]

        lattice.add(contentsOf: gyms)

        let home = (latitude: 37.7749, longitude: -122.4194)
        let work = (latitude: 37.8044, longitude: -122.2712)

        // Find gyms within 15km of home AND within 15km of work
        let results = lattice.objects(Place.self)
            .nearest(to: home, on: \.location, maxDistance: 15, unit: .kilometers)
            .nearest(to: work, on: \.location, maxDistance: 15, unit: .kilometers)
            .snapshot()

        print("Gyms convenient from home and work:")
        for match in results {
            let homeDist = match.distances["location"] ?? -1  // Note: both use same column
            print("  \(match.name): distance=\(homeDist) km")
        }

        // SF Fitness and Oakland Gym should likely be filtered out
        // (one is close to home but far from work, and vice versa)
        // Central Gym and Bay Bridge Fitness should be included
        #expect(results.count >= 1)
    }

    // MARK: - Use Case 5: Nearest warehouse with matching inventory
    // "Find nearest warehouse that has items similar to this order"

    @Test
    func test_GeoAndVectorSearch_NearestMatchingWarehouse() async throws {
        let lattice = try testLattice(Warehouse.self)

        // Inventory embedding: [electronics, clothing, food]
        let warehouses = [
            // Close to delivery address
            Warehouse(name: "Downtown Warehouse",
                     lat: 37.7850, lon: -122.4000,
                     inventory: [0.9, 0.1, 0.1]),  // Electronics focused
            Warehouse(name: "SoMa Fulfillment",
                     lat: 37.7750, lon: -122.4100,
                     inventory: [0.1, 0.9, 0.2]),  // Clothing focused

            // Further away
            Warehouse(name: "Oakland Distribution",
                     lat: 37.8044, lon: -122.2712,
                     inventory: [0.8, 0.5, 0.3]),  // Mixed, electronics heavy
            Warehouse(name: "San Jose Hub",
                     lat: 37.3382, lon: -121.8863,
                     inventory: [0.9, 0.8, 0.1]),  // Best electronics match, but far
        ]

        lattice.add(contentsOf: warehouses)

        let deliveryAddress = (latitude: 37.7800, longitude: -122.4050)
        let orderEmbedding = FloatVector([0.9, 0.2, 0.0])  // Electronics order

        // Find warehouses within 20km that match the order
        let results = lattice.objects(Warehouse.self)
            .nearest(to: orderEmbedding, on: \.inventoryEmbedding, limit: 10)
            .nearest(to: deliveryAddress, on: \.location, maxDistance: 20, unit: .kilometers)
            .snapshot()

        print("Warehouses matching order near delivery:")
        for match in results {
            let geoDist = match.distances["location"] ?? -1
            let invDist = match.distances["inventoryEmbedding"] ?? -1
            print("  \(match.name): geo=\(geoDist) km, inventory=\(invDist)")
        }

        // San Jose should be filtered out (> 20km)
        let names = results.map { $0.name }
        #expect(!names.contains("San Jose Hub"))

        // Downtown Warehouse should be a good match (close + electronics)
        #expect(names.contains("Downtown Warehouse"))
    }

    // MARK: - Edge Cases

    @Test
    func test_EmptyConstraints_ReturnsAllObjects() async throws {
        let lattice = try testLattice(Place.self)

        let places = [
            Place(name: "Place A", category: "test", lat: 37.7, lon: -122.4, embedding: [1, 0]),
            Place(name: "Place B", category: "test", lat: 37.8, lon: -122.3, embedding: [0, 1]),
        ]
        lattice.add(contentsOf: places)

        // This won't compile without at least one proximity constraint
        // since NearestResults requires an initial proximity
        // This test verifies the base case works
        let allPlaces = lattice.objects(Place.self).snapshot()
        #expect(allPlaces.count == 2)
    }

    @Test
    func test_ChainedConstraints_PreserveWhereClause() async throws {
        let lattice = try testLattice(Place.self)

        let places = [
            Place(name: "Cafe A", category: "cafe", lat: 37.7751, lon: -122.4180, embedding: [0.9, 0.1]),
            Place(name: "Cafe B", category: "cafe", lat: 37.7755, lon: -122.4190, embedding: [0.1, 0.9]),
            Place(name: "Bar A", category: "bar", lat: 37.7753, lon: -122.4185, embedding: [0.9, 0.1]),
        ]
        lattice.add(contentsOf: places)

        let sfLocation = (latitude: 37.7749, longitude: -122.4194)
        let query = FloatVector([0.9, 0.0])

        // Filter by category, then chain nearest queries
        let results = lattice.objects(Place.self)
            .where { $0.category == "cafe" }
            .nearest(to: sfLocation, on: \.location, maxDistance: 1, unit: .kilometers)
            .nearest(to: query, on: \.embedding, limit: 10)
            .snapshot()

        // Should only include cafes
        let names = results.map { $0.name }
        #expect(!names.contains("Bar A"))
        #expect(results.count <= 2)
    }

    @Test
    func test_MultipleDistancesAccessible() async throws {
        let lattice = try testLattice(Place.self)

        let place = Place(name: "Test Place", category: "test",
                         lat: 37.7800, lon: -122.4100,
                         embedding: [0.5, 0.5])
        lattice.add(place)

        let location = (latitude: 37.7749, longitude: -122.4194)
        let query = FloatVector([1.0, 0.0])

        let results = lattice.objects(Place.self)
            .nearest(to: location, on: \.location, maxDistance: 10, unit: .kilometers)
            .nearest(to: query, on: \.embedding, limit: 10)
            .snapshot()

        #expect(results.count == 1)

        let match = results[0]

        // Both distances should be accessible
        let geoDist = match.distance(for: "location")
        let vecDist = match.distance(for: "embedding")

        #expect(geoDist != nil, "Geo distance should be present")
        #expect(vecDist != nil, "Vector distance should be present")

        print("Distances: geo=\(geoDist ?? -1), vec=\(vecDist ?? -1)")
    }

    // MARK: - Sorting Tests

    @Test
    func test_SortByGeoDistance_Ascending() async throws {
        let lattice = try testLattice(Place.self)

        // Create places at varying distances from SF
        let places = [
            Place(name: "Far", category: "test", lat: 37.90, lon: -122.20, embedding: [1, 0]),      // ~15km
            Place(name: "Close", category: "test", lat: 37.78, lon: -122.41, embedding: [1, 0]),    // ~1km
            Place(name: "Medium", category: "test", lat: 37.82, lon: -122.35, embedding: [1, 0]),   // ~7km
        ]
        lattice.add(contentsOf: places)

        let sf = (latitude: 37.7749, longitude: -122.4194)

        let results = lattice.objects(Place.self)
            .nearest(to: sf, on: \.location, maxDistance: 50, unit: .kilometers)
            .sortedBy(.geoDistance(.forward))
            .snapshot()

        #expect(results.count == 3)
        #expect(results[0].name == "Close", "Closest should be first")
        #expect(results[1].name == "Medium", "Medium distance should be second")
        #expect(results[2].name == "Far", "Farthest should be last")

        // Verify distances are in ascending order
        for i in 0..<(results.count - 1) {
            #expect(results[i].distance <= results[i + 1].distance,
                   "Distances should be in ascending order")
        }
    }

    @Test
    func test_SortByGeoDistance_Descending() async throws {
        let lattice = try testLattice(Place.self)

        let places = [
            Place(name: "Far", category: "test", lat: 37.90, lon: -122.20, embedding: [1, 0]),
            Place(name: "Close", category: "test", lat: 37.78, lon: -122.41, embedding: [1, 0]),
            Place(name: "Medium", category: "test", lat: 37.82, lon: -122.35, embedding: [1, 0]),
        ]
        lattice.add(contentsOf: places)

        let sf = (latitude: 37.7749, longitude: -122.4194)

        let results = lattice.objects(Place.self)
            .nearest(to: sf, on: \.location, maxDistance: 50, unit: .kilometers)
            .sortedBy(.geoDistance(.reverse))
            .snapshot()

        #expect(results.count == 3)
        #expect(results[0].name == "Far", "Farthest should be first")
        #expect(results[1].name == "Medium", "Medium distance should be second")
        #expect(results[2].name == "Close", "Closest should be last")

        // Verify distances are in descending order
        for i in 0..<(results.count - 1) {
            #expect(results[i].distance >= results[i + 1].distance,
                   "Distances should be in descending order")
        }
    }

    @Test
    func test_SortByVectorDistance_Ascending() async throws {
        let lattice = try testLattice(Place.self)

        // Embeddings at varying distances from query [1, 0]
        let places = [
            Place(name: "Far", category: "test", lat: 37.7, lon: -122.4, embedding: [0.0, 1.0]),    // Orthogonal
            Place(name: "Close", category: "test", lat: 37.7, lon: -122.4, embedding: [0.9, 0.1]),  // Very similar
            Place(name: "Medium", category: "test", lat: 37.7, lon: -122.4, embedding: [0.5, 0.5]), // Moderate
        ]
        lattice.add(contentsOf: places)

        let query = FloatVector([1.0, 0.0])

        let results = lattice.objects(Place.self)
            .nearest(to: query, on: \.embedding, limit: 10)
            .sortedBy(.vectorDistance(.forward))
            .snapshot()

        #expect(results.count == 3)
        #expect(results[0].name == "Close", "Most similar should be first")
        #expect(results[2].name == "Far", "Least similar should be last")

        // Verify distances are in ascending order
        for i in 0..<(results.count - 1) {
            #expect(results[i].distance <= results[i + 1].distance,
                   "Distances should be in ascending order")
        }
    }

    @Test
    func test_SortByVectorDistance_Descending() async throws {
        let lattice = try testLattice(Place.self)

        let places = [
            Place(name: "Far", category: "test", lat: 37.7, lon: -122.4, embedding: [0.0, 1.0]),
            Place(name: "Close", category: "test", lat: 37.7, lon: -122.4, embedding: [0.9, 0.1]),
            Place(name: "Medium", category: "test", lat: 37.7, lon: -122.4, embedding: [0.5, 0.5]),
        ]
        lattice.add(contentsOf: places)

        let query = FloatVector([1.0, 0.0])

        let results = lattice.objects(Place.self)
            .nearest(to: query, on: \.embedding, limit: 10)
            .sortedBy(.vectorDistance(.reverse))
            .snapshot()

        #expect(results.count == 3)
        #expect(results[0].name == "Far", "Least similar should be first")
        #expect(results[2].name == "Close", "Most similar should be last")

        // Verify distances are in descending order
        for i in 0..<(results.count - 1) {
            #expect(results[i].distance >= results[i + 1].distance,
                   "Distances should be in descending order")
        }
    }

    @Test
    func test_SortByGeoDistance_WithVectorConstraint() async throws {
        let lattice = try testLattice(Place.self)

        // Places with both geo and vector properties
        let places = [
            Place(name: "Near but different", category: "test", lat: 37.78, lon: -122.41, embedding: [0.0, 1.0]),
            Place(name: "Far but similar", category: "test", lat: 37.85, lon: -122.30, embedding: [0.9, 0.1]),
            Place(name: "Medium both", category: "test", lat: 37.80, lon: -122.38, embedding: [0.5, 0.5]),
        ]
        lattice.add(contentsOf: places)

        let sf = (latitude: 37.7749, longitude: -122.4194)
        let query = FloatVector([1.0, 0.0])

        // Combined query sorted by geo distance
        let results = lattice.objects(Place.self)
            .nearest(to: sf, on: \.location, maxDistance: 50, unit: .kilometers)
            .nearest(to: query, on: \.embedding, limit: 10)
            .sortedBy(.geoDistance(.forward))
            .snapshot()

        #expect(results.count == 3)
        #expect(results[0].name == "Near but different", "Geographically closest should be first")
        #expect(results[2].name == "Far but similar", "Geographically farthest should be last")
    }

    @Test
    func test_SortByVectorDistance_WithGeoConstraint() async throws {
        let lattice = try testLattice(Place.self)

        let places = [
            Place(name: "Near but different", category: "test", lat: 37.78, lon: -122.41, embedding: [0.0, 1.0]),
            Place(name: "Far but similar", category: "test", lat: 37.85, lon: -122.30, embedding: [0.9, 0.1]),
            Place(name: "Medium both", category: "test", lat: 37.80, lon: -122.38, embedding: [0.5, 0.5]),
        ]
        lattice.add(contentsOf: places)

        let sf = (latitude: 37.7749, longitude: -122.4194)
        let query = FloatVector([1.0, 0.0])

        // Combined query sorted by vector distance
        let results = lattice.objects(Place.self)
            .nearest(to: sf, on: \.location, maxDistance: 50, unit: .kilometers)
            .nearest(to: query, on: \.embedding, limit: 10)
            .sortedBy(.vectorDistance(.forward))
            .snapshot()

        #expect(results.count == 3)
        #expect(results[0].name == "Far but similar", "Vector-closest should be first")
        #expect(results[2].name == "Near but different", "Vector-farthest should be last")
    }

    @Test
    func test_SortWithWhereClause() async throws {
        let lattice = try testLattice(Place.self)

        let places = [
            Place(name: "Cafe Far", category: "cafe", lat: 37.85, lon: -122.30, embedding: [1, 0]),
            Place(name: "Cafe Close", category: "cafe", lat: 37.78, lon: -122.41, embedding: [1, 0]),
            Place(name: "Bar Close", category: "bar", lat: 37.775, lon: -122.42, embedding: [1, 0]),
        ]
        lattice.add(contentsOf: places)

        let sf = (latitude: 37.7749, longitude: -122.4194)

        let results = lattice.objects(Place.self)
            .where { $0.category == "cafe" }
            .nearest(to: sf, on: \.location, maxDistance: 50, unit: .kilometers)
            .sortedBy(.geoDistance(.forward))
            .snapshot()

        #expect(results.count == 2, "Should only include cafes")
        #expect(results[0].name == "Cafe Close", "Closer cafe should be first")
        #expect(results[1].name == "Cafe Far", "Farther cafe should be second")
    }
}
