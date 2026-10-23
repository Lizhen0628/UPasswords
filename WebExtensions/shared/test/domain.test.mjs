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

test('website fields accept full HTTP URLs without matching deceptive origins', () => {
    assert.equal(canonicalizeHost('  HTTPS://WWW.Example.COM:8443/login?q=1  '), 'example.com')
    assert.equal(canonicalizeHost('Example.COM.'), 'example.com')
    assert.equal(hostMatches('login.example.com', 'https://www.example.com/sign-in'), true)
    assert.equal(hostMatches('example.com.evil.org', 'https://example.com'), false)
    assert.equal(hostMatches('example.com', 'https://example.com@evil.org'), false)
    assert.equal(hostMatches('example.com', 'https://example.com/login'), true)
    for (const value of ['ftp://example.com/login', 'javascript://example.com/login']) {
        assert.equal(hostMatches('example.com', value), false)
    }
    for (const value of ['javascript://example.com', 'ftp://example.com', 'example.com/path', 'not a host']) {
        assert.equal(canonicalizeHost(value), '')
    }
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
    assert.equal(isRequestMessage({ type: 'unlock', password: 'x' }), true)
    assert.equal(isRequestMessage({ type: 'pong' }), false, 'responses must not pass as requests')
    assert.equal(isRequestMessage(null), false)
    assert.equal(isRequestMessage('ping'), false)
    assert.equal(isRequestMessage({}), false)
    assert.equal(isRequestMessage({ type: 'site-hint' }), true)
    assert.equal(isRequestMessage({ type: 'open-vault' }), true)
    assert.equal(isRequestMessage({ type: 'vault-opened' }), false)
    assert.equal(isRequestMessage({ type: 'vault-session', action: 'replace' }), true)
    assert.equal(isRequestMessage({ type: 'vault-session', action: 'read' }), true)
    assert.equal(isRequestMessage({ type: 'vault-session', action: 'arbitrary' }), false)
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
    assert.equal(schema.$defs.autofill.enum.length, 20, 'autofill vocabulary has 20 tokens')
    assert.ok(schema.$defs.card, 'card def present')
    assert.equal(schema.$defs.ghost, undefined, 'no tombstone (row store is authoritative)')
    assert.equal(schema.$defs.card.properties.id.type, 'string', 'card id is uuid string')
    assert.equal(schema.$defs.label.properties.id.format, 'uuid', 'label id is uuid')
})

test('Contracts: extension message schema covers all request/response tags', () => {
    const schema = JSON.parse(
        readFileSync(join(here, '../../../Contracts/schemas/extension-message.schema.json'), 'utf8')
    )
    const tag = (branch) => branch.properties.type.const
    const [request, response] = schema.oneOf
    assert.deepEqual(request.oneOf.map(tag).sort(), ['active-location', 'fill', 'location', 'open-vault', 'ping', 'query', 'registration-check', 'site-hint', 'unlock', 'vault-session'])
    assert.deepEqual(response.oneOf.map(tag).sort(), ['active-location', 'error', 'filled', 'items', 'locked', 'noVault', 'pong', 'site-hint', 'unlocked', 'vault-opened', 'vault-session'])
})

test('Contracts: raw XML is trusted-session only and fills require an origin', () => {
    const schema = JSON.parse(readFileSync(join(here, '../../../Contracts/schemas/extension-message.schema.json'), 'utf8'))
    const requests = schema.oneOf[0].oneOf
    const fill = requests.find((branch) => branch.properties.type.const === 'fill')
    const session = requests.find((branch) => branch.properties.type.const === 'vault-session')
    assert.ok(fill.required.includes('expectedOrigin'))
    assert.equal(schema.$defs.item.additionalProperties, false)
    assert.equal(schema.$defs.item.properties.source, undefined)
    assert.equal(schema.$defs.item.properties.notes, undefined)
    assert.ok(schema.$defs.sessionItem.properties.source)
    assert.equal(schema.$defs.sessionItem.properties.favorite.type, 'boolean')
    assert.equal(schema.$defs.item.properties.favorite, undefined, 'favorites must remain trusted-session only')
    assert.equal(session.properties.item.$ref, '#/$defs/sessionItem')
    assert.ok(session.properties.action.enum.includes('replace'))
    const hint = schema.oneOf[1].oneOf.find((branch) => branch.properties.type.const === 'site-hint')
    assert.deepEqual(Object.keys(hint.properties).sort(), ['count', 'profileAvailable', 'type', 'unlocked'])
    assert.equal(hint.additionalProperties, false)
})

test('Contracts: all four browser manifests agree on shared entry points', () => {
    const read = (browser) =>
        JSON.parse(readFileSync(join(here, `../../${browser}/manifest.json`), 'utf8'))
    const safari = read('safari')
    const chrome = read('chrome')
    const edge = read('edge')
    const firefox = read('firefox')
    for (const m of [safari, chrome, edge, firefox]) {
        assert.equal(m.manifest_version, 3)
        // 弹窗必须始终能读当前页地址做站点匹配:无 tabs 权限时
        // tabs.query 不含 url,插件在所有网页都报"此页面不可填充"
        assert.ok(m.permissions.includes('tabs'), 'permissions must include tabs')
        assert.ok(m.permissions.includes('clipboardWrite'), 'explicit copy must work across popup session checks')
        assert.equal(m.permissions.includes('clipboardRead'), false, 'never request clipboard reading')
        assert.ok(m.content_scripts.some((cs) => cs.js.includes('src/content.js')))
        assert.ok(m.action.default_popup.includes('popup.html'))
        // relay 数据通路:各端都要覆盖 relay 域名(Firefox 为可选授予语义)
        assert.ok(
            (m.host_permissions ?? []).some((h) => h.startsWith('https://api.upasswords.com/')),
            'host_permissions must cover the relay API origin'
        )
    }
    assert.equal(safari.background.scripts[0], 'src/background.js')
    // Chromium 系:service worker + module(ES import 生效前提)
    for (const m of [chrome, edge]) {
        assert.equal(m.background.service_worker, 'src/background.js')
        assert.equal(m.background.type, 'module')
    }
    // Firefox:事件页 + module;AMO 上架需要的 gecko id 与最低版本
    assert.equal(firefox.background.scripts[0], 'src/background.js')
    assert.equal(firefox.background.type, 'module')
    assert.ok(firefox.browser_specific_settings.gecko.id)
})

test('hostMatches: single-label and suffix-fragment item hosts never wildcard', () => {
    assert.equal(hostMatches('phish.com', 'com'), false)
    assert.equal(hostMatches('sub.phish.com', 'com'), false)
    assert.equal(hostMatches('1.2.3.4', '2.3.4'), false)
    assert.equal(hostMatches('anything.org', 'org'), false)
    // 全等仍允许(localhost 这类无点 host 的正常用法);正常子域匹配不变
    assert.equal(hostMatches('localhost', 'localhost'), true)
    assert.equal(hostMatches('a.b.com', 'b.com'), true)
    assert.equal(hostMatches('github.com.evil.io', 'github.com'), false)
})
