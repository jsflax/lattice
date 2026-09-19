# Held live-scalar diagnostic successor 003

This source-only packet prepares one fresh hosted macOS instrumented B build/run at SDK `96a5bf0256f81691a92d98cb8fe24b54e00de811` and Core `d1e06f4b74ffc76410a9e59f062117c160e191b6`. Its workflow is disabled; no allocation, native execution or dispatch is authorized by the packet. The negative frozen benchmark remains unchanged.

The previous diagnostic run 35436821175 built successfully, then stopped before measurement when its 7,180,184-byte Swift dependency file exceeded the supplemental parser's4MiB cap. That file also contains 124 make rules rather than the assumed single rule. Final custody then tried to verify a supplement that had not been constructed. The immutable failed-run assessments are retained in `evidence`; the earlier run receives no new acceptance or measurement credit.

## Changes in 003

The supplemental parser permits the observed Swift dependency shape with a 16 MiB bounded read, at most 1024 rules and 32768 input names per rule. Native dependency input retains its 4 MiB/single-rule bound. Identical repeated WMO input lists are tokenized once and individual input bytes are hashed once. Unsupported syntax, unowned/missing inputs or outputs, duplicate/unexpected/missing target rules and missing required source dependencies still fail closed. Every concrete frontend object and driver module/doc/source-info output is required; unused SwiftPM partial-module/global-object map slots earn no output credit. Each rule must include every authenticated module Swift source and the exact test module map. Dependency copies, target files and listed input bytes remain hash-bound and rechecked.

The actual Swift dependency file lists `CLatticeTestSQLite/module.modulemap` but does not list that module's two transitive profile headers. The successor records two different evidence categories: direct emitted module-map/source dependency evidence, and an explicitly inferred header chain. The latter binds the exact map declaration, sealed shim/header bytes, actual driver and object-producing frontend macro/map/Core include arguments, and the same fresh owned scratch module-cache path. Both argument contexts reject VFS, prebuilt module/PCH, cache and unsupported header lookup overrides; ordinary include directories are required and an earlier header shadow is rejected. This is authenticated source/configuration inference, **not direct Swift-emitted transitive-header or retained PCM proof**. `IMPORTER-EVIDENCE-PROPOSAL.md` preserves the contract root accepted; source checks record that acceptance. Existing later ABI/enabled/fault and native counter assertions remain required before any profile is accepted.

The runner now writes and hashes the base compiler proof before constructing the supplemental proof. Final custody verifies that available base proof when the supplement is absent, explicitly reporting that a complete profile proof is unavailable. The primary failure remains primary, and other final evidence/resource checks still run independently.

Actual compiler-mode/target/flag/source/object/link checks from 002 remain. No product, instrumentation, source manifest, dependency pin, build command, measurement command, workload/sample order, analyzer, process supervisor, workflow or overall resource/time limit changes are made. `CONFIG.json`, `Core.patch`, `SDK.patch`, all four source manifests, `guarded_runner.py`, `build_proof.py`, `frozen_binding.py`, `profile_binding.py`, `perf_refinement_report.py`, `analyze_profile.py` and `profile-hosted.yml` remain byte-identical to 002.

## Measurement and resource boundaries

One Release j2 build is followed by one filtered skip-build command: local then attached, 5 warmup + 100 measured samples each, followed by 8 off/on calibration samples per variant. That is 210 canonical instrumented samples plus 16 separate calibration samples. No A/A2/baseline run is added. Calibration measures only incremental native-counter overhead; diagnostic phase clocks/branches remain when counters are off. It cannot be subtracted to claim stock performance or host causation. Swift/bridge conversion and native per-category CPU remain unmeasured.

The 12 GiB free floor, 30 GiB packet ceiling, 512 MiB per-log ceiling, 5400-second build, 1200-second measurement, 18000-second overall deadline, 600-second finalization reserve and 60-second settling command are unchanged. The guard describes owned process groups/reaped leaders, not arbitrary escaped descendants or physical host idleness. Any first failure is terminal; no retries, automatic correction, count reduction or widened runtime bounds.

## Evidence and future admission

Saved actual dependency bytes, output maps and importer commands are inert parser fixtures. Synthetic tests use files under this packet's localdev scratch directories; no compiler, preprocessor, SQLite, native code or benchmark is executed. The final pure-check log records the count. The original source 002 and the failed run remain immutable.

Compiler object/archive/test-binary custody and all retained-source checks keep their existing scope. System/toolchain headers and derived module outputs are hash-bound when present; the unchanged upload workflow does not retain every such byte or the module cache. Inferred importer-chain custody does not fill those retention gaps.

Before execution, root must review the source seal, independent review, concrete workflow installation/enabling delta and an exact owner allocation. `ADMISSION-TEMPLATE.json` stays unapproved. Installation remains `Scripts/live-scalar-profile-96-d1`; the existing entry is:

```
python3 -B "$TASK_ROOT/tools/Scripts/live-scalar-profile-96-d1/run-profile.py" \
  --root "$TASK_ROOT" --seal-sha256 "$PACKET_SEAL_SHA256" \
  --admission-json "$TASK_ROOT/ADMISSION.json" --admission-sha256 "$ROOT_ADMISSION_SHA256"
```

A source seal grants no new native, runtime, platform, performance or release acceptance. All 210 + 16 samples and remaining source/counter/evidence gates still have to pass on a separately admitted fresh run.
