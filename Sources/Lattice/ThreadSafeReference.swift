import Foundation

public protocol SendableReference<NonSendable>: Sendable {
    associatedtype NonSendable
    
    func resolve(on lattice: Lattice) -> NonSendable
}

public struct ModelThreadSafeReference<T: Model>: SendableReference, Equatable {
    private let key: Int64?
    public init(_ model: T) {
        self.key = model.primaryKey
    }
    
    public func resolve(on lattice: Lattice) -> T? {
        if let key {
            return lattice.newObject(T.self, primaryKey: key)
        }
        return nil
    }
//    public func resolve(isolation: isolated (any Actor)? = #isolation,
//                        on lattice: Lattice) async -> T? {
//        if let key {
//            let object = T()
//            object._assign(lattice: lattice)
//            object.primaryKey = key
//            await lattice.dbPtr.insertModelObserver(
//                tableName: T.entityName,
//                primaryKey: key,
//                object.weakCapture(isolation: #isolation))
//            return object
//        }
//        return nil
//    }
    
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.key == rhs.key
    }
}

extension Model {
    public var sendableReference: ModelThreadSafeReference<Self> {
        .init(self)
    }
}

public struct ResultsThreadSafeReference<T: Model>: SendableReference {
    private let whereStatement: Predicate<T>?
    private let sortStatement: SortDescriptor<T>?
    
    public init(_ results: Results<T>) {
        self.whereStatement = results.whereStatement
        self.sortStatement = results.sortStatement
    }
    
    public func resolve(on lattice: Lattice) -> Results<T> {
        Results(lattice, whereStatement: whereStatement, sortStatement: sortStatement)
    }
}

extension Results {
    public var sendableReference: ResultsThreadSafeReference<Element> {
        .init(self)
    }
}

public struct LatticeThreadSafeReference: Sendable {
    private let modelTypes: [Model.Type]
    private let configuration: Lattice.Configuration
    
    init(modelTypes: [Model.Type], configuration: Lattice.Configuration) {
        self.modelTypes = modelTypes
        self.configuration = configuration
    }
    
    public func resolve(isolation: isolated (any Actor)? = #isolation) -> Lattice? {
        try? Lattice(for: self.modelTypes, configuration: configuration)
    }
}

extension Lattice {
    public var sendableReference: LatticeThreadSafeReference {
        .init(modelTypes: self.modelTypes, configuration: self.configuration)
    }
}
