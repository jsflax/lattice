import Foundation

public protocol SendableReference<NonSendable>: Sendable {
    associatedtype NonSendable
    
    func resolve(on lattice: Lattice) -> NonSendable
}

public protocol LatticeIsolated {
}

public struct ModelThreadSafeReference<NonSendable: Model>: SendableReference, Equatable {
    private let key: Int64?
    public init(_ model: NonSendable) {
        self.key = model.primaryKey
    }
    
    public func resolve(on lattice: Lattice) -> NonSendable? {
        if let key {
            return lattice.object(NonSendable.self, primaryKey: key)
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

public struct ResultsThreadSafeReference<R: Results>: SendableReference {
    private let anyResultsThreadSafeReference: any AnyResultsThreadSafeReference<R>
    
    fileprivate init(_ results: any AnyResultsThreadSafeReference<R>) {
        self.anyResultsThreadSafeReference = results
    }
    
    public func resolve(on lattice: Lattice) -> R {
        anyResultsThreadSafeReference.resolve(on: lattice)
    }
}

protocol AnyResultsThreadSafeReference<NonSendable>: SendableReference where NonSendable: Results {
}

private struct TableResultsThreadSafeReference<T: Model>: AnyResultsThreadSafeReference {
    typealias Res = TableResults<T>
    
    private let whereStatement: Query<Bool>?
    private let sortStatement: SortDescriptor<T>?
    
    public init(_ results: TableResults<T>) {
        self.whereStatement = results.whereStatement
        self.sortStatement = results.sortStatement
    }
    
    public func resolve(on lattice: Lattice) -> some Results<T> {
        TableResults(lattice, whereStatement: whereStatement, sortStatement: sortStatement)
    }
}

private struct VirtualResultsThreadSafeReference<each M: Model, Element>: AnyResultsThreadSafeReference {
    typealias Res = _VirtualResults<repeat each M, Element>
    
    private let whereStatement: Query<Bool>?
    private let sortStatement: SortDescriptor<Element>?
    
    public init(_ results: Res) {
        self.whereStatement = results.whereStatement
        self.sortStatement = results.sortStatement
    }
    
    public func resolve(on lattice: Lattice) -> some Results<Element> {
        Res(lattice, whereStatement: whereStatement, sortStatement: sortStatement)
    }
}

extension TableResults {
    public var sendableReference: ResultsThreadSafeReference<TableResults<Element>> {
        .init(TableResultsThreadSafeReference(self) as! (any AnyResultsThreadSafeReference<TableResults<Element>>))
    }
}

extension _VirtualResults {
    public var sendableReference: ResultsThreadSafeReference<Self> {
        .init(VirtualResultsThreadSafeReference(self) as! (any AnyResultsThreadSafeReference<Self>))
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
