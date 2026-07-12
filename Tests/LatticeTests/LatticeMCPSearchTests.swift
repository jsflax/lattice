import Foundation
import Testing
import Lattice
import LatticeMCP
#if canImport(CoreLocation)
import CoreLocation
#endif

// Geo model for lattice_geo (the GeoboundsTests models are file-private).
@Model final class GeoPlace {
    var name: String = ""
    var location: CLLocationCoordinate2D = CLLocationCoordinate2D(latitude: 0, longitude: 0)
}

@Suite("LatticeMCP Search Tools")
final class LatticeMCPSearchTests {

    // FTS (lattice_search) + vector ANN (lattice_nearest), reusing `Article`
    // (title / @FullText content / FloatVector embedding) from FullTextSearchTests.
    @Test func testSearchAndNearest() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "mcps_\(UUID().uuidString).sqlite")
        defer { try? Lattice.delete(for: .init(fileURL: url)) }
        do {
            let l = try Lattice(Article.self, configuration: .init(fileURL: url))
            try l.add(Article(title: "ML", content: "machine learning and neural networks", embedding: [1, 0, 0, 0]))
            try l.add(Article(title: "Cook", content: "pasta recipes and sauces", embedding: [0, 0, 1, 0]))
            try l.add(Article(title: "DL", content: "deep learning with neural networks", embedding: [0.9, 0.1, 0, 0]))
            l.checkpoint()
            l.close()
        }

        let p = try await LatticeDataProvider(fileURL: url)

        let s = await p.handle(tool: "lattice_search",
                               argumentsJSON: #"{"model":"Article","field":"content","match":"learning"}"#)
        #expect(!s.isError)
        #expect(s.json.contains("\"score\""))
        #expect(s.json.contains("ML") || s.json.contains("DL"))
        #expect(!s.json.contains("pasta"))   // "Cook" doesn't match "learning"

        let v = await p.handle(tool: "lattice_nearest",
                               argumentsJSON: #"{"model":"Article","field":"embedding","vector":[1,0,0,0],"k":2,"metric":"l2"}"#)
        #expect(!v.isError)
        #expect(v.json.contains("\"distance\""))
        #expect(v.json.contains("ML"))        // exact match is nearest
    }

    // Geo proximity (lattice_geo).
    @Test func testGeo() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "mcpg_\(UUID().uuidString).sqlite")
        defer { try? Lattice.delete(for: .init(fileURL: url)) }
        do {
            let l = try Lattice(GeoPlace.self, configuration: .init(fileURL: url))
            let sf = GeoPlace(); sf.name = "SF"
            sf.location = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
            try l.add(sf)
            let nyc = GeoPlace(); nyc.name = "NYC"
            nyc.location = CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060)
            try l.add(nyc)
            l.checkpoint()
            l.close()
        }

        let p = try await LatticeDataProvider(fileURL: url)
        let g = await p.handle(tool: "lattice_geo",
                               argumentsJSON: #"{"model":"GeoPlace","field":"location","near":{"lat":37.77,"lon":-122.41},"radiusMeters":50000}"#)
        #expect(!g.isError)
        #expect(g.json.contains("SF"))
        #expect(!g.json.contains("NYC"))      // ~4000km away, outside 50km radius
        #expect(g.json.contains("distanceMeters"))
    }
}
