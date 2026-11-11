import Foundation
import Testing
import Lattice

@Suite("Lattice error presentation")
struct LatticeErrorPresentationTests {
    @Test(arguments: 0..<7)
    func underlyingDetailsSurviveFoundationBridging(_ index: Int) {
        let detail = "SQLite constraint — café\nsecond line"
        let cases: [(LatticeError, String, LatticeError?, String?)] = [
            (.missingLatticeContext, "The operation requires a Lattice database context.", nil, nil),
            (.transactionError(detail), "The database transaction failed: " + detail,
             .transactionError(""), "The database transaction failed."),
            (.syncReceiveFailed(detail), "The database could not receive the update: " + detail,
             .syncReceiveFailed(""), "The database could not receive the update."),
            (.attachFailed(detail), "The database could not be attached: " + detail,
             .attachFailed(""), "The database could not be attached."),
            (.detachFailed(detail), "The database could not be detached: " + detail,
             .detachFailed(""), "The database could not be detached."),
            (.alreadyManaged, "The object already belongs to a Lattice database.", nil, nil),
            (.addFailed(detail), "The object could not be added to the database: " + detail,
             .addFailed(""), "The object could not be added to the database.")
        ]
        let (value, expected, empty, fallback) = cases[index]
        let error: any Error = value
        #expect(error.localizedDescription == expected)
        #expect((error as NSError).localizedDescription == expected)
        if let empty, let fallback {
            let erased: any Error = empty
            #expect(erased.localizedDescription == fallback)
            #expect((erased as NSError).localizedDescription == fallback)
        }
    }
}
