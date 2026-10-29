import { test } from 'node:test';
import assert from 'node:assert/strict';
import { IDBFactory } from 'fake-indexeddb';
import { JSDOM } from 'jsdom';
import {
    AttachmentDownloadLedger, ATTACHMENT_RETRY_DELAYS_MS, attachmentVersionKey,
    classifyAttachmentFailure, createEncryptedCache, planAttachmentCache, attachmentReferencesIn,
    RelayApiError,
} from '../dist/index.js';

const dom = new JSDOM('');
globalThis.DOMParser = dom.window.DOMParser;
globalThis.XMLSerializer = dom.window.XMLSerializer;
const cardID = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';
const id = '11111111-2222-4333-8444-555555555555';
const contentVersion = '11111111-2222-4333-8444-555555555556';
const reference = { cardID, id, contentVersion, missing: true };
const key = attachmentVersionKey(reference);
const now = 1_800_000_000_000;
const scope = { userId: 'test-user', vaultId: 'test-vault', origin: 'https://api.test' };
const row = { uuid: cardID, kind: 1, revision: 1, modifiedMs: 1, bodyB64: 'AQID' };
const snapshot = { scope, rows: [row], cursor: 1, passwordVersion: 1, accountEpoch: 0, envelope: 'encrypted' };

test('five automatic retries remain bounded across popup/process restarts', () => {
    let ledger = new AttachmentDownloadLedger();
    for (const [index, delay] of ATTACHMENT_RETRY_DELAYS_MS.entries()) {
        ledger.fail(key, 'transient', now);
        ledger = new AttachmentDownloadLedger(JSON.parse(JSON.stringify(ledger)));
        assert.equal(ledger.record(key).failureCount, index + 1);
        assert.equal(ledger.isReady(key, now), false);
        assert.equal(ledger.isReady(key, now + delay), true);
    }
    ledger.fail(key, 'transient', now);
    assert.equal(ledger.record(key).retryAt, undefined);
    ledger.request(key);
    assert.equal(ledger.isReady(key, now + 1e9), false);
    ledger.request(key, true);
    assert.equal(ledger.isReady(key, now), true);
    ledger.fail(key, 'transient', now, 120_000);
    assert.equal(ledger.record(key).retryAt, now + 120_000);
});

test('authorization changes and network recovery resume only the appropriate failure class', () => {
    const ledger = new AttachmentDownloadLedger();
    ledger.authorize('a'.repeat(64));
    ledger.fail(key, 'authorization', now);
    ledger.authorize('a'.repeat(64));
    ledger.recoverNetwork();
    assert.equal(ledger.isReady(key, now), false);
    ledger.authorize('b'.repeat(64));
    assert.equal(ledger.isReady(key, now), true);
    ledger.fail(key, 'integrity', now);
    ledger.recoverNetwork();
    assert.equal(ledger.isReady(key, now), false);
    ledger.fail(key, 'transient', now);
    ledger.recoverNetwork();
    assert.equal(ledger.isReady(key, now), true);
});

test('offline retention follows identity, while eviction and retry history follow exact content', () => {
    const ledger = new AttachmentDownloadLedger();
    ledger.setKeptOffline(key, true);
    ledger.evict(key);
    ledger.recoverNetwork();
    assert.equal(ledger.isReady(key), false);
    const replaced = { ...reference, contentVersion: cardID };
    const newKey = attachmentVersionKey(replaced);
    assert.equal(ledger.isKeptOffline(newKey), true);
    ledger.reconcile([replaced]);
    assert.equal(ledger.record(key), undefined);
    assert.equal(ledger.isReady(newKey), true);
});

test('whole-library batches survive restart and protect cached successes until complete or explicitly ended', () => {
    const present = { ...reference, contentVersion: cardID, missing: false };
    let ledger = new AttachmentDownloadLedger();
    ledger.requestAll([present, reference]);
    ledger.setKeptOffline(key, true);
    ledger = new AttachmentDownloadLedger(JSON.parse(JSON.stringify(ledger)));
    assert.equal(ledger.downloadingAll, true);
    assert.equal(ledger.isBatchProtected(attachmentVersionKey(present)), true);
    ledger.reconcile([present, { ...reference, missing: false }]);
    assert.equal(ledger.downloadingAll, false);
    assert.equal(ledger.isKeptOffline(key), true);
    ledger.requestAll([reference]);
    ledger.cancelAll();
    assert.equal(ledger.isReady(key), true);
    assert.equal(ledger.isKeptOffline(key), true);
});

