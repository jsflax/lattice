import Foundation
import Testing
import Lattice

// MARK: - Fixtures (top-level so sibling links don't need namespace qualification)

@Model @Detached
final class DDog {
    var name: String = ""
    var owner: DPerson?     // back-edge → used for cycle tests
    var buddy: DDog?        // self-link → used for depth/fan-out tests
}

@Model @Detached
final class DPerson {
    var name: String = ""
    var age: Int = 0
    var nickname: String? = nil
    var tags: [String] = []
    var dog: DDog?
    var dogs: List<DDog> = .init()
}

@Suite("@Detached")
final class DetachedTests: BaseTest {

    // 1. Scalars/value-arrays mirror exactly and are a true value copy.
    @Test func valueCopyIsIndependentOfLaterMutation() throws {
        let lattice = try testLattice(DPerson.self, DDog.self)
        let p = DPerson()
        p.name = "Ada"; p.age = 36; p.nickname = "A"; p.tags = ["x", "y"]
        lattice.add(p)

        let snap = p.detached()
        #expect(snap.name == "Ada")
        #expect(snap.age == 36)
        #expect(snap.nickname == "A")
        #expect(snap.tags == ["x", "y"])
        #expect(snap.globalId == p.globalId)

        // Mutating the live model must not change the detached value.
        p.name = "Grace"; p.age = 0; p.tags = []
        #expect(snap.name == "Ada")
        #expect(snap.age == 36)
        #expect(snap.tags == ["x", "y"])
    }

    @Test func optionalScalarNilVsSet() throws {
        let lattice = try testLattice(DPerson.self, DDog.self)
        let p = DPerson(); p.name = "NoNick"
        lattice.add(p)
        #expect(p.detached().nickname == nil)

        p.nickname = "Set"
        #expect(p.detached().nickname == "Set")
    }

    // 2. To-one + to-many expand within depth.
    @Test func toOneAndToManyExpand() throws {
        let lattice = try testLattice(DPerson.self, DDog.self)
        let p = DPerson(); p.name = "Ada"; lattice.add(p)
        let rex = DDog(); rex.name = "Rex"; lattice.add(rex)
        let fido = DDog(); fido.name = "Fido"; lattice.add(fido)
        p.dog = rex
        p.dogs.append(rex)
        p.dogs.append(fido)

        let snap = p.detached(maxDepth: 5)
        #expect(snap.dog.value?.name == "Rex")
        #expect(snap.dog.name == "Rex")                       // @dynamicMemberLookup ergonomics
        #expect(snap.dogs.count == 2)
        #expect(snap.dogs.compactMap { $0.value?.name } == ["Rex", "Fido"])
    }

    // 3. At the depth boundary, links drop to nil / empty.
    @Test func depthBoundaryCutsLinks() throws {
        let lattice = try testLattice(DPerson.self, DDog.self)
        let p = DPerson(); p.name = "Ada"; lattice.add(p)
        let rex = DDog(); rex.name = "Rex"; lattice.add(rex)
        p.dog = rex
        p.dogs.append(rex)

        let snap = p.detached(maxDepth: 1)
        #expect(snap.name == "Ada")          // self always expands
        #expect(snap.dog.value == nil)        // to-one cut → .none
        #expect(snap.dogs.isEmpty)            // to-many cut → []
    }

    // 3b. Cycles terminate and cut the back-edge.
    @Test func cycleIsCut() throws {
        let lattice = try testLattice(DPerson.self, DDog.self)
        let p = DPerson(); p.name = "Ada"; lattice.add(p)
        let rex = DDog(); rex.name = "Rex"; lattice.add(rex)
        p.dog = rex
        rex.owner = p                 // Ada → Rex → Ada cycle

        let snap = p.detached(maxDepth: 10)
        #expect(snap.dog.value?.name == "Rex")
        #expect(snap.dog.value?.owner.value == nil)   // back-edge to Ada cut
    }

