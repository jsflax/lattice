/// Query defaults are a compatibility contract. An explicit read policy opts
/// into bounded inspection; callers without one keep the original query limits.
struct LatticeQueryLimits: Sendable {
    let defaultRows: Int
    let maxRows: Int
    let defaultDepth: Int
    let maxDepth: Int
    let defaultNearest: Int
    let scoped: Bool

    init(defaultRows: Int? = nil, maxRows: Int? = nil, maxDepth: Int? = nil, scoped: Bool) {
        self.scoped = scoped
        if scoped {
            self.maxRows = max(1, min(maxRows ?? 500, 500))
            self.defaultRows = max(1, min(defaultRows ?? 25, self.maxRows))
            self.maxDepth = max(0, min(maxDepth ?? 3, 3))
            self.defaultDepth = 0
            self.defaultNearest = self.defaultRows
        } else {
            self.maxRows = max(0, maxRows ?? 10_000)
            self.defaultRows = max(0, min(defaultRows ?? 100, self.maxRows))
            self.maxDepth = max(0, maxDepth ?? 5)
            self.defaultDepth = min(1, self.maxDepth)
            self.defaultNearest = 10
        }
    }

    var rowRange: ClosedRange<Int> { (scoped ? 1 : 0)...maxRows }
    var nearestRange: ClosedRange<Int> { scoped ? rowRange : 0...Int(Int32.max) }
    var status: [String: Any] {
        var result: [String: Any] = ["defaultRows": defaultRows, "maxRows": maxRows,
            "defaultDepth": defaultDepth, "maxDepth": maxDepth, "defaultNearest": defaultNearest]
        if scoped { result["maxOutputBytes"] = 32_768 }
        return result
    }
}
