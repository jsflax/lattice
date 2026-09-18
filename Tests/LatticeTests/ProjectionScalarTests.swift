import Foundation
import Testing
import Lattice

@Model private final class ProjectionMappingLinkedItem {
    var title: String = ""
}

@Model private final class ProjectionMappingItem {
    var title: String = ""
    @Property(name: "stored_count") var count: Int = 0
    var optionalCount: Int?
    @Transient var transientTitle: String = ""
    var computedTitle: String { title }
    var linked: ProjectionMappingLinkedItem?
    var tags: [String] = []
}

private struct ProjectionCustomRank: ProjectionScalar, Equatable {
    let value: Int

    static func decodeProjectionValue(_ value: ColumnValue) throws -> Self {
        let rank = try Int.decodeProjectionValue(value)
        guard rank > 0 else {
            throw ProjectionDecodingError.invalidValue(expected: "ProjectionCustomRank")
        }
        return Self(value: rank)
    }
}

@Suite("Strict projection scalar decoding")
struct ProjectionScalarTests {
    private func expectFailure<T: ProjectionScalar>(
        _ type: T.Type, _ value: ColumnValue, _ expected: ProjectionDecodingError
    ) {
        #expect(throws: expected) { try type.decodeProjectionValue(value) }
    }

    private func checkSignedInteger<T: ProjectionScalar & FixedWidthInteger>(_ type: T.Type) throws {
        #expect(try type.decodeProjectionValue(.int64(Int64(T.min))) == T.min)
        #expect(try type.decodeProjectionValue(.int64(Int64(T.max))) == T.max)
        #expect(try type.decodeProjectionValue(.int64(0)) == 0)
        let expected = String(describing: type)
        expectFailure(type, .null, .unexpectedNull(expected: expected))
        expectFailure(type, .real(1), .typeMismatch(expected: expected, actual: "REAL"))
        expectFailure(type, .real(1.5), .typeMismatch(expected: expected, actual: "REAL"))
        expectFailure(type, .text("1"), .typeMismatch(expected: expected, actual: "TEXT"))
        expectFailure(type, .blob(Data([1])), .typeMismatch(expected: expected, actual: "BLOB"))
        if T.bitWidth < Int64.bitWidth {
            expectFailure(type, .int64(Int64(T.max) + 1), .outOfRange(expected: expected))
            expectFailure(type, .int64(Int64(T.min) - 1), .outOfRange(expected: expected))
        }
    }

    @Test func signedIntegerWidthsAndStorageClasses() throws {
        try checkSignedInteger(Int.self)
        try checkSignedInteger(Int64.self)
        try checkSignedInteger(Int32.self)
        try checkSignedInteger(Int16.self)
        try checkSignedInteger(Int8.self)
    }

    @Test func booleanRequiresZeroOrOneInteger() throws {
        #expect(try Bool.decodeProjectionValue(.int64(0)) == false)
        #expect(try Bool.decodeProjectionValue(.int64(1)) == true)
        expectFailure(Bool.self, .int64(-1), .invalidValue(expected: "Bool"))
        expectFailure(Bool.self, .int64(2), .invalidValue(expected: "Bool"))
        expectFailure(Bool.self, .real(1), .typeMismatch(expected: "Bool", actual: "REAL"))
        expectFailure(Bool.self, .text("true"), .typeMismatch(expected: "Bool", actual: "TEXT"))
        expectFailure(Bool.self, .null, .unexpectedNull(expected: "Bool"))
    }

