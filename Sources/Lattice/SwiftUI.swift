import Foundation
#if canImport(SwiftUI)
import os
import SwiftUI
import Combine

private let latticeQueryLog = OSLog(subsystem: "io.engram.app", category: "FrameStall")

@MainActor
@propertyWrapper public struct LatticeQuery<T: Model>: @preconcurrency DynamicProperty {

    private class Wrapper: ObservableObject, @unchecked Sendable {
        @MainActor var wrappedValue: TableResults<T>
        let predicate: Predicate<T>
        var lastFetched = Date.now
        var lattice: Lattice?

        @MainActor var fetchLimit: Int? {
            didSet {
                fetch()
            }
        }
        @MainActor var sortBy: SortDescriptor<T>? {
            didSet {
                fetch()
            }
        }
        private var tokens: [AnyCancellable] = []
        @MainActor private var debouncedFetchTask: Task<Void, Never>?
        deinit {
            tokens.forEach { $0.cancel() }
        }

        @MainActor init(predicate: @escaping Predicate<T>, fetchLimit: Int? = nil,
                        sortBy: SortDescriptor<T>?) {
            self.predicate = predicate
            self.fetchLimit = fetchLimit
            self.sortBy = sortBy
            self.wrappedValue = try! TableResults(LatticeEnvironmentKey.defaultValue)
        }

        @MainActor func fetch() {
            guard let lattice else {
                return
            }
            wrappedValue = lattice.objects().where(predicate)
            if let sortBy {
                wrappedValue = wrappedValue.sortedBy(sortBy)
            }
            DispatchQueue.main.async {
                self.objectWillChange.send()
            }
        }

        /// Debounced fetch — coalesces rapid observer fires into a single fetch per frame.
        @MainActor func scheduleFetch() {
            guard debouncedFetchTask == nil else { return }
            debouncedFetchTask = Task { @MainActor in
                await Task.yield()  // yield to end of current run loop cycle
                self.debouncedFetchTask = nil
                self.fetch()
            }
        }

        private let historyDispatchQueue = DispatchQueue(label: "io.trader.wrapper.history")
        private var cancellable: AnyCancellable?

        @MainActor func updateWrappedValue(lattice: Lattice) {
            // Rebind when the environment `\.lattice` changes identity (e.g. a hotel
            // switch, or a re-login after the previous handle was closed/deleted).
            // Identity is the shared C++ ref pointer hash: a reopened DB for the same
            // path gets a fresh `impl_` because `close()` evicts the cache, so this
            // reliably detects the swap. (The previous bind-once guard kept observing
            // the stale — possibly closed — handle forever.)
            if let current = self.lattice,
               current.cxxLatticeRef.hash_value() == lattice.cxxLatticeRef.hash_value() {
                return  // same handle — keep the existing observation
            }

            // Tear down the old observation before re-observing the new handle,
            // otherwise the stale-handle token leaks and double-fires.
            tokens.forEach { $0.cancel() }
            tokens.removeAll()

            self.lattice = lattice

            lattice.objects().where(predicate).observe { _ in
                Task { @MainActor in
                    self.scheduleFetch()
                }
            }.store(in: &tokens)
            fetch()
        }
    }
    
    @Environment(\.lattice)
    var lattice: Lattice
    @MainActor public var wrappedValue: TableResults<T> {
        wrapper.wrappedValue
    }
    
    @ObservedObject
    private var wrapper: Wrapper
    
    @MainActor public var projectedValue: LatticeQuery<T> {
        self
    }

    private let predicate: Predicate<T>
    @MainActor public var fetchLimit: Int? {
        get {
            wrapper.fetchLimit
        }
        nonmutating set {
            wrapper.fetchLimit = newValue
        }
    }
    public var sortBy: [SortDescriptor<T>] = []
    
    @MainActor public init<V>(predicate: @escaping Predicate<T> = { _ in true },
                              fetchLimit: Int? = nil,
                              sort: (any KeyPath<T, V> & Sendable)? = nil,
                              order: SortOrder? = nil) where V: Comparable {
        self.predicate = predicate
        self._wrapper = .init(wrappedValue: Wrapper(predicate: predicate, fetchLimit: fetchLimit, sortBy: sort.map { SortDescriptor($0, order: order ?? .forward) }))
    }
    
    @MainActor public init(fetchLimit: Int) {
        self.predicate = { _ in true }
        self._wrapper = .init(wrappedValue: Wrapper(predicate: predicate, fetchLimit: fetchLimit, sortBy: nil))
    }
    
    @MainActor public mutating func update() {
        wrapper.updateWrappedValue(lattice: lattice)
    }
}

public struct LatticeEnvironmentKey: EnvironmentKey {
    nonisolated(unsafe) public static var defaultValue: Lattice = try! Lattice(configuration: .init(isStoredInMemoryOnly: true))
}
public struct LatticeSchemaEnvironmentKey: EnvironmentKey {
    nonisolated(unsafe) public static var defaultValue: [any Model.Type] = []
}

extension EnvironmentValues {
    public var lattice: Lattice {
        get { self[LatticeEnvironmentKey.self] }
        set { self[LatticeEnvironmentKey.self] = newValue }
    }
    
    public var latticeSchema: [any Model.Type] {
        get { self[LatticeSchemaEnvironmentKey.self] }
        set { self[LatticeSchemaEnvironmentKey.self] = newValue }
    }
}

import SwiftUI

@Model
final class Person: @unchecked Sendable {
    var name: String
    var age: Int
}


struct TestView: View {
    @Bindable var person: Person
    
    var body: some View {
        VStack {
            Text("Age: \(person.age)")
        }.padding()
        Button("Increment Age") {
            person.age += 1
        }.onAppear {
            print(person.globalId)
        }.onChange(of: person) { oldValue, newValue in
            print("change")
        }
    }
}

#Preview {
    let lattice = try! Lattice(Person.self, configuration: .init(fileURL: FileManager.default.temporaryDirectory.appending(path: "preview_lattice.sqlite")))
    let person = {
        var person = Person()
        lattice.add(person)
        Task.detached { [ref = person.sendableReference] in
            let lattice = try! Lattice(Person.self, configuration: .init(fileURL: FileManager.default.temporaryDirectory.appending(path: "preview_lattice.sqlite")))
            let person = ref.resolve(on: lattice)!
            print(person.globalId)
            while true {
                try await Task.sleep(for: .seconds(2))
                person.age += 1
            }
        }
        return person
    }()
    TestView(person: lattice.object(primaryKey: person.primaryKey!)!)
}
#endif