test('damaged counters, timestamps, unknown fields and format versions are rejected', () => {
    const ledger = new AttachmentDownloadLedger();
    ledger.fail(key, 'transient', now);
    const mutations = [
        state => { state.formatVersion = 2; },
        state => { state.password = 'forbidden'; },
        state => { state.records[key].failureCount = 0; },
        state => { delete state.records[key].retryAt; },
        state => { state.records[key].failure = 'permanent'; },
        state => { state.records[key].lastAccess = Infinity; },
        state => { state.records[key].filename = 'forbidden'; },
    ];
    for (const mutate of mutations) {
        const state = ledger.toJSON();
        mutate(state);
        assert.throws(() => new AttachmentDownloadLedger(state), /attachment_policy_corrupt/);
    }
});

test('failure classification respects cancellation, backoff, integrity, and browser quota', () => {
    assert.equal(classifyAttachmentFailure(new DOMException('cancel', 'AbortError')), null);
    assert.equal(classifyAttachmentFailure(new DOMException('timeout', 'TimeoutError')).failure, 'transient');
    assert.equal(classifyAttachmentFailure(new TypeError('fetch failed')).failure, 'transient');
    assert.equal(classifyAttachmentFailure(new RelayApiError(429, 'rate_limited', '90')).minimumDelay, 90_000);
    assert.equal(classifyAttachmentFailure(new RelayApiError(503, 'unavailable')).failure, 'transient');
    assert.equal(classifyAttachmentFailure(new RelayApiError(401, 'unauthorized')).failure, 'authorization');
    assert.equal(classifyAttachmentFailure(new RelayApiError(404, 'attachment_version_missing')).failure, 'unavailable');
    assert.equal(classifyAttachmentFailure(new RelayApiError(0, 'attachment_integrity_failure')).failure, 'integrity');
    assert.equal(classifyAttachmentFailure(new DOMException('full', 'QuotaExceededError')).failure, 'storage');
});

test('policy persists independently of normal snapshot commits and is scoped to account and vault', async () => {
    const factory = new IDBFactory();
    const cache = createEncryptedCache(factory);
    await cache.commit(snapshot, null);
    const ledger = new AttachmentDownloadLedger();
    ledger.fail(key, 'transient', now);
    await cache.writeAttachmentLedger({ scope, state: ledger.toJSON(), accountEpoch: 0 }, null);
    await cache.commit({ ...snapshot, cursor: 2 }, 1);
    cache.close();
    const reopened = createEncryptedCache(factory);
    const stored = await reopened.readAttachmentLedger(scope);
    assert.deepEqual(stored.state, ledger.toJSON());
    assert.equal(stored.version, 1);
    assert.equal(await reopened.readAttachmentLedger({ ...scope, vaultId: 'other' }), null);
    assert.equal(await reopened.readAttachmentLedger({ ...scope, userId: 'other' }), null);
    assert.equal(await reopened.readAttachmentLedger({ ...scope, origin: 'https://other.test' }), null);
    reopened.close();
});

test('stale policy CAS aborts the entire combined ciphertext/policy commit', async () => {
    const cache = createEncryptedCache(new IDBFactory());
    await cache.commit(snapshot, null);
    const ledger = new AttachmentDownloadLedger();
    ledger.evict(key);
    await cache.writeAttachmentLedger({ scope, state: ledger.toJSON(), accountEpoch: 0 }, null);
    const before = await cache.read(scope);
    await assert.rejects(cache.commit({ ...snapshot, cursor: 99 }, 1,
        { state: ledger.toJSON(), expectedVersion: null }), /attachment_policy_version_conflict/);
    assert.deepEqual(await cache.read(scope), before);
    assert.equal((await cache.readAttachmentLedger(scope)).version, 1);
    await cache.commit({ ...snapshot, cursor: 2 }, 1, { state: ledger.toJSON(), expectedVersion: 1 });
    assert.equal((await cache.readAttachmentLedger(scope)).version, 2);
    assert.equal((await cache.read(scope)).version, 2);
    cache.close();
});

