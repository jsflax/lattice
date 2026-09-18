import Testing

private func reportBody(_ label: String) throws {
    let current = try #require(Test.current)
    #expect(current.id.moduleName == "FilterProbeTests")
    print("FILTER_PROBE_BODY\t\(label)\t\(current.id)")
}

@Suite("Chosen display name")
struct FilterProbeSuite {
    @Test func selected() throws {
        try reportBody("chosen")
    }

    @Test func selectedExtra() throws {
        try reportBody("same_suite_distractor")
    }
}

@Suite("Other display name")
struct OtherFilterProbeSuite {
    @Test func selected() throws {
        try reportBody("other_suite_distractor")
    }
}
