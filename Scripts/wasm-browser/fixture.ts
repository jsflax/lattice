import 'reflect-metadata';
import { Lattice, model } from '../../src/index';

@model
class BrowserPersistenceRow {
    title = '';
    count = 0;
    enabled = false;
}

const initial = { title: 'persist-α-"exact"', count: 7, enabled: true };
const updated = { title: 'updated-β-"exact"', count: 19, enabled: false };
const pageInstance = crypto.randomUUID();
function check(value: unknown, message: string): asserts value {
    if (!value) throw new Error(message);
}
function values(row: any) {
    return { id: Number(row.id), globalId: String(row.globalId), title: row.title,
        count: Number(row.count), enabled: row.enabled };
}
function exact(row: any, expected: any) {
    for (const key of Object.keys(expected)) {
        check(Object.is(row[key], expected[key]), `Exact ${key} mismatch: ${JSON.stringify(row[key])} != ${JSON.stringify(expected[key])}`);
    }
}
async function snapshot(path: string) {
    check(typeof navigator.storage?.getDirectory === 'function', 'Real OPFS API unavailable');
    const directory = await (await navigator.storage.getDirectory()).getDirectoryHandle('lattice-snapshots');
    const file = await (await directory.getFileHandle(path.replace(/[^a-z0-9._-]/gi, '_'))).getFile();
    check(file.size > 0 && file.size <= 8 * 1024 * 1024, `OPFS snapshot size out of bounds: ${file.size}`);
    const bytes = new Uint8Array(await file.arrayBuffer());
    const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes));
    let binary = '';
    for (let index = 0; index < bytes.length; index += 8192) {
        binary += String.fromCharCode(...bytes.subarray(index, index + 8192));
    }
    return { bytes: file.size, sha256: Array.from(digest, n => n.toString(16).padStart(2, '0')).join(''),
        base64: btoa(binary) };
}
async function step(action: 'createClose' | 'reloadUpdateClose' | 'reloadVerifyClose', path: string, identity?: any) {
    check(/^browser-[AB]-[a-f0-9-]+$/.test(path), 'Only this synthetic fixture path is allowed');
    check(isSecureContext && crossOriginIsolated, 'Secure isolated origin is required');
    check(typeof navigator.storage?.getDirectory === 'function', 'OPFS cannot be replaced by an in-memory fallback');
    const lattice = await Lattice.open(path, [BrowserPersistenceRow]);
    let row: any;
    try {
        if (action === 'createClose') {
            check(await lattice.count(BrowserPersistenceRow) === 0, 'Synthetic store must start empty');
            const added = new BrowserPersistenceRow();
            Object.assign(added, initial);
            await lattice.add(added);
            row = values(added);
            check(Number.isSafeInteger(row.id) && row.id > 0 && row.globalId.length > 0, 'Missing persisted identity');
            exact(row, initial);
        } else {
            check(identity && Number.isSafeInteger(identity.id), 'Prior page identity required');
            check(await lattice.count(BrowserPersistenceRow) === 1, 'Reload must restore exactly one row');
            const found = await lattice.find(BrowserPersistenceRow, identity.id);
            check(found, 'Persisted row missing after a real page reload');
            row = values(found);
            exact(row, { id: identity.id, globalId: identity.globalId,
                ...(action === 'reloadUpdateClose' ? initial : updated) });
            if (action === 'reloadUpdateClose') {
                found.title = updated.title;
                found.count = updated.count;
                found.enabled = updated.enabled;
                const readBack = await lattice.find(BrowserPersistenceRow, identity.id);
                check(readBack, 'Updated row missing');
                row = values(readBack);
                exact(row, { id: identity.id, globalId: identity.globalId, ...updated });
            }
        }
    } finally {
        await lattice.close();
    }
    // close() can internally log/save errors; actual OPFS bytes and next reload
    // are the oracle rather than assuming a resolved close promise proves durability.
    return { action, pageInstance, row, snapshot: await snapshot(path),
        sharedWorkerType: typeof SharedWorker, broadcastChannelType: typeof BroadcastChannel };
}
(window as any).qualificationFixture = { step, pageInstance, initial, updated };