test('explicit account cache removal removes policy and fences stale policy writes', async () => {
    const cache = createEncryptedCache(new IDBFactory());
    const ledger = new AttachmentDownloadLedger();
    await cache.commit(snapshot, null, { state: ledger.toJSON(), expectedVersion: null });
    await cache.removeAccount(scope.userId);
    assert.equal(await cache.readAttachmentLedger(scope), null);
    await assert.rejects(cache.writeAttachmentLedger({ scope, accountEpoch: 0, state: ledger.toJSON() }, null),
        /account_epoch_mismatch/);
    assert.equal(await cache.read(scope), null);
    cache.close();
});

function cacheFixture() {
    const fragments = [1, 2, 3].map(number => {
        const uuid = `aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeee${number}`;
        return { row: { ...row, uuid },
            xml: `<card id="${uuid}"><file id="${id}" version="${contentVersion}" name="file">${Buffer.alloc(10, number).toString('base64')}</file></card>` };
    });
    const references = attachmentReferencesIn(fragments);
    const remoteVersions = references.map(reference => ({ attachmentId: reference.id, cardUuid: reference.cardID,
        contentVersion: reference.contentVersion, bytes: 38, sha256: 'a'.repeat(64), dekWrapped: 'AQ==', isCurrent: true }));
    return { fragments, references, remoteVersions };
}

test('LRU eviction removes only bytes and atomically supplies durable suppression metadata', () => {
    const { fragments, references, remoteVersions } = cacheFixture();
    const ledger = new AttachmentDownloadLedger();
    references.forEach((reference, index) => ledger.access(attachmentVersionKey(reference), now + index));
    const plan = planAttachmentCache({ fragments, ledger, remoteVersions, conflictCardIDs: new Set(), budgetBytes: 30, incomingBytes: 10 });
    assert.equal(plan.hasCapacity, true);
    assert.deepEqual(plan.evictedVersions, [attachmentVersionKey(references[0])]);
    assert.equal(plan.cachedBytes, 20);
    const after = attachmentReferencesIn(plan.fragments);
    assert.equal(after[0].missing, true);
    assert.equal(after[0].contentVersion, references[0].contentVersion);
    assert.equal(plan.ledger.isReady(plan.evictedVersions[0]), false);
    assert.equal(attachmentReferencesIn(fragments)[0].missing, false);
    assert.equal(ledger.isReady(plan.evictedVersions[0]), true);
});

test('offline, in-use, conflict and whole-library versions cannot be evicted to make room', () => {
    const { fragments, references, remoteVersions } = cacheFixture();
    const ledger = new AttachmentDownloadLedger();
    ledger.setKeptOffline(attachmentVersionKey(references[0]), true);
    const plan = planAttachmentCache({ fragments, ledger, remoteVersions,
        conflictCardIDs: new Set([references[1].cardID]), protectedCardIDs: new Set([references[2].cardID]),
        budgetBytes: 30, incomingBytes: 1 });
    assert.equal(plan.hasCapacity, false);
    assert.deepEqual(plan.fragments, fragments);
    assert.deepEqual(plan.evictedVersions, []);
    ledger.requestAll([...references, { ...reference, missing: true }]);
    const batch = planAttachmentCache({ fragments, ledger, remoteVersions, conflictCardIDs: new Set(), budgetBytes: 30, incomingBytes: 1 });
    assert.equal(batch.hasCapacity, false);
    assert.deepEqual(batch.evictedVersions, []);
});

test('unconfirmed rows and unavailable or foreign-parent remote versions remain intact', () => {
    const { fragments, remoteVersions } = cacheFixture();
    fragments[0].row.revision = 0;
    remoteVersions[1].cardUuid = cardID;
    remoteVersions.splice(2, 1);
    const plan = planAttachmentCache({ fragments, ledger: new AttachmentDownloadLedger(), remoteVersions,
        conflictCardIDs: new Set(), budgetBytes: 0 });
    assert.equal(plan.hasCapacity, false);
    assert.deepEqual(plan.fragments, fragments);
    assert.deepEqual(plan.evictedVersions, []);
});

