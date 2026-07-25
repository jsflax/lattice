// READMESnippetSwiftUITests.swift
//
// Compile-checks README.md § "SwiftUI Integration". Split from
// READMESnippetTests.swift because importing SwiftUI there would make the
// unqualified `List<Pet>` in the Quick Start model snippet ambiguous with
// SwiftUI.List. Same sync-by-construction contract: if you edit the README
// snippet, update this file (and vice versa). Models nest inside the suite
// for the same namespacing reasons as READMESnippetTests.

#if canImport(SwiftUI)
import Foundation
import Testing
import SwiftUI
import Lattice

@Suite("README SwiftUI Snippet Tests")
final class READMESnippetSwiftUITests {

    // [test-only] Mirror of the Quick Start `Person` model (the README's
    // SwiftUI snippet reuses it; the main suite's nested model is scoped
    // to its class).
    @Model final class Person {
        var name: String
        var age: Int
        var email: String
    }

    // MARK: README § SwiftUI Integration

    struct PersonListView: View {
        @LatticeQuery(
            predicate: { $0.age >= 18 },
            sort: \Person.name,
            order: .forward
        ) var adults: TableResults<Person>

        var body: some View {
            List(adults) { person in
                Text(person.name)
            }
        }
    }

    @Test @MainActor func test_SwiftUIIntegration_ViewConstructs() {
        let view = PersonListView()
        _ = view.body
    }
}
#endif
