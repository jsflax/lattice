import Foundation

/// Keep the first reported backend failure until a synchronous transaction
/// finishes. The bridge's last-error slot is cleared by the next successful
/// call, so inspecting it only at commit would miss earlier failed setters.
internal final class TransactionFailureScope {
    private static let key = "Lattice.TransactionFailureScope"
    private let previous: TransactionFailureScope?
    private(set) var firstError: String?

    static var isActive: Bool {
        Thread.current.threadDictionary[key] is TransactionFailureScope
    }

    init() {
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

    static func record(_ message: String) {
        guard let scope = Thread.current.threadDictionary[key] as? TransactionFailureScope,
              scope.firstError == nil else { return }
        scope.firstError = message
    }
}
