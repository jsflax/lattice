# Independent source review — first tick and manual drain

Accepted as a bounded source protocol, with no remaining source blocker in the reviewed draft. This is not execution admission, a C++ build result, retention latency evidence, or an automatic-scheduler qualification.

The reviewed DRAFT-PACKET.json is SHA256 `50e9b3b644d458d0b4bff300d679dccd806521ea40fe27fdd7f71818ed242d56`. All 13 listed postimages match. All eight predecessor files authenticate against SDK Git commit 289ed743. The exact Core source/tree pairs are baseline d5463886856cd93391cf7dd088910a59cfc3b2f1 / 1f8a2fd6dfb65f5fc81b2c7803f3a45fe107fe28, and bounded beee2f94838ff196eaaedefcffa3c0fb5f70e6b6 / e226c905e4da55fe81a0c5da78ed062f5f8284fa.

## Findings resolved in this draft

- Missing file observations now remain null in both named envelopes and the two legacy top-level WAL maxima. They cannot be mistaken for a measured zero.
- File windows now use only parent monotonic timestamps. `foregroundEnvelope` starts at the writer signal and ends at the writerDone receipt; `continuationEnvelope` starts at the post-reap drain signal and ends at the drainDone receipt. These explicitly include signal/pipe/receipt latency. Native write/tick/continuation durations and overlap comparisons remain in the native clock domain. The disjoint-epoch synthetic test discriminates the original mixed-clock error.

## Source conclusions

`probe.cpp` keeps the seed, 1,000 foreground updates, original survivor/value/sequence assertions, and correctness control unchanged. Its first tick still brackets precisely the public call. It reports completion and waits for a second control byte before residual SQL. `supervise.py` sends that byte only after tickDone and the foreground process's output EOF, zero exit and wait/reap. The initial tickEntering message releases the writer paused at update 200, so this handshake introduces no circular wait. The obsolete two-writer in-SQL claim rendezvous has no reachable role or schedule in this new lane; it remains historical evidence.

The fixture's exact expected progression follows actual beee source: eight owned units of up to 256 old audit IDs, then bounded auxiliary cleanup and exact-stamp release when more work remains. With this fixture's no-writer-slot floor, aged watermark at 10,000, no externally changing history revision, and foreground IDs above that bound, the first residual is 7,952 and manual continuations reach 5,904 / 3,856 / 1,808 / 0. Baseline d546's public prune removes the old range in one tick; recent-claim controls leave all 10,000. Both the child and independent analyzer reject incorrect intermediate counts/first IDs, missing calls, absent B overlap, or a fabricated automatic-scheduler claim. Final zero cannot hide an incorrect first tick.

The held reader begins before foreground writes and stays pinned through all continuation calls, final native data validation and the first truncating checkpoint. Its original 10,010-row snapshot and busy-then-clear checkpoints are still required. The correctness control's DELETE authorizer only denies a statement; it does not wait or reenter SQLite. The performance lane installs no diagnostic SQL callback. Each probe stops its background worker before the handshake; this lane does not exercise the separate callback-initiated stop/join concern.

First-tick foreground latency and complete cleanup are distinct outcomes. The delay until writer reap, residual queries, inter-call output and process scheduling contribute to first-entry-to-final-observation; sumPublicCallNS excludes that deliberate waiting. Manual continuation costs have no concurrent foreground writer and cannot establish foreground behavior at the real 100 ms cadence. Five retained A/A/B triplets support a descriptive comparison against A/A noise, not a fixed SLO, inferred 2x gain, percentile of tick tails, or source-comparison acceptance. Sparse file observations remain lower bounds; a null envelope has no data.

The 115 s supervisor / 120 s guarded sample limits, outer runtime/build limits, disk/log caps, fresh-copy discipline, source/compiler checks, first-failure retention, and cleanup-before-successful-copy-removal remain. A nonoverlapping B sample fails rather than being retried. Failure or resource refusal remains a failure, not permission to enlarge limits.

## Evidence and remaining gates

INDEPENDENT-CHECKS.json binds seven independently rerun pure math tests and replay of all four saved final-source synthetic pipe receipts, including deliberately corrupt residual rejection with children reaped and the held-reader continuation/checkpoint order. The author's final suite reports 11 passing synthetic checks. No new pipe smoke, compiler, SQLite, native experiment, network dispatch, or product mutation was performed for this review.

The separate baseline/bounded installers, exact source/config manifests, fixed sequential same-host comparison schedule, hosted toolchain/platform configuration and one-shot admission are outside this protocol acceptance. Seal both sourceMode and exact source/tree with the final integration inputs. Actual C++ portability, runtime convergence, busy contention, callback behavior and measured improvement still require that admitted run. No automatic maintenance cadence, full shutdown, complete history-gap behavior or public performance guarantee is established here.
