import Foundation
import Lattice

/// Note model - matches the Note model in LatticePython, LatticeJS, and LatticeKotlin examples.
@Model
public class Note {
    public var text: String = ""
    public var createdAt: Date = Date()

    public init(text: String = "", createdAt: Date = Date()) {
        self.text = text
        self.createdAt = createdAt
    }
}
