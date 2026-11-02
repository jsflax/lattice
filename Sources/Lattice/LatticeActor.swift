import Foundation

public actor LatticeActor {
    private let modelTypes: [any Model.Type]
    private let configuration: Lattice.Configuration
    
    public init(isolation: isolated (any Actor)? = #isolation, _ lattice: Lattice) {
        self.modelTypes = lattice.modelTypes
        // A managed owner's lineage crosses actor contexts, while transport
        // credentials and process-level task ownership remain with that owner.
        self.configuration = lattice.configuration.withoutBackgroundTaskOwnership()
    }
    public init(for schema: [any Model.Type], configuration: Lattice.Configuration) {
        self.modelTypes = schema
        self.configuration = configuration
    }

    private func context() throws -> Lattice {
        guard configuration.backgroundSync == nil else {
            throw Lattice.Error.databaseError("LatticeActor creates temporary contexts. Open and retain the background-managed Lattice in your app's store actor, then pass it to LatticeActor.init(_:).")
        }
        return try Lattice(for: modelTypes, configuration: configuration)
    }
    
    public func withModelContext<T: Sendable>(
        _ closure: @Sendable (Lattice) throws -> T
    ) async throws -> T {
        let lattice = try context()
        return try closure(lattice)
    }
    
    public func withModelContext<M: Model, T: Sendable>(
        _ model: M,
        _ closure: @escaping (M, Lattice) throws -> T
    ) async throws -> T {
        let lattice = try context()
        guard let model = model.sendableReference.resolve(on: lattice) else {
            throw LatticeError.missingLatticeContext
        }
        return try closure(model, lattice)
    }
}
