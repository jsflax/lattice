import Foundation
import SQLite3

public protocol EmbeddedModel: Codable, Property {
    
}
extension EmbeddedModel {
    public static var sqlType: String {
        "TEXT"
    }
    
    public init(from statement: OpaquePointer?, with columnId: Int32) {
        self = try! JSONDecoder().decode(Self.self, from: String(from: statement, with: 0).data(using: .utf8)!)
    }
    
    public func encode(to statement: OpaquePointer?, with columnId: Int32) {
        let text = String(data: try! JSONEncoder().encode(self), encoding: .utf8)!
        sqlite3_bind_text(statement, 1, (text as NSString).utf8String, -1, nil)
    }
}