    // 3c. A shared node reached twice (diamond, not a cycle) still expands both times.
    @Test func diamondStillExpands() throws {
        let lattice = try testLattice(DPerson.self, DDog.self)
        let p = DPerson(); p.name = "Ada"; lattice.add(p)
        let rex = DDog(); rex.name = "Rex"; lattice.add(rex)
        p.dog = rex
        p.dogs.append(rex)            // same Rex via two paths

        let snap = p.detached(maxDepth: 5)
        #expect(snap.dog.value?.name == "Rex")
        #expect(snap.dogs.count == 1)
        #expect(snap.dogs[0].value?.name == "Rex")   // path-set, not global-visited
    }

    // 4. Depth fan-out: every sibling expands to the SAME depth (guards the
    //    order-dependent shallow-cut regression from a shared depth counter).
    @Test func toManySiblingsExpandToEqualDepth() throws {
        let lattice = try testLattice(DPerson.self, DDog.self)
        let p = DPerson(); p.name = "Ada"; lattice.add(p)
        let d1 = DDog(); d1.name = "D1"; lattice.add(d1)
        let d2 = DDog(); d2.name = "D2"; lattice.add(d2)
        let b1 = DDog(); b1.name = "B1"; lattice.add(b1)
        let b2 = DDog(); b2.name = "B2"; lattice.add(b2)
        d1.buddy = b1; d2.buddy = b2
        p.dogs.append(d1); p.dogs.append(d2)

        let snap = p.detached(maxDepth: 3)
        #expect(snap.dogs.count == 2)
        #expect(snap.dogs[0].value?.buddy.value?.name == "B1")
        #expect(snap.dogs[1].value?.buddy.value?.name == "B2")   // not cut despite being the 2nd sibling
    }

    // 5. Sendable: a detached value crosses an isolation boundary on its own.
    @Test func detachedValueIsSendableAcrossTask() async throws {
        let lattice = try testLattice(DPerson.self, DDog.self)
        let p = DPerson(); p.name = "Ada"; lattice.add(p)
        let rex = DDog(); rex.name = "Rex"; lattice.add(rex)
        p.dog = rex

        let snap = p.detached()
        let pulled = await Task.detached { "\(snap.name)/\(snap.dog.value?.name ?? "-")" }.value
        #expect(pulled == "Ada/Rex")
    }

    // 6. Codable round-trip preserves present/absent links.
    @Test func codableRoundTrip() throws {
        let lattice = try testLattice(DPerson.self, DDog.self)
        let p = DPerson(); p.name = "Ada"; p.tags = ["t1"]; lattice.add(p)
        let rex = DDog(); rex.name = "Rex"; lattice.add(rex)
        p.dog = rex
        p.dogs.append(rex)

        let snap = p.detached(maxDepth: 5)
        let data = try JSONEncoder().encode(snap)
        let back = try JSONDecoder().decode(DPerson.Detached.self, from: data)
        #expect(back.name == "Ada")
        #expect(back.tags == ["t1"])
        #expect(back.dog.value?.name == "Rex")
        #expect(back.dog.value?.owner.value == nil)
        #expect(back.dogs.count == 1)
        #expect(back.dogs[0].value?.name == "Rex")
    }

    // 7. detached() defaults to maxDepth: 5.
    @Test func defaultDepthIsFive() throws {
        let lattice = try testLattice(DDog.self, DPerson.self)
        // Build a buddy chain c0 → c1 → … → c6.
        var chain: [DDog] = []
        for i in 0...6 {
            let d = DDog(); d.name = "C\(i)"; lattice.add(d)
            chain.append(d)
        }
        for i in 0..<6 { chain[i].buddy = chain[i + 1] }

        // Count buddy hops expanded from c0. (Deterministic — avoids comparing
        // raw JSON bytes, whose key order is non-deterministic without .sortedKeys.)
        func expandedHops(_ snap: DDog.Detached) -> Int {
            var depth = 0
            var cur: DDog.Detached? = snap
            while let next = cur?.buddy.value { depth += 1; cur = next }
            return depth
        }

        let viaDefault = expandedHops(chain[0].detached())
        let viaFive = expandedHops(chain[0].detached(maxDepth: 5))
        let viaFour = expandedHops(chain[0].detached(maxDepth: 4))
        #expect(viaDefault == viaFive)   // default param is 5
        #expect(viaFive > viaFour)        // a deeper limit expands more hops
    }
}
