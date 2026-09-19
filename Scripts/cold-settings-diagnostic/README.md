This source-only successor divides the measured connection-settings span into individual settings without changing configuration. It targets Core743c1c20bea3fcb966f640e22348916571c83034/tree85dbc9548b5ad6e2f8932c002b1f9f75a7c28f6c and reuses the successful5139f6249bed39723fd6de6b7e9db8f9f5b490c3 packet from run35447218968. That coarse run attributed58–76% of its constructor span to settings; three pairs support further investigation, not a product speedup claim.

No foreign-key API, SQL, flags, setting values, ordering, exception handling or database workload changes. PRAGMA foreign_keys=ON remains an execute call: a configuration-API replacement requires separate authorizer/trace/auto-extension equivalence analysis. Busy timeout, cache2000, mmap300000000, tempMEMORY and the existing conditional scanstatus call remain in place.

Six new tags append after the existing25:26 busy_begin,27 busy_end,28 foreign_keys_end,29 cache_end_setting,30 mmap_end,31 temp_end. Historical tags1–25 retain their numbers; obsolete cache-clamp8/9 remain forbidden. Exact cold order is1,2,3,6,22,23,26,27,28,29,30,31,24,25,7,10,11,12,13,14,15,16,17,18,19,20,21. Warm remains1,2,3,10,11,12,13,14,15,16,17,18,19,20,21.

The successful cold path needs27 records; the recorder uses exactly27 slots, replacing24, and retains static_assert(sizeof(state)<4096). Warm needs15. The decoder occurrence array grows to32 to include tag31. Overflow, unexpected victim retirement, duplicate/nested/missing constructor, incorrect order or return facts are refused. The existing constructor-window/identity guard is unchanged. Pure checks do not establish C++ storage size or emitted records; later native qualification remains required.

The parser uses schema cold-settings-phases/1. It retains all outer/acquisition/page intervals and coarse connectionSettings23→24 as a reconciliation check. Constructor components are:

| Component | Tags | Elapsed source bracket |
| --- | --- | --- |
| sqliteOpen |22→23|sqlite3_open_v2 and adjacent recorder overhead|
| busyHandling |26→27|Existing read-control branch or sqlite3_busy_timeout; measured keeper uses the latter|
| foreignKeys |27→28|Unchanged PRAGMA foreign_keys=ON execute|
| cacheSetting |28→29|Native read-only cache PRAGMA plus skipped writable-journal branch check|
| mmapSetting |29→30|Unchanged mmap PRAGMA|
| tempSetting |30→31|Unchanged temp-store PRAGMA|
| scanstatusTail |31→24|Skipped writable-only branch and optional scanstatus configuration|
| vectorRegistration |24→25|Unchanged sqlite3_vec_init|
| remainder |6→22 +23→26 +25→7|Allocation/member/factory work, open-status validation gap, flags, successful tail and recorder overhead|

The six setting components plus settingsPrefix23→26 must sum exactly to coarse connectionSettings. All nine constructor components must be nonnegative and sum exactly to outer constructor6→7. Shares use the outer duration, or null at zero clock resolution. Remainder now includes the separated settings-prefix gap; the predecessor remainder must not be directly substituted. Every raw timestamp remains.

Tag24 now records whether SQLITE_DBCONFIG_STMT_SCANSTATUS was defined:fact1 if present,0 otherwise. scanstatusCallCompiled exposes that distinction. The span includes adjacent branch/recorder overhead when the call is absent. This flag does not assert a successful return from the product's existing unchecked call, whose behavior remains unchanged. Tags23/25 require success0; pool and acquisition/page facts keep their old rules. Other facts are0. These are elapsed source brackets, not exclusive CPU time or individual SQLite-internal phases.

OFF preprocessing restores both Core overlay files byte-for-byte to743. OFF probe workload matches5139. run.py, build.py, prepare.py, guarded_runner.py, CMakeLists and fetch-core are unchanged. Only probe validation/tag capacity changes. Native/WASM branches retain original product statements; this recipe remains macOS native and does not qualify WASM. SOURCE-MANIFEST keeps887 baseline files and three overlays.

The workload remains six fresh-path processes alternating OFF/ON three times, each100 ordered integer/string/double rows and cold then warm acquisition/page. Expected SQL is7 cold and3 warm. Owner opening/seeding and validation/formatting retain prior timing boundaries; no prewarming or moved work. Coarse21-record ON logs are negative format controls; coarse OFF logs still parse identically. No old sample becomes a new measurement.

All execution bounds remain in the unchanged driver:macos-14/85minute job, fresh uniformO3 OFF/ON builds,14actualTUs per arm, one compiler,12.5GiB raw-free floor,512MiB task root,64MiB compile/64KiB sample logs,1200second compiler child/1355outer,30second sample/shared180second window/335outer,35second cleanup reserve. Source/tool/SDK identity, actual modes and commands, object/archive/link-map proof and post-sample custody remain. These sampled controls do not add RSS/CPU isolation.

Hosted integration reuses registered .github/workflows/cold-keeper-diagnostic.yml on a new qualification branch. Template stays manual-only and changes only display name, owned root/artifact label and Scripts/cold-settings-diagnostic path. SOURCE-READY.executionAdmitted=false blocks execution. Independent/root review, exact qualification binding and separate one-shot admission remain required; no installation/dispatch occurred.

Report every span and OFF/ON perturbation. Ranking can guide compatibility investigation, but three pairs/shared-host timing do not establish p95 stability, current Swift app latency,2x or release acceptance. Do not subtract timer overhead or compare latency across runs. Preparation used only pure parser/source checks and local Git reads; no compiler/native/SQLite/network/commit/push/dispatch.
