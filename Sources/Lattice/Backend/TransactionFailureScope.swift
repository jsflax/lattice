import Foundation
import LatticeSwiftCppBridge

/// Native incarnations are compared by weak control-block identity, never by
/// a path, pointer hash or the identity of a newly minted Swift facade.
internal enum TransactionOwnerIdentity {
    case native(lattice.bridge_owner_identity)
    case alternate(ObjectIdentifier)

    /// Stale bookkeeping only. This never proves transaction ending, Native
    /// retirement, quota refund or that an otherwise live alias disappeared.
    var isExpired: Bool {
        if case let .native(identity) = self { return !identity.isValid() }
        return false
    }

    func matches(_ other: TransactionOwnerIdentity) -> Bool {
        switch (self, other) {
        case let (.native(lhs), .native(rhs)): return lhs.matches(rhs)
        case let (.alternate(lhs), .alternate(rhs)): return lhs == rhs
        default: return false
        }
    }
}

/// Keep the first reported backend failure until a synchronous transaction
/// finishes. The bridge's last-error slot is cleared by the next successful
/// call, so inspecting it only at commit would miss earlier failed setters.
internal final class TransactionFailureScope {
    private static let key = "Lattice.TransactionFailureScope"
    private let previous: TransactionFailureScope?
    private let ownerIdentity: TransactionOwnerIdentity
    private(set) var firstError: String?

    static var isActive: Bool {
        Thread.current.threadDictionary[key] is TransactionFailureScope
    }

    static func isOwned(by identity: TransactionOwnerIdentity) -> Bool {
        (Thread.current.threadDictionary[key] as? TransactionFailureScope)?.ownerIdentity.matches(identity) == true
    }

    init(ownerIdentity: TransactionOwnerIdentity) {
        self.ownerIdentity = ownerIdentity
        let dictionary = Thread.current.threadDictionary
        previous = dictionary[Self.key] as? TransactionFailureScope
        dictionary[Self.key] = self
    }

    func restore() {
        let dictionary = Thread.current.threadDictionary
        if let previous {
            dictionary[Self.key] = previous
        } else {
            dictionary.removeObject(forKey: Self.key)
        }
    }

    static func record(_ message: String, ownerIdentity: TransactionOwnerIdentity) {
        guard let scope = Thread.current.threadDictionary[key] as? TransactionFailureScope,
              scope.firstError == nil, scope.ownerIdentity.matches(ownerIdentity) else { return }
        scope.firstError = message
    }
}


/// The frame identifies a single accepted BEGIN. The map keeps this object
/// only for bookkeeping; Native settlement always requires its opaque receipt.
internal final class TransactionReceiptFrame {
    let native: lattice.swift_transaction_receipt?
    let ownerIdentity: TransactionOwnerIdentity
    init(native: lattice.swift_transaction_receipt? = nil, ownerIdentity: TransactionOwnerIdentity) {
        self.native = native
        self.ownerIdentity = ownerIdentity
    }
}

internal struct NativeTransactionStep {
    let receipt: lattice.swift_transaction_receipt
    let ended: Bool
    let failure: String?

    init(_ result: lattice.swift_transaction_result) {
        let outcome = result.borrowOutcome()
        if !outcome.failed {
            failure = nil
        } else if outcome.diagnostic_available, let bytes = outcome.message_data,
                  let size = Int(exactly: outcome.message_size) {
            let buffer = UnsafeBufferPointer(
                start: UnsafeRawPointer(bytes).assumingMemoryBound(to: UInt8.self), count: size)
            let text = String(decoding: buffer, as: UTF8.self)
            failure = result.diagnosticTruncated() ? text + " [truncated]" : text
        } else {
            failure = "Native transaction failed; diagnostic unavailable"
        }
        receipt = result.receipt()
        ended = result.ended()
    }
}