test('v1 encrypted snapshots migrate to the policy store without changing ciphertext or cursor', async () => {
    const factory = new IDBFactory();
    const db = await new Promise((resolve, reject) => {
        const request = factory.open('upasswords-encrypted-vault-cache', 1);
        request.onupgradeneeded = () => {
            request.result.createObjectStore('snapshots');
            request.result.createObjectStore('accountEpochs');
        };
        request.onsuccess = () => resolve(request.result);
        request.onerror = () => reject(request.error);
    });
    const tx = db.transaction('snapshots', 'readwrite');
    tx.objectStore('snapshots').put({ ...snapshot, version: 3 }, 'https://api.test\u0000test-user\u0000test-vault');
    await new Promise((resolve, reject) => { tx.oncomplete = resolve; tx.onabort = () => reject(tx.error); });
    db.close();
    const cache = createEncryptedCache(factory);
    assert.deepEqual(await cache.read(scope), { ...snapshot, version: 3, quarantinedItems: [] });
    assert.equal(await cache.readAttachmentLedger(scope), null);
    await cache.writeAttachmentLedger({ scope, accountEpoch: 0, state: new AttachmentDownloadLedger().toJSON() }, null);
    assert.deepEqual(await cache.read(scope), { ...snapshot, version: 3, quarantinedItems: [] });
    cache.close();
});

test('corrupt durable policy is rejected and preserved rather than overwritten with an empty ledger', async () => {
    const factory = new IDBFactory();
    const cache = createEncryptedCache(factory);
    await cache.commit(snapshot, null);
    const db = await new Promise((resolve, reject) => {
        const request = factory.open('upasswords-encrypted-vault-cache', 3);
        request.onsuccess = () => resolve(request.result);
        request.onerror = () => reject(request.error);
    });
    const corrupt = { scope, accountEpoch: 0, version: 1, state: { formatVersion: 999 } };
    const tx = db.transaction('attachmentPolicies', 'readwrite');
    const storageKey = 'https://api.test\u0000test-user\u0000test-vault';
    tx.objectStore('attachmentPolicies').put(corrupt, storageKey);
    await new Promise((resolve, reject) => { tx.oncomplete = resolve; tx.onabort = () => reject(tx.error); });
    await assert.rejects(cache.readAttachmentLedger(scope), /attachment_policy_corrupt/);
    await assert.rejects(cache.writeAttachmentLedger({ scope, accountEpoch: 0, state: new AttachmentDownloadLedger().toJSON() }, null),
        /attachment_policy_corrupt/);
    const read = db.transaction('attachmentPolicies', 'readonly').objectStore('attachmentPolicies').get(storageKey);
    assert.deepEqual(await new Promise((resolve, reject) => {
        read.onsuccess = () => resolve(read.result); read.onerror = () => reject(read.error);
    }), corrupt);
    db.close();
    cache.close();
});

test('a synchronous policy-write failure aborts an already staged ciphertext replacement', async () => {
    const factory = new IDBFactory();
    const cache = createEncryptedCache(factory);
    await cache.commit(snapshot, null);
    const db = await new Promise((resolve, reject) => {
        const request = factory.open('upasswords-encrypted-vault-cache', 3);
        request.onsuccess = () => resolve(request.result);
        request.onerror = () => reject(request.error);
    });
    const prototype = Object.getPrototypeOf(db);
    const originalTransaction = prototype.transaction;
    prototype.transaction = function (stores, mode, options) {
        const tx = originalTransaction.call(this, stores, mode, options);
        if (mode === 'readwrite' && Array.from(tx.objectStoreNames).includes('snapshots')) {
            const originalObjectStore = tx.objectStore.bind(tx);
            tx.objectStore = name => {
                const store = originalObjectStore(name);
                if (name === 'attachmentPolicies') store.put = () => { throw new DOMException('quota', 'QuotaExceededError'); };
                return store;
            };
        }
        return tx;
    };
    try {
        await assert.rejects(cache.commit({ ...snapshot, cursor: 99 }, 1,
            { state: new AttachmentDownloadLedger().toJSON(), expectedVersion: null }), error => error.name === 'QuotaExceededError');
    } finally {
        prototype.transaction = originalTransaction;
    }
    assert.equal((await cache.read(scope)).cursor, 1);
    assert.equal((await cache.read(scope)).version, 1);
    assert.equal(await cache.readAttachmentLedger(scope), null);
    db.close();
    cache.close();
});
