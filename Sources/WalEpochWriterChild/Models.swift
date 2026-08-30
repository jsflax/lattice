import Foundation
import Lattice

// Mirrors of the harness's channel schema BY NAME (the table name is the type
// name), so the parent test's fresh Lattice reopens the same tables:
//   SimpleSyncObject(value:floatValue:)  — Tests/.../SyncTestHelpers.swift:28
//   WalEpochBlob(seq:payload:)           — Tests/.../WalEpochForensicsTests.swift
// Declared outside main.swift: top-level declarations in a script file pick
// up main-actor isolation that the @Model expansion cannot satisfy.

@Model class SimpleSyncObject {
    var value: Int = 0
    var floatValue: Float

    init(value: Int, floatValue: Float) {
        self.value = value
        self.floatValue = floatValue
    }
}

@Model class WalEpochBlob {
    var seq: Int = 0
    var payload: String = ""

    init(seq: Int, payload: String) {
        self.seq = seq
        self.payload = payload
    }
}
