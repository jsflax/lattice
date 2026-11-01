# Initial background-sync evidence

Captured November 1, 2026 against SDK 2.5.0 / Core 2.4.2 baselines plus explicitly new probe/tests. These are initial design/characterization results, not feature readiness or device qualification.

- Three native suspension characterizations passed: disconnect preserves queued work/ownership; destruction settles queued work without applying/ACKing it and leaves the parent database usable; close releases ownership.
- Filtered upload regression: ordinary UPDATE control passed; synthetic leave/reenter transitions FAILED and remained stale through reconnect. The failures are retained as baseline evidence, not passing qualification.
- Actor bridge: iOS 15 device/simulator object compilation and 2,000 macOS actor-isolated operations passed. External build objects remain in the localdev evidence directory; their hashes are recorded separately.
- Default SQLite interrupt did not cut short a busy wait (1,993ms after interrupt with a 2,000ms budget). The scoped-cancellation mechanism probe settled in 7ms while preserving an independent holder and an unrelated writer on the same connection. The latter is a mechanism probe, not integration of native Lattice cancellation.
- The completion contract review is source analysis; the proposed horizon and marker are not yet validated end-to-end.

`manifest.json` hashes copied source/receipts. No binary build outputs are committed. Original build logs and artifacts: `/Users/jason/localdev/lattice-bg-sync-evidence-20261101`.
