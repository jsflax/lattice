# Preparation review, 2026-09-18

SourceCore independently reviewed the exact-artifact serving and detached-process cleanup paths. Concrete findings were corrected before the preparation seal:

- GuardedRunner compact command records contain `label` / `success`, so missing browser-inventory detection now uses the label, not nonexistent argv.
- Spawn registry updates now use a temporary file and rename. Initial publication failure kills the just-created owned process/group before propagating. A later exit-receipt failure makes the run fail and does not blindly signal an old child PID.
- Cleanup verifies retained Linux PID/startTicks/session/process-group identities before signals. New identities are accepted only while an already trusted identity survives the entire membership scan. An old numeric PGID alone cannot authenticate new members after leader exit. A previously witnessed group-gone state is permanent.
- Unknown surviving ownership is a missing-proof failure; it does not authorize signaling an unrelated group. Cleanup has a shared 30-second budget and the final overall deadline/resource checks still apply.

SourceCore's final bounded read found no further concrete blocker in the serving/cleanup changes. This is a source review, not an execution or complete failure-injection proof.

The author additionally checked the substantive original browser assertions and corrected the six-skip coverage descriptions to their actual counts/semantics (bulk inserts 100 rows, link assignment precedes persistence, query checks counts/iteration/snapshot). The browser receipt now records `BrowserServer.process().spawnfile`, because headless launch can use a different executable from the default `chromium.executablePath()`. Asset response attempts/in-flight bodies/errors are bounded, and original results are preserved before supplemental fixtures and after context cleanup.

`OFFLINE-CHECKS.json` records 32 passing preparation checks: Python ASTs, Node syntax, exact clean JS/head/hashes, ordered original names, dedicated npm lock join to the read-only Engram lock, exact archived asset bytes, six-case mapping and absence of local dependency/browser installation. TypeScript fixture typechecking, browser installation/launch, WASM execution, process fault injection, Chromium results, OPFS durability, no-worker runtime behavior and remote sync were **not executed**.
