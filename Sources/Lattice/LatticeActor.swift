import Foundation

public actor LatticeActor {
    private let modelTypes: [Model.Type]
    private let configuration: Lattice.Configuration
    
    public init(isolation: isolated (any Actor)? = #isolation, _ lattice: Lattice) {
        self.modelTypes = lattice.modelTypes
        self.configuration = lattice.configuration
    }
    public init(for schema: [Model.Type], configuration: Lattice.Configuration) {
        self.modelTypes = schema
        self.configuration = configuration
    }
    
    public func withModelContext<T: Sendable>(
        _ closure: @Sendable (Lattice) throws -> T
    ) async throws -> T {
        let lattice = try Lattice(for: modelTypes, configuration: configuration)
        return try await closure(lattice)
    }
    
    public func withModelContext<M: Model, T: Sendable>(
        _ model: M,
        _ closure: @escaping (M, Lattice) throws -> T
    ) async throws -> T {
        let lattice = try Lattice(for: modelTypes, configuration: configuration)
        guard let model = await model.sendableReference.resolve(on: lattice) else {
            throw LatticeError.missingLatticeContext
        }
        return try closure(model, lattice)
    }
}
