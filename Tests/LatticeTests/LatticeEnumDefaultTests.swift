import Testing
@testable import Lattice

/// §1.7.1 — the LatticeEnum protocol-extension default must not trap for
/// MANUAL conformances (the `@LatticeEnum` macro synthesizes first-case and
/// was always safe). A fresh row's enum column reads as the raw zero value
/// ("" for String backing); an enum with no zero case used to hit
/// `Self(rawValue: "")!` and crash the reader.
@Suite struct LatticeEnumDefaultTests {

    /// The JoyJet shape that crashed: manual conformance, String-backed,
    /// no "" case — but CaseIterable, so the first case is derivable.
    enum ManualPhase: String, CaseIterable, LatticeEnum {
        case drafting
        case booked
    }

    /// A manual conformance whose zero raw value IS a case keeps meaning it.
    enum ManualState: String, CaseIterable, LatticeEnum {
        case unknown = ""
        case ready
    }

    @Test func caseIterableManualConformanceDefaultsToFirstCase() {
        #expect(ManualPhase.defaultValue == .drafting,
                "no zero-raw case: the default is the FIRST case — the same reading the @LatticeEnum macro synthesizes")
    }

    @Test func zeroRawCaseStillWinsWhenPresent() {
        #expect(ManualState.defaultValue == .unknown,
                "a zero-raw case is the authored zero reading; the first-case fallback must not preempt it")
    }
}
