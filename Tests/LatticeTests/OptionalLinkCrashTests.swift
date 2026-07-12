import Testing
import Foundation
import Lattice

/// Reproduces a crash in set_object when setting an optional link field
/// to an already-managed child object while the field is currently nil.
///
/// Crash path: set_object (dynamic_object.cpp:130) → get_managed_field<swift_dynamic_object>
/// (managed_object.hpp:217) → *m.get_value() dereferences nullptr when field is nil.
///
/// This only occurs when the child is already managed (value.get()->lattice is true),
/// causing set_object to take the branch at line 130 which calls the non-pointer
/// specialization of get_managed_field. The pointer specialization at line 138
/// (used when child is unmanaged) does not crash because it returns the wrapper directly.
@Suite("Optional Link Crash")
struct OptionalLinkCrashTests {

    @Model final class Parent {
        var name: String = ""
        var children: List<Child>
        var favorite: Child?
    }

    @Model final class Child {
        var name: String = ""
        var value: Int = 0
    }

    func makeLattice() throws -> Lattice {
        try Lattice(
            Parent.self,
            Child.self,
            configuration: .init(fileURL: FileManager.default.temporaryDirectory.appending(path: "\(String.random(length: 32)).sqlite"))
        )
    }

    /// This is the exact pattern that crashes trader-mcp:
    /// 1. Create parent, add to lattice
    /// 2. Create child
    /// 3. Append child to parent's List<Child> (child becomes managed)
    /// 4. Set child as parent's optional `Child?` field
    ///    → SIGSEGV because set_object reads current nil field via
    ///      get_managed_field<swift_dynamic_object> which dereferences nullptr
    @Test func setOptionalToManagedChild_afterListAppend() throws {
        let lattice = try makeLattice()

        let parent = Parent()
        parent.name = "team"
        try lattice.add(parent)

        let child = Child()
        child.name = "alice"
        child.value = 100

        // This makes child managed (lattice_ is set)
        parent.children.append(child)
        #expect(parent.children.count == 1)

        // This crashes: set_object takes managed branch (line 130),
        // calls get_managed_field<swift_dynamic_object> which does
        // *m.get_value() on the nil field → nullptr dereference
        parent.favorite = child
        #expect(parent.favorite?.name == "alice")
    }

    /// Control: setting optional to an unmanaged child works fine
    /// because set_object takes the unmanaged branch (line 138)
    @Test func setOptionalToUnmanagedChild_works() throws {
        let lattice = try makeLattice()

        let parent = Parent()
        parent.name = "team"
        try lattice.add(parent)

        let child = Child()
        child.name = "bob"

        // Child is NOT managed (not appended to list, not added to lattice)
        parent.favorite = child
        #expect(parent.favorite?.name == "bob")
    }

    /// Control: setting optional to a separately-added child
    /// (managed via lattice.add, not via list append)
    @Test func setOptionalToSeparatelyManagedChild() throws {
        let lattice = try makeLattice()

        let parent = Parent()
        parent.name = "team"
        try lattice.add(parent)

        let child = Child()
        child.name = "carol"
        try lattice.add(child)  // managed via direct add, not list

        // This should also crash since child is managed
        parent.favorite = child
        #expect(parent.favorite?.name == "carol")
    }
}
