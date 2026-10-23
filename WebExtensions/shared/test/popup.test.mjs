import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { webcrypto } from 'node:crypto'
import { runInNewContext } from 'node:vm'
import {
    safeWebsiteUrl,
    credentialsOf,
    generatePassword,
    hostMatches,
    VaultCryptoError,
} from '../dist/index.js'

const here = dirname(fileURLToPath(import.meta.url))
const browsers = process.env.TEST_BROWSERS ? process.env.TEST_BROWSERS.split(',') : ['chrome', 'edge', 'firefox', 'safari']
const read = (browser, file) => readFileSync(join(here, `../../${browser}/src/${file}`), 'utf8')

function element(tag = 'div') {
    let value = ''
    return {
        tagName: String(tag).toUpperCase(), textContent: '', hidden: false, disabled: false,
        readOnly: false, type: 'text', children: [], listeners: {}, attributes: {}, dataset: {},
        get value() { return value },
        set value(input) {
            value = String(input)
            if (tag === 'input') value = value.replace(/[\r\n]/g, '')
            if (tag === 'textarea') value = value.replace(/\r\n?/g, '\n')
        },
        append(...children) {
            for (const child of children) child.parentElement = this
            this.children.push(...children)
        },
        appendChild(child) {
            child.parentElement = this
            this.children.push(child)
        },
        replaceChildren(...children) {
            for (const child of this.children) child.parentElement = null
            for (const child of children) child.parentElement = this
            this.children = children
        },
        remove() {
            const index = this.parentElement?.children.indexOf(this) ?? -1
            if (index >= 0) this.parentElement.children.splice(index, 1)
        },
        setAttribute(name, value) { this.attributes[name] = value },
        addEventListener(type, listener) { this.listeners[type] = listener },
        focus() {},
        scrollIntoView() {},
        classList: {
            values: new Set(),
            add(...values) { values.forEach(value => this.values.add(value)) },
            remove(...values) { values.forEach(value => this.values.delete(value)) },
            contains(value) { return this.values.has(value) },
            toggle(value, force) {
                const enabled = force ?? !this.values.has(value)
                if (enabled) this.values.add(value)
                else this.values.delete(value)
                return enabled
            },
        },
        querySelector() { return null },
        querySelectorAll() { return [] },
    }
}

function renderer(browser, { host = 'example.com', query = '', filter = 'all', registrationForm = false } = {}) {
    const source = read(browser, 'popup.js')
    const start = source.indexOf('function isPersonalInfoItem(item) {')
    const end = source.indexOf('\nasync function fill(', start)
    const itemsEl = element()
    const suggestionsEl = element()
    const suggestionSection = element()
    const resultCount = element()
    const emptyState = element()
    const labels = { emptyTitle: element(), emptyDescription: element(), itemsHeading: element(), emptyNewLoginButton: element() }
    const calls = []
    const render = runInNewContext(`${source.slice(start, end)}; renderCandidates`, {
        itemsEl, suggestionsEl, suggestionSection, resultCount, emptyState, host, credentialsOf, hostMatches, registrationForm,
        searchInput: { value: query }, siteFilter: { value: filter }, sortItems: { value: 'title' },
        t: (zh, en) => en, copyText: (...args) => calls.push(['copy', ...args]),
        document: { createElement: element, getElementById: id => labels[id] },
        fill: (...args) => calls.push(['fill', ...args]),
        openItemDetail: id => calls.push(['detail', id]),
    })
    return { render, itemsEl, suggestionsEl, suggestionSection, resultCount, emptyState, labels, calls }
}

const item = (title, username, host = 'example.com') => ({
    id: `${title}-${username}`, title, host,
    fields: [{ type: 'login', value: username }, { type: 'password', value: 'not-searchable' }],
})

async function popup(browserName, {
    items = [], unlocked = true, hooks = {}, url = 'https://example.com/login',
    cached = unlocked, expired = false, userId = 'synthetic-user',
} = {}) {
    const source = read(browserName, 'popup.js')
    const html = read(browserName, 'popup.html')
    const elements = Object.fromEntries([...html.matchAll(/<(\w+)\b([^>]*\bid="([^"]+)"[^>]*)>/g)].map(match => {
        const control = element(match[1])
        control.value = match[2].match(/\bvalue="([^"]*)"/)?.[1] ?? ''
        control.checked = /\bchecked\b/.test(match[2])
        control.hidden = /\bhidden\b/.test(match[2])
        control.type = match[2].match(/\btype="([^"]+)"/)?.[1] ?? 'text'
        control.scrollTop = 0
        if (match[3] === 'siteFilter') control.value = 'all'
        if (match[3] === 'sortItems') control.value = 'title'
        return [match[3], control]
    }))
    const storage = {
        'relay.session': { token: 'synthetic-token', userId, expiresAt: expired ? 0 : Date.now() + 60_000 },
        'relay.vault': { id: 'synthetic-vault', name: 'Main' },
    }
    const commands = [], fills = [], saves = [], keys = [], edits = [], intervals = []
    const cacheCalls = [], syncCalls = [], envelopeCalls = [], events = [], creations = [], confirmations = [], clipboard = []
    const confirm = (...args) => {
        confirmations.push(args)
        return hooks.confirm ? hooks.confirm(...args) : true
    }
    const scope = { userId, vaultId: 'synthetic-vault' }
    const rowOf = item => ({ uuid: item.id, revision: item.source?.revision ?? 1,
        kind: 1, bodyB64: 'synthetic-ciphertext', modifiedMs: 1 })
    let snapshot = cached ? { scope, envelope: 'synthetic', passwordVersion: 1, version: 1,
        cursor: 1, accountEpoch: 0, rows: items.map(rowOf) } : null
    let accountEpoch = 0
    const cache = {
        async read(requestedScope) {
            cacheCalls.push({ action: 'read', scope: structuredClone(requestedScope) })
            if (hooks.cacheRead) await hooks.cacheRead(requestedScope)
            return snapshot && requestedScope.userId === snapshot.scope.userId
                && requestedScope.vaultId === snapshot.scope.vaultId ? structuredClone(snapshot) : null
        },
        async getEpoch() { return accountEpoch },
        async commit(input, expectedVersion) {
            cacheCalls.push({ action: 'commit', input: structuredClone(input), expectedVersion })
            if (hooks.cacheCommit) await hooks.cacheCommit(input, expectedVersion)
            if (input.accountEpoch !== accountEpoch) throw new Error('account_epoch_mismatch')
            if ((snapshot?.version ?? null) !== expectedVersion) throw new Error('cache_version_conflict')
            snapshot = structuredClone({ ...input, version: (expectedVersion ?? 0) + 1 })
            return structuredClone(snapshot)
        },
        async removeAccount(id) {
            cacheCalls.push({ action: 'removeAccount', userId: id })
            events.push('removeAccount')
            if (hooks.removeAccount) await hooks.removeAccount(id)
            if (snapshot?.scope.userId === id) snapshot = null
            accountEpoch += 1
        },
        close() {},
    }
    const sourceItems = new Map(items.map(item => [item.source?.xml, item]))
    const syntheticParse = xml => {
        const body = xml.replace(/^<passworddatabase>/, '').replace(/<\/passworddatabase>$/, '')
        if (sourceItems.has(body)) return [structuredClone(sourceItems.get(body))]
        if (body.startsWith('{')) return [JSON.parse(body)]
        return []
    }
    const parse = hooks.parse ?? syntheticParse
    const project = fragment => {
        const projected = parse(`<passworddatabase>${fragment.xml}</passworddatabase>`)
        if (projected.length !== 1 || projected[0].id.toLowerCase() !== fragment.uuid.toLowerCase()) {
            throw new VaultCryptoError('bad_item_identity')
        }
        return { ...projected[0], source: { xml: fragment.xml, revision: fragment.revision } }
    }
    const decrypt = async (body, key, uuid) => hooks.decrypt
        ? await hooks.decrypt(body, key, uuid)
        : items.find(item => item.id.toLowerCase() === uuid.toLowerCase())?.source?.xml ?? ''
    let state = { type: 'vault-session', unlocked, items: structuredClone(items), generation: 'g1',
        snapshotVersion: 1, passwordVersion: 1, expiresAt: Date.now() + 60_000 }
    let stateContext = { token: 'synthetic-token', userId, vaultId: 'synthetic-vault' }
    const locked = code => ({ type: 'vault-session', unlocked: false, code })
    const response = () => structuredClone(state)
    let deferredRead = null
    const browser = {
        tabs: {
            query: async () => [{ id: 1, url }],
            sendMessage: async (tab, message) => {
                if (message.type === 'registration-check') return hooks.registrationForm === true
                fills.push(message)
                return hooks.fillResponse ? await hooks.fillResponse(tab, message) : { ok: true }
            },
        },
        permissions: { contains: async () => true },
        notifications: { create: async (...args) => confirmations.push(args) },
        storage: { local: {
            get: async keys => {
                const bag = structuredClone(Object.fromEntries(keys.map(key => [key, storage[key]])))
                if (hooks.storageGet) await hooks.storageGet(keys, bag)
                return bag
            },
            set: async entries => Object.assign(storage, structuredClone(entries)),
            remove: async keys => {
                events.push('removeAuth')
                for (const key of [].concat(keys)) delete storage[key]
            },
        } },
        runtime: { getURL: path => path, sendMessage: async message => {
            commands.push(structuredClone(message))
            if (message.action === 'read' && deferredRead) {
                const deferred = deferredRead
                deferredRead = null
                deferred.started()
                return deferred.promise
            }
            if (message.action === 'lock') {
                if (hooks.beforeLock) await hooks.beforeLock(message)
                if (message.generation !== undefined && message.generation !== state.generation) {
                    return locked('session_generation_mismatch')
                }
                events.push('lock')
                state = locked('session_locked')
                return response()
            }
            const session = storage['relay.session'], vault = storage['relay.vault']
            if (message.context?.token !== session?.token || message.context?.userId !== session?.userId
                || message.context?.vaultId !== vault?.id) return locked('session_context_mismatch')
            if (message.action === 'begin') {
                stateContext = structuredClone(message.context)
                state = { ...locked(), generation: 'ticket' }
            }
            if (message.action !== 'begin' && state.unlocked
                && (message.context.token !== stateContext.token || message.context.userId !== stateContext.userId
                    || message.context.vaultId !== stateContext.vaultId)) return locked('session_context_mismatch')
            if (message.action === 'commit' && message.generation === state.generation) {
                state = { ...state, unlocked: true, items: structuredClone(message.items),
                    snapshotVersion: message.snapshotVersion, passwordVersion: message.passwordVersion,
                    expiresAt: Date.now() + 60_000 }
            }
            if (['decrypt', 'refresh', 'replace'].includes(message.action)) {
                if (message.action === 'replace' && hooks.beforeReplace) await hooks.beforeReplace(message)
                const hook = message.action === 'decrypt' ? hooks.sessionDecrypt : hooks[message.action]
                if (hook) return await hook(message)
                if (!state.unlocked || message.generation !== state.generation) {
                    return locked('session_generation_mismatch')
                }
                if (message.action === 'decrypt') {
                    const fragments = []
                    for (const row of message.rows) fragments.push({ ...row,
                        xml: await decrypt(new Uint8Array(), null, row.uuid) })
                    return { ...response(), fragments }
                }
                if (message.expectedSnapshotVersion !== state.snapshotVersion) {
                    return locked('session_snapshot_conflict')
                }
                if (message.snapshotVersion <= state.snapshotVersion) return locked('invalid_snapshot_version')
                if (message.action === 'refresh' && message.passwordVersion !== state.passwordVersion) {
                    return locked('session_password_version_mismatch')
                }
                state = { ...state, snapshotVersion: message.snapshotVersion,
                    items: message.action === 'refresh' ? structuredClone(message.items)
                        : state.items.map(item => item.id === message.item.id ? structuredClone(message.item) : item) }
            }
            return response()
        } },
    }
    const synchronize = async options => {
        syncCalls.push(options)
        if (hooks.sync) return await hooks.sync(options)
        await options.validate()
        const current = await cache.read(options.scope)
        if (current) return { snapshot: current, changedRows: [], deletedIds: [], rebuilt: false, changedCount: 0 }
        const rows = await (hooks.rows?.() ?? [])
        await options.verifyRows(rows)
        await options.validate()
        const initialized = await cache.commit({ scope: options.scope, envelope: 'synthetic',
            passwordVersion: options.keyVersion, accountEpoch, cursor: 1, rows }, null)
        return { snapshot: initialized, changedRows: rows, deletedIds: [], rebuilt: true, changedCount: rows.length }
    }
    const main = { scrollTop: 0 }
    const document = {
        body: { dataset: {} }, documentElement: {},
        getElementById: id => elements[id], createElement: element,
        querySelector: selector => selector === 'main' ? main : null,
        querySelectorAll: () => [], addEventListener() {},
    }
    const window = { confirm }
    const start = source.indexOf('const zh = ')
    const api = await runInNewContext(`(async () => { ${source.slice(start)}; return { render, fill, quickFillCurrentSite, unlock, syncVault, openItemDetail, saveItemDetail, clearUnlockedView, copyText, createNewLogin, regeneratePassword }; })()`, {
        browser, chrome: browser, document, navigator: { language: 'en', clipboard: {
            writeText: async text => { clipboard.push(text) },
        } },
        window, confirm, crypto: webcrypto,
        canonicalizeHost: host => host, hostnameOf: url => new URL(url).hostname,
        hostMatches, credentialsOf, generatePassword, safeWebsiteUrl,
        createLoginItemXml: (input, nowMs) => {
            const created = { id: input.id, title: input.title, host: input.url ? new URL(safeWebsiteUrl(input.url)).hostname : '',
                notes: input.notes, symbol: 'key', fields: [
                    { type: 'login', value: input.username, autofill: 'username' },
                    { type: 'password', value: input.password, autofill: 'current-password' },
                    { type: 'website', value: input.url, autofill: 'url' },
                ] }
            return JSON.stringify(created)
        },
        createItem: async (token, vaultId, input) => {
            creations.push(structuredClone({ token, vaultId, item: input }))
            if (hooks.createItem) return await hooks.createItem(token, vaultId, input)
            return { revision: 1 }
        },
        clearItems: async () => {},
        verifyCode: async (...args) => hooks.verifyCode ? await hooks.verifyCode(...args)
            : { token: 'new-synthetic-token', userId: 'new-synthetic-user', expiresAt: Date.now() + 60_000 },
        revokeOwnSession: async () => {
            events.push('revoke')
            assert.equal(storage['relay.session'], undefined)
            assert.equal(storage['relay.vault'], undefined)
            if (hooks.revoke) await hooks.revoke()
        },
        createEncryptedCache: () => cache, synchronizeVault: synchronize, projectVaultFragment: project,
        setInterval(callback) { intervals.push(callback) }, clearInterval() {}, console: { info() {}, warn() {} },
        URL, Uint8Array, VaultCryptoError,
        listVaults: async (...args) => hooks.listVaults ? await hooks.listVaults(...args) : [],
        getVaultEnvelope: async (...args) => {
            envelopeCalls.push(args)
            return hooks.envelope ? await hooks.envelope(...args)
                : { envelope: 'synthetic', meta: { passwordVersion: 1 } }
        },
        base64ToBytes: () => new Uint8Array(), bytesToBase64: () => 'encrypted-body',
        unwrapEnvelope: async (...args) => {
            if (hooks.unwrap) await hooks.unwrap(...args)
            const key = new Uint8Array(32).fill(7)
            keys.push(key)
            return key
        },
        listAllVaultItems: hooks.rows ?? (async () => []),
        decryptItemBody: decrypt,
        fragmentsToXml: fragments => `<passworddatabase>${fragments.join('')}</passworddatabase>`,
        parseVaultXml: parse,
        readItemDetail: hooks.detail ?? (item => ({ notes: item.notes ?? '' })),
        updateItemXml: (xml, edit, modifiedMs) => {
            edits.push(structuredClone(edit))
            const original = sourceItems.get(xml)
            return JSON.stringify({ ...original, title: edit.title, notes: edit.notes,
                fields: original.fields.map((field, i) => ({ ...field, value: edit.fieldValues[i] })) })
        },
        encryptItemBody: hooks.encrypt ?? (async () => new Uint8Array(48)),
        saveVaultItem: async (token, vaultId, item) => {
            saves.push({ token, vaultId, item })
            if (hooks.save) return await hooks.save(token, vaultId, item)
            return { revision: item.revision + 1 }
        },
    })
    // Let startup's intentionally unawaited automatic sync settle before each test takes control.
    await new Promise(setImmediate)
    return {
        api, elements, document, window, commands, fills, storage, saves, keys, edits, intervals,
        cache, cacheCalls, syncCalls, envelopeCalls, events, creations, confirmations, clipboard,
        get snapshot() { return structuredClone(snapshot) },
        get state() { return response() },
        setState: value => {
            state = { ...state, type: 'vault-session', ...value }
            stateContext = { token: storage['relay.session']?.token, userId: storage['relay.session']?.userId,
                vaultId: storage['relay.vault']?.id }
        },
        deferRead() {
            const snapshot = response()
            let resolve, started
            const promise = new Promise(done => { resolve = done })
            const ready = new Promise(done => { started = done })
            deferredRead = { promise, started }
            return { ready, release: () => resolve(snapshot) }
        },
    }
}