    @Test func floatingPointDecodingIsFiniteAndLossless() throws {
        #expect(try Double.decodeProjectionValue(.real(0.1)) == 0.1)
        #expect(try Double.decodeProjectionValue(.int64(9_007_199_254_740_992)) == 9_007_199_254_740_992)
        #expect(try Double.decodeProjectionValue(.int64(Int64.min)) == Double(Int64.min))
        expectFailure(Double.self, .int64(9_007_199_254_740_993), .outOfRange(expected: "Double"))
        expectFailure(Double.self, .int64(Int64.max), .outOfRange(expected: "Double"))
        #expect(try Float.decodeProjectionValue(.int64(16_777_216)) == 16_777_216)
        #expect(try Float.decodeProjectionValue(.real(1.5)) == 1.5)
        let storedFloat: Float = 0.1
        #expect(try Float.decodeProjectionValue(.real(Double(storedFloat))) == storedFloat)
        #expect(try Float.decodeProjectionValue(.real(Double(Float.greatestFiniteMagnitude))) == Float.greatestFiniteMagnitude)
        #expect(try Float.decodeProjectionValue(.real(Double(Float.leastNonzeroMagnitude))) == Float.leastNonzeroMagnitude)
        expectFailure(Float.self, .int64(16_777_217), .outOfRange(expected: "Float"))
        expectFailure(Float.self, .real(0.1), .outOfRange(expected: "Float"))
        expectFailure(Float.self, .real(Double.greatestFiniteMagnitude), .outOfRange(expected: "Float"))
        expectFailure(Float.self, .real(Double.leastNonzeroMagnitude), .outOfRange(expected: "Float"))
        for value in [Double.nan, Double.infinity, -Double.infinity] {
            expectFailure(Double.self, .real(value), .nonFinite(expected: "Double"))
            expectFailure(Float.self, .real(value), .nonFinite(expected: "Float"))
        }
        #expect(try Double.decodeProjectionValue(.real(-0.0)).sign == .minus)
        #expect(try Float.decodeProjectionValue(.real(-0.0)).sign == .minus)
        expectFailure(Double.self, .text("1.5"), .typeMismatch(expected: "Double", actual: "TEXT"))
        expectFailure(Float.self, .text("1.5"), .typeMismatch(expected: "Float", actual: "TEXT"))
        expectFailure(Double.self, .null, .unexpectedNull(expected: "Double"))
        expectFailure(Float.self, .null, .unexpectedNull(expected: "Float"))
    }

    @Test func textAndBlobPreserveNulUnicodeAndEmptyValues() throws {
        let text = "before\u{0}e\u{301}👩🏽‍💻漢字\u{0}after"
        let decoded = try String.decodeProjectionValue(.text(text))
        #expect(Array(decoded.utf8) == Array(text.utf8))
        #expect(try String.decodeProjectionValue(.text("")) == "")
        let bytes = Data([0, 255, 192, 128, 0, 65] + Array(text.utf8))
        #expect(try Data.decodeProjectionValue(.blob(bytes)) == bytes)
        #expect(try Data.decodeProjectionValue(.blob(Data())).isEmpty)
        expectFailure(String.self, .blob(Data(text.utf8)), .typeMismatch(expected: "String", actual: "BLOB"))
        expectFailure(Data.self, .text(text), .typeMismatch(expected: "Data", actual: "TEXT"))
        expectFailure(String.self, .int64(1), .typeMismatch(expected: "String", actual: "INTEGER"))
        expectFailure(String.self, .null, .unexpectedNull(expected: "String"))
        expectFailure(Data.self, .null, .unexpectedNull(expected: "Data"))
    }

    @Test func datesDecodeFiniteUnixSeconds() throws {
        #expect(try Date.decodeProjectionValue(.int64(100)) == Date(timeIntervalSince1970: 100))
        #expect(try Date.decodeProjectionValue(.real(1_700_000_000.125)) == Date(timeIntervalSince1970: 1_700_000_000.125))
        #expect(try Date.decodeProjectionValue(.real(-123.5)) == Date(timeIntervalSince1970: -123.5))
        for value in [Double.nan, Double.infinity, -Double.infinity] {
            expectFailure(Date.self, .real(value), .nonFinite(expected: "Date"))
        }
        expectFailure(Date.self, .int64(Int64.max), .outOfRange(expected: "Date"))
        expectFailure(Date.self, .text("2026-09-18"), .typeMismatch(expected: "Date", actual: "TEXT"))
        expectFailure(Date.self, .null, .unexpectedNull(expected: "Date"))
    }

