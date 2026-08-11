import Testing
import Foundation
@testable import Lattice

// MARK: - Parameter binding for the pathological literal classes
//
// `Query`'s renderer has TWO channels:
//
//   * LITERAL (`Query.predicate`) — every constant interpolated, no `?`.
//     Byte-identical to the pre-parameter renderer. The only channel that is
//     safe where there is no parameter surface to bind through: `SyncFilter`,
//     the union CASE-WHEN wrapping, `_unionSubquery`, `List.findWhere`, the
//     combined-nearest query, and the in-transaction writer reads.
//   * PARAMETERIZED (`_parameterizedPredicate()`) — a large collection
//     membership test binds as ONE JSON-array parameter through
//     `IN (SELECT value FROM json_each(?))`, and blob constants bind. Used
//     only where the caller carries `params` to the statement.
//
// These tests pin the boundary between the two, the value conversions that
// must agree across them, and the cache-identity consequence of placeholders.

@Model final class BindItem {
    var tag: String = ""
    var rank: Int = 0
    var note: String = ""
}

@Model final class BindTyped {
    var uuid: UUID = UUID()
    var occurredAt: Date = Date(timeIntervalSince1970: 0)
    var ratio: Double = 0
    var flag: Bool = false
    var optTag: String? = nil
    var payload: Data = Data()
    var kind: BindKind = .alpha
}

@LatticeEnum
enum BindKind: String {
    case alpha, beta, gamma
}

@LatticeEnum
enum BindLevel: Int {
    case low = 1, mid = 2, high = 3
}

@Model final class BindLevelled {
    var level: BindLevel = .low
    var name: String = ""
}

protocol BindVendor: VirtualModel {
    var name: String { get }
}

@Model final class BindShop: BindVendor {
    var name: String = ""
}

@Model final class BindStall: BindVendor {
    var name: String = ""
}

@Suite("Query bind-parameter tests")
class QueryBindParameterTests: BaseTest {

    /// Comfortably above `inlineCollectionThreshold` so the binding path is
    /// taken; small enough to keep the tests fast.
    private static let bigN = 200

    private func seed(_ lattice: Lattice, tags: [String], rank: Int = 1) throws {
        try lattice.transaction {
            for tag in tags {
                let item = BindItem()
                item.tag = tag
                item.rank = rank
                item.note = "seed"
                try lattice.add(item)
            }
        }
    }

    // MARK: - Amendment E — the flat bind list never approaches the ceiling

