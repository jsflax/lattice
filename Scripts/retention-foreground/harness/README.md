# Retention foreground harness — source review packet

This packet is authored, not executed. There is no exported Core source, build, SQLite fixture, or measured result. Root reviewed source and authorized one hosted run with unchanged guard and workload parameters; no local native run is authorized by this packet. The earlier NEXT-GATE.md remains the broader qualification proposal; this first implementation covers its initial paired workload plus held-reader, competing-claim, retry/partial-ACK/floor/ancient-insert controls.

All arms deliberately use **the same exact 7b11c282800d2bd6478538edb4e87de81953d315 source** (tree 18b482a47df9413e151887ef77a9dc5abb6be041). A1/A2 have a recent claim; B has an expired claim. This is the cost of current pruning, not a code optimization comparison. No numerical foreground SLO was provided, so the result requires review against A/A variation, with every run and outlier retained.

`probe.cpp` exercises the real Core schema/audit triggers, retention tick, claim, sync ACK/floor and remote-apply helpers. It seeds one 10,000-entry master from 100 real rows and 99 update rounds (100 rows/seed transaction, 1 KiB changed bodies), backdates the sampled watermark, and appends 10 new foreground rows. Timed arms each make 1,000 autocommit updates with 256-byte changed bodies; maintenance is released after 200 writes. B must overlap a recorded writer interval and remove exactly the old 10,000 entries, preserving all 1,010 newer entries, final values, audit sequence and enabled sync state. An absence of overlap is a nonqualifying failure, not a reason to repeat or add sleeps.

The per-sample Python supervisor owns two or three child processes in the outer runner's process group. It coordinates through pipes and records main/WAL/SHM sizes every 5 ms without opening SQLite files. Maxima are sampled lower bounds. The held-reader pair uses an unfinished SELECT from before writes, verifies the unchanged 10,010-row snapshot, requires the first TRUNCATE to report busy, then releases that reader and requires the changed-state retry to complete. The competing-claim case uses a fixed diagnostic trace callback only to rendezvous at the claim and count real prune entries; timing arms have no trace/authorizer/progress callbacks installed by the harness.

The separate small correctness child uses a denied DELETE to check rollback and immediate retry, a real partial ACK plus contiguous floor below a higher confirmed cursor, an observer slot excluded from the floor, and two old-origin remote updates inserted after the watermark. Both late updates must survive and relay to a second owned store with the correct final value. This does not test network sync, every filter policy, or a history-gap protocol.

Only one closed master and one current sample copy are required. Master creation must finish and its entire owned group must be gone; main/WAL/SHM are hashed, and any WAL must be absent or zero length before copying main alone. The master stays unchanged. Successful copies are removed only after native validation, closed-file hashes, zero child exits, and the outer runner's complete process-group cleanup proof. Failed copies and all failure receipts remain. There is no 45-copy footprint assumption.

Each reviewed execution stage is one-shot and fail-fast:

```sh
python3 harness/run.py prepare --core-source /absolute/localdev/read-only-Core-object-source

python3 harness/run.py build \
  --c-compiler /absolute/clang \
  --cxx-compiler /absolute/clang++ \
  --sqlite-include /absolute/platform/sqlite/include \
  --sqlite-library /absolute/platform/sqlite/library
# macOS additionally supplies --sdk /absolute/MacOSX.sdk

python3 harness/run.py run
```

Run from this packet's parent directory (retention-foreground). Exact compiler, SDK and platform SQLite paths must be reviewed and recorded before launch; these placeholders are not permission to guess an alternate toolchain. A fresh remote same-host job is preferred. Source export is `git archive` of exact tracked CMakeLists.txt, Sources and Tests; it never copies an owner's working tree, changes an existing checkout, resolves dependencies or fetches network content. CMake builds only the probe and its Core/SqliteVec dependencies, not the Swift bridge, GoogleTest executables or SDK. No TestHelpers global environment is included.

All generated source/build/cache/tmp/log/fixture files stay in this localdev packet. The copied, signal-proven Interrupts/GuardedRunner is unchanged. Guards are 12.5 GiB available space, 512 MiB total allocated packet, 32 MiB per-command output, one compiler, 1200 s compile and 120 s per runtime child/supervisor. Source export/configure/proof/summary have smaller separate limits. Runtime has a 3600 s outer budget including a 30 s finalization reserve. These bounds are admission/emergency limits, not performance acceptance thresholds. Actual filesystem metric and observed peak are retained by each guard receipt. No automatic retry, scale-up, threshold change or unrelated cleanup is implemented.

Build proof requires every Core translation unit in the frozen CMake target, SqliteVec and probe to have O3/NDEBUG/g0 flags, verifies their owned object hashes, rejects unexpected static support archives or extra direct link objects, and records the actual link map and binary hash. Runtime identifies its actual SQLite image/version/sourceid/options and effective pragmas. This is a uniformly optimized Core build proposal, not reuse of the prior O0 focused archive. Actual portability/compilation remains unqualified.

The schedule is one retained warmup A/A/B triplet, five measured triplets alternating order, one claim race, and one held-reader A/B pair. Every sample has a fresh main copy. ANALYSIS.json reports per-arm p50/p95/max write durations, tick duration, logical-close duration, sampled WAL peak and B-minus-A effects against A1/A2 noise. It does not report p99 from five ticks or call logical close a destructor/maintenance-thread join measurement. Only the outer RESULT.json written after the summary child cleanup is the completed collection receipt.

Still outside this first source increment: independent traced transaction phase timing, deliberate newer-stamp replacement during failed-claim cleanup, slot registration/reset between floor read and BEGIN, final memory invalidation after compaction, maintenance-thread shutdown join, growing no-history payload amplification, and full slow-reader history-gap/link-regeneration acceptance. Existing named correctness receipts remain relevant, but this harness does not silently claim those further scenarios. No product/API changes or production queue/cache/chunking implementation are included.

Before launch: independently review the C++ fixture/API assumptions, timing and cleanup orchestration, exact toolchain/path commands, build provenance checks, and resource admission. Python AST parsing is the only executed check so far; it is not C++ qualification.

The original e578 source-only packet is retained under versions. Before the first execution, all three arms were explicitly repinned to qualified7b11 after independent API/retention-delta review. No retained measurement or frozen numerical SLO was changed. Root also added exact source-inventory verification, compiler-version receipts and nonmasking finalization evidence.
