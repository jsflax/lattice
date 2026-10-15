import Foundation

/// Separate internal capability: existing public backend conformers acquire no
/// raw query/stream requirement. The returned control retains this exact owner.
protocol OwnedCatalogBackend: AnyObject, Sendable {
    func makeOwnedCatalogOperation(tablesJSON: String,
        timeoutNanoseconds: UInt64) throws -> any OwnedCatalogOperation
}

/// Created before queue admission, without entering SQL or opening a read lease.
/// capture is one-shot and runs synchronously on the admitted worker. It cannot
/// retain/dispatch consume; return joins checked statement/transaction ending
/// and native operation unpublication. Only cancel may race capture/cleanup.
protocol OwnedCatalogOperation: AnyObject, Sendable {
    func capture(consume: (Int32, Data) throws -> Void) throws
    /// Prompt, idempotent, operation-specific interrupt. No SQL or waiting.
    func cancel()
}
