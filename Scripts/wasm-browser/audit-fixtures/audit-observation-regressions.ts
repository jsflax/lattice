import 'reflect-metadata';
import { Lattice, model, list, type AuditLogEntry } from '../../src/index';

@model
class AuditCompatPerson {
    declare id?: number;
    declare globalId?: string;
    name = '';
    age = 0;
}

@model
class AuditCompatDog {
    name = '';
    puppies = list(AuditCompatDog);
}

type Outcome = { name: string; status: 'pass' | 'fail'; error?: string };
const results: Outcome[] = [];
const receipt = { complete: false, results };
Object.assign(window, { auditObservationRegressions: receipt });

function check(value: unknown, message: string): asserts value {
    if (!value) throw new Error(message);
}
function equal(actual: unknown, expected: unknown, message: string) {
    check(JSON.stringify(actual) === JSON.stringify(expected), message);
}
const settle = () => new Promise<void>(resolve => setTimeout(resolve, 50));
const path = (memory: boolean) => memory ? ':memory:' : `audit-compat-${crypto.randomUUID()}`;

function assertMemoryBackend(db: Lattice) {
    // A ':memory:' prefix with a suffix is a file path to SQLite. Use the
    // actual connection metadata, not the TypeScript branch, as the oracle.
    equal(Number(db.debugQueryCount("SELECT * FROM pragma_database_list WHERE name='main' AND file=''")),
        1, 'fixture is not an actual SQLite memory database');
}

async function test(name: string, body: () => Promise<void>) {
    try {
        await body();
        results.push({ name, status: 'pass' });
    } catch (error) {
        results.push({ name, status: 'fail', error: String(error).slice(0, 4096) });
    }
    document.querySelector('#results')!.textContent = JSON.stringify(receipt, null, 2);
}

function assertContract(entry: AuditLogEntry, rowId: number, globalRowId: string) {
    check(Number.isSafeInteger(entry.id) && entry.id > 0, 'audit id is missing or invalid');
    check(typeof entry.globalId === 'string' && entry.globalId.length > 0, 'audit globalId is missing');
    equal(entry.tableName, 'AuditCompatPerson', 'model tableName was not serialized');
    equal(entry.rowId, rowId, 'model rowId was replaced by audit rowId');
    equal(entry.globalRowId, globalRowId, 'model globalRowId was not serialized');
    check(typeof entry.changedFields === 'object' && entry.changedFields !== null, 'changedFields is missing');
    check(Array.isArray(entry.changedFieldsNames), 'changedFieldsNames is missing');
    check(typeof entry.timestamp === 'string' && Number.isFinite(Number(entry.timestamp)) && Number(entry.timestamp) > 0,
        'stored numeric timestamp did not retain a nonempty string representation');
    equal(entry.isFromRemote, false, 'local provenance flag is missing or wrong');
    equal(entry.isSynchronized, false, 'unsynchronized flag is missing or wrong');
}

async function personStore(memory: boolean): Promise<Lattice> {
    const db = await Lattice.open(path(memory), [AuditCompatPerson]);
    try {
        if (memory) assertMemoryBackend(db);
        return db;
    } catch (error) {
        await db.close();
        throw error;
    }
}

