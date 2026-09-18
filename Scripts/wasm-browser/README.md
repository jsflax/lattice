# Isolated WASM browser qualification preparation

This packet is prepared source, not browser qualification. No browser, browser binary installer, Vite server, application, or existing profile was launched during preparation. No active LatticeJS source was changed. The dedicated Playwright lock was generated with npm's package-lock-only / ignore-scripts mode; parser and offline provenance checks are the only local checks.

The runner requires a **new Linux allocation**, Node **20.18.0**, Python **3.12+**, Chromium system dependencies already available, and an empty run directory under `~/localdev`. Linux `/proc` birth identities are used to authenticate detached child cleanup. macOS execution is not prepared. Playwright **1.58.2** and playwright-core are locked with registry integrity hashes matching the read-only Engram server lock at `cf9810a:app/package-lock.json`. Chromium is downloaded into the new run's own directory only when execution is separately authorized; its actual launched executable path/hash and browser version are recorded. This packet does not use system Chrome or a pre-existing debugging endpoint.

## Inputs and invocation after authorization

Use a clean read-only LatticeJS checkout at `ea5379bdffbf60a76f939d74ff1a2d7aa38f7b36`. Supply the untouched artifact ZIP from WASM CI run **35340302120**, artifact **10544642780**, SHA256 `8c88e372b2a962ffaf06d60a62077e39fa2dd254598c45004f6d652a7bd6d145`. The runner verifies the whole archive and each of its four selected generated JS/WASM entries. A is the JS gitlink Core `36b828864cbb1543e945898be31589f9c04d6384`; B is Core `cbf360d14d696c84b40f5a58a966eed0271035ae` / tree `cfa80cca9a05fbb2ee92f6db7ed5b9e2cbf41e03`. Compiler-input/toolchain receipts remain in that original ZIP and the sealed WASM result; this browser runner does not rebuild or relabel those artifacts.

```sh
python3 run-browser.py \
  --root "$HOME/localdev/lattice-wasm-browser-NEW-RUN" \
  --js-source /absolute/path/to/clean/exact/LatticeJS \
  --wasm-artifact /absolute/path/to/artifact-10544642780.zip
```

The wrapper authenticates the clean source, archives it independently into A/B staging directories, preserves their original tracked file hashes, installs the JS checkout's unchanged complete npm lock, installs the dedicated tooling lock, and finally launches its own loopback-only Vite and Chromium. B uses the same owned A node_modules graph and a separate Vite cache. Nothing is installed in the read-only source checkout. All explicit caches, temporary paths, browser profiles/binaries, OPFS artifacts and logs are under the new run directory. No workflow has been installed or dispatched by this preparation.

## Required results

For **each arm**, the driver first opens the unchanged `test/browser/index.html` and runs every original case in its existing order. It requires exactly the **23 names** frozen in `config.json`, all passed, no missing case, no skip and no page error. Original DOM results and bounded console/error records are saved **before** any supplemental fixture and again after context cleanup. It does not silently repair `:memory:N`, worker-era comments, or any original fixture, and does not rerun a failed case. B still runs after ordinary assertion failures in A so original A/B behavior is preserved. An infrastructure failure can stop execution; missing results fail closed.

`NODE-SKIP-BROWSER-MAPPING.json` maps the six Node skips to these substantive browser assertions. The five skipped Node integration bodies are empty placeholders; executing those empty functions would add no coverage. The original WASM run's **82 passing + 6 skipped individual cases per arm** remains unchanged. This harness's zero-skip browser gate is additional evidence, not a rewrite of the original Node receipt.

Supplemental fixtures use the **real Lattice TS API and real WASM** on a new synthetic persistent store. They perform three distinct document lifetimes:

1. Add `{title: 'persist-α-"exact"', count: 7, enabled: true}`, retain assigned id/globalId, close, and read/hash the real OPFS SQLite snapshot bytes.
2. Reload the page, require one row with the same id/globalId and exact values, update to `{title: 'updated-β-"exact"', count: 19, enabled: false}`, read back, close, and retain OPFS bytes.
3. Reload again and require exactly the updated row and same identity, then close and retain OPFS bytes.