    @Test func uuidsAndURLsValidateSerializedText() throws {
        let uuid = UUID(uuidString: "ABCDEF01-2345-6789-ABCD-EF0123456789")!
        #expect(try UUID.decodeProjectionValue(.text(uuid.uuidString)) == uuid)
        #expect(try UUID.decodeProjectionValue(.text(uuid.uuidString.lowercased())) == uuid)
        for text in ["", "invalid", uuid.uuidString + "\u{0}", uuid.uuidString + "extra"] {
            expectFailure(UUID.self, .text(text), .invalidValue(expected: "UUID"))
        }
        for text in ["https://example.test/a%20b?key=%E6%BC%A2#fragment", "notes/relative?tag=1", "file:///tmp/a%20b"] {
            #expect(try URL.decodeProjectionValue(.text(text)).absoluteString == text)
        }
        for text in ["https://example.test/a b", "https://example.test/%ZZ", "https://example.test/\u{0}", "https://["] {
            expectFailure(URL.self, .text(text), .invalidValue(expected: "URL"))
        }
        expectFailure(UUID.self, .blob(Data()), .typeMismatch(expected: "UUID", actual: "BLOB"))
        expectFailure(URL.self, .int64(1), .typeMismatch(expected: "URL", actual: "INTEGER"))
        expectFailure(UUID.self, .null, .unexpectedNull(expected: "UUID"))
        expectFailure(URL.self, .null, .unexpectedNull(expected: "URL"))
    }

    @Test func optionalAcceptsOnlyActualNullWithoutMaskingErrors() throws {
        #expect(try Optional<Int>.decodeProjectionValue(.null) == nil)
        #expect(try Optional<Int>.decodeProjectionValue(.int64(7)) == 7)
        #expect(try Optional<String>.decodeProjectionValue(.text("")) == "")
        #expect(try Optional<Data>.decodeProjectionValue(.blob(Data())) == Data())
        expectFailure(Optional<Int8>.self, .int64(128), .outOfRange(expected: "Int8"))
        expectFailure(Optional<Int>.self, .text("7"), .typeMismatch(expected: "Int", actual: "TEXT"))
        expectFailure(Optional<UUID>.self, .text("invalid"), .invalidValue(expected: "UUID"))
        expectFailure(Optional<Double>.self, .real(.nan), .nonFinite(expected: "Double"))
    }

    @Test func customScalarsExplicitlyOptInAndPreserveTheirErrors() throws {
        #expect(try ProjectionCustomRank.decodeProjectionValue(.int64(4)) == ProjectionCustomRank(value: 4))
        #expect(try Optional<ProjectionCustomRank>.decodeProjectionValue(.null) == nil)
        expectFailure(ProjectionCustomRank.self, .int64(0), .invalidValue(expected: "ProjectionCustomRank"))
        expectFailure(Optional<ProjectionCustomRank>.self, .int64(-1), .invalidValue(expected: "ProjectionCustomRank"))
    }

    @Test func modelMacroMapsOnlyKnownStoredScalarKeyPaths() {
        #expect(ProjectionMappingItem._storedColumn(for: \ProjectionMappingItem.title) == "title")
        #expect(ProjectionMappingItem._storedColumn(for: \ProjectionMappingItem.count) == "stored_count")
        #expect(ProjectionMappingItem._storedColumn(for: \ProjectionMappingItem.optionalCount) == "optionalCount")
        #expect(ProjectionMappingItem._storedColumn(for: \ProjectionMappingItem.primaryKey) == "id")
        #expect(ProjectionMappingItem._storedColumn(for: \ProjectionMappingItem.globalId) == "globalId")
        #expect(ProjectionMappingItem._storedColumn(for: \ProjectionMappingItem.computedTitle) == nil)
        #expect(ProjectionMappingItem._storedColumn(for: \ProjectionMappingItem.transientTitle) == nil)
        #expect(ProjectionMappingItem._storedColumn(for: \ProjectionMappingItem.title.count) == nil)
        #expect(ProjectionMappingItem._storedColumn(for: \ProjectionMappingItem.linked?.title) == nil)
        #expect(ProjectionMappingItem._storedColumn(for: \ProjectionMappingLinkedItem.title) == nil)
        #expect(ProjectionMappingItem._storedColumn(for: \ProjectionMappingItem.linked) == nil)
        #expect(ProjectionMappingItem._storedColumn(for: \ProjectionMappingItem.tags) == nil)
        // Identifiable.id is computed SwiftUI identity, not the stored SQL id.
        #expect(ProjectionMappingItem._storedColumn(for: \ProjectionMappingItem.id) == nil)
    }
}
