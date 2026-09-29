import Foundation
import Testing
@testable import RecoveryProcessSupport

@Suite("Recovery child explicit hosted HOME")
struct RecoveryProcessHomeRootTests {
    @Test func suppliedLinuxAndMacHomesUseWrapperContract() throws {
        for home in ["/github/home", "/Users/runner"] {
            let path = home + "/localdev/qualification/private/connected-case"
            #expect(try RecoveryProcessPOSIX.hostedDirectoryPath(URL(fileURLWithPath: path), home: home) == path)
        }
    }
    @Test func absentRelativeAndAlternateHomeSpellingsRefuse() {
        let url = URL(fileURLWithPath: "/github/home/localdev/qualification")
        for home in [nil, "github/home", "/github//home", "/github/./home", "/github/other/../home", "/github/home/", "/github/ho\0me"] as [String?] {
            #expect(throws: RecoveryProcessFailure.self) { try RecoveryProcessPOSIX.hostedDirectoryPath(url, home: home) }
        }
    }
    @Test func outsideOrSiblingAndTraversalPathsRefuse() {
        for path in ["/github/home/localdev", "/github/home/localdeveloper/case", "/github/home-other/localdev/case",
                     "/github/home/localdev/../outside", "/github/home/localdev/./case"] {
            #expect(throws: RecoveryProcessFailure.self) {
                try RecoveryProcessPOSIX.hostedDirectoryPath(URL(fileURLWithPath: path), home: "/github/home")
            }
        }
    }
    @Test func boundedSpellingAndFileSchemeRemainRequired() {
        let home = "/" + String(repeating: "h", count: 4096)
        #expect(throws: RecoveryProcessFailure.self) {
            try RecoveryProcessPOSIX.hostedDirectoryPath(URL(fileURLWithPath: home + "/localdev/case"), home: home)
        }
        #expect(throws: RecoveryProcessFailure.self) {
            try RecoveryProcessPOSIX.hostedDirectoryPath(URL(fileURLWithPath: "/github/home/localdev/" + String(repeating: "x", count: 4096)), home: "/github/home")
        }
        #expect(throws: RecoveryProcessFailure.self) {
            try RecoveryProcessPOSIX.hostedDirectoryPath(URL(string: "https://example.invalid/github/home/localdev/case")!, home: "/github/home")
        }
    }
}
