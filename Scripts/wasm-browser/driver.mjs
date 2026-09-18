import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import childProcess from 'node:child_process';
import { createRequire, syncBuiltinESMExports } from 'node:module';
import { pathToFileURL } from 'node:url';

const [rootArgument, configArgument] = process.argv.slice(2);
if (!rootArgument || !configArgument) throw new Error('Usage: driver.mjs OWNED_RUN_ROOT CONFIG_JSON');
const root = fs.realpathSync(rootArgument);
const config = JSON.parse(fs.readFileSync(configArgument));
const receipts = path.join(root, 'receipts');
const sha = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const save = (name, value) => {
    const destination = path.join(receipts, name), temporary = destination + '.tmp';
    fs.writeFileSync(temporary, JSON.stringify(value, null, 2) + '\n');
    fs.renameSync(temporary, destination);
};
if (process.platform !== 'linux') throw new Error('This preparation requires Linux /proc process-identity proof');
function processIdentity(pid) {
    try {
        const raw = fs.readFileSync(`/proc/${pid}/stat`, 'utf8');
        const fields = raw.slice(raw.lastIndexOf(')') + 2).trim().split(/\s+/);
        return { pid, processGroup: Number(fields[2]), session: Number(fields[3]), startTicks: fields[19] };
    } catch (error) { if (error.code === 'ENOENT' || error.code === 'ESRCH') return null; throw error; }
}
function groupGone(pid) {
    try { process.kill(-pid, 0); return false; }
    catch (error) { if (error.code === 'ESRCH') return true; throw error; }
}
function captureGroupMembers(pid) {
    const members = [];
    for (const entry of fs.readdirSync('/proc')) {
        if (!/^\d+$/.test(entry)) continue;
        const identity = processIdentity(Number(entry));
        if (identity?.processGroup === pid && identity.session === pid) {
            if (members.length >= 256) throw new Error('Owned group identity cap reached');
            members.push(identity);
        }
    }
    return members;
}
if (config.browserEngine !== 'chromium') throw new Error('Only Chromium is prepared');
function extendGroupIdentities(row) {
    const anchor = row.identities.find(identity => JSON.stringify(processIdentity(identity.pid)) === JSON.stringify(identity));
    if (!anchor) return false;
    const members = captureGroupMembers(row.pid);
    // A retained birth identity must survive the complete scan. Numeric PGID
    // membership alone cannot establish ownership after leader PID reuse.
    if (JSON.stringify(processIdentity(anchor.pid)) !== JSON.stringify(anchor)) return false;
    const merged = new Map(row.identities.map(identity => [`${identity.pid}/${identity.startTicks}`, identity]));
    for (const identity of members) merged.set(`${identity.pid}/${identity.startTicks}`, identity);
    if (merged.size > 256) throw new Error('Retained group identity cap reached');
    row.identities = [...merged.values()];
    return true;
}
if (process.version !== `v${config.nodeVersion}`) throw new Error('Exact qualified Node version required');
if (!fs.realpathSync(process.env.PLAYWRIGHT_BROWSERS_PATH || '/missing').startsWith(root + path.sep)) throw new Error('Browser binaries must belong to this owned run');
for (const name of ['TMPDIR', 'TMP', 'TEMP']) if (!path.resolve(process.env[name] || '/missing').startsWith(root + path.sep)) throw new Error('Owned temporary paths required');
const result = { schemaVersion: 1, success: false, remoteSyncQualified: false,
    fullBrowserMatrixQualified: false, engine: config.browserEngine, arms: {}, errors: [], cleanup: [] };
