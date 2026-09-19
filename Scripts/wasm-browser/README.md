# Broad Core205 / published JS1.1 browser preparation

This pending successor uses exact Core a09e622 / JS831cac6. It refuses runtime setup until a new actual builder artifact is authenticated and sealed with bind-artifact.py. Historical cfe/4b assets are not current inputs.

The additional builder gate requires the unchanged published native16 harness, its exact newly built assets and zero per-case/final native resources, plus JS109 passes and the exact six existing browser-required skips. The strict all-Node-cases gate remains false. Node skips do not become passes. Native16 uses real WASM/SQLite in Node22.16.0 with fixture sockets, not browser/live sync.

Browser runtime retains Node20.18.0, Playwright1.58.2, unchanged original23, audit6 and both three-page persistence scenarios, received asset hashes and owned cleanup. Published JS1.1 omits audit6 files; their frozen bytes are an explicit qualification-only overlay under audit-fixtures, separate from exact published source and verified again at exit. Browser driver, fixture deadlines and resource guards remain unchanged. Remote sync, full matrix, release and performance qualification remain false.

Builder and later bound-browser workflows have separate isolated trigger branches. Source review/admission precedes a build; actual builder evidence review and one-shot binding precede any browser run.
