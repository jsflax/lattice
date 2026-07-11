import Foundation

/// True only on macOS CI runners (GitHub sets `CI=true`).
///
/// A handful of relay/sync tests intermittently hang there: the await they
/// suspend on never resumes, and on Darwin swift-testing's `.timeLimit`
/// cannot interrupt a stuck await — the job dies at timeout-minutes with no
/// per-test failure. The same tests pass locally on macOS (fast machines
/// win the race) and on Linux CI (where `.timeLimit` CAN interrupt, so a
/// hang would surface as a visible test failure, preserving coverage).
/// Owner: 1.0 item D1b/D2 (test-server consolidation + non-INSERT delivery).
let isMacOSCI: Bool = {
    #if os(macOS)
    return ProcessInfo.processInfo.environment["CI"] != nil
    #else
    return false
    #endif
}()
