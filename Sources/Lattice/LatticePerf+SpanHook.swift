import Foundation

extension LatticePerf {
    /// Where a library operation executes relative to the actor that requested it.
    public enum SpanScope: Sendable, Equatable {
        case caller
        case worker
    }

    /// Begins an application-owned interval and returns its completion callback.
    /// The hook must be thread-safe, must not throw, and must not retain managed
    /// values from an open. It can attach application correlation without making
    /// the library depend on a tracing backend or an application identifier.
    public typealias SpanHook = @Sendable (StaticString, SpanScope) -> (@Sendable () -> Void)

    /// Optional diagnostics for the current task. Child tasks inherit the hook;
    /// local-open workers explicitly carry it across their detached boundary.
    /// A nil hook allocates no span state and emits no callbacks.
    @TaskLocal public static var spanHook: SpanHook?

    /// An interval whose captured completion callback runs at most once.
    /// Ending a copy, or ending after the task-local hook changes, uses the
    /// callback returned by the original hook. Callers must explicitly end it.
    public struct Span: Sendable {
        private let state: SpanState?
        fileprivate init(_ state: SpanState?) { self.state = state }
        public func end() { state?.finish() }
    }

    public static func beginSpan(_ name: StaticString, scope: SpanScope) -> Span {
        guard let spanHook else { return Span(nil) }
        return Span(SpanState(spanHook(name, scope)))
    }

    fileprivate final class SpanState: @unchecked Sendable {
        private let lock = NSLock()
        private var completion: (@Sendable () -> Void)?

        init(_ completion: @escaping @Sendable () -> Void) { self.completion = completion }

        func finish() {
            let callback = lock.withLock {
                let callback = completion
                completion = nil
                return callback
            }
            // User diagnostics run outside our lock and may start/end spans.
            callback?()
        }
    }
}
