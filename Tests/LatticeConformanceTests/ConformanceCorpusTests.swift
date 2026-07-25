import Foundation
import Testing
import Lattice

// The cross-SDK conformance runner (plan WS-C item C4a): loads the
// declarative corpus from latticecore/conformance/corpus and interprets
// every scenario against this SDK's public API.
//
// Corpus location: $LATTICE_CONFORMANCE_DIR, defaulting to the sibling
// checkout ../latticecore/conformance/corpus. When neither exists (e.g. CI
// without the edit override) the suite reports the skip and passes — it
// never fabricates a green conformance signal from zero scenarios.

@Suite("Lattice Conformance Corpus")
struct ConformanceCorpusTests {

    /// Known divergences of THIS SDK from the cross-SDK contract, keyed
    /// "suite/scenario". The corpus stays the pure contract; these scenarios
    /// still execute and their failures are reported as expected divergences
    /// (XFAIL) instead of test failures. If one starts PASSING the suite
    /// fails loudly so the entry gets removed — the ledger can only shrink
    /// by fixing the SDK.
    static let knownDivergences: [String: String] = [
        // The bridge's combined-nearest CTE fetches vec0 MATCH candidates
        // (ranked by L2) and re-scores non-L2 metrics per row, but the
        // re-scored ORDER BY lives in a subselect whose order the outer
        // SELECT does not preserve — so `nearest(distance: .cosine)` returns
        // correct cosine DISTANCES in L2 ORDER. The core's own
        // `lattice_db::knn_query` (the C-ABI path other SDKs use) orders by
        // the requested metric. (LatticeSwiftCppBridge lattice.hpp,
        // build_combined_nearest_ctes_.)
        "query-knn/cosine-order":
            "cosine KNN returns correct distances but L2 ordering (bridge CTE drops the re-scored ORDER BY)",
        // transactions/own-writes-visible-inside was ledgered here until the
        // §4.1 in-transaction writer-connection carve-out was extended to
        // file stores (InTransactionReads.swift + the TableResults /
        // Lattice.count / object(primaryKey:) in-txn routing) — reads inside
        // an explicit transaction now see the transaction's own uncommitted
        // writes on every storage family.
    ]

    @Test func corpusDiscovery() {
        if let dir = CorpusLoader.corpusDirectory() {
            let files = CorpusLoader.discover()
            print("conformance: corpus at \(dir.path) — \(files.count) file(s); runner capabilities: \(ConformanceRegistry.capabilities.sorted())")
            #expect(!files.isEmpty, "corpus directory exists but contains no scenario files")
        } else {
            print("conformance: SKIP — no corpus directory (set LATTICE_CONFORMANCE_DIR or check out latticecore next to this repo)")
        }
    }

    @Test(arguments: CorpusLoader.discover())
    func corpus(file: CorpusFile) throws {
        let doc = try CorpusLoader.load(file)
        let suite = (try? (doc["suite"] ?? .null).requireString()) ?? file.name
        let scenarios = try (doc["scenarios"] ?? .array([])).requireArray()
        let interpreter = ConformanceInterpreter()

        var passed = 0, skipped = 0, expectedDivergences = 0
        for scenario in scenarios {
            let result = interpreter.run(scenario: scenario, suite: suite)
            let key = "\(suite)/\(result.name)"
            switch result.status {
            case .passed:
                if let reason = Self.knownDivergences[key] {
                    Issue.record("conformance: \(key) PASSES but is listed as a known divergence (\(reason)) — the SDK fix landed; remove the entry")
                } else {
                    passed += 1
                }
            case .skipped(let missing):
                skipped += 1
                print("conformance: SKIP \(key) — missing capabilities \(missing)")
            case .failed(let message):
                if let reason = Self.knownDivergences[key] {
                    expectedDivergences += 1
                    print("conformance: XFAIL \(key) — known SDK divergence: \(reason)\n  evidence: \(message)")
                } else {
                    Issue.record("conformance: FAIL \(key): \(message)")
                }
            }
        }
        print("conformance: \(suite) — \(passed)/\(scenarios.count) passed, \(skipped) skipped, \(expectedDivergences) known divergence(s)")
    }
}
