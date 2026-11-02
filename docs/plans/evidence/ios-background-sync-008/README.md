# Background sync checkpoint 008 — release closure

**Released, verified, and notified:** [Lattice 2.6.1](https://github.com/jsflax/lattice/releases/tag/2.6.1) with [Core 2.5.1](https://github.com/jsflax/LatticeCore/releases/tag/2.5.1). All three authorized consumer notices were accepted after publication verification. Downstream adoption is not inferred.

SDK 2.6.1 was published at **2026-11-02T05:23:19Z** from `248b1864f866134dc0f167f6adfd79eac4c8be61`. Verification passed **all 30 checks**, including the remote tag, exact-source workflow, all **350 published source files**, package manifest, complete 34-dependency lock, and Core pin. Release notes exactly match the prepared text. The SDK is a source-only release; its source archive and local verification report are hashed. [Release verification](release-verification.json).

[PR 39](https://github.com/jsflax/lattice/pull/39) and [exact-main CI](https://github.com/jsflax/lattice/actions/runs/41391009161) passed all four legs. [Release workflow 41392446229](https://github.com/jsflax/lattice/actions/runs/41392446229) passed all seven jobs. The [caller guide](https://jsflax.github.io/lattice/documentation/lattice/backgroundsync/) built/deployed from the exact source and passed served version/API checks. DocC has no embedded source SHA; this is workflow-plus-content verification, not deployment-artifact byte attestation. [CI and docs evidence](ci-and-docs-verification.json).

| Consumer | Notice | Adoption |
| --- | --- | --- |
| Engram integration hardening | Accepted after release verification | Not verified |
| Orbital | Accepted after release verification | Not verified |
| HUD | Accepted after release verification | Not verified |

[Delivery evidence](consumer-delivery.json) includes safe receipt/message hashes. Private chat identifiers and message bodies stay outside the repo. No shock-trooper contact occurred, and forwarding through Engram was explicitly canceled.

[Checkpoint 007](../ios-background-sync-007/README.md) remains unchanged. It preserves the bootstrap correction, test-provenance correction, full/strict published-Core tests, and phone qualification. The phone proves manual finite sync and successful debugger-triggered BGTask completion with cleanup/reopen. Natural scheduling, true cold launch, locked-phone behavior, active-transfer expiration, and takeover during active work remain unqualified. The earlier failed SDK 2.6.0 tag remains immutable. This closeout changes documentation only and requires no additional product release.
