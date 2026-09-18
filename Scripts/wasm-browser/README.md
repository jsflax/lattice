# Corrected candidate browser runtime (partial qualification)

Only exact corrected B is executed. Original A's unchanged21/23 outcome is retained in `historical-A-original-23.json`; baselineQualified/fullABCompatibility remain false. Superseded cbf B assets are recorded separately. Runtime refuses unbound candidate artifacts before setup.

B must pass all23 unchanged original browser tests, the six strictly named real-WASM audit regressions, actual OPFS close/reload/update/reload and unavailable-SharedWorker checks. Original120s test/30s fixture bounds, exact Playwright1.58.2 and Node20.18.0, byte proof, source checks and owned process cleanup remain mandatory. All WebSockets/external HTTP are blocked; remote sync remains unqualified.

The reviewed collector records non-module JS fetch metadata without treating it as executed-module proof; actual module and WASM response hashes are still required. Any case, asset, page-error, source-integrity or cleanup failure keeps the candidate unqualified. Historical A failures never prevent capturing B's independent evidence and never become passes.

`check-preparation.py` performs source checks only. `bind-artifact.py` is a separate one-shot preparation step requiring actual authenticated builder output, never a CI fallback or fixture correction. See the parent packet README for the two-stage installation and source identities.
