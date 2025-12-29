import Foundation
import SQLite3

public protocol LinkProperty {
    associatedtype ModelType: Model
    static var modelType: any Model.Type { get }
}

extension Array: SchemaProperty where Element: SchemaProperty {
    public typealias DefaultValue = Self
    public static var defaultValue: Array<Element> { [] }
    public static var anyPropertyKind: AnyProperty.Kind {
        .string
    }
}

extension Set: SchemaProperty where Element: SchemaProperty {
    public typealias DefaultValue = Self
    public static var defaultValue: Set<Element> { [] }
    public static var anyPropertyKind: AnyProperty.Kind {
        .string
    }
}

extension Array: LinkProperty where Element: Model {
    public static var modelType: any Model.Type {
        Element.self
    }

    public typealias ModelType = Element

    public func `where`(_ query: @escaping LatticePredicate<Element>) -> Results<Element> {
        return Results(first!.lattice!, whereStatement: query(Query()))
    }
}

extension Optional: LinkProperty where Wrapped: Model {
    public typealias ModelType = Wrapped
    public static var modelType: any Model.Type { Wrapped.self }
}
