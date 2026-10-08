// Shared TS core 的精细测试:直接针对 tsc 产物 dist/index.js 运行,
// 覆盖 host 规范化/匹配、凭据抽取、消息守卫、WebCrypto 指纹,
// 以及 Contracts/ 两份 JSON Schema 的结构校验(契约与代码不漂移)。
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'
import {
    canonicalizeHost,
    hostMatches,
    hostnameOf,
    credentialsOf,
    isRequestMessage,
    sha256Hex,
    itemFingerprint,
} from '../dist/index.js'

const here = dirname(fileURLToPath(import.meta.url))

test('hostnameOf parses and lower-cases, tolerates junk', () => {
    assert.equal(hostnameOf('https://User@Example.COM:8443/p?q=1'), 'example.com')
    assert.equal(hostnameOf('ftp://files.example.net/'), 'files.example.net')
    assert.equal(hostnameOf('not a url'), '')
    assert.equal(hostnameOf(''), '')
})

test('canonicalizeHost strips wired prefixes but keeps registrable depth', () => {
    assert.equal(canonicalizeHost('www.example.com'), 'example.com')
    assert.equal(canonicalizeHost('www.example.co.uk'), 'example.co.uk')
    assert.equal(canonicalizeHost('login.accounts.google.com'), 'google.com')
    assert.equal(canonicalizeHost('example.com'), 'example.com')
    assert.equal(canonicalizeHost(''), '')
})

test('hostMatches matches exact, subdomain and cross-subdomain', () => {
    assert.equal(hostMatches('a.example.com', 'example.com'), true)
    assert.equal(hostMatches('example.com', 'a.example.com'), true)
    assert.equal(hostMatches('login.example.com', 'www.example.com'), true)
    assert.equal(hostMatches('example.com', 'other.org'), false)
    assert.equal(hostMatches('', 'example.com'), false)
    assert.equal(hostMatches('example.com', ''), false)
})

test('credentialsOf picks first login/email and password, tolerates gaps', () => {
    const creds = credentialsOf({
        fields: [
            { type: 'email', value: 'u@x.io' },
            { type: 'text', value: 'note' },
            { type: 'password', value: 'secret' },
        ],
    })
    assert.deepEqual(creds, { username: 'u@x.io', password: 'secret' })
    assert.deepEqual(credentialsOf({ fields: [{ type: 'text', value: 'x' }] }), { username: '', password: '' })
})

test('isRequestMessage accepts only tagged shapes', () => {
    assert.equal(isRequestMessage({ type: 'ping' }), true)
    assert.equal(isRequestMessage({ type: 'query', host: 'x.com' }), true)
    assert.equal(isRequestMessage({ type: 'fill', candidate: {} }), true)
    assert.equal(isRequestMessage({ type: 'pong' }), false, 'responses must not pass as requests')
    assert.equal(isRequestMessage(null), false)
    assert.equal(isRequestMessage('ping'), false)
    assert.equal(isRequestMessage({}), false)
})

test('sha256Hex matches FIPS 180-2 vector', async () => {
    assert.equal(
        await sha256Hex('abc'),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
    )
})

test('itemFingerprint is stable and input-sensitive', async () => {
    const base = { id: 1, title: 'GitHub', host: 'github.com' }
    assert.equal(await itemFingerprint(base), await itemFingerprint({ ...base }))
    assert.notEqual(await itemFingerprint(base), await itemFingerprint({ ...base, title: 'GitLab' }))
    assert.notEqual(await itemFingerprint(base), await itemFingerprint({ ...base, id: 2 }))
})

test('Contracts: database schema parses and field vocabulary matches the app', () => {
    const schema = JSON.parse(
        readFileSync(join(here, '../../../Contracts/schemas/upw-database.schema.json'), 'utf8')
    )
    assert.equal(schema.title.includes('UPasswords'), true)
    const fieldType = schema.$defs.fieldType.enum
    assert.deepEqual([...fieldType].sort(), [
        'date', 'email', 'expiry', 'login', 'number', 'one_time_password',
        'password', 'phone', 'pin', 'secret', 'text', 'website',
    ])
    assert.equal(schema.$defs.autofill.enum.length, 9, 'autofill vocabulary has 9 tokens')
    assert.ok(schema.$defs.card, 'card def present')
    assert.ok(schema.$defs.ghost, 'ghost (tombstone) def present')
})

test('Contracts: extension message schema covers all request/response tags', () => {
    const schema = JSON.parse(
        readFileSync(join(here, '../../../Contracts/schemas/extension-message.schema.json'), 'utf8')
    )
    const tag = (branch) => branch.properties.type.const
    const [request, response] = schema.oneOf
    assert.deepEqual(request.oneOf.map(tag).sort(), ['fill', 'ping', 'query'])
    assert.deepEqual(response.oneOf.map(tag).sort(), ['error', 'filled', 'items', 'pong'])
})

test('Contracts: safari and chrome manifests agree on shared entry points', () => {
    const safari = JSON.parse(
        readFileSync(join(here, '../../safari/manifest.json'), 'utf8')
    )
    const chrome = JSON.parse(
        readFileSync(join(here, '../../chrome/manifest.json'), 'utf8')
    )
    for (const m of [safari, chrome]) {
        assert.equal(m.manifest_version, 3)
        assert.ok(m.content_scripts.some((cs) => cs.js.includes('src/content.js')))
        assert.ok(m.action.default_popup.includes('popup.html'))
    }
    assert.equal(safari.background.scripts[0], 'src/background.js')
    assert.equal(chrome.background.service_worker, 'src/background.js')
})
