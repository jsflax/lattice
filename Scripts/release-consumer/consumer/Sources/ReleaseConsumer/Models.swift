import Foundation
import Lattice

// A separate file avoids script/main.swift actor-isolation inference.
@Model final class ReleaseRecord {
    var ordinal: Int = 0
    var title: String = ""
    var score: Double = 0

    init(ordinal: Int, title: String, score: Double) {
        self.ordinal = ordinal
        self.title = title
        self.score = score
    }
}
