// LinuxCompat.swift
// Provides minimal stubs for Apple-only frameworks (Combine, os) on Linux.

import Foundation

// MARK: - Combine Stubs

#if !canImport(Combine)

public protocol Cancellable {
    func cancel()
}

public final class AnyCancellable: Cancellable, Hashable, @unchecked Sendable {
    private var _cancel: (() -> Void)?
    private let _lock = NSLock()

    public init(_ cancel: @escaping () -> Void) {
        self._cancel = cancel
    }

    public func cancel() {
        _lock.lock()
        let fn = _cancel
        _cancel = nil
        _lock.unlock()
        fn?()
    }

    public func store(in set: inout Set<AnyCancellable>) {
        set.insert(self)
    }

    public func store(in collection: inout [AnyCancellable]) {
        collection.append(self)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    public static func == (lhs: AnyCancellable, rhs: AnyCancellable) -> Bool {
        lhs === rhs
    }

    deinit { cancel() }
}

public class ObservableObjectPublisher: @unchecked Sendable {
    private let lock = NSLock()
    private var subscribers: [(id: Int, handler: () -> Void)] = []
    private var nextId = 0
    public init() {}

    public func send() {
        lock.lock()
        let current = subscribers
        lock.unlock()
        for sub in current {
            sub.handler()
        }
    }

    public func sink(receiveValue: @escaping () -> Void) -> AnyCancellable {
        lock.lock()
        let id = nextId
        nextId += 1
        subscribers.append((id: id, handler: receiveValue))
        lock.unlock()
        return AnyCancellable { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.subscribers.removeAll { $0.id == id }
            self.lock.unlock()
        }
    }
}

public protocol ObservableObject: AnyObject {
    associatedtype ObjectWillChangePublisher = ObservableObjectPublisher
    var objectWillChange: ObjectWillChangePublisher { get }
}

extension ObservableObject where ObjectWillChangePublisher == ObservableObjectPublisher {
    public var objectWillChange: ObservableObjectPublisher { ObservableObjectPublisher() }
}

#endif

// MARK: - os.Logger Stub

#if !canImport(os)

public struct Logger: Sendable {
    public let subsystem: String
    public let category: String

    public init(subsystem: String, category: String) {
        self.subsystem = subsystem
        self.category = category
    }

    public func debug(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("[\(subsystem):\(category)] DEBUG: \(message())")
        #endif
    }

    public func info(_ message: @autoclosure () -> String) {
        print("[\(subsystem):\(category)] INFO: \(message())")
    }

    public func error(_ message: @autoclosure () -> String) {
        print("[\(subsystem):\(category)] ERROR: \(message())")
    }

    public func warning(_ message: @autoclosure () -> String) {
        print("[\(subsystem):\(category)] WARNING: \(message())")
    }
}

#endif

// MARK: - autoreleasepool Stub

#if !canImport(ObjectiveC)

public func autoreleasepool<Result>(_ body: () throws -> Result) rethrows -> Result {
    try body()
}

#endif

// MARK: - OSAllocatedUnfairLock Replacement
//
// A back-deployable unfair lock exposing the OSAllocatedUnfairLock surface
// (`withLock` / `withLockUnchecked`). It exists on ALL platforms so the call
// sites never have to `#if`-select between OSAllocatedUnfairLock and a fallback.
//
// On Apple it wraps `os_unfair_lock` — available since iOS 10, i.e. the exact
// primitive `OSAllocatedUnfairLock` is built on — so there is zero behavior
// change versus the old modern path, but it back-deploys below the iOS-16 floor
// of `OSAllocatedUnfairLock` itself. On Linux it falls back to `NSLock`.

#if canImport(os)
import os

public final class UnfairLock<State>: @unchecked Sendable {
    private let _lock: os_unfair_lock_t
    private var _state: State

    public init(initialState: State) {
        self._lock = .allocate(capacity: 1)
        self._lock.initialize(to: os_unfair_lock())
        self._state = initialState
    }

    deinit {
        _lock.deinitialize(count: 1)
        _lock.deallocate()
    }

    public func withLockUnchecked<R>(_ body: (inout State) throws -> R) rethrows -> R {
        os_unfair_lock_lock(_lock)
        defer { os_unfair_lock_unlock(_lock) }
        return try body(&_state)
    }

    public func withLockUnchecked<R>(_ body: () throws -> R) rethrows -> R {
        os_unfair_lock_lock(_lock)
        defer { os_unfair_lock_unlock(_lock) }
        return try body()
    }

    public func withLock<R: Sendable>(_ body: (inout State) throws -> R) rethrows -> R {
        try withLockUnchecked(body)
    }
}

#else

public final class UnfairLock<State>: @unchecked Sendable {
    private let _lock = NSLock()
    private var _state: State

    public init(initialState: State) {
        self._state = initialState
    }

    public func withLockUnchecked<R>(_ body: (inout State) throws -> R) rethrows -> R {
        _lock.lock()
        defer { _lock.unlock() }
        return try body(&_state)
    }

    public func withLockUnchecked<R>(_ body: () throws -> R) rethrows -> R {
        _lock.lock()
        defer { _lock.unlock() }
        return try body()
    }

    public func withLock<R: Sendable>(_ body: (inout State) throws -> R) rethrows -> R {
        try withLockUnchecked(body)
    }
}

#endif