    @Test func largeCollectionBindsExactlyOnePlaceholder() {
        let ids = (0..<40_000).map { "id-\($0)" }
        let (sql, params) = Query<BindItem>().tag.in(ids)._parameterizedPredicate()

        #expect(sql == "(tag IN (SELECT value FROM json_each(?)))")
        #expect(params.count == 1,
                "a bound collection must spend ONE variable regardless of size — the stock wasm/Android amalgamations cap out at 32766")
        #expect(sql.filter { $0 == "?" }.count == 1)
        guard case .text(let json) = params[0] else {
            Issue.record("expected the collection bound as JSON text, got \(params[0])")
            return
        }
        #expect(json.hasPrefix("[\"id-0\",\"id-1\","))
        #expect(json.hasSuffix("\"id-39999\"]"))
    }

    @Test func smallCollectionKeepsTheInlineLiteralList() {
        // At/below the threshold the inline list is kept: better plans, and it
        // was never the pathological case.
        let atThreshold = (0..<QueryParameterization.inlineCollectionThreshold).map { "t\($0)" }
        let (sql, params) = Query<BindItem>().tag.in(atThreshold)._parameterizedPredicate()
        #expect(params.isEmpty)
        #expect(!sql.contains("json_each"))

        let overThreshold = atThreshold + ["one-more"]
        let (sql2, params2) = Query<BindItem>().tag.in(overThreshold)._parameterizedPredicate()
        #expect(params2.count == 1)
        #expect(sql2.contains("json_each"))
    }

    // MARK: - Amendment A — the literal channel is untouched

    @Test func literalChannelStillRendersFlatListForLargeCollections() {
        // SyncFilter.include, the union CASE-WHEN wrapping and _unionSubquery
        // all render through `.predicate`. They have NO parameter channel, so
        // a placeholder leaking in would produce silently-broken SQL.
        let tags = (0..<Self.bigN).map { "t\($0)" }
        let literal = Query<BindItem>().tag.in(tags).predicate

        #expect(!literal.contains("?"), "the literal channel must never emit a placeholder")
        #expect(!literal.contains("json_each"))
        #expect(literal.hasPrefix("(tag IN ('t0','t1',"))
    }

    @Test func syncFilterRendersLiterally() {
        // The production sync filter uses exactly the `.in(collection)` shape.
        var filter = Lattice.SyncFilter()
        let tags = (0..<Self.bigN).map { "t\($0)" }
        filter.include(BindItem.self, where: { $0.tag.in(tags) })

        let clause = filter.entries["BindItem"] ?? nil
        #expect(clause != nil)
        #expect(clause?.contains("?") == false,
                "a bound placeholder in a sync filter would reach the core with nothing to bind it to")
        #expect(clause?.contains("json_each") == false)
    }

    // MARK: - Amendment D — bind conversions mirror formatValue exactly

    @Test func uuidElementsLowercaseLikeTheLiteralRenderer() {
        let uuids = (0..<Self.bigN).map { _ in UUID() }
        let (_, params) = Query<BindTyped>().uuid.in(uuids)._parameterizedPredicate()
        guard case .text(let json) = params[0] else { Issue.record("expected JSON text"); return }

        for uuid in uuids {
            #expect(json.contains("\"\(uuid.uuidString.lowercased())\""))
            if uuid.uuidString != uuid.uuidString.lowercased() {
                #expect(!json.contains(uuid.uuidString),
                        "an uppercase UUID would stop matching rows written through the lowercasing path")
            }
        }
    }

    @Test func dateElementsBindAsEpochSecondsLikeTheLiteralRenderer() {
        let dates = (0..<Self.bigN).map { Date(timeIntervalSince1970: Double($0) + 0.25) }
        let (_, params) = Query<BindTyped>().occurredAt.in(dates)._parameterizedPredicate()
        guard case .text(let json) = params[0] else { Issue.record("expected JSON text"); return }

        // formatValue interpolates `timeIntervalSince1970`; the bound form must
        // use the SAME text, or the comparison silently changes.
        for date in dates.prefix(5) {
            #expect(json.contains("\(date.timeIntervalSince1970)"))
        }
        #expect(!json.contains("\""), "dates are numbers on both channels, not strings")
    }

    @Test func enumElementsUnwrapToRawValue() {
        let levels = (0..<Self.bigN).map { _ in BindLevel.mid }
        let (_, params) = Query<BindLevelled>().level.in(levels)._parameterizedPredicate()
        guard case .text(let json) = params[0] else { Issue.record("expected JSON text"); return }
        #expect(json.hasPrefix("[2,2,"), "an Int-raw enum binds its rawValue, as formatValue does")

        let kinds = (0..<Self.bigN).map { _ in BindKind.beta }
        let (_, kindParams) = Query<BindTyped>().kind.in(kinds)._parameterizedPredicate()
        guard case .text(let kindJSON) = kindParams[0] else { Issue.record("expected JSON text"); return }
        #expect(kindJSON.hasPrefix("[\"beta\",\"beta\","))
    }

    @Test func emptyCollectionKeepsNullSemanticsOnBothChannels() {
        let empty: [String] = []
        let literal = Query<BindItem>().tag.in(empty).predicate
        let (bound, params) = Query<BindItem>().tag.in(empty)._parameterizedPredicate()
        #expect(literal == bound, "empty membership must render identically on both channels")
        #expect(params.isEmpty)
        #expect(literal.contains("NULL"))
    }

    @Test func optionalElementsMarshalNullsAndValues() {
        var values: [String?] = (0..<Self.bigN).map { "v\($0)" }
        values[3] = nil
        let (_, params) = Query<BindTyped>().optTag.in(values)._parameterizedPredicate()
        guard case .text(let json) = params[0] else { Issue.record("expected JSON text"); return }
        #expect(json.contains(",null,"), "an optional .none binds as JSON null, matching formatValue's NULL")
        #expect(json.contains("\"v0\""))
    }

    @Test func stringEscapingSurvivesTheRoundTrip() throws {
        let lattice = try testLattice(BindItem.self)
        // Values that break naive escaping on either channel.
        let nasty = ["it's", "quote\"inside", "back\\slash", "new\nline", "tab\there", "emoji-🎯", "']); DROP TABLE BindItem;--"]
        let filler = (0..<Self.bigN).map { "filler-\($0)" }
        try seed(lattice, tags: nasty + filler)

        let found = lattice.objects(BindItem.self).where { $0.tag.in(nasty + filler) }.snapshot()
        #expect(found.count == nasty.count + filler.count)

        // And a bound query for ONLY the nasty values, padded past the
        // threshold with values that do not exist.
        let probe = nasty + (0..<Self.bigN).map { "absent-\($0)" }
        let nastyOnly = lattice.objects(BindItem.self).where { $0.tag.in(probe) }.snapshot()
        #expect(Set(nastyOnly.map(\.tag)) == Set(nasty))
    }

    @Test func unrepresentableAndMixedKindCollectionsRefuseToBind() {
        // Homogeneous kinds bind …
        #expect(SQLBindMarshaling.jsonArrayText(forCollection: ["a", "b"]) == "[\"a\",\"b\"]")
        #expect(SQLBindMarshaling.jsonArrayText(forCollection: [1, 2]) == "[1,2]")
        #expect(SQLBindMarshaling.jsonArrayText(forCollection: [Optional("a"), nil]) == "[\"a\",null]")

        // … a string/number mixture does NOT. SQLite's `IN (SELECT …)` form
        // takes the SUBQUERY's affinity rather than the left operand's, and a
        // TEXT-affinity column compared against a JSON number is the one cell
        // where it diverges from the literal list (verified on 3.44: a TEXT
        // column holding '5' matches `s IN (5)` but not the json_each form).
        // Lattice's schema mapping makes that unreachable for homogeneous
        // collections; a mixture would reopen it, so it falls back to the
        // literal list instead of changing the match.
        #expect(SQLBindMarshaling.jsonArrayText(forCollection: [AnyHashable("a"), AnyHashable(1)]) == nil)

        // Blobs and non-finite doubles have no faithful JSON form.
        #expect(SQLBindMarshaling.jsonArrayText(forCollection: [Data([1, 2])]) == nil)
        #expect(SQLBindMarshaling.jsonArrayText(forCollection: [Double.infinity]) == nil)
        #expect(SQLBindMarshaling.jsonArrayText(forCollection: [Double.nan]) == nil)
        #expect(SQLBindMarshaling.jsonArrayText(forCollection: [[1, 2], [3]]) == nil)
    }

    @Test func largeUnrepresentableCollectionStaysOnTheLiteralList() {
        // The fallback is the STATUS QUO, not an error: a big blob collection
        // renders exactly as it did before parameterization.
        //
        // Amendment E in its sharpest form: blobs cannot ride the single-JSON
        // path, so an unguarded renderer would fall back to the flat list AND
        // bind each element — 40k placeholders against a 32766 ceiling. Above
        // the threshold, element binding is off entirely.
        let blobs = (0..<40_000).map { Data([UInt8($0 % 256)]) }
        let (sql, params) = Query<BindTyped>().payload.in(blobs)._parameterizedPredicate()
        #expect(params.isEmpty,
                "a large unbindable collection must not emit one placeholder per element")
        #expect(!sql.contains("json_each"))
        #expect(sql == Query<BindTyped>().payload.in(blobs).predicate,
                "it must render byte-identically to the literal channel")

        // Below the threshold, element binding is both safe and a strict
        // improvement (the literal channel has no faithful blob rendering).
        let few = (0..<8).map { Data([UInt8($0)]) }
        let (fewSQL, fewParams) = Query<BindTyped>().payload.in(few)._parameterizedPredicate()
        #expect(fewParams.count == 8)
        #expect(fewSQL.filter { $0 == "?" }.count == 8)
    }

    @Test func noPredicateEverExceedsThePlatformBindCeiling() {
        // The ceiling is a platform floor (32766 on stock amalgamations), so
        // the invariant is structural: every rendering path is either a single
        // JSON parameter or a list capped by the inline threshold.
        let ceiling = 32766
        let cases: [[QueryParameter]] = [
            Query<BindItem>().tag.in((0..<40_000).map { "s\($0)" })._parameterizedPredicate().params,
            Query<BindTyped>().payload.in((0..<40_000).map { Data([UInt8($0 % 256)]) })._parameterizedPredicate().params,
            Query<BindTyped>().uuid.in((0..<40_000).map { _ in UUID() })._parameterizedPredicate().params,
            Query<BindTyped>().ratio.in((0..<40_000).map { Double($0) })._parameterizedPredicate().params,
        ]
        for params in cases {
            #expect(params.count <= QueryParameterization.inlineCollectionThreshold)
            #expect(params.count < ceiling)
        }
    }

    @Test func blobConstantsBindInsteadOfInterpolating() {
        let payload = Data([0x00, 0x01, 0xFE, 0xFF])
        let (sql, params) = (Query<BindTyped>().payload == payload)._parameterizedPredicate()
        #expect(sql.contains("?"))
        #expect(params == [.blob(payload)])
    }

    // MARK: - End-to-end: bound queries return the right rows

    @Test func largeMembershipQueryReturnsExactlyTheRequestedRows() throws {
        let lattice = try testLattice(BindItem.self)
        let all = (0..<600).map { "tag-\($0)" }
        try seed(lattice, tags: all)

        let wanted = Array(all.prefix(300))
        let results = lattice.objects(BindItem.self).where { $0.tag.in(wanted) }.sortedBy(\.tag)

        #expect(results.count == wanted.count)
        #expect(Set(results.snapshot().map(\.tag)) == Set(wanted))
        // Iterating drives the keyset cursor, which conjoins a resume
        // predicate AFTER the bound clause — a param-ordering regression shows
        // up here.
        #expect(Set(results.map(\.tag)) == Set(wanted))
    }

    @Test func typeSensitiveMembershipMatchesTheLiteralChannelRowForRow() throws {
        let lattice = try testLattice(BindTyped.self)
        var uuids: [UUID] = []
        var dates: [Date] = []
        var ratios: [Double] = []
        try lattice.transaction {
            for i in 0..<300 {
                let row = BindTyped()
                row.uuid = UUID()
                row.occurredAt = Date(timeIntervalSince1970: Double(i) * 1.5)
                row.ratio = Double(i) / 7.0
                row.flag = i % 2 == 0
                row.optTag = i % 3 == 0 ? nil : "opt\(i)"
                row.payload = Data([UInt8(i % 256)])
                row.kind = i % 2 == 0 ? .alpha : .beta
                try lattice.add(row)
                if i < 150 {
                    uuids.append(row.uuid)
                    dates.append(row.occurredAt)
                    ratios.append(row.ratio)
                }
            }
        }

        // Each of these crosses the threshold, so each takes the bound path.
        // The count is compared against the row set the values came from.
        #expect(lattice.objects(BindTyped.self).where { $0.uuid.in(uuids) }.count == 150)
        #expect(lattice.objects(BindTyped.self).where { $0.occurredAt.in(dates) }.count == 150)
        #expect(lattice.objects(BindTyped.self).where { $0.ratio.in(ratios) }.count == 150)
    }

    @Test func deleteWhereBindsAndCascadesOverTheSameRowSet() throws {
        let lattice = try testLattice(BindItem.self)
        let all = (0..<400).map { "d-\($0)" }
        try seed(lattice, tags: all)

        let doomed = Array(all.prefix(250))
        lattice.delete(BindItem.self, where: { $0.tag.in(doomed) })

        #expect(lattice.count(BindItem.self) == all.count - doomed.count)
        // The cascade statements re-issue the predicate; bindings must reach
        // every one of them, not just the final DELETE.
        #expect(lattice.objects(BindItem.self).where { $0.tag.in(doomed) }.count == 0)
    }

    // MARK: - Union queries replicate bindings per arm

    @Test func unionQueryBindsEveryArm() throws {
        // `query_union_rows` emits the predicate ONCE PER TABLE, so the core
        // must repeat the bindings once per table. Binding only the first arm
        // would leave the rest unbound — SQLite reads unbound parameters as
        // NULL, so the later arms would silently contribute no rows, and the
        // bug would look like "polymorphic queries lost half their results".
        let lattice = try testLattice(BindShop.self, BindStall.self)
        var wanted: [String] = []
        try lattice.transaction {
            for i in 0..<Self.bigN {
                let shop = BindShop()
                shop.name = "shop-\(i)"
                try lattice.add(shop)
                let stall = BindStall()
                stall.name = "stall-\(i)"
                try lattice.add(stall)
                wanted.append("shop-\(i)")
                wanted.append("stall-\(i)")
            }
        }

        let all = lattice.objects(BindVendor.self).where { $0.name.in(wanted) }
        let names = Set(all.snapshot().map(\.name))
        #expect(names.count == wanted.count,
                "every unioned arm must see its bindings — got \(names.count) of \(wanted.count)")
        #expect(names.contains("shop-0") && names.contains("stall-0"))
        #expect(all.count == wanted.count)

        // A half-open set: only the second arm's rows are requested, which
        // fails loudly if the arms' bindings were swapped or shifted.
        let stallsOnly = (0..<Self.bigN).map { "stall-\($0)" }
        let stalls = lattice.objects(BindVendor.self).where { $0.name.in(stallsOnly) }
        #expect(Set(stalls.snapshot().map(\.name)) == Set(stallsOnly))
    }

    // MARK: - Amendment B — bound values are part of shape identity
    //
    // RED-FIRST: with placeholders and no bind digest in `QueryShapeKey`, the
    // two facades below render IDENTICAL SQL, collide onto one
    // `QueryShapeState`, and the second serves the first's cached count, pages
    // and id vector — i.e. the WRONG ROWS.

    private func assertDisjointInSetsDoNotShareState(_ lattice: Lattice) throws {
        let setA = (0..<Self.bigN).map { "A-\($0)" }
        let setB = (0..<Self.bigN).map { "B-\($0)" }
        try seed(lattice, tags: setA + setB)

        let resultsA = lattice.objects(BindItem.self).where { $0.tag.in(setA) }.sortedBy(\.tag)
        let resultsB = lattice.objects(BindItem.self).where { $0.tag.in(setB) }.sortedBy(\.tag)

        // Warm A first — count and page 0 — so a colliding shape would be
        // fully populated by the time B looks.
        #expect(resultsA.count == setA.count)
        #expect(resultsA[0].tag == "A-0")
        let warmA = Set(resultsA.snapshot().map(\.tag))
        #expect(warmA == Set(setA))

        // No intervening write: B must NOT inherit A's cached state.
        #expect(resultsB.count == setB.count)
        #expect(resultsB[0].tag == "B-0")
        let warmB = Set(resultsB.snapshot().map(\.tag))

        #expect(warmB == Set(setB),
                "B served \(warmB.sorted().prefix(3))… — a shape-key collision would serve A's rows")
        #expect(warmA.isDisjoint(with: warmB),
                "two .in() queries over disjoint id sets must return disjoint rows")

        // A must still be correct after B warmed (collision is symmetric).
        #expect(Set(resultsA.snapshot().map(\.tag)) == Set(setA))
    }

    @Test func disjointInSets_doNotShareShapeState_fileDB() throws {
        try assertDisjointInSetsDoNotShareState(try testLattice(BindItem.self))
    }

    @Test func disjointInSets_doNotShareShapeState_memoryFamily() throws {
        // §4.1 materialized-id generations: the id vector is cached per shape
        // too, so the collision would serve A's captured ids for B.
        try assertDisjointInSetsDoNotShareState(
            try Lattice(BindItem.self, configuration: .init(storage: .memory())))
    }

    @Test func bindDigestSeparatesOtherwiseIdenticalShapeKeys() {
        let setA = (0..<Self.bigN).map { "A-\($0)" }
        let setB = (0..<Self.bigN).map { "B-\($0)" }
        let (sqlA, paramsA) = Query<BindItem>().tag.in(setA)._parameterizedPredicate()
        let (sqlB, paramsB) = Query<BindItem>().tag.in(setB)._parameterizedPredicate()

        #expect(sqlA == sqlB, "this is the whole hazard: the SQL text is identical")
        #expect(BindDigest(paramsA) != BindDigest(paramsB))
        #expect(BindDigest(paramsA) == BindDigest(paramsA))
        #expect(BindDigest([]) == nil, "an all-literal predicate has no digest")

        let keyA = QueryShapeKey(identityHash: 1, table: "BindItem", whereSQL: sqlA,
                                 orderBySQL: "id ASC", groupBy: nil, distinctBy: nil,
                                 bindDigest: BindDigest(paramsA))
        let keyB = QueryShapeKey(identityHash: 1, table: "BindItem", whereSQL: sqlB,
                                 orderBySQL: "id ASC", groupBy: nil, distinctBy: nil,
                                 bindDigest: BindDigest(paramsB))
        #expect(keyA != keyB)
    }

    @Test func bindDigestDistinguishesTypeAndOrder() {
        // Tag bytes: an integer 0 and an empty blob must not collide.
        #expect(BindDigest([.integer(0)]) != BindDigest([.blob(Data())]))
        #expect(BindDigest([.null]) != BindDigest([.integer(0)]))
        // Length prefixes: concatenation ambiguity must not collide.
        #expect(BindDigest([.text("ab"), .text("c")]) != BindDigest([.text("a"), .text("bc")]))
        // Order matters.
        #expect(BindDigest([.integer(1), .integer(2)]) != BindDigest([.integer(2), .integer(1)]))
        // Real vs integer of the same magnitude.
        #expect(BindDigest([.integer(1)]) != BindDigest([.real(1.0)]))
    }

    // MARK: - Amendment C — column-dependency extraction survives the subquery

    @Test func extractor_recognizesTheBoundCollectionSubquery() {
        // The general subquery bail must still hold …
        #expect(ShapeColumnExtractor.referencedColumns(in: "tag IN (SELECT id FROM Other)") == nil)
        // … but the ONE closed form the renderer emits resolves to its lhs.
        #expect(ShapeColumnExtractor.referencedColumns(
            in: "(tag IN (SELECT value FROM json_each(?)))") == ["tag"])
        #expect(ShapeColumnExtractor.referencedColumns(
            in: "(rank > 10 AND (tag IN (SELECT value FROM json_each(?))))") == ["rank", "tag"])
    }

    @Test func extractor_shapeDependencyForBoundMembership() {
        let (sql, _) = Query<BindItem>().tag.in((0..<Self.bigN).map { "t\($0)" })._parameterizedPredicate()
        let key = QueryShapeKey(identityHash: 1, table: "BindItem", whereSQL: sql,
                                orderBySQL: "tag ASC, id ASC", groupBy: nil, distinctBy: nil,
                                bindDigest: nil)
        #expect(ShapeColumnExtractor.dependency(of: key) == .columns(["id", "tag"]),
                "a large .in() shape must extract its lhs column, not collapse to mustInvalidate")
    }

    /// Behavioral twin of `memberRowUnrelatedColumnUpdate_noShapeRebuild`:
    /// a bound-membership shape must keep the changedFields skip, or every
    /// `.in()` live query rebuilds on every unrelated write.
    @Test func boundMembershipShape_unrelatedColumnUpdate_noShapeRebuild() throws {
        let lattice = try testLattice(BindItem.self)
        let tags = (0..<Self.bigN).map { "m-\($0)" }
        try seed(lattice, tags: tags)

        let results = lattice.objects(BindItem.self).where { $0.tag.in(tags) }.sortedBy(\.tag)
        #expect(results.count == tags.count)
        #expect(results[0].tag == "m-0")

        let shape = results._shapeState
        #expect(shape.columnDependency != .mustInvalidate,
                "the bound subquery must not collapse the shape to mustInvalidate")

        let fillsBefore = shape.fillCounts
        let coordinator = GenerationCoordinatorRegistry.coordinator(
            for: lattice.backend, tuning: lattice.configuration.resultsTuning)
        let skipsBefore = coordinator.fieldSkipCounter

        // `note` is disjoint from (tag ∪ id).
        let member = results[0]
        member.note = "repainted"

        #expect(results.count == tags.count)
        #expect(results[0].tag == "m-0")
        let fillsAfter = shape.fillCounts
        #expect(fillsAfter.offset == fillsBefore.offset && fillsAfter.keyset == fillsBefore.keyset,
                "unrelated-column update must not rebuild a bound-membership shape: \(fillsBefore) → \(fillsAfter)")
        #expect(coordinator.fieldSkipCounter > skipsBefore,
                "the skip must actually have engaged (not a vacuous pass)")
    }
}