let interrupted = null, browserServer, browser, vite;
const ownedSpawns = [];
save('owned-spawns.json', ownedSpawns);
// Record detached browser process groups synchronously at spawn return, before
// JS signal handlers can run. The supervisor retains and cleans only these owned groups.
const originalSpawn = childProcess.spawn;
childProcess.spawn = function (...args) {
    if (ownedSpawns.length >= 64) throw new Error('Owned child admission cap reached');
    const child = originalSpawn.apply(this, args);
    const options = Array.isArray(args[1]) ? args[2] : args[1];
    const row = { pid: child.pid ?? null, detached: options?.detached === true,
        executableBasename: path.basename(String(args[0])), exited: false, groupGone: false, identities: [] };
    const emergencyKill = () => {
        if (!child.pid) return;
        try {
            // This is the just-created child, still retained by its ChildProcess.
            // If detached publication fails, stop its group before propagating.
            if (row.detached) process.kill(-child.pid, 'SIGKILL');
            else child.kill('SIGKILL');
        } catch (error) { if (error.code !== 'ESRCH') throw error; }
    };
    const publish = () => {
        try { save('owned-spawns.json', ownedSpawns); }
        catch (error) { emergencyKill(); interrupted = 'spawn-registry-publication-failed'; throw error; }
    };
    ownedSpawns.push(row);
    try {
        if (row.detached && child.pid) {
            const identity = processIdentity(child.pid);
            if (identity && (identity.processGroup !== child.pid || identity.session !== child.pid)) throw new Error('Detached child identity mismatch');
            if (identity) { row.identities.push(identity); extendGroupIdentities(row); }
            else row.groupGone = groupGone(child.pid);
            if (!identity && !row.groupGone) throw new Error('No initial detached-group identity');
        }
        publish();
    } catch (error) { emergencyKill(); throw error; }
    child.once('exit', (code, signal) => {
        row.exited = true; row.code = code; row.signal = signal;
        try {
            if (row.detached && child.pid && !row.groupGone) {
                row.groupGone = groupGone(child.pid);
                if (!row.groupGone) extendGroupIdentities(row);
            }
            save('owned-spawns.json', ownedSpawns);
        } catch (error) {
            // Fail closed; do not turn a receipt failure into a passing driver.
            interrupted = 'spawn-registry-exit-proof-failed';
            result.errors.push(String(error));
        }
    });
    return child;
};
syncBuiltinESMExports();
process.on('SIGTERM', () => { interrupted = 'SIGTERM'; });
process.on('SIGINT', () => { interrupted = 'SIGINT'; });
const checkSignal = () => { if (interrupted) throw new Error(`Interrupted: ${interrupted}`); };
async function bounded(promise, ms, label) {
    let timer;
    try { return await Promise.race([promise, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error(`${label} timed out`)), ms); })]); }
    finally { clearTimeout(timer); }
}
const require = createRequire(import.meta.url);
const pwPackage = require('playwright/package.json');
if (pwPackage.version !== config.playwrightVersion) throw new Error('Playwright version mismatch');
const { chromium } = await import('playwright');
const sourceRequire = createRequire(path.join(root, 'A', 'package.json'));
const { createServer } = await import(pathToFileURL(sourceRequire.resolve('vite')).href);
const pendingBodies = new Set();
function recordLiveGroupIdentities() {
    for (const row of ownedSpawns) {
        if (!row.detached || !row.pid || row.groupGone) continue;
        row.groupGone = groupGone(row.pid);
        if (!row.groupGone) extendGroupIdentities(row);
    }
    save('owned-spawns.json', ownedSpawns);
}