async function transactionFields(memory: boolean) {
    const db = await personStore(memory);
    const entries: AuditLogEntry[] = [];
    const unsubscribe = db.observe(batch => entries.push(...batch));
    try {
        const person = new AuditCompatPerson();
        person.name = 'insert α "quoted"';
        person.age = 42;
        let rowId = 0;
        let globalId = '';
        await db.write(async () => {
            await db.add(person);
            rowId = Number(person.id);
            globalId = person.globalId!;
            person.name = 'update β "quoted"';
            check(await db.remove(AuditCompatPerson, rowId), 'transaction delete failed');
        });
        await settle();
        equal(entries.length, 3, 'one transaction must deliver each of its three audit rows once');
        equal(entries.map(entry => entry.operation), ['INSERT', 'UPDATE', 'DELETE'], 'stored operation/order mismatch');
        equal(new Set(entries.map(entry => entry.globalId)).size, 3, 'audit event duplicated');
        check(entries[0].id < entries[1].id && entries[1].id < entries[2].id, 'audit IDs are not in transaction order');
        for (const entry of entries) assertContract(entry, rowId, globalId);
        equal((entries[0].changedFields.name as { value: unknown }).value, 'insert α "quoted"', 'insert value was lost or misescaped');
        equal((entries[1].changedFields.name as { value: unknown }).value, 'update β "quoted"', 'update value was lost or misescaped');
        equal((entries[2].changedFields.name as { value: unknown }).value, 'update β "quoted"', 'delete old value was lost');
        check(entries[1].changedFieldsNames.includes('name'), 'changed field names omitted the mutation');
    } finally {
        unsubscribe();
        await db.close();
    }
}

async function persistentLinkAudit() {
    const db = await Lattice.open(path(false), [AuditCompatDog]);
    const entries: AuditLogEntry[] = [];
    const unsubscribe = db.observe(batch => entries.push(...batch));
    try {
        const parent = new AuditCompatDog();
        const puppy = new AuditCompatDog();
        parent.name = 'parent';
        puppy.name = 'puppy';
        await db.add(parent);
        await db.add(puppy);
        parent.puppies.push(puppy);
        await settle();
        const storedCount = Number(db.debugQueryCount('SELECT id FROM AuditLog'));
        check(storedCount > 2, 'link-table audit fixture did not create an audit row');
        equal(entries.length, storedCount, 'direct and derived link/model audit delivery must not duplicate');
        equal(new Set(entries.map(entry => entry.globalId)).size, storedCount, 'duplicate audit globalId');
        check(entries.some(entry => entry.tableName.startsWith('_') && entry.operation === 'INSERT'), 'link-table audit event missing');
    } finally {
        unsubscribe();
        await db.close();
    }
}

async function cancelQueued() {
    const db = await personStore(true);
    let deliveries = 0;
    const unsubscribe = db.observe(() => { deliveries++; });
    try {
        // add() performs the native write before returning its promise; the
        // Core observer is already copied into the deferred event-loop job.
        const write = db.add(new AuditCompatPerson());
        unsubscribe();
        unsubscribe();
        await write;
        await settle();
        equal(deliveries, 0, 'copied callback ran after unsubscribe');
    } finally {
        unsubscribe();
        await db.close();
    }
}

async function cancelInsideCallback() {
    const db = await personStore(true);
    let deliveries = 0;
    const unsubscribe = db.observe(() => { deliveries++; unsubscribe(); });
    try {
        await db.add(new AuditCompatPerson());
        await settle();
        equal(deliveries, 1, 'first callback missing or duplicated');
        await db.add(new AuditCompatPerson());
        await settle();
        equal(deliveries, 1, 'self-unsubscribe did not retire the observer');
        unsubscribe();
    } finally {
        unsubscribe();
        await db.close();
    }
}

async function closeQueued() {
    const db = await personStore(true);
    let deliveries = 0;
    db.observe(() => { deliveries++; });
    const write = db.add(new AuditCompatPerson());
    // No persistent snapshot awaits in this memory-store close path.
    await db.close();
    await write;
    await settle();
    equal(deliveries, 0, 'deleted JS wrapper retained an active AuditLog observer');
}

await test('audit_fields_memory_transaction', () => transactionFields(true));
await test('audit_fields_persistent_transaction', () => transactionFields(false));
await test('audit_link_rows_once_persistent', persistentLinkAudit);
await test('audit_unsubscribe_queued_and_idempotent', cancelQueued);
await test('audit_unsubscribe_inside_callback', cancelInsideCallback);
await test('audit_close_suppresses_queued_callback', closeQueued);
receipt.complete = true;
document.querySelector('#results')!.textContent = JSON.stringify(receipt, null, 2);