A second isolated context repeats all three actions with **SharedWorker and BroadcastChannel absent before module import**. Each document must record a successful real WebAssembly instantiation; no loader/mock/storage fallback is supplied. Secure-context, cross-origin isolation and real OPFS are required. Each OPFS artifact is capped at 8 MiB and transferred bytes are SHA256-checked. This supplements the existing `test_PersistentDB_WorkerSync`, whose oracle only reads the same open handle.

Generated JS and WASM are served by exact-byte middleware. Vite handles URL-import wrappers, while raw artifact responses bypass transformation. The driver authenticates staged bytes and independently hashes actual browser response bodies. A successful run requires received JS and WASM hashes matching the selected arm, plus actual WASM instantiation. These facts are separate from the source/compiler provenance of the supplied archive.

## Scope limits that remain explicit

All browser WebSocket connections are locally intercepted and closed. HTTP is restricted to the newly created Vite origin, data and blob URLs. This prevents the unchanged legacy `test_RealServerSync` from reaching any existing localhost:5050 service. That test checks one **local observation** after a delay; passing it is not remote synchronization evidence. `remoteSyncQualified` remains false. A separately accepted isolated server fixture must demonstrate real server persistence, acknowledgement, peer delivery/reconnect and exact values using compatible pinned server/client sources before any wire-compatibility claim.

Only Chromium/Linux is prepared. `fullBrowserMatrixQualified` and `browserCompatibility` remain false even if this packet succeeds; `localChromiumCasesQualified` identifies its narrower result. Firefox, WebKit, Safari and production sync remain unqualified. The browser's headless mode includes `--disable-gpu`; no existing GPU/application/profile is used.

## Bounds, ownership and evidence

The parent supervisor is the exact previously reviewed `guarded_runner.py`, SHA256 in config. It checks resource bounds every 0.5 seconds: **12 GiB free floor**, **2 GiB run ceiling**, **128 MiB command-log ceiling**, **1,200 seconds overall**, and a 60-second finalization reserve. The driver requires admission of its unchanged 720-second timeout, rather than silently shortening its run. Original suite timeout is 120 seconds per arm, fixture action timeout 30 seconds, and browser launch timeout 30 seconds. Resource/time failures retain their receipts and do not trigger retries or threshold changes.

The supervisor owns a new process group for each command. Chromium may start a detached session, so a synchronous spawn audit atomically publishes a bounded 64-entry registry; publication failure kills the just-created child/group before propagating. Retained Linux PID/start-tick/session identities authenticate later group signals. Member identities are added only while a previously trusted identity survives the scan. A witnessed group-gone state is permanent, so a reused numeric PGID is never signaled based on that stale record. If no retained live identity authenticates a remaining group, the wrapper records missing cleanup proof and fails rather than signaling a potentially unrelated process. A global 30-second detached cleanup budget and the final overall/resource checks still apply. A hard kill or evidence-storage failure can leave missing proof; it can never yield success. These paths have had source review only in this packet, not browser runtime fault injection.

Vite/context/browser close waits are bounded. Raw original outcomes, additional fixture results, OPFS SQLite bytes, received artifact hashes, actual browser identity, process/command receipts and final RESULT stay under the owned run. Console bytes and scalar error inventories have explicit caps. Preserve the entire run when it fails; do not remove failed originals before a separately reviewed fixture correction.

The driver uses Playwright's documented [launchServer](https://playwright.dev/docs/api/class-browsertype#browser-type-launch-server), owned [BrowserServer process/close/kill](https://playwright.dev/docs/api/class-browserserver), and [WebSocket routing](https://playwright.dev/docs/api/class-browsercontext#browser-context-route-web-socket) APIs. The spawn-audit wrapper is deliberately tied to the exact locked Playwright version and needs runtime verification in the isolated allocation.
