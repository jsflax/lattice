import Foundation

/// Shared only by test targets. CI supplies its existing owned scratch root;
/// ordinary unconfigured test invocations retain Foundation's default.
public enum LatticeTestScratch {
    public static let directory: URL = {
        guard let path = ProcessInfo.processInfo.environment["LATTICE_TEST_TMPDIR"] else {
            return FileManager.default.temporaryDirectory
        }
        precondition(path.hasPrefix("/"), "LATTICE_TEST_TMPDIR must be absolute")
        var isDirectory: ObjCBool = false
        precondition(FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                     && isDirectory.boolValue, "LATTICE_TEST_TMPDIR must be an existing directory")
        return URL(fileURLWithPath: path, isDirectory: true)
    }()
}
