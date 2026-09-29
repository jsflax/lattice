import Foundation
import Testing

// Pure supplied strings only: no environment mutation, directory creation,
// symlink traversal, trust, server, SQLite or native owner is involved here.
@Suite struct ConnectedHostedRootLayoutTests {
    @Test func hostedContainerHomeIsTheExplicitWorkflowHome() {
        let raw = "/github/home/localdev/connected-36567205106-1-Linux"
        #expect(ConnectedHostedRootLayout.runRoot(raw, home: "/github/home")?.path == raw)
        #expect(ConnectedHostedRootLayout.runRoot(raw, home: "/root") == nil)
    }
    @Test func ordinaryHostedMacHomeUsesTheSameContract() {
        let raw = "/Users/runner/localdev/connected-17-1-macOS"
        #expect(ConnectedHostedRootLayout.runRoot(raw, home: "/Users/runner")?.path == raw)
    }
    @Test func missingEmptyAndRelativeHomeNeverFallBackToAnotherHome() {
        let raw = "/github/home/localdev/connected-17-1-Linux"
        for home in [nil, "", "github/home", "~", "/github/ho\0me"] as [String?] {
            #expect(ConnectedHostedRootLayout.runRoot(raw, home: home) == nil)
        }
    }
    @Test func siblingAndLocaldevRootAreNotDescendantWorkspaces() {
        for raw in ["/github/home/localdev", "/github/home/localdev-other/connected-17", "/github/home-other/localdev/connected-17",
                    "/tmp/connected-17", "github/home/localdev/connected-17", "/github/home/localdev/run\0suffix"] {
            #expect(ConnectedHostedRootLayout.runRoot(raw, home: "/github/home") == nil)
        }
    }
    @Test func traversalAndAlternateSpellingsAreRefused() {
        for raw in ["/github/home/localdev/../outside", "/github/home/localdev/./run", "/github/home//localdev/run"] {
            #expect(ConnectedHostedRootLayout.runRoot(raw, home: "/github/home") == nil)
        }
        #expect(ConnectedHostedRootLayout.runRoot("/github/home/localdev/run", home: "/github/other/../home") == nil)
    }
    @Test func oversizedSuppliedPathsAreBoundedBeforeURLConstruction() {
        let home = "/" + String(repeating: "a", count: 4096)
        #expect(ConnectedHostedRootLayout.runRoot(home + "/localdev/run", home: home) == nil)
        #expect(ConnectedHostedRootLayout.runRoot("/github/home/localdev/" + String(repeating: "a", count: 4096), home: "/github/home") == nil)
    }
}
