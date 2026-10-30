import Lattice
import Testing

// Intentionally omit CxxStdlib: importing Lattice must suffice for @Union.
@Union enum ConsumerPayload {
    case empty
    case note(text: String)
}

struct UnionConsumerTests {
    @Test func roundTripsWithoutCxxStdlibImport() {
        let payloads: [ConsumerPayload] = [.empty, .note(text: "café — 👋")]
        for payload in payloads {
            let encoded = payload._toCxxUnionValue()
            let decoded = ConsumerPayload._fromCxxUnionValue(encoded)
            #expect(decoded == payload)
        }
    }
}
