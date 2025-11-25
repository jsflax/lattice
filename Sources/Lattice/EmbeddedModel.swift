import Foundation
import SQLite3

public protocol DefaultInitializable {
    init()
}

public protocol EmbeddedModel: Codable, PrimitiveProperty {
}

extension EmbeddedModel {
    public static var defaultValue: Self {
        fatalError("EmbeddedModels require a default value, but none was provided")
    }
    
    public static var sqlType: String {
        "TEXT"
    }
    
    public static var anyPropertyKind: AnyProperty.Kind { .string }
    public init(from statement: OpaquePointer?, with columnId: Int32) {
        self = try! JSONDecoder().decode(Self.self, from: String(from: statement, with: columnId).data(using: .utf8)!)
    }
    
    public func encode(to statement: OpaquePointer?, with columnId: Int32) {
        let text = String(data: try! JSONEncoder().encode(self), encoding: .utf8)!
        sqlite3_bind_text(statement, columnId, (text as NSString).utf8String, -1, nil)
    }
}

