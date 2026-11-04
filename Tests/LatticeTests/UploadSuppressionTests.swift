import Foundation
import Testing
@testable import Lattice

@Suite("Upload suppression configuration", .serialized)
struct UploadSuppressionTests {
    @Test func defaultAndDerivedConfigurationsPreserveUploadPolicy() {
        let original = Lattice.Configuration(fileURL: testTemporaryDirectory.appending(path: "upload-policy.sqlite"))
        #expect(original.uploadsEnabled)
        var download = original
        download.uploadsEnabled = false
        #expect(download != original)
        #expect(Set([download, original]).count == 2)
        let copied = download
        #expect(copied == download)
        #expect(copied.hashValue == download.hashValue)
        #expect(!copied.withoutBackgroundTaskOwnership(queryOnly: true).uploadsEnabled)
        #expect(!download.cxxConfiguration().uploads_enabled)
        #expect(original.cxxConfiguration().uploads_enabled)
    }

    @Test func oppositeUploadPoliciesCannotAliasAnExistingNativeHandle() throws {
        let path = testTemporaryDirectory.appending(path: "upload-cache-" + UUID().uuidString + ".sqlite")
        defer { try? Lattice.delete(for: .init(fileURL: path)) }
        let upload = Lattice.Configuration(fileURL: path)
        var download = upload
        download.uploadsEnabled = false
        let writer = try Lattice(TunedItem.self, configuration: upload)
        let receiver = try Lattice(TunedItem.self, configuration: download)
        let sameReceiver = try Lattice(TunedItem.self, configuration: download)
        defer { receiver.close(); writer.close() }
        #expect(writer.backend.identityHash != receiver.backend.identityHash)
        #expect(receiver.backend.identityHash == sameReceiver.backend.identityHash)
        try receiver.add(TunedItem(name: "local write remains allowed"))
        #expect(writer.objects(TunedItem.self).count == 1)
    }
}
