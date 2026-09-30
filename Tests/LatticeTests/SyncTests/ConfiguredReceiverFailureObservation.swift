import Foundation
import Lattice
import NIOConcurrencyHelpers
import Testing

// Failure-only fixture state. No owner, barrier token, exception string, URL or
// payload survives observation. Codes are exact static Core52f strings, never
// message hashes or guessed error types; zero means unobserved, not success.
final class ConfiguredReceiverFailureObservation: Sendable {
    private struct State {
        var gates = [0, 0]
        var errors = [0, 0, 0, 0]
        var changed = 0
    }
    private let state = NIOLockedValueBox(State())
    static let prefix = "canonical receiver failed: "
    static let exact: [String: Int] = [
        "controller Q actual receiver unavailable": 3,
        "controller UNKNOWN persisted after one restricted pass; new external source/request generation or actual delivery timeout required": 4,
        "controller actual Swift catalog unavailable": 5,
        "controller actual incoming authorization differs from enrolled claim": 6,
        "controller actual source request count capacity": 7,
        "controller admission retry budget exhausted; gate remains closed": 8,
        "controller authenticated source retired during owned operation": 9,
        "controller bounded late response inbox full": 10,
        "controller bounded response inbox full": 11,
        "controller closed phase lacks actual barrier": 12,
        "controller complete union exceeds finite request capacity": 13,
        "controller completed disposal correlation differs": 14,
        "controller completed disposal exact Q differs": 15,
        "controller completed disposal lacks current known COMMIT": 16,
        "controller completed disposal lacks terminal source facts": 17,
        "controller completed disposal local/source custody changed": 18,
        "controller completed disposal receipt capacity": 19,
        "controller completed disposal request retired": 20,
        "controller completed disposal submitted Q changed": 21,
        "controller contribution Q missing": 22,
        "controller control object required": 23,
        "controller decimal capacity": 24,
        "controller delivery retry revision exhausted": 25,
        "controller demand revision exhausted": 26,
        "controller descriptor source compatibility changed": 27,
        "controller discard did not terminal-fence Q": 28,
        "controller disposal actual receiver unavailable": 29,
        "controller disposal current Q binding changed": 30,
        "controller disposal durable M identity differs": 31,
        "controller disposal durable Q identity differs": 32,
        "controller disposal durable phase changed": 33,
        "controller disposal generation changed": 34,
        "controller disposal handoff generation changed": 35,
        "controller disposal lacks frozen cohort": 36,
        "controller disposal predecessor lacks installed or canceled evidence": 37,
        "controller disposal predecessor receiver is active": 38,
        "controller disposal receipt capacity": 39,
        "controller disposal requires owned writer": 40,
        "controller disposal unknown request channel": 41,
        "controller duplicate member": 42,
        "controller durable integer unavailable": 43,
        "controller final install source compatibility changed": 44,
        "controller final physical handoff refused": 45,
        "controller frame byte capacity": 46,
        "controller frame index exceeds actual lease inventory": 47,
        "controller frame structure capacity": 48,
        "controller framing replacement generation changed": 49,
        "controller framing replacement lacks whole-cohort disposal": 50,
        "controller frozen barrier missing": 51,
        "controller frozen local custody missing": 52,
        "controller frozen reconciliation lacks actual provenance": 53,
        "controller frozen reconciliation scope changed": 54,
        "controller frozen request binding changed": 55,
        "controller full replacement operation scope incomplete": 56,
        "controller incoming catalog differs": 57,
        "controller incoming model not actual Swift declaration": 58,
        "controller incomplete stage selection missing": 59,
        "controller initial Q receiver has prior state": 60,
        "controller installed phase lacks complete framing": 61,
        "controller invalid decimal": 62,
        "controller invalid lease status": 63,
        "controller invalid no-effect admission outcome": 64,
        "controller late lifecycle authenticated binding differs": 65,
        "controller late lifecycle physical route differs": 66,
        "controller late predecessor authenticated binding differs": 67,
        "controller late predecessor route differs": 68,
        "controller late response byte capacity": 69,
        "controller late response order exhausted": 70,
        "controller lease correlation differs": 71,
        "controller lease frame inventory capacity": 72,
        "controller lease identity capacity": 73,
        "controller lease status type": 74,
        "controller lease wire inventory capacity": 75,
        "controller lifecycle body without known source COMMIT": 76,
        "controller lifecycle bounded text differs": 77,
        "controller lifecycle canonical UUID differs": 78,
        "controller lifecycle correlation differs": 79,
        "controller lifecycle differs from exact authenticated frozen Q": 80,
        "controller lifecycle digest shape differs": 81,
        "controller lifecycle durable Q changed": 82,
        "controller lifecycle envelope shape differs": 83,
        "controller lifecycle frozen attempt changed": 84,
        "controller lifecycle lacks known source COMMIT": 85,
        "controller lifecycle reply outside negotiated profile": 86,
        "controller lifecycle source context changed": 87,
        "controller lifecycle state type": 88,
        "controller lifecycle status/high-water shape differs": 89,
        "controller live channel outside enrollment": 90,
        "controller manifest changed on resume": 91,
        "controller manifestless Q lacks exact current or canceled predecessor": 92,
        "controller manifestless cancellation has active or retired receiver/stage": 93,
        "controller missing installed framing": 94,
        "controller mixed prepare result": 95,
        "controller mixed resume result": 96,
        "controller model contribution coverage differs": 97,
        "controller modern receive guard allocation refused": 98,
        "controller normalized decimal required": 99,
        "controller original discard envelope differs": 100,
        "controller outgoing aggregate capacity": 101,
        "controller overlapping replacement authority requires explicit configuration": 102,
        "controller overlapping request admission": 103,
        "controller page before committed manifest": 104,
        "controller pending framing missing": 105,
        "controller pending generation changed": 106,
        "controller pending response byte capacity": 107,
        "controller pending stage unverified": 108,
        "controller physical phase missing": 109,
        "controller physical route capacity": 110,
        "controller predecessor UUID differs": 111,
        "controller predecessor UUID type": 112,
        "controller predecessor binding text differs": 113,
        "controller predecessor body/version differs": 114,
        "controller predecessor correlation or committed facts missing": 115,
        "controller predecessor digest bound": 116,
        "controller predecessor digest type": 117,
        "controller predecessor durable phase changed": 118,
        "controller predecessor envelope differs": 119,
        "controller predecessor exact submitted Q differs": 120,
        "controller predecessor generation changed": 121,
        "controller predecessor inspected facts unavailable": 122,
        "controller predecessor non-profile context changed": 123,
        "controller predecessor retained Q missing": 124,
        "controller predecessor retained Q/context changed": 125,
        "controller predecessor without known source COMMIT": 126,
        "controller preparation lease without complete source publication": 127,
        "controller preparing phase lacks its exact prior receiver sequence": 128,
        "controller previously manifested Q became unstarted": 129,
        "controller prior Q lacks exact installed or canceled receiver evidence": 130,
        "controller prior context encoding differs": 131,
        "controller prior installed request is not the exact barrier predecessor": 132,
        "controller range index differs from durable stage": 133,
        "controller range lacks durable Q": 134,
        "controller range physical or logical attempt differs": 135,
        "controller read refusal correlation differs": 136,
        "controller receipt producer or cohort differs across contributions": 137,
        "controller reconciliation actual owner retired": 138,
        "controller reconciliation altered retained framing": 139,
        "controller reconciliation attempt already installed or superseded": 140,
        "controller reconciliation authorized postimage differs": 141,
        "controller reconciliation compatibility generation changed": 142,
        "controller reconciliation descriptor replaced": 143,
        "controller reconciliation frozen Q/M changed": 144,
        "controller reconciliation input missing": 145,
        "controller reconciliation journal address changed": 146,
        "controller reconciliation original, order, receipt or first claim changed": 147,
        "controller reconciliation pending inventory changed": 148,
        "controller reconciliation physical generation differs": 149,
        "controller reconciliation publication needs reserved known COMMIT": 150,
        "controller reconciliation publication reservation changed": 151,
        "controller reconciliation publication retired": 152,
        "controller reconciliation reservation exhausted": 153,
        "controller reconciliation sequence exhausted": 154,
        "controller reconciliation source compatibility changed": 155,
        "controller reconciliation source retired": 156,
        "controller reconciliation step/phase differs": 157,
        "controller reopened Q differs": 158,
        "controller reopened attempt differs": 159,
        "controller reopened canceled predecessor differs": 160,
        "controller reopened contribution binding differs": 161,
        "controller reopened installed framing differs": 162,
        "controller reopened journal phase differs": 163,
        "controller reopened manifest binding differs": 164,
        "controller reopened manifest framing differs": 165,
        "controller reopened reconciliation differs from exact canceled attempt": 166,
        "controller reopened unresolved-original capacity differs": 167,
        "controller required control member missing": 168,
        "controller reservation exceeded": 169,
        "controller response order exhausted": 170,
        "controller restricted predecessor framing missing": 171,
        "controller restricted reconciliation scope changed": 172,
        "controller restricted restart generation changed": 173,
        "controller restricted restart lacks exact canceled receiver/journal": 174,
        "controller restricted restart source changed": 175,
        "controller resume framing missing": 176,
        "controller resume journal not installed": 177,
        "controller resume lease without known source commit": 178,
        "controller retained late response capacity": 179,
        "controller retained response capacity": 180,
        "controller retained source context changed": 181,
        "controller returned lease differs from frozen Q": 182,
        "controller returned lease duration invalid": 183,
        "controller scalar capacity": 184,
        "controller settlement flag type": 185,
        "controller settlement state type": 186,
        "controller settlement state unknown": 187,
        "controller shared original differs": 188,
        "controller source authorization renewal required": 189,
        "controller source context capacity": 190,
        "controller source differs from enrolled contribution or actual catalog": 191,
        "controller source preparation refused; exact Q retained": 192,
        "controller stale reply request retired": 193,
        "controller terminal cancellation altered retained Q/M": 194,
        "controller terminal cancellation changed original inventory or installed proof": 195,
        "controller terminal cancellation demand changed": 196,
        "controller terminal cancellation lacks exact uninstalled active identity": 197,
        "controller terminal cancellation lost exact Q/source custody": 198,
        "controller terminal cancellation original/ACK/claim or receiver postimage differs": 199,
        "controller terminal cohort framing/source changed": 200,
        "controller terminal journal generation exhausted": 201,
        "controller terminal profile grace invalid": 202,
        "controller terminal profile grace missing": 203,
        "controller terminal rearm needs every negotiated source": 204,
        "controller terminal restart generation or work changed": 205,
        "controller terminal restart retained cohort changed": 206,
        "controller terminal restart sequence exhausted": 207,
        "controller terminal successor differs from frozen predecessor": 208,
        "controller transaction outcome unavailable; gate remains closed": 209,
        "controller unavailable lease carries positive identity": 210,
        "controller unknown control member": 211,
        "controller unknown durable request channel": 212,
        "controller unsolicited manifest index": 213,
        "controller unsolicited original late discard": 214,
        "controller unsupported durable phase": 215,
        "controller witness missing on reopen": 216,
    ]
    static func category(_ message: String) -> Int {
        // Bound traversal before dictionary hashing/copying. Classification is
        // outside the observation lock and exports only a closed numeric code.
        guard message.utf8.prefix(2_113).count <= 2_112 else { return 1 }
        guard message.hasPrefix(prefix) else { return 1 }
        return exact[String(message.dropFirst(prefix.count))] ?? 2
    }
    func received(_ message: String, slot: Int) {
        guard (0..<4).contains(slot) else { return }
        let code = Self.category(message)
        state.withLockedValue { value in
            let prior = value.errors[slot]
            if prior != 0 && prior != code { value.changed |= 1 << slot }
            // Preserve the first canonical category, even if a transport error
            // preceded it. Later differing categories are explicitly lossy.
            if prior == 0 || (prior == 1 && code >= 2) { value.errors[slot] = code }
        }
    }
    // Initial succeeded before this replacement window starts. Registration
    // stays installed on the actual stable owner across physical successors.
    func beginReplacement() { state.withLockedValue { $0 = State() } }
    func beginPoll() { state.withLockedValue { $0.gates = [0, 0] } }
    static func gate(phase: Int, hasError: Bool, unexpectedCommit: Bool, barrier: Bool,
                     primary: Bool, cleanup: Bool, postcommit: Bool, notification: Bool) -> Int {
        // Low three bits are phase+1 (1...5); zero is never inspected.
        precondition((0...4).contains(phase))
        return phase + 1 | (hasError ? 8 : 0) | (unexpectedCommit ? 16 : 0) |
            (barrier ? 32 : 0) | (primary ? 64 : 0) | (cleanup ? 128 : 0) |
            (postcommit ? 256 : 0) | (notification ? 512 : 0)
    }
    func inspected(_ result: ContinuousProducerResult, receiver: Int) {
        guard (0..<2).contains(receiver) else { return }
        let settlement = result.settlement
        let code = Self.gate(phase: Int(settlement.phase.rawValue), hasError: settlement.hasError,
            unexpectedCommit: settlement.unexpectedCommitObserved, barrier: result.barrier != nil,
            primary: settlement.primaryError != nil, cleanup: settlement.cleanupError != nil,
            postcommit: settlement.postcommitError != nil, notification: settlement.notificationError != nil)
        state.withLockedValue { $0.gates[receiver] = code }
    }
    // Fixed tuple: gate A/B; first canonical error A0/A1/B0/B1 (or other);
    // four-bit differing-category mask. Snapshot is later than the last poll.
    var json: [Int] { state.withLockedValue { $0.gates + $0.errors + [$0.changed] } }
}