test('Popup: four browsers share markup, local assets and complete DOM bindings', () => {
    const baseline = read('chrome', 'popup.html')
    for (const browser of browsers) {
        const html = read(browser, 'popup.html')
        assert.equal(html, baseline, browser)
        const ids = [...html.matchAll(/\bid="([^"]+)"/g)].map(match => match[1])
        assert.equal(ids.length, new Set(ids).size, `${browser}: duplicate IDs`)
        for (const match of read(browser, 'popup.js').matchAll(/getElementById\("([^"]+)"\)/g)) {
            assert.ok(ids.includes(match[1]), `${browser}: missing ${match[1]}`)
        }
        assert.match(html, /\[hidden\]\s*\{\s*display:\s*none\s*!important/)
        assert.match(html, /role="status" aria-live="polite"/)
        assert.match(html, /prefers-color-scheme: dark/)
        assert.doesNotMatch(html, /(?:src|href)="https?:/)
    }
})

test('Popup: fixed root width and independent scroll prevent popup collapse', () => {
    const html = read('chrome', 'popup.html')
    const rootStyle = html.match(/html, body\s*\{([^}]+)\}/)[1]
    assert.match(rootStyle, /(?:^|;)\s*width:\s*440px\s*;/)
    assert.match(rootStyle, /(?:^|;)\s*min-width:\s*340px\s*;/)
    assert.match(rootStyle, /(?:^|;)\s*max-width:\s*440px\s*;/)
    assert.doesNotMatch(html, /\b(?:max-)?width:\s*100vw/)
    assert.match(html, /overflow-y:\s*auto/)
    for (const id of ['suggestionSection', 'suggestions', 'settingsBox', 'lockTimeout', 'lockNowButton', 'navigation']) {
        assert.match(html, new RegExp(`id="${id}"`))
    }
})

for (const browser of browsers) {
    test(`Popup ${browser}: suggestions are site-scoped while vault search includes all entries`, () => {
        const view = renderer(browser, { query: 'ALICE' })
        view.render([item('Work', 'Alice'), item('Personal', 'Bob'), item('Other', 'Alice', 'other.org')])
        assert.equal(view.resultCount.textContent, '2')
        assert.equal(view.emptyState.hidden, true)
        assert.equal(view.itemsEl.children.length, 2)
        assert.equal(view.suggestionsEl.children.length, 0)
        const workRow = view.itemsEl.children.find(row => row.children[0].children[1].children[0].textContent === 'Work')
        const button = workRow.children[0]
        assert.equal(button.disabled, false)
        assert.equal(button.children[1].children[0].textContent, 'Work')
        button.listeners.click()
        assert.equal(view.calls[0][0], 'fill', 'clicking a site-matching row fills the page')
        workRow.children[1].children.find(button => button.textContent === 'Fill').listeners.click()
        assert.equal(view.calls[1][0], 'fill')
        workRow.children[1].children.find(button => button.textContent === 'Detail').listeners.click()
        assert.deepEqual(view.calls[2], ['detail', 'Work-Alice'])
        const otherRow = view.itemsEl.children.find(row => row.children[0].children[1].children[0].textContent === 'Other')
        const other = otherRow.children[0]
        assert.equal(other.disabled, false)
        other.listeners.click()
        assert.deepEqual(view.calls[3], ['detail', 'Other-Alice'])
        assert.equal(otherRow.children[1].children.some(button => button.textContent === 'Fill'), false)
        view.render([])
        assert.equal(view.itemsEl.children.length, 0)
        assert.equal(view.suggestionsEl.children.length, 0)
        assert.equal(view.emptyState.hidden, false)
        assert.equal(view.labels.emptyTitle.textContent, 'No matching items')
        const passwordSearch = renderer(browser, { query: 'not-searchable' })
        passwordSearch.render([item('Work', 'Alice')])
        assert.equal(passwordSearch.resultCount.textContent, '0')
    })

    test(`Popup ${browser}: internal pages can browse the vault but cannot fill`, () => {
        const view = renderer(browser, { host: '' })
        view.render([item('Work', 'Alice')])
        assert.equal(view.resultCount.textContent, '1')
        assert.equal(view.suggestionSection.hidden, true)
        assert.equal(view.itemsEl.children[0].children[0].disabled, false)
        assert.equal(view.itemsEl.children[0].children[1].children.some(button => button.textContent === 'Fill'), false)
    })

    test(`Popup ${browser}: reopening restores an empty unlocked vault and settings`, async () => {
        const view = await popup(browser)
        assert.equal(view.document.body.dataset.panel, 'items')
        assert.equal(view.elements.emptyState.hidden, false)
        assert.equal(view.elements.emptyNewLoginButton.hidden, false)
        assert.equal(view.elements.switchVaultButton.hidden, false)
        assert.equal(view.elements.navigation.hidden, false)
        await view.elements.settingsTab.listeners.click()
        assert.equal(view.document.body.dataset.panel, 'settings')
        assert.equal(view.elements.lockTimeout.value, '15')
        view.elements.lockTimeout.value = '30'
        await view.elements.lockTimeout.listeners.change()
        assert.equal(view.storage['extension.lockMinutes'], 30)
        await view.elements.lockNowButton.listeners.click()
        assert.equal(view.document.body.dataset.panel, 'unlock')
        assert.equal(view.elements.navigation.hidden, true)
        assert.equal(view.elements.switchVaultButton.hidden, false)
        assert.ok(view.storage['relay.session'], 'locking must not sign out')
    })

    test(`Popup ${browser}: expired state and foreign-site candidates cannot fill`, async () => {
        const entry = item('Work', 'Alice')
        const view = await popup(browser, { items: [entry] })
        view.setState({ unlocked: false })
        await view.api.fill({ item: entry, ...credentialsOf(entry) }, element())
        assert.equal(view.fills.length, 0)
        assert.equal(view.document.body.dataset.panel, 'unlock')
        await view.api.fill({ item: item('Other', 'Alice', 'other.org') }, element())
        assert.equal(view.fills.length, 0)
    })

    test(`Popup ${browser}: fresh empty-vault unlock commits a session and matching fill still works`, async () => {
        const fresh = await popup(browser, { unlocked: false })
        fresh.elements.masterPassword.value = 'synthetic-password'
        await fresh.api.unlock()
        assert.equal(fresh.document.body.dataset.panel, 'items')
        assert.equal(fresh.elements.masterPassword.value, '')
        assert.deepEqual(fresh.commands.filter(command => ['begin', 'commit'].includes(command.action)).map(command => command.action), ['begin', 'commit'])
        const entry = item('Work', 'Alice')
        const view = await popup(browser, { items: [entry] })
        await view.api.fill({ item: entry, ...credentialsOf(entry) }, element())
        assert.equal(view.fills.length, 1)
        assert.equal(view.fills[0].candidate.username, 'Alice')
    })

    test(`Popup ${browser}: delayed read cannot resurrect entries after manual lock`, async () => {
        const view = await popup(browser, { items: [item('Work', 'Alice')] })
        const deferred = view.deferRead()
        const pending = view.api.render()
        await deferred.ready
        await view.elements.lockNowButton.listeners.click()
        deferred.release()
        await pending
        assert.equal(view.document.body.dataset.panel, 'unlock')
        assert.equal(view.elements.items.children.length, 0)
        assert.equal(view.elements.suggestions.children.length, 0)
        assert.equal(view.elements.navigation.hidden, true)
    })

    test(`Popup ${browser}: legacy authentication expiry clears the old vault binding`, async () => {
        const view = await popup(browser, { userId: null })
        delete view.storage['relay.session'].userId
        view.storage['relay.session'].expiresAt = Date.now() - 1
        await view.api.render()
        assert.equal(view.document.body.dataset.panel, 'login')
        assert.equal(view.storage['relay.vault'], undefined)
    })

    test(`Popup ${browser}: sign out removes local authentication before remote revoke`, async () => {
        const view = await popup(browser)
        await view.elements.lockButton.listeners.click()
        assert.equal(view.document.body.dataset.panel, 'login')
        assert.equal(view.storage['relay.session'], undefined)
        assert.equal(view.storage['relay.vault'], undefined)
        assert.equal(view.elements.vaultName.textContent, '')
        assert.equal(view.snapshot, null)
        assert.deepEqual(view.cacheCalls.filter(call => call.action === 'removeAccount'),
            [{ action: 'removeAccount', userId: 'synthetic-user' }])
        assert.ok(view.events.indexOf('removeAuth') < view.events.indexOf('removeAccount'))
        assert.ok(view.events.indexOf('removeAccount') < view.events.indexOf('revoke'))
    })
}

const editableItem = () => ({
    id: '12345678-abcd-1234-abcd-123456789abc', title: 'Work', host: 'example.com', symbol: 'key',
    notes: 'private notes\r\nsecond line',
    fields: [
        { name: 'User', type: 'login', value: 'Alice', autofill: 'username' },
        { name: 'Password', type: 'password', value: 'p\r\na\rss', autofill: 'current-password' },
        { name: 'PIN', type: 'pin', value: '1234', autofill: 'off' },
        { name: 'Secret', type: 'secret', value: 'secret', autofill: 'off' },
        { name: 'OTP', type: 'one_time_password', value: 'seed', autofill: 'off' },
    ],
    source: { xml: '<synthetic-original/>', revision: 3 },
})
const detailControl = (view, index) => view.elements.detailContent.children[index].children[1].children[0]
const deferredOperation = () => {
    let release, started
    const promise = new Promise(resolve => { release = resolve })
    const ready = new Promise(resolve => { started = resolve })
    return { ready, release, async wait() { started(); return await promise } }
}

for (const browser of browsers) {
    test(`Popup ${browser}: details show every field, explicit reveal only, legacy is view-only`, async () => {
        const entry = editableItem()
        const view = await popup(browser, { items: [entry] })
        await view.api.openItemDetail(entry.id)
        assert.equal(view.document.body.dataset.panel, 'detail')
        assert.equal(view.elements.detailContent.children.length, entry.fields.length + 2)
        assert.equal(detailControl(view, 0).value, 'Work')
        for (const index of [2, 3, 4, 5]) {
            const input = detailControl(view, index)
            assert.equal(input.type, 'password')
            const toggle = view.elements.detailContent.children[index].children[1].children[1]
            toggle.listeners.click()
            assert.equal(input.type, 'text')
            toggle.listeners.click()
            assert.equal(input.type, 'password')
        }
        assert.equal(detailControl(view, 6).readOnly, true)
        await view.api.openItemDetail(entry.id, true)
        assert.equal(detailControl(view, 2).type, 'password')
        detailControl(view, 0).value = 'Discard me'
        await view.elements.detailCancelButton.listeners.click()
        assert.equal(detailControl(view, 0).value, 'Work')
        assert.equal(view.saves.length, 0)
        const legacy = item('Legacy', 'Alice')
        const old = await popup(browser, { items: [legacy] })
        await old.api.openItemDetail(legacy.id)
        assert.equal(old.elements.detailEditButton.disabled, true)
        assert.equal(old.elements.detailLegacyNote.hidden, false)
        const unsupported = await popup(browser, { items: [entry], hooks: { detail() { throw new Error('unsupported') } } })
        await unsupported.api.openItemDetail(entry.id)
        assert.equal(unsupported.elements.detailEditButton.disabled, true)
    })

    test(`Popup ${browser}: polling keeps draft; save requires password and preserves untouched normalized values`, async () => {
        const entry = editableItem()
        const view = await popup(browser, { items: [entry] })
        await view.api.openItemDetail(entry.id, true)
        const title = detailControl(view, 0)
        title.value = 'Changed'
        await view.api.render()
        assert.equal(detailControl(view, 0), title)
        assert.equal(title.value, 'Changed')
        await view.api.saveItemDetail()
        assert.equal(view.saves.length, 0)
        view.elements.detailMasterPassword.value = 'synthetic-password'
        await view.api.saveItemDetail()
        assert.equal(view.saves.length, 1)
        assert.equal(view.saves[0].item.revision, 3)
        assert.equal(view.saves[0].item.bodyB64, 'encrypted-body')
        assert.equal(view.edits[0].fieldValues[1], entry.fields[1].value)
        assert.equal(view.edits[0].notes, entry.notes)
        assert.equal(detailControl(view, 0).value, 'Changed')
        assert.equal(detailControl(view, 0).readOnly, true)
        assert.equal(view.elements.detailMasterPassword.value, '')
        assert.ok(view.keys.every(key => key.every(byte => byte === 0)))
        const replacement = view.commands.find(command => command.action === 'replace')
        assert.equal(replacement.generation, 'g1')
        assert.equal(replacement.item.source.revision, 4)
        assert.equal(replacement.context.vaultId, 'synthetic-vault')
        assert.equal(replacement.context.userId, 'synthetic-user')
        assert.equal(replacement.expectedSnapshotVersion, 1)
        assert.equal(replacement.snapshotVersion, 2)
        assert.equal(view.snapshot.version, 2)
        assert.equal(view.snapshot.rows[0].revision, 4)
        assert.equal(view.state.snapshotVersion, 2)
        assert.equal(Object.keys(view.storage).some(key => /draft/i.test(key)), false)
    })

    for (const code of ['item_conflict', 'item_deleted']) {
        test(`Popup ${browser}: ${code} never retries or replaces session`, async () => {
            const entry = editableItem()
            const view = await popup(browser, { items: [entry], hooks: {
                save() { throw Object.assign(new Error('conflict'), { code }) },
            } })
            await view.api.openItemDetail(entry.id, true)
            view.elements.detailMasterPassword.value = 'synthetic-password'
            await view.api.saveItemDetail()
            assert.equal(view.saves.length, 1)
            assert.equal(view.commands.some(command => command.action === 'replace'), false)
            assert.match(view.elements.status.textContent, /Nothing was overwritten/)
            assert.ok(view.keys.every(key => key.every(byte => byte === 0)))
            assert.equal(view.elements.detailMasterPassword.value, '')
        })
    }

    test(`Popup ${browser}: wrong password, changed revision and rotated envelope block cloud writes`, async () => {
        const entry = editableItem()
        for (const mode of ['password', 'revision', 'envelope']) {
            let envelopes = 0
            const view = await popup(browser, { items: [entry], hooks: {
                unwrap() { if (mode === 'password') throw new VaultCryptoError('unwrap_failed') },
                envelope: async () => ({ envelope: mode === 'envelope' && ++envelopes > 1 ? 'rotated' : 'synthetic',
                    meta: { passwordVersion: 1 } }),
            } })
            await view.api.openItemDetail(entry.id, true)
            if (mode === 'revision') view.setState({ unlocked: true, generation: 'g1', items: [{ ...entry, source: { ...entry.source, revision: 4 } }] })
            view.elements.detailMasterPassword.value = 'synthetic-password'
            await view.api.saveItemDetail()
            assert.equal(view.saves.length, 0, mode)
            assert.equal(view.elements.detailMasterPassword.value, '')
            assert.ok(view.keys.every(key => key.every(byte => byte === 0)))
        }
    })

    for (const stage of ['unwrap', 'save']) {
        test(`Popup ${browser}: lock during ${stage} clears every control and cannot resurrect details`, async () => {
            const entry = editableItem()
            const deferred = deferredOperation()
            const hooks = stage === 'unwrap'
                ? { unwrap: () => deferred.wait(), confirm: () => false }
                : { save: async () => { await deferred.wait(); return { revision: 4 } }, confirm: () => false }
            const view = await popup(browser, { items: [entry], hooks })
            await view.api.openItemDetail(entry.id, true)
            const controls = view.elements.detailContent.children.map((_, i) => detailControl(view, i))
            view.elements.detailMasterPassword.value = 'synthetic-password'
            const pending = view.api.saveItemDetail()
            await deferred.ready
            assert.equal(view.elements.detailMasterPassword.value, '')
            assert.ok(controls.every(control => control.readOnly))
            await view.elements.lockNowButton.listeners.click()
            deferred.release()
            await pending
            assert.equal(view.document.body.dataset.panel, 'unlock')
            assert.equal(view.elements.detailBox.hidden, true)
            assert.equal(view.elements.detailContent.children.length, 0)
            assert.ok(controls.every(control => control.value === '' && control.originalValue === ''))
            assert.equal(view.commands.some(command => command.action === 'replace'), false)
            assert.equal(view.saves.length, stage === 'save' ? 1 : 0)
            assert.ok(view.keys.every(key => key.every(byte => byte === 0)))
        })
    }

    test(`Popup ${browser}: source-aware unlock checks row ID and keeps revision per active card`, async () => {
        const entry = editableItem()
        const view = await popup(browser, { unlocked: false, hooks: {
            rows: async () => [{ uuid: entry.id.toUpperCase(), revision: 8, kind: 1, bodyB64: '' }],
            decrypt: async () => '<card/>', parse: () => [entry],
        } })
        view.elements.masterPassword.value = 'synthetic-password'
        await view.api.unlock()
        const commit = view.commands.find(command => command.action === 'commit')
        assert.equal(commit.items.length, 1)
        assert.equal(commit.items[0].source.revision, 8)
        assert.equal(commit.items[0].source.xml, '<card/>')
    })

    test(`Popup ${browser}: failed fill preconditions always give visible feedback`, async () => {
        const entry = editableItem()
        const view = await popup(browser, { items: [entry] })
        await view.api.fill({ item: { ...entry, host: 'different.example' } }, element())
        assert.equal(view.elements.status.className, 'error')
        assert.match(view.elements.status.textContent, /页面不可填充|cannot be filled/)

        view.setState({ items: [] })
        await view.api.fill({ item: entry }, element())
        assert.equal(view.elements.status.className, 'error')
        assert.match(view.elements.status.textContent, /条目已变化|item changed/)
    })

    test(`Popup ${browser}: site banner quick fill resolves matches from the unlocked session, not rendered filters`, async () => {
        const entry = editableItem()
        const view = await popup(browser, { items: [entry] })
        view.elements.searchItems.value = 'no match'
        await view.api.quickFillCurrentSite()
        await new Promise(setImmediate)
        assert.equal(view.fills.length, 1)
        assert.equal(view.fills[0].candidate.item.id, entry.id)
        assert.equal(view.fills[0].candidate.username, 'Alice')
    })

    test(`Popup ${browser}: matching row waits for fill success before closing`, async () => {
        const entry = editableItem()
        let finishFill
        const pendingFill = new Promise(resolve => { finishFill = resolve })
        const view = await popup(browser, { items: [entry], hooks: {
            fillResponse: () => pendingFill,
        } })
        let closes = 0
        view.window.close = () => { closes += 1 }
        const row = view.elements.items.children.find(row => row.dataset.itemId === entry.id)
        assert.ok(row)
        row.children[0].listeners.click()
        await new Promise(setImmediate)
        assert.equal(view.fills.length, 1)
        assert.equal(view.fills[0].candidate.item.id, entry.id)
        assert.equal(closes, 0, 'wait for the page to acknowledge filling')
        finishFill({ type: 'filled', ok: true })
        await new Promise(setImmediate)
        assert.equal(closes, 1)
    })

    test(`Popup ${browser}: matching row reports missing forms without closing`, async () => {
        const view = await popup(browser, { items: [editableItem()], hooks: {
            fillResponse: async () => ({ type: 'filled', ok: false }),
        } })
        let closes = 0
        view.window.close = () => { closes += 1 }
        view.elements.items.children[0].children[0].listeners.click()
        await new Promise(setImmediate)
        assert.equal(closes, 0)
        assert.equal(view.elements.status.className, 'error')
        assert.match(view.elements.status.textContent, /No fillable login form/)
    })

    test(`Popup ${browser}: fill sends only selected credentials with exact origin and no raw XML`, async () => {
        const entry = editableItem()
        const view = await popup(browser, { items: [entry] })
        await view.api.fill({ item: entry }, element())
        const message = view.fills[0]
        assert.equal(message.expectedOrigin, 'https://example.com')
        assert.deepEqual(Object.keys(message.candidate.item).sort(), ['autofillEnabled', 'fields', 'host', 'id', 'symbol', 'title'])
        assert.equal(message.candidate.item.fields.length, 2)
        assert.equal(message.candidate.item.fields[0].autofill, 'username')
        assert.equal(JSON.stringify(message).includes('private notes'), false)
        assert.equal(JSON.stringify(message).includes('synthetic-original'), false)
        const internal = await popup(browser, { items: [entry], url: 'chrome://example.com' })
        await internal.api.fill({ item: entry }, element())
        assert.equal(internal.fills.length, 0)
    })

    test(`Popup ${browser}: registration profile fills only with an enabled current session item`, async () => {
        const profile = { ...editableItem(), host: '', recordType: 'userProfile',
            autofillEnabled: true, fields: [
                { name: 'Email', type: 'email', value: 'test@example.com', autofill: 'email' },
                { name: 'Phone', type: 'phone', value: '5550100', autofill: 'tel' },
                { name: 'Private', type: 'secret', value: 'synthetic-private', autofill: 'off' },
                { name: 'Password', type: 'password', value: 'synthetic-password', autofill: 'current-password' },
                { name: 'Account', type: 'login', value: 'synthetic-account', autofill: 'username' },
            ] }
        const view = await popup(browser, { items: [profile], hooks: { registrationForm: true } })
        assert.equal(view.elements.items.children.length, 1)
        await view.api.fill({ item: profile }, element())
        assert.equal(view.fills.length, 1)
        const message = view.fills[0]
        assert.equal(message.expectedOrigin, 'https://example.com')
        assert.equal(message.candidate.item.fields.length, 2)
        assert.equal(JSON.stringify(message).includes('synthetic-private'), false)
        assert.equal(JSON.stringify(message).includes('synthetic-password'), false)
        assert.equal(JSON.stringify(message).includes('synthetic-account'), false)
        assert.equal(JSON.stringify(message).includes('synthetic-original'), false)
        view.setState({ items: [{ ...profile, autofillEnabled: false }] })
        await view.api.fill({ item: profile }, element())
        assert.equal(view.fills.length, 1, 'fresh disabled flag blocks stale candidate')
        const disabled = await popup(browser, { items: [{ ...profile, autofillEnabled: false }],
            hooks: { registrationForm: true } })
        assert.equal(disabled.elements.items.children.length, 0)
        const login = await popup(browser, { items: [profile] })
        assert.equal(login.elements.items.children.length, 0)
        await login.api.fill({ item: profile }, element())
        assert.equal(login.fills.length, 0)
    })

    test(`Popup ${browser}: delayed detail read and external timeout cannot restore detail DOM`, async () => {
        const entry = editableItem()
        const view = await popup(browser, { items: [entry] })
        const deferred = view.deferRead()
        const pending = view.api.openItemDetail(entry.id)
        await deferred.ready
        await view.elements.lockNowButton.listeners.click()
        deferred.release()
        await pending
        assert.equal(view.elements.detailContent.children.length, 0)
        assert.equal(view.document.body.dataset.panel, 'unlock')
        view.setState({ unlocked: true, items: [entry], generation: 'g2', expiresAt: Date.now() + 60_000 })
        await view.api.render()
        await view.api.openItemDetail(entry.id, true)
        view.setState({ unlocked: false })
        await view.intervals[0]()
        assert.equal(view.elements.detailBox.hidden, true)
        assert.equal(view.elements.detailContent.children.length, 0)
        assert.equal(view.document.body.dataset.panel, 'unlock')
    })
}

for (const browser of browsers) {
    test(`Popup ${browser}: context change before POST aborts and post-save replace failure stays out of detail`, async () => {
        const entry = editableItem()
        let view
        const deferred = deferredOperation()
        view = await popup(browser, { items: [entry], hooks: { unwrap: () => deferred.wait() } })
        await view.api.openItemDetail(entry.id, true)
        view.elements.detailMasterPassword.value = 'synthetic-password'
        const pending = view.api.saveItemDetail()
        await deferred.ready
        view.storage['relay.vault'] = { id: 'different-vault', name: 'Different' }
        deferred.release()
        await pending
        assert.equal(view.saves.length, 0)
        assert.equal(view.elements.detailContent.children.length, 0)
        assert.equal(view.elements.detailBox.hidden, true)
        assert.ok(view.keys.every(key => key.every(byte => byte === 0)))

        const replaced = await popup(browser, { items: [entry], hooks: {
            replace: async () => ({ type: 'vault-session', unlocked: false }),
        } })
        await replaced.api.openItemDetail(entry.id, true)
        replaced.elements.detailMasterPassword.value = 'synthetic-password'
        await replaced.api.saveItemDetail()
        assert.equal(replaced.saves.length, 1)
        assert.equal(replaced.elements.detailContent.children.length, 0)
        assert.equal(replaced.elements.detailBox.hidden, true)
        assert.match(replaced.elements.status.textContent, /Saved to the cloud/)
    })

    test(`Popup ${browser}: ambiguous network result does not claim failure or retry`, async () => {
        const entry = editableItem()
        const view = await popup(browser, { items: [entry], hooks: {
            save() { throw new Error('response lost') },
        } })
        await view.api.openItemDetail(entry.id, true)
        view.elements.detailMasterPassword.value = 'synthetic-password'
        await view.api.saveItemDetail()
        assert.equal(view.saves.length, 1)
        assert.match(view.elements.status.textContent, /Could not confirm the save/)
        assert.equal(view.commands.some(command => command.action === 'replace'), false)
        assert.equal(detailControl(view, 0).readOnly, false)
        assert.equal(view.elements.detailMasterPassword.value, '')
    })
}

async function synchronizeDelta(options, { rows = [], deletedIds = [], rebuilt = false } = {}) {
    await options.validate()
    const current = await options.cache.read(options.scope)
    await options.verifyRows(rows)
    await options.validate()
    const replaced = new Set([...deletedIds, ...rows.map(row => row.uuid)].map(id => id.toLowerCase()))
    const snapshot = await options.cache.commit({ ...current,
        cursor: current.cursor + 1,
        rows: [...(rebuilt ? [] : current.rows.filter(row => !replaced.has(row.uuid.toLowerCase()))), ...rows],
    }, current.version)
    return { snapshot, changedRows: rows, deletedIds, rebuilt, changedCount: rows.length + deletedIds.length }
}

for (const browser of browsers) {
    test(`Popup ${browser}: expired cloud login retains cache and allows local-first offline unlock`, async () => {
        const entry = editableItem()
        const hooks = {
            envelope() { assert.fail('local unlock must not fetch an envelope') },
            sync() { assert.fail('expired login must not start network sync') },
        }
        const view = await popup(browser, { items: [entry], unlocked: false, cached: true, expired: true, hooks })
        const original = view.snapshot
        assert.equal(view.document.body.dataset.panel, 'unlock')
        view.elements.masterPassword.value = 'synthetic-password'
        await view.api.unlock()
        await new Promise(setImmediate)
        assert.equal(view.document.body.dataset.panel, 'items')
        assert.equal(view.state.items[0].source.xml, entry.source.xml)
        assert.equal(view.elements.masterPassword.value, '')
        assert.equal(view.storage['relay.vault'].id, 'synthetic-vault')
        assert.equal(view.storage['relay.session'].userId, 'synthetic-user')
        assert.deepEqual(view.snapshot, original)
        assert.equal(view.envelopeCalls.length, 0)
        assert.equal(view.syncCalls.length, 0)
        const commit = view.commands.find(command => command.action === 'commit')
        assert.equal(commit.context.userId, 'synthetic-user')
        assert.equal(commit.snapshotVersion, 1)
        assert.equal(commit.passwordVersion, 1)
        assert.equal(commit.vaultKey.length, 32)
        assert.ok(view.keys.every(key => key.every(byte => byte === 0)))
        await view.api.fill({ item: entry }, element())
        assert.equal(view.fills.length, 1, 'expired cloud login must not disable offline session fill')
    })

    test(`Popup ${browser}: wrong offline password and cold offline unlock preserve cache and binding`, async () => {
        for (const cached of [true, false]) {
            const view = await popup(browser, { items: [editableItem()], unlocked: false, expired: true, cached,
                hooks: { unwrap() { throw new VaultCryptoError('unwrap_failed') } } })
            const original = view.snapshot
            view.elements.masterPassword.value = 'synthetic-wrong-password'
            await view.api.unlock()
            assert.equal(view.commands.some(command => command.action === 'commit'), false)
            assert.deepEqual(view.snapshot, original)
            assert.ok(view.storage['relay.vault'])
            assert.equal(view.elements.masterPassword.value, '')
            assert.equal(view.elements.unlockButton.disabled, false)
            assert.equal(view.envelopeCalls.length, 0)
            assert.equal(view.document.body.dataset.panel, 'login')
        }
    })

    test(`Popup ${browser}: malformed row identity rejects the entire unlock instead of silently skipping it`, async () => {
        const entry = editableItem()
        const view = await popup(browser, { unlocked: false, hooks: {
            rows: async () => [{ uuid: entry.id, revision: 8, kind: 1, bodyB64: '' },
                { uuid: 'wrong-id', revision: 2, kind: 1, bodyB64: '' }],
            decrypt: async () => '<card/>', parse: () => [entry],
        } })
        view.elements.masterPassword.value = 'synthetic-password'
        await view.api.unlock()
        assert.equal(view.commands.some(command => command.action === 'commit'), false)
        assert.equal(view.snapshot, null)
        assert.equal(view.document.body.dataset.panel, 'unlock')
        assert.match(view.elements.status.textContent, /unreadable cache/)
        assert.ok(view.keys.every(key => key.every(byte => byte === 0)))
    })

    test(`Popup ${browser}: sync applies upserts and deletes without locking or requesting a password`, async () => {
        const entry = editableItem(), other = { ...item('Other', 'Bob'), source: { xml: '<other/>', revision: 1 } }
        const hooks = {}
        const view = await popup(browser, { items: [entry, other], hooks })
        const updated = { ...entry, title: 'Remote change' }
        hooks.decrypt = async () => JSON.stringify(updated)
        const row = { uuid: entry.id.toUpperCase(), kind: 1, revision: 4,
            bodyB64: 'remote-ciphertext', modifiedMs: 2 }
        hooks.sync = options => synchronizeDelta(options, { rows: [row], deletedIds: [other.id] })
        const start = view.commands.length
        await view.elements.refreshButton.listeners.click()
        const commands = view.commands.slice(start)
        assert.equal(view.document.body.dataset.panel, 'items')
        assert.equal(view.state.generation, 'g1')
        assert.equal(view.state.snapshotVersion, 2)
        assert.equal(view.state.items.length, 1)
        assert.equal(view.state.items[0].title, 'Remote change')
        assert.equal(view.state.items[0].source.revision, 4)
        assert.equal(view.state.unlocked, true, 'render after refresh must not discard the published session')
        assert.equal(view.state.passwordVersion, 1)
        assert.equal(view.snapshot.version, 2)
        assert.equal(view.keys.length, 0)
        assert.equal(view.envelopeCalls.length, 0)
        assert.equal(view.saves.length, 0)
        assert.equal(commands.some(command => ['lock', 'begin', 'commit', 'replace'].includes(command.action)), false)
        assert.equal(commands.filter(command => command.action === 'decrypt').length, 1)
        const refresh = commands.find(command => command.action === 'refresh')
        assert.equal(refresh.expectedSnapshotVersion, 1)
        assert.equal(refresh.snapshotVersion, 2)
        assert.equal(refresh.passwordVersion, 1)
        assert.equal(refresh.context.userId, 'synthetic-user')
        assert.equal(Object.hasOwn(view.syncCalls.at(-1), 'password'), false)
        assert.equal(Object.hasOwn(view.syncCalls.at(-1), 'vaultKey'), false)
        assert.match(view.elements.status.textContent, /Synced 2 changes/)
    })

    test(`Popup ${browser}: no-op sync keeps snapshot version and automatic polling is throttled`, async () => {
        const view = await popup(browser, { items: [editableItem()] })
        assert.equal(view.syncCalls.length, 1, 'startup performs one automatic sync')
        const calls = view.syncCalls.length
        await view.intervals[0]()
        await view.api.syncVault(true)
        assert.equal(view.syncCalls.length, calls)
        await view.api.syncVault()
        assert.equal(view.syncCalls.length, calls + 1)
        assert.equal(view.state.snapshotVersion, 1)
        assert.equal(view.snapshot.version, 1)
        assert.equal(view.commands.some(command => command.action === 'refresh'), false)
        assert.match(view.elements.status.textContent, /up to date/)
    })

    test(`Popup ${browser}: failed network or row decryption keeps old unlocked state and encrypted cache`, async () => {
        for (const mode of ['network', 'decrypt']) {
            const entry = editableItem(), hooks = {}
            const view = await popup(browser, { items: [entry], hooks })
            const snapshot = view.snapshot, state = view.state, start = view.commands.length
            hooks.sync = mode === 'network' ? async () => { throw new Error('offline') }
                : options => synchronizeDelta(options, { rows: [{ uuid: entry.id, kind: 1, revision: 4,
                    bodyB64: 'corrupt', modifiedMs: 2 }] })
            hooks.sessionDecrypt = async () => ({ type: 'vault-session', unlocked: false, code: 'item_decrypt_failed' })
            await view.api.syncVault()
            assert.deepEqual(view.snapshot, snapshot, mode)
            assert.deepEqual(view.state, state, mode)
            assert.equal(view.document.body.dataset.panel, 'items', mode)
            assert.equal(view.commands.slice(start).some(command => ['refresh', 'lock'].includes(command.action)), false)
            assert.match(view.elements.status.textContent, /local copy is preserved/)
            assert.equal(view.elements.refreshButton.disabled, false)
        }
    })

    for (const code of ['password_changed', 'rekey_required']) {
        test(`Popup ${browser}: ${code} locks plaintext but retains encrypted cache and login`, async () => {
            const hooks = {}, view = await popup(browser, { items: [editableItem()], hooks })
            const snapshot = view.snapshot
            hooks.sync = async () => { throw Object.assign(new Error(code), { code }) }
            await view.api.syncVault()
            assert.equal(view.state.unlocked, false)
            assert.equal(view.document.body.dataset.panel, 'unlock')
            assert.equal(view.elements.items.children.length, 0)
            assert.equal(view.elements.detailContent.children.length, 0)
            assert.deepEqual(view.snapshot, snapshot)
            assert.ok(view.storage['relay.session'])
            assert.ok(view.storage['relay.vault'])
            assert.match(view.elements.status.textContent, /latest password/)
        })
    }

    test(`Popup ${browser}: 401 expires cloud sign-in but preserves encrypted cache for offline re-unlock`, async () => {
        const hooks = {}, view = await popup(browser, { items: [editableItem()], hooks })
        const snapshot = view.snapshot
        hooks.sync = async () => { throw Object.assign(new Error('unauthorized'), { status: 401 }) }
        await view.api.syncVault()
        assert.equal(view.document.body.dataset.panel, 'login')
        assert.equal(view.state.unlocked, false)
        assert.equal(view.storage['relay.session'].expiresAt, 0)
        assert.equal(view.storage['relay.session'].userId, 'synthetic-user')
        assert.ok(view.storage['relay.vault'])
        assert.deepEqual(view.snapshot, snapshot)
        assert.equal(view.cacheCalls.some(call => call.action === 'removeAccount'), false)
        assert.match(view.elements.status.textContent, /local encrypted copy is preserved/)
        view.elements.masterPassword.value = 'synthetic-password'
        await view.api.unlock()
        await new Promise(setImmediate)
        assert.equal(view.document.body.dataset.panel, 'items')
        assert.equal(view.envelopeCalls.length, 0)
    })

    test(`Popup ${browser}: delayed 401 cannot expire a newly selected account with the same token`, async () => {
        const hooks = {}, view = await popup(browser, { items: [editableItem()], hooks })
        const deferred = deferredOperation()
        hooks.sync = async () => {
            await deferred.wait()
            throw Object.assign(new Error('old request unauthorized'), { status: 401 })
        }
        const start = view.commands.length
        const pending = view.api.syncVault()
        await deferred.ready
        view.storage['relay.session'] = { ...view.storage['relay.session'], userId: 'new-synthetic-user' }
        const session = structuredClone(view.storage['relay.session'])
        deferred.release()
        await pending
        assert.deepEqual(view.storage['relay.session'], session)
        assert.equal(view.commands.slice(start).some(command => command.action === 'lock'), false)
        assert.ok(view.snapshot)
    })

    test(`Popup ${browser}: cache failure after cloud save closes draft and never resubmits`, async () => {
        const entry = editableItem(), hooks = {}, view = await popup(browser, { items: [entry], hooks })
        const snapshot = view.snapshot
        hooks.cacheCommit = async () => { throw new Error('quota_exceeded') }
        await view.api.openItemDetail(entry.id, true)
        const controls = view.elements.detailContent.children.map((_, i) => detailControl(view, i))
        view.elements.detailMasterPassword.value = 'synthetic-password'
        await view.api.saveItemDetail()
        assert.equal(view.saves.length, 1)
        assert.equal(view.saves[0].item.revision, 3)
        assert.deepEqual(view.snapshot, snapshot)
        assert.equal(view.state.unlocked, false)
        assert.equal(view.document.body.dataset.panel, 'unlock')
        assert.equal(view.elements.detailContent.children.length, 0)
        assert.ok(controls.every(control => control.value === '' && control.originalValue === ''))
        assert.equal(view.commands.some(command => command.action === 'replace'), false)
        assert.match(view.elements.status.textContent, /Saved to the cloud/)
        assert.ok(view.keys.every(key => key.every(byte => byte === 0)))
        await view.api.saveItemDetail()
        assert.equal(view.saves.length, 1, 'uncertain local publication must not repeat a confirmed cloud POST')
    })

    test(`Popup ${browser}: sync is suppressed during editing and cloud save; draft survives polling`, async () => {
        const entry = editableItem(), hooks = {}, view = await popup(browser, { items: [entry], hooks })
        await view.api.openItemDetail(entry.id, true)
        const title = detailControl(view, 0)
        title.value = 'Unsaved draft'
        const calls = view.syncCalls.length
        await view.api.syncVault()
        await view.api.syncVault(true)
        await view.intervals[0]()
        assert.equal(view.syncCalls.length, calls)
        assert.equal(detailControl(view, 0), title)
        assert.equal(title.value, 'Unsaved draft')
        const deferred = deferredOperation()
        hooks.save = async () => { await deferred.wait(); return { revision: 4 } }
        view.elements.detailMasterPassword.value = 'synthetic-password'
        const pending = view.api.saveItemDetail()
        await deferred.ready
        await view.api.syncVault()
        assert.equal(view.syncCalls.length, calls)
        deferred.release()
        await pending
        assert.equal(view.state.items[0].title, 'Unsaved draft')
        assert.equal(view.state.snapshotVersion, 2)
    })

    test(`Popup ${browser}: active sync blocks edit entry, then permits editing the refreshed snapshot`, async () => {
        const entry = editableItem(), hooks = {}, view = await popup(browser, { items: [entry], hooks })
        const deferred = deferredOperation()
        hooks.sync = async options => {
            await deferred.wait()
            return await synchronizeDelta(options)
        }
        const pending = view.api.syncVault()
        await deferred.ready
        await view.api.openItemDetail(entry.id, true)
        assert.equal(view.document.body.dataset.panel, 'items')
        assert.equal(view.elements.detailContent.children.length, 0)
        assert.equal(view.elements.refreshButton.disabled, true)
        const calls = view.syncCalls.length
        await view.api.syncVault()
        assert.equal(view.syncCalls.length, calls, 'only one sync may be active')
        deferred.release()
        await pending
        await view.api.openItemDetail(entry.id, true)
        assert.equal(view.document.body.dataset.panel, 'detail')
        assert.equal(detailControl(view, 0).readOnly, false)
        assert.equal(view.state.snapshotVersion, 2)
    })

    test(`Popup ${browser}: sync completing after manual lock never republishes plaintext`, async () => {
        const entry = editableItem(), hooks = {}, view = await popup(browser, { items: [entry], hooks })
        const deferred = deferredOperation(), snapshot = view.snapshot
        hooks.sync = async options => {
            await deferred.wait()
            return await synchronizeDelta(options)
        }
        const pending = view.api.syncVault()
        await deferred.ready
        await view.elements.lockNowButton.listeners.click()
        deferred.release()
        await pending
        assert.equal(view.state.unlocked, false)
        assert.equal(view.document.body.dataset.panel, 'unlock')
        assert.equal(view.elements.items.children.length, 0)
        assert.deepEqual(view.snapshot, snapshot)
        assert.equal(view.commands.some(command => command.action === 'refresh'), false)
    })

    test(`Popup ${browser}: concurrent session snapshot change rejects sync publication with version CAS`, async () => {
        const hooks = {}, view = await popup(browser, { items: [editableItem()], hooks })
        const deferred = deferredOperation()
        hooks.refresh = async message => {
            assert.equal(message.expectedSnapshotVersion, 1)
            await deferred.wait()
            return { type: 'vault-session', unlocked: false, code: 'session_snapshot_conflict' }
        }
        hooks.sync = options => synchronizeDelta(options)
        const pending = view.api.syncVault()
        await deferred.ready
        view.setState({ snapshotVersion: 3 })
        deferred.release()
        await pending
        assert.equal(view.snapshot.version, 2)
        assert.equal(view.state.unlocked, false)
        assert.equal(view.document.body.dataset.panel, 'unlock')
        assert.equal(view.elements.items.children.length, 0)
        assert.match(view.elements.status.textContent, /Unlock the local copy again/)
    })

    test(`Popup ${browser}: post-commit sync cancellation invalidates only the old generation`, async () => {
        const entry = editableItem(), hooks = {}, view = await popup(browser, { items: [entry], hooks })
        const deferred = deferredOperation()
        hooks.sync = async options => {
            const outcome = await synchronizeDelta(options)
            await deferred.wait()
            return outcome
        }
        const pending = view.api.syncVault()
        await deferred.ready
        await view.elements.lockNowButton.listeners.click()
        view.setState({ unlocked: true, generation: 'new-generation', items: [entry],
            snapshotVersion: 2, passwordVersion: 1, expiresAt: Date.now() + 60_000 })
        await view.api.render()
        deferred.release()
        await pending
        assert.equal(view.state.unlocked, true)
        assert.equal(view.state.generation, 'new-generation')
        assert.equal(view.document.body.dataset.panel, 'items')
        const conditional = view.commands.filter(command => command.action === 'lock' && command.generation)
        assert.ok(conditional.some(command => command.generation === 'g1'))
        assert.equal(conditional.some(command => command.generation === 'new-generation'), false)
    })

    test(`Popup ${browser}: local unlock publishes before online sync completes and a failed sync cannot undo it`, async () => {
        const entry = editableItem(), deferred = deferredOperation()
        const view = await popup(browser, { items: [entry], unlocked: false, cached: true, hooks: {
            envelope() { assert.fail('a valid local envelope must be used first') },
            sync: async () => { await deferred.wait(); throw new Error('offline') },
        } })
        view.elements.masterPassword.value = 'synthetic-password'
        await view.api.unlock()
        await deferred.ready
        assert.equal(view.document.body.dataset.panel, 'items')
        assert.equal(view.state.unlocked, true)
        assert.equal(view.state.items[0].source.revision, 3)
        assert.equal(view.envelopeCalls.length, 0)
        assert.ok(view.keys.every(key => key.every(byte => byte === 0)))
        const snapshot = view.snapshot
        deferred.release()
        await new Promise(setImmediate)
        assert.equal(view.document.body.dataset.panel, 'items')
        assert.equal(view.state.unlocked, true)
        assert.deepEqual(view.snapshot, snapshot)
        assert.match(view.elements.status.textContent, /local copy is preserved/)
    })

    test(`Popup ${browser}: edit 401 closes plaintext but retains account cache and does not retry POST`, async () => {
        const entry = editableItem()
        const view = await popup(browser, { items: [entry], hooks: {
            save() { throw Object.assign(new Error('unauthorized'), { status: 401 }) },
        } })
        const snapshot = view.snapshot
        await view.api.openItemDetail(entry.id, true)
        const title = detailControl(view, 0)
        view.elements.detailMasterPassword.value = 'synthetic-password'
        await view.api.saveItemDetail()
        assert.equal(view.saves.length, 1)
        assert.equal(view.document.body.dataset.panel, 'login')
        assert.equal(view.state.unlocked, false)
        assert.equal(title.value, '')
        assert.equal(title.originalValue, '')
        assert.equal(view.elements.detailContent.children.length, 0)
        assert.equal(view.storage['relay.session'].expiresAt, 0)
        assert.equal(view.storage['relay.session'].userId, 'synthetic-user')
        assert.ok(view.storage['relay.vault'])
        assert.deepEqual(view.snapshot, snapshot)
        assert.equal(view.commands.some(command => command.action === 'replace'), false)
        assert.match(view.elements.status.textContent, /local copy is preserved/)
        assert.ok(view.keys.every(key => key.every(byte => byte === 0)))
        await view.api.saveItemDetail()
        assert.equal(view.saves.length, 1)
    })

    test(`Popup ${browser}: concurrent cache writer after confirmed save fails CAS without overwriting or resubmitting`, async () => {
        const entry = editableItem(), hooks = {}, deferred = deferredOperation()
        const view = await popup(browser, { items: [entry], hooks })
        hooks.save = async () => { await deferred.wait(); return { revision: 4 } }
        await view.api.openItemDetail(entry.id, true)
        view.elements.detailMasterPassword.value = 'synthetic-password'
        const pending = view.api.saveItemDetail()
        await deferred.ready
        const concurrent = await view.cache.commit({ ...view.snapshot, cursor: 8 }, 1)
        deferred.release()
        await pending
        assert.equal(view.saves.length, 1)
        assert.deepEqual(view.snapshot, concurrent)
        assert.equal(view.snapshot.rows[0].revision, 3)
        assert.equal(view.state.unlocked, false)
        assert.equal(view.elements.detailContent.children.length, 0)
        assert.equal(view.commands.some(command => command.action === 'replace'), false)
        assert.match(view.elements.status.textContent, /Saved to the cloud/)
        await view.api.saveItemDetail()
        assert.equal(view.saves.length, 1)
    })

    test(`Popup ${browser}: stale post-save replace CAS never overwrites another session snapshot`, async () => {
        const entry = editableItem(), hooks = {}, deferred = deferredOperation()
        const view = await popup(browser, { items: [entry], hooks })
        hooks.cacheCommit = () => deferred.wait()
        await view.api.openItemDetail(entry.id, true)
        view.elements.detailMasterPassword.value = 'synthetic-password'
        const pending = view.api.saveItemDetail()
        await deferred.ready
        view.setState({ snapshotVersion: 3 })
        deferred.release()
        await pending
        assert.equal(view.saves.length, 1)
        assert.equal(view.snapshot.version, 2)
        const replace = view.commands.find(command => command.action === 'replace')
        assert.equal(replace.expectedSnapshotVersion, 1)
        assert.equal(replace.snapshotVersion, 2)
        assert.equal(view.state.unlocked, false)
        assert.equal(view.elements.detailContent.children.length, 0)
        assert.match(view.elements.status.textContent, /Saved to the cloud/)
    })

    test(`Popup ${browser}: failed account cache removal keeps sign-out fail-closed and never revokes first`, async () => {
        const view = await popup(browser, { items: [editableItem()], hooks: {
            removeAccount() { throw new Error('storage unavailable') },
        } })
        const snapshot = view.snapshot
        await view.elements.lockButton.listeners.click()
        assert.equal(view.state.unlocked, false)
        assert.equal(view.storage['relay.session'], undefined)
        assert.equal(view.storage['relay.vault'], undefined)
        assert.equal(view.document.body.dataset.panel, 'login')
        assert.deepEqual(view.snapshot, snapshot)
        assert.equal(view.events.includes('revoke'), false)
        assert.match(view.elements.status.textContent, /encrypted cache could not be removed/)
    })

    test(`Popup ${browser}: polling during sync cache-to-session publication never locks the old snapshot`, async () => {
        const entry = editableItem(), hooks = {}, view = await popup(browser, { items: [entry], hooks })
        const deferred = deferredOperation()
        hooks.sync = async options => {
            const result = await synchronizeDelta(options)
            await deferred.wait()
            return result
        }
        const start = view.commands.length
        const pending = view.api.syncVault()
        await deferred.ready
        assert.equal(view.snapshot.version, 2)
        assert.equal(view.state.snapshotVersion, 1)
        await view.intervals[0]()
        await view.api.render()
        assert.equal(view.state.unlocked, true)
        assert.equal(view.document.body.dataset.panel, 'items')
        assert.equal(view.commands.slice(start).some(command => command.action === 'lock'), false)
        deferred.release()
        await pending
        assert.equal(view.state.snapshotVersion, 2)
        assert.equal(view.state.unlocked, true)
        assert.equal(view.document.body.dataset.panel, 'items')
    })

    test(`Popup ${browser}: polling during save cache-to-session publication preserves controls and completes replace`, async () => {
        const entry = editableItem(), hooks = {}, view = await popup(browser, { items: [entry], hooks })
        await view.api.openItemDetail(entry.id, true)
        const title = detailControl(view, 0)
        title.value = 'Published edit'
        const deferred = deferredOperation()
        hooks.beforeReplace = () => deferred.wait()
        view.elements.detailMasterPassword.value = 'synthetic-password'
        const saving = view.api.saveItemDetail()
        await deferred.ready
        assert.equal(view.snapshot.version, 2)
        assert.equal(view.state.snapshotVersion, 1)
        await view.intervals[0]()
        assert.equal(detailControl(view, 0), title)
        assert.equal(title.value, 'Published edit')
        assert.equal(view.state.unlocked, true)
        assert.equal(view.commands.some(command => command.action === 'lock'), false)
        deferred.release()
        await saving
        assert.equal(view.state.snapshotVersion, 2)
        assert.equal(view.saves.length, 1)
        assert.equal(view.state.unlocked, true)
        assert.equal(view.elements.detailContent.children.length, entry.fields.length + 2)
        assert.equal(detailControl(view, 0).value, 'Published edit')
        assert.match(view.elements.status.textContent, /Saved encrypted/)
        assert.equal(view.commands.some(command => command.action === 'lock'), false)
    })

    test(`Popup ${browser}: old polling read rechecks session after another publisher advances cache and session`, async () => {
        const entry = editableItem(), view = await popup(browser, { items: [entry] })
        const deferred = view.deferRead()
        const pending = view.api.render()
        await deferred.ready
        await view.cache.commit({ ...view.snapshot, cursor: 9 }, 1)
        view.setState({ snapshotVersion: 2, items: [{ ...entry, title: 'Concurrent publication' }] })
        const start = view.commands.length
        deferred.release()
        await pending
        assert.equal(view.state.unlocked, true)
        assert.equal(view.state.snapshotVersion, 2)
        assert.equal(view.document.body.dataset.panel, 'items')
        assert.equal(view.elements.items.children[0].children[0].children[1].children[0].textContent, 'Concurrent publication')
        assert.equal(view.commands.slice(start).some(command => command.action === 'lock'), false)
        assert.ok(view.commands.slice(start).filter(command => command.action === 'read').length >= 2)
    })

    test(`Popup ${browser}: 401 storage await cannot invalidate a newly selected vault`, async () => {
        const hooks = {}, view = await popup(browser, { items: [editableItem()], hooks })
        const deferred = deferredOperation()
        hooks.sync = async () => {
            hooks.storageGet = async keys => {
                if (keys.includes('relay.session') && keys.includes('relay.vault')) {
                    delete hooks.storageGet
                    await deferred.wait()
                }
            }
            throw Object.assign(new Error('unauthorized'), { status: 401 })
        }
        const start = view.commands.length
        const pending = view.api.syncVault()
        await deferred.ready
        await view.elements.lockNowButton.listeners.click()
        view.storage['relay.vault'] = { id: 'new-vault', name: 'New vault' }
        const session = structuredClone(view.storage['relay.session'])
        const count = view.commands.length
        const status = view.elements.status.textContent
        deferred.release()
        await pending
        assert.equal(view.elements.status.textContent, status, 'stale 401 must not overwrite the new UI status')
        assert.deepEqual(view.storage['relay.session'], session)
        assert.equal(view.storage['relay.vault'].id, 'new-vault')
        assert.equal(view.commands.slice(count).some(command => command.action === 'lock'), false)
        assert.equal(view.commands.slice(start).filter(command => command.action === 'lock').length, 1)
    })

    test(`Popup ${browser}: 401 conditional lock await cannot lock a newly unlocked generation`, async () => {
        const entry = editableItem(), hooks = {}, view = await popup(browser, { items: [entry], hooks })
        const deferred = deferredOperation()
        hooks.beforeLock = message => message.generation === 'g1' ? deferred.wait() : undefined
        hooks.sync = async () => { throw Object.assign(new Error('unauthorized'), { status: 401 }) }
        const pending = view.api.syncVault()
        await deferred.ready
        view.setState({ generation: 'new-unlock', unlocked: true })
        const session = structuredClone(view.storage['relay.session'])
        await view.api.render()
        deferred.release()
        await pending
        assert.equal(view.state.unlocked, true)
        assert.equal(view.state.generation, 'new-unlock')
        assert.deepEqual(view.storage['relay.session'], session)
        assert.equal(view.document.body.dataset.panel, 'items')
        assert.ok(view.commands.some(command => command.action === 'lock' && command.generation === 'g1'))
        assert.equal(view.commands.some(command => command.action === 'lock' && !command.generation), false)
    })

    test(`Popup ${browser}: delayed login verification cannot restore authentication after sign-out`, async () => {
        const deferred = deferredOperation()
        const view = await popup(browser, { hooks: {
            verifyCode: async () => {
                await deferred.wait()
                return { token: 'late-synthetic-token', userId: 'late-synthetic-user', expiresAt: Date.now() + 60_000 }
            },
        } })
        view.elements.email.value = 'synthetic@example.invalid'
        view.elements.code.value = '123456'
        const pending = view.elements.loginButton.listeners.click()
        await deferred.ready
        await view.elements.lockButton.listeners.click()
        deferred.release()
        await pending
        assert.equal(view.storage['relay.session'], undefined)
        assert.equal(view.storage['relay.vault'], undefined)
        assert.equal(view.snapshot, null)
        assert.equal(view.document.body.dataset.panel, 'login')
        assert.equal(view.state.unlocked, false)
        assert.equal(view.elements.loginButton.disabled, false)
    })

    test(`Popup ${browser}: restore rejects mismatched cache or password versions`, async () => {
        for (const mismatch of [{ snapshotVersion: 0 }, { passwordVersion: 2 }]) {
            const view = await popup(browser, { items: [editableItem()] })
            view.setState(mismatch)
            await view.api.render()
            assert.equal(view.state.unlocked, false)
            assert.equal(view.document.body.dataset.panel, 'unlock')
            assert.equal(view.elements.items.children.length, 0)
            assert.ok(view.commands.some(command => command.action === 'lock' && command.generation === 'g1'))
            assert.equal(view.snapshot.version, 1)
        }
    })
}

const settle = () => new Promise(setImmediate)
const newLoginIds = ['newLoginTitle', 'newLoginUsername', 'newLoginPassword', 'newLoginUrl', 'newLoginNotes']
async function draftNewLogin(view) {
    await view.elements.newLoginButton.listeners.click()
    const values = ['Synthetic site', 'synthetic-user', 'synthetic-created-password', 'https://example.com/login', 'synthetic private note']
    newLoginIds.forEach((id, index) => {
        view.elements[id].value = values[index]
        view.elements[id].listeners.input?.({ target: view.elements[id] })
    })
}

for (const browser of browsers) {
    test(`Popup ${browser}: creation requires master password then publishes encrypted row with refresh`, async () => {
        const existing = editableItem()
        const view = await popup(browser, { items: [existing] })
        await draftNewLogin(view)
        await view.api.createNewLogin()
        assert.equal(view.creations.length, 0)
        assert.equal(view.keys.length, 0)
        view.elements.newLoginMasterPassword.value = 'synthetic-password'
        await view.api.createNewLogin()
        assert.equal(view.creations.length, 1)
        const creation = view.creations[0]
        assert.equal(creation.token, 'synthetic-token')
        assert.equal(creation.vaultId, 'synthetic-vault')
        assert.match(creation.item.uuid, /^[0-9a-f-]{36}$/i)
        assert.equal(creation.item.bodyB64, 'encrypted-body')
        assert.equal(Object.hasOwn(creation.item, 'revision'), false)
        assert.equal(JSON.stringify(creation).includes('synthetic-created-password'), false)
        assert.equal(view.snapshot.rows.length, 2)
        assert.equal(view.snapshot.version, 2)
        assert.equal(view.state.items.length, 2)
        assert.equal(view.state.items.find(item => item.id.toLowerCase() === creation.item.uuid.toLowerCase()).source.revision, 1)
        const refresh = view.commands.find(command => command.action === 'refresh')
        assert.equal(refresh.expectedSnapshotVersion, 1)
        assert.equal(refresh.snapshotVersion, 2)
        assert.equal(view.commands.some(command => command.action === 'replace'), false)
        assert.equal(view.elements.newLoginMasterPassword.value, '')
        assert.ok(newLoginIds.every(id => view.elements[id].value === ''))
        assert.ok(view.keys.every(key => key.every(byte => byte === 0)))
        assert.equal(JSON.stringify(view.storage).includes('synthetic-created-password'), false)
        await view.api.createNewLogin()
        assert.equal(view.creations.length, 1)
    })

    test(`Popup ${browser}: ambiguous creation response never retries or auto-resubmits`, async () => {
        const view = await popup(browser, { hooks: { createItem() { throw new Error('synthetic response lost') } } })
        await draftNewLogin(view)
        view.elements.newLoginMasterPassword.value = 'synthetic-password'
        await view.api.createNewLogin()
        assert.equal(view.creations.length, 1)
        assert.equal(view.commands.some(command => ['replace', 'refresh'].includes(command.action)), false)
        assert.equal(view.elements.newLoginMasterPassword.value, '')
        assert.ok(view.keys.every(key => key.every(byte => byte === 0)))
        await view.api.render()
        await view.intervals[0]()
        await view.api.createNewLogin()
        assert.equal(view.creations.length, 1)
        assert.match(view.elements.status.textContent, /confirm|check|sync|password/i)
    })

    test(`Popup ${browser}: lock during creation cannot publish or restore plaintext`, async () => {
        const deferred = deferredOperation()
        const view = await popup(browser, { hooks: { createItem: async () => {
            await deferred.wait()
            return { revision: 1 }
        } } })
        await draftNewLogin(view)
        const controls = newLoginIds.map(id => view.elements[id])
        view.elements.newLoginMasterPassword.value = 'synthetic-password'
        const saving = view.api.createNewLogin()
        await deferred.ready
        assert.equal(view.elements.newLoginMasterPassword.value, '')
        await view.elements.lockNowButton.listeners.click()
        assert.ok(controls.every(control => control.value === ''))
        deferred.release()
        await saving
        assert.equal(view.document.body.dataset.panel, 'unlock')
        assert.equal(view.state.unlocked, false)
        assert.equal(view.elements.newLoginBox.hidden, true)
        assert.ok(controls.every(control => control.value === ''))
        assert.equal(view.commands.some(command => ['replace', 'refresh'].includes(command.action)), false)
        assert.ok(view.keys.every(key => key.every(byte => byte === 0)))
    })

    test(`Popup ${browser}: generation uses selected options, populates new login and clears on lock`, async () => {
        const view = await popup(browser)
        await view.elements.generatorTab.listeners.click()
        view.elements.generatorLength.value = '32'
        for (const id of ['genUppercase', 'genLowercase', 'genSymbols']) view.elements[id].checked = false
        view.elements.genDigits.checked = true
        await view.api.regeneratePassword()
        const generated = view.elements.generatedPassword.value
        assert.match(generated, /^\d{32}$/)
        await view.elements.useGeneratedButton.listeners.click()
        assert.equal(view.document.body.dataset.panel, 'new-login')
        assert.equal(view.elements.newLoginPassword.value, generated)
        assert.equal(JSON.stringify(view.storage).includes(generated), false)
        await view.elements.lockNowButton.listeners.click()
        assert.equal(view.elements.generatedPassword.value, '')
        assert.equal(view.elements.newLoginPassword.value, '')
    })

    test(`Popup ${browser}: copy reads fresh session credentials and never stale rendered values`, async () => {
        const entry = editableItem()
        const view = await popup(browser, { items: [entry] })
        const buttons = view.elements.items.children[0].children[1].children
        const copyPassword = buttons.find(button => /Copy password/i.test(button.textContent))
        const fresh = { ...entry, fields: entry.fields.map(field => field.type === 'password'
            ? { ...field, value: 'synthetic-fresh-password' } : field) }
        view.setState({ items: [fresh] })
        copyPassword.listeners.click()
        await settle()
        assert.deepEqual(view.clipboard, ['synthetic-fresh-password'])
        view.setState({ unlocked: false })
        copyPassword.listeners.click()
        await settle()
        assert.deepEqual(view.clipboard, ['synthetic-fresh-password'])
    })

    test(`Popup ${browser}: delayed copy after lock cannot export secrets`, async () => {
        const entry = editableItem(), view = await popup(browser, { items: [entry] })
        const deferred = view.deferRead()
        const copy = view.api.copyText({ id: entry.id, field: 'password' })
        await deferred.ready
        await view.elements.lockNowButton.listeners.click()
        deferred.release()
        await copy
        assert.equal(view.clipboard.length, 0)
    })

    test(`Popup ${browser}: rejected HTTP confirmation never sends credentials`, async () => {
        const entry = editableItem()
        const view = await popup(browser, { items: [entry], url: 'http://example.com/login', hooks: { confirm: () => false } })
        await view.api.fill({ item: entry }, element())
        assert.equal(view.confirmations.length, 1)
        assert.equal(view.fills.length, 0)
    })

    test(`Popup ${browser}: dirty navigation cancellation retains edit and new-login plaintext only in current view`, async () => {
        const entry = editableItem()
        const view = await popup(browser, { items: [entry], hooks: { confirm: () => false } })
        await view.api.openItemDetail(entry.id, true)
        const title = detailControl(view, 0)
        title.value = 'Synthetic unsaved title'
        title.listeners.input?.({ target: title })
        await view.elements.settingsTab.listeners.click()
        assert.equal(view.document.body.dataset.panel, 'detail')
        assert.equal(title.value, 'Synthetic unsaved title')
        assert.equal(view.saves.length, 0)
        await view.elements.lockNowButton.listeners.click()
        assert.equal(title.value, '')
        const draft = await popup(browser, { hooks: { confirm: () => false } })
        await draftNewLogin(draft)
        await draft.elements.settingsTab.listeners.click()
        assert.equal(draft.document.body.dataset.panel, 'new-login')
        assert.equal(draft.elements.newLoginPassword.value, 'synthetic-created-password')
        assert.equal(draft.creations.length, 0)
    })

    test(`Popup ${browser}: favorites, current site and domain filters exclude secret search`, async () => {
        const entries = [{ ...item('Work', 'Alice'), favorite: true }, item('Personal', 'Bob', 'other.org'),
            { ...item('Child', 'Charlie', 'sub.example.com'), favorite: false }]
        const favorites = renderer(browser, { filter: 'favorites' })
        favorites.render(entries)
        assert.equal(favorites.resultCount.textContent, '1')
        const current = renderer(browser, { filter: 'current' })
        current.render(entries)
        assert.equal(current.resultCount.textContent, '2')
        const domain = renderer(browser, { query: 'OTHER.ORG' })
        domain.render(entries)
        assert.equal(domain.resultCount.textContent, '1')
        const privateEntry = { ...entries[0], notes: 'synthetic-private-search', fields: [...entries[0].fields,
            { type: 'secret', value: 'synthetic-private-search' }, { type: 'pin', value: '91827364' }] }
        for (const query of ['not-searchable', 'synthetic-private-search', '91827364']) {
            const search = renderer(browser, { query })
            search.render([privateEntry])
            assert.equal(search.resultCount.textContent, '0', query)
        }
    })

    test(`Popup ${browser}: switching vault clears all old plaintext and draft controls`, async () => {
        const entry = editableItem(), view = await popup(browser, { items: [entry] })
        await view.api.openItemDetail(entry.id, true)
        const controls = view.elements.detailContent.children.map((_, index) => detailControl(view, index))
        view.storage['relay.vault'] = { id: 'synthetic-other-vault', name: 'Other' }
        await view.api.render()
        assert.ok(controls.every(control => control.value === '' && control.originalValue === ''))
        assert.equal(view.elements.detailContent.children.length, 0)
        assert.equal(view.elements.items.children.length, 0)
        assert.ok(newLoginIds.every(id => view.elements[id].value === ''))
        assert.equal(view.elements.generatedPassword.value, '')
        assert.notEqual(view.document.body.dataset.panel, 'detail')
    })
}

for (const browser of browsers) {
    for (const stage of ['unwrap', 'encrypt']) {
        test(`Popup ${browser}: lock during new-login ${stage} aborts before creation POST`, async () => {
            const deferred = deferredOperation()
            const hooks = stage === 'unwrap' ? { unwrap: () => deferred.wait() }
                : { encrypt: async () => { await deferred.wait(); return new Uint8Array(48) } }
            const view = await popup(browser, { hooks })
            await draftNewLogin(view)
            view.elements.newLoginMasterPassword.value = 'synthetic-password'
            const pending = view.api.createNewLogin()
            await deferred.ready
            await view.elements.lockNowButton.listeners.click()
            deferred.release()
            await pending
            assert.equal(view.creations.length, 0)
            assert.equal(view.state.unlocked, false)
            assert.equal(view.document.body.dataset.panel, 'unlock')
            assert.ok(newLoginIds.every(id => view.elements[id].value === ''))
            assert.ok(view.keys.every(key => key.every(byte => byte === 0)))
        })
    }

    test(`Popup ${browser}: confirmed creation followed by cache failure closes draft without another POST`, async () => {
        const hooks = {}, view = await popup(browser, { hooks })
        await draftNewLogin(view)
        hooks.cacheCommit = () => { throw new Error('synthetic cache failure') }
        view.elements.newLoginMasterPassword.value = 'synthetic-password'
        await view.api.createNewLogin()
        assert.equal(view.creations.length, 1)
        assert.equal(view.state.unlocked, false)
        assert.equal(view.document.body.dataset.panel, 'unlock')
        assert.ok(newLoginIds.every(id => view.elements[id].value === ''))
        assert.equal(view.commands.some(command => ['replace', 'refresh'].includes(command.action)), false)
        await view.api.createNewLogin()
        assert.equal(view.creations.length, 1)
        assert.ok(view.keys.every(key => key.every(byte => byte === 0)))
    })
}

for (const browser of browsers) {
    test(`Popup ${browser}: detail secret copy resolves latest session field and denies stale controls after lock`, async () => {
        const entry = editableItem(), view = await popup(browser, { items: [entry] })
        await view.api.openItemDetail(entry.id)
        const row = view.elements.detailContent.children[3].children[1]
        const copy = row.children.find(button => button.textContent === 'Copy')
        const fresh = { ...entry, fields: entry.fields.map((field, index) => index === 2
            ? { ...field, value: 'synthetic-current-pin' } : field) }
        view.setState({ items: [fresh] })
        copy.listeners.click()
        await settle()
        assert.deepEqual(view.clipboard, ['synthetic-current-pin'])
        await view.elements.lockNowButton.listeners.click()
        copy.listeners.click()
        await settle()
        assert.deepEqual(view.clipboard, ['synthetic-current-pin'])
    })
}

for (const browser of browsers) {
    test(`Popup ${browser}: blank optional credentials and website still require a master password`, async () => {
        const view = await popup(browser)
        await draftNewLogin(view)
        for (const id of ['newLoginUsername', 'newLoginPassword', 'newLoginUrl']) view.elements[id].value = ''
        await view.api.createNewLogin()
        assert.equal(view.creations.length, 0)
        assert.equal(view.keys.length, 0)
        view.elements.newLoginMasterPassword.value = 'synthetic-password'
        await view.api.createNewLogin()
        assert.equal(view.creations.length, 1)
        assert.equal(view.state.items.length, 1)
        assert.equal(credentialsOf(view.state.items[0]).password, '')
        assert.equal(view.elements.newLoginMasterPassword.value, '')
        assert.ok(view.keys.every(key => key.every(byte => byte === 0)))
    })
}

for (const browser of browsers) {
    test(`Popup ${browser}: cancelled vault switch rejects late vault-list response`, async () => {
        const deferred = deferredOperation()
        const view = await popup(browser, { items: [editableItem()], hooks: {
            listVaults: async () => { await deferred.wait(); return [{ vaultId: 'synthetic-other', name: 'Other', itemCount: 1 }] },
        } })
        const switching = view.elements.switchVaultButton.listeners.click()
        await deferred.ready
        await view.elements.cancelVaultSwitchButton.listeners.click()
        assert.equal(view.document.body.dataset.panel, 'unlock')
        deferred.release()
        await switching
        assert.equal(view.document.body.dataset.panel, 'unlock')
        assert.equal(view.elements.vaultBox.hidden, true)
        assert.equal(view.elements.vaultList.children.length, 0)
        assert.equal(view.storage['relay.vault'].id, 'synthetic-vault')
        assert.equal(view.state.unlocked, false)
    })

    test(`Popup ${browser}: remote field reorder blocks old copy control and repaints read-only details`, async () => {
        const entry = editableItem(), view = await popup(browser, { items: [entry] })
        await view.api.openItemDetail(entry.id)
        const oldInput = detailControl(view, 3)
        const oldCopy = view.elements.detailContent.children[3].children[1].children.find(button => button.textContent === 'Copy')
        const reordered = { ...entry, title: 'Remote reorder', fields: [entry.fields[0], entry.fields[1], entry.fields[3], entry.fields[2], entry.fields[4]],
            source: { xml: '<synthetic-reordered/>', revision: 4 } }
        view.setState({ items: [reordered] })
        oldCopy.listeners.click()
        await settle()
        assert.equal(view.clipboard.length, 0)
        await view.api.render()
        assert.equal(oldInput.value, '')
        assert.equal(oldInput.originalValue, '')
        assert.equal(detailControl(view, 0).value, 'Remote reorder')
        assert.equal(detailControl(view, 3).value, entry.fields[3].value)
        await view.api.openItemDetail(entry.id)
        const newCopy = view.elements.detailContent.children[3].children[1].children.find(button => button.textContent === 'Copy')
        newCopy.listeners.click()
        await settle()
        assert.deepEqual(view.clipboard, [entry.fields[3].value])
    })
}
