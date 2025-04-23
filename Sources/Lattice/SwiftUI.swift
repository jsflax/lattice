import Foundation
#if canImport(SwiftUI)
import SwiftUI
import Combine

@MainActor
@propertyWrapper public struct LatticeQuery<T: Model>: @preconcurrency DynamicProperty {

    private class Wrapper: ObservableObject, @unchecked Sendable {
        @MainActor var wrappedValue: Results<T>
        let predicate: Predicate<T>
        var lastFetched = Date.now
        var lattice: Lattice?
        
        @MainActor var fetchLimit: Int? {
            didSet {
                fetch()
            }
        }
        @MainActor var sortBy: [SortDescriptor<T>] = [] {
            didSet {
                fetch()
            }
        }
        private var tokens: [AnyCancellable] = []
        deinit {
            tokens.forEach { $0.cancel() }
        }
        
        @MainActor init(predicate: @escaping Predicate<T>, fetchLimit: Int? = nil,
                        sortBy: [SortDescriptor<T>] = []) {
            self.predicate = predicate
            self.fetchLimit = fetchLimit
            self.sortBy = sortBy
            self.wrappedValue = try! Results(Lattice())
        }
        
        @MainActor func fetch() {
            guard let lattice else {
                return
            }
            
            wrappedValue = lattice.objects().where(predicate)
            DispatchQueue.main.async {
                self.objectWillChange.send()
            }
        }
        
        private let historyDispatchQueue = DispatchQueue(label: "io.trader.wrapper.history")
        private var cancellable: AnyCancellable?
        
        @MainActor func updateWrappedValue(lattice: Lattice) {
            guard self.lattice == nil else { return
            }
            self.lattice = lattice
            
            lattice.objects().where(predicate).observe { _ in
                Task { @MainActor in
                    await self.fetch()
                }
            }.store(in: &tokens)
            let entityName = T.entityName
            fetch()
        }
    }
    
    @Environment(\.lattice)
    var lattice: Lattice
    @MainActor public var wrappedValue: Results<T> {
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
    
    @MainActor public init(predicate: @escaping Predicate<T> = { _ in true },
                           fetchLimit: Int? = nil,
                           sortBy: [SortDescriptor<T>] = []) {
        self.predicate = predicate
        
        self._wrapper = .init(wrappedValue: Wrapper(predicate: predicate, fetchLimit: fetchLimit, sortBy: sortBy))
    }
    

    @MainActor public mutating func update() {
        wrapper.updateWrappedValue(lattice: lattice)
    }
}

public struct LatticeEnvironmentKey: EnvironmentKey {
    nonisolated(unsafe) public static var defaultValue: Lattice = try! Lattice()
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
#endif
