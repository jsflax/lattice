# Core 2.0.7 candidate / published JavaScript 1.1.1 browser preparation

Exact Core 0a31bb88ae06b26a6b28db83d7e5477a8cac5d72 / JS d811adcdfbb39d09afbe82564be48cde0553a92e. This source-only packet refuses runtime setup until the new builder artifact is authenticated and sealed once with the existing bind-artifact.py. All historical assets remain historical; no asset from an earlier Core qualifies this candidate.

The unchanged builder requires native16 with actual new WASM and zero per-case/final native resources, plus 109 TypeScript/Node passes and six exact existing browser-required skips. Its strict all-Node-cases gate remains failed. The unchanged browser runner retains original23, audit6 and both three-page persistence scenarios, received asset hashes, deadlines and owned cleanup. Audit6 remains a frozen qualification-only overlay, separate from published source.

Published JS1.1.1 keeps DYNAMIC_EXECUTION=0. No JS source, API, version, lock dependency, Core gitlink or distributed asset changes are proposed. These two manual-only workflows qualify a private exact Core override. Remote sync, other browsers, performance, full A/B and overall release qualification remain false. The parent preparation README describes the finite build → review/bind → browser sequence.
