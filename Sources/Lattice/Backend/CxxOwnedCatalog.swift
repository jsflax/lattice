import Foundation
import LatticeSwiftCppBridge

extension CxxBackend: OwnedCatalogBackend {
    func makeOwnedCatalogOperation(tablesJSON: String,
        timeoutNanoseconds: UInt64) throws -> any OwnedCatalogOperation {
        guard timeoutNanoseconds > 0, timeoutNanoseconds <= 30_000_000_000 else {
            throw OwnedCatalogError.invalidRequest("Native catalog budget is out of bounds")
        }
        let operation = ref.makeOwnedCatalogOperation(tablesJSON: std.string(tablesJSON),
            timeoutNanoseconds: Int64(timeoutNanoseconds))
        guard operation.valid() else {
            throw OwnedCatalogError.database("Original owner refused catalog operation control")
        }
        return CxxOwnedCatalogOperation(backend: self, operation: operation)
    }
}

/// The native value contains cancellation/deadline and parent ownership before
/// admission, with no SQL resources. Core synchronizes cancel against capture
/// and checked ending. The exact original backend is additionally retained here;
/// no path, raw connection or reopening constructor crosses the async boundary.
private final class CxxOwnedCatalogOperation: OwnedCatalogOperation, @unchecked Sendable {
    private let backend: CxxBackend
    private let operation: lattice.owned_catalog_operation

    init(backend: CxxBackend, operation: lattice.owned_catalog_operation) {
        self.backend = backend
        self.operation = operation
    }

    func cancel() { operation.cancel() }

    func capture(consume: (Int32, Data) throws -> Void) throws {
        try withExtendedLifetime(backend) {
            // The C callback borrows the box only for this synchronous native
            // call, through all cleanup paths. It is never retained/dispatched.
            try withoutActuallyEscaping(consume) { borrowed in
                let box = CxxOwnedCatalogConsumer(borrowed)
                let context = Unmanaged.passRetained(box).toOpaque()
                defer { Unmanaged<CxxOwnedCatalogConsumer>.fromOpaque(context).release() }
                let result = operation.capture(context: context, callback: { context, kind, pointer, count in
                    guard let context else { return false }
                    return Unmanaged<CxxOwnedCatalogConsumer>.fromOpaque(context)
                        .takeUnretainedValue().receive(kind: kind, pointer: pointer, count: Int(clamping: count))
                })
                // Copy every owned result field before any error reporting.
                let succeeded = result.success()
                let cleanupFailed = result.cleanupFailed()
                let finalized = result.finalizeCode()
                let transaction = result.transactionCode()
                let rollback = result.rollbackCode()
                let stop = result.stopCode()
                let message = String(result.errorMessage())
                if cleanupFailed {
                    let failure = OwnedCatalogCleanupError(finalizeCode: Int32(finalized),
                        transactionCode: Int32(transaction), rollbackCode: Int32(rollback))
                    TransactionFailureScope.record(failure.localizedDescription)
                    throw failure
                }
                if let failure = box.failure { throw failure }
                if stop == 2 { throw CancellationError() }
                if stop == 3 { throw OwnedCatalogError.deadlineExceeded }
                guard succeeded && stop == 0 else {
                    let failure = OwnedCatalogError.database(message.isEmpty
                        ? "Original owner catalog capture failed [stop=\(stop)]" : message)
                    TransactionFailureScope.record(String(describing: failure))
                    throw failure
                }
            }
        }
    }
}

private final class CxxOwnedCatalogConsumer {
    private let consume: (Int32, Data) throws -> Void
    private(set) var failure: (any Error)?
    init(_ consume: @escaping (Int32, Data) throws -> Void) { self.consume = consume }

    func receive(kind: Int32, pointer: UnsafePointer<UInt8>?, count: Int) -> Bool {
        guard failure == nil else { return false }
        do {
            guard count >= 0, count <= 65_536, count == 0 || pointer != nil else {
                throw OwnedCatalogError.malformedFrame("Native frame exceeds its bound or has no payload")
            }
            let bytes = count == 0 ? Data() : Data(bytes: pointer!, count: count)
            try consume(kind, bytes)
            return true
        } catch {
            failure = error
            return false
        }
    }
}
