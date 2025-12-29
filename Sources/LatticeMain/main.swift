import Lattice
import Foundation

@Model
class Person {
    var name: String
}
//
let l = try Lattice(Person.self, configuration: .init(isStoredInMemoryOnly: true))

