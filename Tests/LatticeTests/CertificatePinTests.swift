import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import Lattice
#if canImport(Security)
import Security
#endif

@Suite("Pinned TLS identity")
struct CertificatePinTests {
    private let pin = String(repeating: "a", count: 64)

    @Test func validatesCanonicalLowercaseSHA256Only() {
        #expect(LatticeTLSPin.isValid(pin))
        #expect(LatticeTLSPin.isValid(String(repeating: "0123456789abcdef", count: 4)))
        for invalid in ["", String(repeating: "a", count: 63), String(repeating: "a", count: 65),
                        String(repeating: "A", count: 64), String(repeating: "g", count: 64),
                        String(repeating: "a", count: 63) + "\n"] {
            #expect(!LatticeTLSPin.isValid(invalid))
        }
    }

    @Test func configurationIdentityAndBridgePreservePin() {
        let original = Lattice.Configuration(storage: .memory(named: "pin-configuration"))
        var first = original
        first.pinnedServerCertificateSHA256 = pin
        var second = first
        second.pinnedServerCertificateSHA256 = String(repeating: "b", count: 64)
        #expect(original.pinnedServerCertificateSHA256 == nil)
        #expect(first != original)
        #expect(first != second)
        #expect(Set([original, first, second]).count == 3)
        #expect(String(first.cxxConfiguration().pinned_server_certificate_sha256) == pin)
        second.pinnedServerCertificateSHA256 = pin
        #expect(first == second)
        #expect(first.hashValue == second.hashValue)
    }

    @Test func invalidPinOrNonSecureEndpointIsRejectedBeforeOpening() {
        for (endpoint, fingerprint) in [(nil, pin), ("ws://fixture.invalid/sync", pin),
                                        ("https://fixture.invalid/sync", pin),
                                        ("wss://fixture.invalid/sync", "")] as [(String?, String)] {
            var configuration = Lattice.Configuration(storage: .memory(named: "invalid-pin"),
                wssEndpoint: endpoint.flatMap(URL.init(string:)))
            configuration.pinnedServerCertificateSHA256 = fingerprint
            do {
                let store = try Lattice(configuration: configuration)
                store.close()
                Issue.record("Invalid pin configuration unexpectedly opened")
            } catch LatticeTLSPin.ConfigurationError.invalidPin {
                // Exact failure category; a later unrelated open error is not success.
            } catch { Issue.record("Unexpected error: \(error)") }
        }
    }

    @Test func backgroundDerivedReaderDropsPinWithTransportCredentials() {
        var original = Lattice.Configuration(fileURL: URL(fileURLWithPath: "/unused/pin-policy.sqlite"),
            authorizationToken: "fixture", wssEndpoint: URL(string: "wss://fixture.invalid/sync"),
            backgroundSync: .appRefresh(identifier: "fixture.pin.refresh"))
        original.pinnedServerCertificateSHA256 = pin
        let derived = original.withoutBackgroundTaskOwnership(queryOnly: true)
        #expect(derived.wssEndpoint == nil)
        #expect(derived.authorizationToken == nil)
        #expect(derived.pinnedServerCertificateSHA256 == nil)
        #expect(original.pinnedServerCertificateSHA256 == pin)
    }

    #if !canImport(Security)
    @Test func unsupportedPlatformRejectsPinEvenWithDeferredStartup() {
        var configuration = Lattice.Configuration(storage: .memory(named: "unsupported-pin"),
            wssEndpoint: URL(string: "wss://fixture.invalid/sync"), syncStartup: .deferred)
        configuration.pinnedServerCertificateSHA256 = pin
        do {
            let store = try Lattice(configuration: configuration)
            store.close()
            Issue.record("Unsupported transport accepted certificate pin")
        } catch LatticeTLSPin.ConfigurationError.unsupportedPlatform {
        } catch { Issue.record("Unexpected error: \(error)") }
    }
    #else
    // Self-signed fixture.invalid leaf, valid 2026-01-01 through 2027-01-01.
    // Generated only for this source fixture; private key discarded. No listener.
    private static let leafDER = "MIIBdTCCARugAwIBAgICHIUwCgYIKoZIzj0EAwIwGjEYMBYGA1UEAwwPZml4dHVyZS5pbnZhbGlkMB4XDTI2MDEwMTAwMDAwMFoXDTI3MDEwMTAwMDAwMFowGjEYMBYGA1UEAwwPZml4dHVyZS5pbnZhbGlkMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEU5D57neDCovU5J9jaJJIxULnShiGn5ZcesB/5C1+alSuzWoJSpIx3T+xZKfHK3qMBIWhQ+ZZHy7yKUKFhRtfLKNRME8wGgYDVR0RBBMwEYIPZml4dHVyZS5pbnZhbGlkMAwGA1UdEwEB/wQCMAAwEwYDVR0lBAwwCgYIKwYBBQUHAwEwDgYDVR0PAQH/BAQDAgeAMAoGCCqGSM49BAMCA0gAMEUCIFN/gLtGGSr0UjyVrBXvkHIsqVbmDu1aXfKthzdBLhD5AiEAhve4lBRGBhfG90HfdW+K8FgrygC+44rooNwEkHpwGik="
    private static let leafSHA256 = "81ec119362db0db3b01d01ee6ae0dec496bfe26b1719ec5f220ac251ab359c22"
    private static let validDate = Date(timeIntervalSince1970: 1_780_272_000) // 2026-06-01 UTC

    private func trust(at date: Date = Self.validDate) throws -> SecTrust {
        let data = try #require(Data(base64Encoded: Self.leafDER))
        let certificate = try #require(SecCertificateCreateWithData(nil, data as CFData))
        var trust: SecTrust?
        #expect(SecTrustCreateWithCertificates(certificate, SecPolicyCreateBasicX509(), &trust) == errSecSuccess)
        let value = try #require(trust)
        #expect(SecTrustSetNetworkFetchAllowed(value, false) == errSecSuccess)
        #expect(SecTrustSetVerifyDate(value, date as CFDate) == errSecSuccess)
        return value
    }

    @Test func exactLeafPinAdmitsSelfSignedTLSForItsHostname() throws {
        let value = try trust()
        #expect(LatticeTLSTrust.credential(for: value, host: "fixture.invalid",
            certificateSHA256: Self.leafSHA256) != nil)
    }

    @Test func differentLeafPinIsRejected() throws {
        let value = try trust()
        #expect(LatticeTLSTrust.credential(for: value, host: "fixture.invalid", certificateSHA256: pin) == nil)
    }

    @Test func matchingPinDoesNotBypassHostnameValidation() throws {
        let value = try trust()
        #expect(LatticeTLSTrust.credential(for: value, host: "other.invalid",
            certificateSHA256: Self.leafSHA256) == nil)
    }

    @Test func matchingPinDoesNotBypassCertificateValidityDates() throws {
        for date in [Date(timeIntervalSince1970: 1_735_689_600), // 2025-01-01, not yet valid
                     Date(timeIntervalSince1970: 1_830_297_600)] { // 2028-01-01, expired
            let value = try trust(at: date)
            #expect(LatticeTLSTrust.credential(for: value, host: "fixture.invalid",
                certificateSHA256: Self.leafSHA256) == nil)
        }
    }
    #endif
}