@Suite("Configured native failure observations")
struct ConfiguredReceiverFailureObservationTests {
    @Test func exactCategoriesRejectDynamicPrefixesAndOversizedMessages() {
        let observed = ConfiguredReceiverFailureObservation()
        let message = "controller admission retry budget exhausted; gate remains closed"
        let code = ConfiguredReceiverFailureObservation.exact[message]!
        observed.received("private path bearer identifier", slot: 0)
        observed.received(ConfiguredReceiverFailureObservation.prefix + message, slot: 0)
        observed.received("canonical receiver failed: unclassified private text", slot: 1)
        observed.received(String(repeating: "x", count: 2_113), slot: 2)
        observed.received("prefix " + ConfiguredReceiverFailureObservation.prefix + message, slot: 3)
        #expect(observed.json == [0, 0, code, 2, 1, 1, 1])
        #expect(ConfiguredReceiverFailureObservation.exact.count == 214)
        #expect(Set(ConfiguredReceiverFailureObservation.exact.values) == Set(3...216))
    }
    @Test func firstCanonicalCategorySurvivesLaterErrorsWithLossFlag() {
        let observed = ConfiguredReceiverFailureObservation()
        let first = "controller authenticated source retired during owned operation"
        let second = "controller admission retry budget exhausted; gate remains closed"
        observed.received(ConfiguredReceiverFailureObservation.prefix + first, slot: 2)
        observed.received(ConfiguredReceiverFailureObservation.prefix + second, slot: 2)
        for _ in 0..<100 { observed.received("other", slot: 2) }
        #expect(observed.json == [0, 0, 0, 0, ConfiguredReceiverFailureObservation.exact[first]!, 0, 4])
        observed.beginPoll()
        #expect(observed.json[4] == ConfiguredReceiverFailureObservation.exact[first]!)
        observed.beginReplacement()
        #expect(observed.json == [0, 0, 0, 0, 0, 0, 0])
    }
    @Test func gateEncodingKeepsSettlementAndBarrierIndependent() {
        let clean = ConfiguredReceiverFailureObservation.gate(phase: 2, hasError: false,
            unexpectedCommit: false, barrier: false, primary: false, cleanup: false,
            postcommit: false, notification: false)
        let closed = ConfiguredReceiverFailureObservation.gate(phase: 2, hasError: false,
            unexpectedCommit: false, barrier: true, primary: false, cleanup: false,
            postcommit: false, notification: false)
        let postcommit = ConfiguredReceiverFailureObservation.gate(phase: 2, hasError: true,
            unexpectedCommit: false, barrier: false, primary: false, cleanup: false,
            postcommit: true, notification: false)
        #expect(clean == 3 && closed == 35 && postcommit == 267)
        #expect(ConfiguredReceiverFailureObservation.gate(phase: 4, hasError: true,
            unexpectedCommit: true, barrier: true, primary: true, cleanup: true,
            postcommit: true, notification: true) == 1021)
    }
    @Test func worstTupleFitsInsideUnchangedReceiptCapWithoutDroppingPrimaryError() throws {
        let tuple = [1021, 1021, 216, 216, 216, 216, 15]
        let data = try JSONSerialization.data(withJSONObject: ["native": tuple], options: [.sortedKeys])
        // Original exact maximum 4032 + one comma plus this dictionary's
        // contents. Initial/replacement remain mutually exclusive.
        #expect(data.count == 41)
        #expect(4032 + data.count - 1 == 4072 && 4072 <= 4096)
    }
}
