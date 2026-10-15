import Foundation
import Dispatch

enum OwnedCatalogReadDeadline {
    static let maximumBudget: Duration = .seconds(30)

    /// One absolute monotonic end is established before native control creation
    /// and shared-worker admission. Positive subnanoseconds round upward.
    static func make(timeout: Duration, now: UInt64 = DispatchTime.now().uptimeNanoseconds) throws -> UInt64 {
        guard timeout > .zero, timeout <= maximumBudget else { throw invalidBudget }
        let value = timeout.components
        let seconds = value.seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !seconds.overflow else { throw invalidBudget }
        let fractional = value.attoseconds / 1_000_000_000
        let roundUp: Int64 = value.attoseconds % 1_000_000_000 > 0 ? 1 : 0
        let total = seconds.partialValue + fractional + roundUp
        guard total > 0 else { throw invalidBudget }
        let result = now.addingReportingOverflow(UInt64(total))
        guard !result.overflow else { throw invalidBudget }
        return result.partialValue
    }

    private static var invalidBudget: OwnedCatalogError {
        .invalidRequest("Timeout must be positive, at most thirty seconds, and representable")
    }
}