function assetError(report, error) {
    if (report.assetErrors.length < 32) report.assetErrors.push(String(error).slice(0, 8192));
    else report.assetErrorsDropped++;
}
async function newContext(origin, report, noWorkers = false) {
    const context = await browser.newContext({ serviceWorkers: 'block', acceptDownloads: false });
    await context.route('**/*', route => {
        const url = new URL(route.request().url());
        if (url.origin === origin || url.protocol === 'data:' || url.protocol === 'blob:') return route.continue();
        report.blockedRequests++;
        return route.abort('blockedbyclient');
    });
    // No running server or external sync service is contacted. The legacy
    // RealServerSync case is retained as its actual local-observation oracle only.
    await context.routeWebSocket('**/*', socket => { report.blockedWebSockets++; socket.close({ code: 1008, reason: 'isolated qualification: remote sync unresolved' }); });
    await context.addInitScript(({ noWorkers }) => {
        globalThis.__qualificationInstantiation = { instantiate: 0, streaming: 0 };
        for (const [name, key] of [['instantiate', 'instantiate'], ['instantiateStreaming', 'streaming']]) {
            const original = WebAssembly[name];
            if (typeof original === 'function') WebAssembly[name] = async function (...args) {
                const value = await original.apply(this, args);
                globalThis.__qualificationInstantiation[key]++;
                return value;
            };
        }
        if (noWorkers) {
            Object.defineProperty(globalThis, 'SharedWorker', { value: undefined, configurable: false });
            Object.defineProperty(globalThis, 'BroadcastChannel', { value: undefined, configurable: false });
        }
    }, { noWorkers });
    context.on('response', response => {
        const expectedHash = response.headers()['x-lattice-artifact-sha256'];
        if (!expectedHash) return;
        report.assetResponseAttempts++;
        if (report.assetResponseAttempts > 32 || pendingBodies.size >= 32) { assetError(report, 'Asset response admission cap exceeded'); return; }
        let task;
        task = (async () => {
            const body = await response.body();
            if (report.assetResponses.length >= 32) throw new Error('Asset response receipt cap exceeded');
            const kind = new URL(response.url()).pathname.endsWith('.wasm') ? 'wasm' : 'js';
            const actual = sha(body);
            report.assetResponses.push({ kind, bytes: body.length, sha256: actual, status: response.status() });
            if (actual !== config.assets[report.arm][kind].sha256 || expectedHash !== actual) throw new Error('Browser received different artifact bytes');
        })().catch(error => { assetError(report, error); }).finally(() => pendingBodies.delete(task));
        pendingBodies.add(task);
    });
    return context;
}
async function finishBodies() { await bounded(Promise.all([...pendingBodies]), 10000, 'asset hash collection'); }
async function originalSuite(origin, report) {
    const context = await newContext(origin, report);
    const page = await context.newPage();
    const output = { namesExpected: config.originalCaseNames, cases: [], console: [], consoleDropped: 0,
        pageErrors: [], timeLimitMs: config.originalSuiteTimeoutMs, success: false };
    let consoleBytes = 0;
    page.on('console', message => {
        const text = message.text();
        if (consoleBytes + Buffer.byteLength(text) <= 256 * 1024) { output.console.push({ type: message.type(), text }); consoleBytes += Buffer.byteLength(text); }
        else output.consoleDropped++;
    });
    page.on('pageerror', error => { if (output.pageErrors.length < 32) output.pageErrors.push(String(error).slice(0, 8192)); });
    try {
        await page.goto(origin + '/test/browser/index.html', { waitUntil: 'load', timeout: 30000 });
        await page.waitForFunction(() => {
            const rows = [...document.querySelectorAll('#tests .test')];
            return rows.filter(row => !row.classList.contains('running')).length >= 23 || rows.some(row => row.classList.contains('skip'));
        }, null, { timeout: config.originalSuiteTimeoutMs });
        checkSignal();
    } catch (error) { output.error = String(error); }
    try {
        output.cases = await bounded(page.locator('#tests .test').evaluateAll(rows => rows.map(row => ({
            name: row.childNodes[0]?.textContent?.replace(/^[✓✗○⏳]\s*/, '').trim(),
            status: ['pass', 'fail', 'skip', 'running'].find(status => row.classList.contains(status)),
            error: row.querySelector('pre')?.textContent?.slice(0, 32768) ?? null
        }))), 10000, 'original DOM capture');
        output.instantiation = await page.evaluate(() => globalThis.__qualificationInstantiation);
        output.success = !output.error && output.cases.length === config.originalCaseNames.length
            && output.cases.every((row, i) => row.name === config.originalCaseNames[i] && row.status === 'pass')
            && output.instantiation.instantiate + output.instantiation.streaming > 0 && output.pageErrors.length === 0;
        output.remoteSyncQualified = false;
        output.realServerSyncMeaning = 'unchanged local-observation assertion; all WebSocket traffic isolated/blocked';
    } catch (error) { output.captureError = String(error); }
    // Preserve original outcomes before any supplemental fixture executes. No correction/retry.
    save(`${report.arm}-original-23-precleanup.json`, output);
    await finishBodies();
    await bounded(context.close(), 10000, 'original context close');
    output.success = output.success && output.pageErrors.length === 0;
    save(`${report.arm}-original-23.json`, output);
    return output;
}
async function persistence(origin, report, noWorkers) {
    const context = await newContext(origin, report, noWorkers);
    const page = await context.newPage();
    const output = { name: noWorkers ? 'realWASM_noSharedWorker_OPFS_reload' : 'realOPFS_close_reload_update_reload', success: false, steps: [], errors: [] };
    page.on('pageerror', error => { if (output.errors.length < 32) output.errors.push(String(error).slice(0, 8192)); });
    const syntheticPath = `browser-${report.arm}-${crypto.randomUUID()}`;
    try {
        let identity;
        for (const action of ['createClose', 'reloadUpdateClose', 'reloadVerifyClose']) {
            checkSignal();
            if (action === 'createClose') await page.goto(origin + '/test/qualification/fixture.html', { timeout: 30000 });
            else await page.reload({ waitUntil: 'load', timeout: 30000 });
            await page.waitForFunction(() => !!window.qualificationFixture, null, { timeout: 30000 });
            const step = await bounded(page.evaluate(async ({ action, path, identity }) =>
                window.qualificationFixture.step(action, path, identity), { action, path: syntheticPath, identity }), config.fixtureActionTimeoutMs, action);
            if (identity && step.pageInstance === output.steps.at(-1).pageInstance) throw new Error('A real page reload did not occur');
            if (!identity) identity = { id: step.row.id, globalId: step.row.globalId };
            const snapshotBytes = Buffer.from(step.snapshot.base64, 'base64');
            if (sha(snapshotBytes) !== step.snapshot.sha256 || snapshotBytes.length !== step.snapshot.bytes) throw new Error('OPFS snapshot custody mismatch');
            fs.writeFileSync(path.join(receipts, `${report.arm}-${noWorkers ? 'no-workers' : 'opfs'}-${action}.sqlite`), snapshotBytes);
            delete step.snapshot.base64;
            step.instantiation = await page.evaluate(() => globalThis.__qualificationInstantiation);
            if (step.instantiation.instantiate + step.instantiation.streaming < 1) throw new Error('No successful real WASM instantiation recorded on this page');
            if (noWorkers && (step.sharedWorkerType !== 'undefined' || step.broadcastChannelType !== 'undefined')) throw new Error('Optional globals were not absent');
            output.steps.push(step);
        }
        output.success = output.steps.length === 3 && output.errors.length === 0;
    } catch (error) { output.errors.push(String(error)); }
    finally {
        await finishBodies();
        try { await bounded(context.close(), 10000, 'fixture context close'); }
        catch (error) { output.errors.push(String(error)); output.success = false; }
        output.success = output.success && output.errors.length === 0;
        save(`${report.arm}-${noWorkers ? 'no-workers' : 'opfs'}.json`, output);
    }
    return output;
}
try {
    browserServer = await chromium.launchServer({ headless: true, host: '127.0.0.1', port: 0,
        timeout: config.browserLaunchTimeoutMs, handleSIGINT: false, handleSIGTERM: false, handleSIGHUP: false,
        args: ['--disable-gpu', '--disable-background-networking'] });
    checkSignal();
    browser = await chromium.connect(browserServer.wsEndpoint(), { timeout: 30000 });
    recordLiveGroupIdentities();
    result.browserVersion = browser.version();
    const launchedBrowser = browserServer.process();
    const actualExecutable = fs.realpathSync(launchedBrowser.spawnfile);
    if (!actualExecutable.startsWith(path.join(root, 'browser-cache') + path.sep)) throw new Error('Browser executable escaped this owned run');
    result.browserExecutable = { path: actualExecutable, sha256: sha(fs.readFileSync(actualExecutable)), pid: launchedBrowser.pid };
    for (const arm of ['A', 'B']) {
        checkSignal();
        const source = path.join(root, arm);
        const report = { arm, success: false, blockedRequests: 0, blockedWebSockets: 0, assetResponses: [], assetErrors: [], assetErrorsDropped: 0, assetResponseAttempts: 0 };
        result.arms[arm] = report;
        const assets = Object.fromEntries(['js', 'wasm'].map(ext => [ext, fs.readFileSync(path.join(source, 'wasm/build/lattice.' + ext))]));
        for (const ext of ['js', 'wasm']) if (sha(assets[ext]) !== config.assets[arm][ext].sha256) throw new Error('Staged artifact mismatch');
        vite = await createServer({ configFile: false, root: source, cacheDir: path.join(root, 'vite-cache', arm),
            server: { host: '127.0.0.1', port: 0, strictPort: true, hmr: false,
                headers: { 'Cross-Origin-Opener-Policy': 'same-origin', 'Cross-Origin-Embedder-Policy': 'require-corp' } },
            plugins: [{ name: 'exact-qualification-artifacts', configureServer(server) {
                server.middlewares.use((request, response, next) => {
                    const url = new URL(request.url, 'http://127.0.0.1');
                    const ext = url.pathname === '/wasm/build/lattice.js' ? 'js' : url.pathname === '/wasm/build/lattice.wasm' ? 'wasm' : null;
                    if (!ext || url.searchParams.has('url') || url.searchParams.has('import')) return next();
                    response.setHeader('Content-Type', ext === 'wasm' ? 'application/wasm' : 'application/javascript');
                    response.setHeader('Cross-Origin-Opener-Policy', 'same-origin');
                    response.setHeader('Cross-Origin-Embedder-Policy', 'require-corp');
                    response.setHeader('Cache-Control', 'no-store');
                    response.setHeader('X-Lattice-Artifact-SHA256', config.assets[arm][ext].sha256);
                    response.end(assets[ext]);
                });
            } }] });
        await vite.listen();
        const address = vite.httpServer.address();
        if (!address || typeof address === 'string' || address.address !== '127.0.0.1') throw new Error('Server failed owned loopback binding');
        const origin = `http://127.0.0.1:${address.port}`;
        report.original = await originalSuite(origin, report);
        report.opfs = await persistence(origin, report, false);
        report.noWorkers = await persistence(origin, report, true);
        await finishBodies();
        for (const ext of ['js', 'wasm']) if (!report.assetResponses.some(row => row.kind === ext && row.sha256 === config.assets[arm][ext].sha256)) assetError(report, 'missing browser response hash proof: ' + ext);
        report.success = report.original.success && report.opfs.success && report.noWorkers.success && !report.assetErrors.length;
        save(`${arm}-RESULT.json`, report);
        await bounded(vite.close(), 10000, 'Vite close'); vite = null;
    }
    result.success = Object.keys(result.arms).length === 2 && Object.values(result.arms).every(arm => arm.success);
} catch (error) { result.errors.push(String(error)); }
finally {
    if (vite) { try { await bounded(vite.close(), 10000, 'final Vite close'); result.cleanup.push('Vite closed'); } catch (error) { result.errors.push(String(error)); } }
    if (browserServer) {
        try { recordLiveGroupIdentities(); } catch (error) { result.errors.push(String(error)); }
        try { await bounded(browserServer.close(), 10000, 'browser close'); result.cleanup.push('browser close acknowledged'); }
        catch (error) { result.errors.push(String(error)); try { await bounded(browserServer.kill(), 10000, 'browser kill'); result.cleanup.push('browser kill acknowledged'); } catch (nested) { result.errors.push(String(nested)); } }
    }
    result.interrupted = interrupted;
    result.success = result.success && !result.errors.length && !interrupted;
    save('BROWSER-RESULT.json', result);
}
process.exitCode = result.success ? 0 : 1;
