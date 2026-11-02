# Checkpoint 002: durability, cancellation, and package boundaries

November 1, 2026. Implementation evidence, not release qualification.

- Core `c6194c3`: 137 tests across eight affected suites passed in 9.585 seconds. Includes 19 filtered-outbox durability cases, 14 cancellation cases, and existing sync, maintenance ownership, apply qualification, deferred delivery, and suspension characterizations.
- SDK `860d043`: 13 focused policy, strict codec, and shipping-relay tests passed in 2.569 seconds. The relay sent three pages (1,000/1,000/1 records), then the opt-in completion marker, then live updates. Legacy requests did not receive a marker.
- Core `b9bffbc`: canonicalized observer callback depth across linked modules. Released Core 2.4.2 reproduced a destruction hang through SwiftBuild's combined object, while the same raw objects passed. The fixed source passes both raw and combined-object boundary repros (about 0.18 seconds each). The earlier diagnostic report is retained as written; its recommendation is implemented by this commit.
- Swift 6.4's new default SwiftBuild path also failed unrelated dependency scanning in the full SDK test graph. The same sources passed with SwiftPM's native backend. This is a recorded toolchain limitation, not a passing default-engine SDK receipt.

The full SDK build logs remain under the local evidence root. The manifest records their sizes and SHA-256 digests; the successful test tail is included here. The native tests have complete stdout and XML receipts.

The remaining finite native operation, actual pause/resume integration, Apple scheduler lifecycle, device qualification, release, and consumer notifications are not complete at this checkpoint.
