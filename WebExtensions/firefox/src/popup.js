// Relay authentication stays on disk; unlocked entries live only in the trusted browser session.
import {
    base64ToBytes,
    bytesToBase64,
    canonicalizeHost,
    clearItems,
    createVault,
    createEncryptedCache,
    synchronizeVault,
    projectVaultFragment,
    credentialsOf,
    decryptItemBody,
    encryptItemBody,
    fragmentsToXml,
    getVaultEnvelope,
    hostMatches,
    hostnameOf,
    listVaults,
    parseVaultXml,
    readItemDetail,
    requestCode,
    saveVaultItem,
    revokeOwnSession,
    unwrapEnvelope,
    updateItemXml,
    wrapEnvelope,
    verifyCode,
    VaultCryptoError,
} from "./shared/index.js";

const zh = (navigator.language || "").toLowerCase().startsWith("zh");
const t = (zhText, enText) => (zh ? zhText : enText);

// Firefox keeps network access optional; cached local unlock needs no origin permission.
const RELAY_ORIGIN_PERMISSION = "https://api.upasswords.com/*";
const PERMISSION_DENIED_TEXT = ["需要授权连接同步服务(api.upasswords.com)", "Allow access to api.upasswords.com to continue"];

async function ensureRelayPermission() {
    const has = await browser.permissions.contains({ origins: [RELAY_ORIGIN_PERMISSION] });
    if (has) return true;
    return await browser.permissions.request({ origins: [RELAY_ORIGIN_PERMISSION] }) === true;
}

const SESSION_KEY = "relay.session"; // {token, expiresAt}
const VAULT_KEY = "relay.vault";     // {id, name}
// 登录草稿 {email, code}:弹窗失焦即被浏览器销毁,输入实时落本地、重开回填,
// 登录成功清除——否则"发码后去查邮件、回来发现邮箱被清空"。
const DRAFT_KEY = "relay.loginDraft";

let unlockedItems = null;
let unlockedGeneration = null;
let unlockedExpiresAt = 0;
let unlockedSnapshotVersion = null;
let unlockedPasswordVersion = null;
let syncInFlight = false;
let lastSyncAttempt = 0;
const encryptedCache = createEncryptedCache();
const SYNC_INTERVAL_MS = 60_000;
let sessionPersistent = true;
let operationGeneration = 0;
let lastTouchAt = 0;
let currentView = "vault";
let renderGeneration = 0;
let selectedItemId = null;
let detailGeneration = null;
let detailItem = null;
let detailEditing = false;
let detailSaving = false;
let detailTitleInput = null;
let detailNotesInput = null;
let detailFieldInputs = [];

// 首次两步引导标记:邮箱验证刚通过时,第二页标题带步骤号
let justVerifiedEmail = false;

const hostEl = document.getElementById("host");
const statusEl = document.getElementById("status");
const loginBox = document.getElementById("loginBox");
const unlockBox = document.getElementById("unlockBox");
const itemsEl = document.getElementById("items");
const itemsBox = document.getElementById("itemsBox");
const searchInput = document.getElementById("searchItems");
const resultCount = document.getElementById("resultCount");
const emptyState = document.getElementById("emptyState");
const stateBadge = document.getElementById("stateBadge");
const vaultNameEl = document.getElementById("vaultName");
const footerEl = document.getElementById("footer");
const emailInput = document.getElementById("email");
const codeInput = document.getElementById("code");
const sendCodeButton = document.getElementById("sendCodeButton");
const loginButton = document.getElementById("loginButton");
const passwordInput = document.getElementById("masterPassword");
const unlockButton = document.getElementById("unlockButton");
const refreshButton = document.getElementById("refreshButton");
const lockButton = document.getElementById("lockButton");
const loginStepTitle = document.getElementById("loginStepTitle");
const unlockStepTitle = document.getElementById("unlockStepTitle");
const vaultBox = document.getElementById("vaultBox");
const vaultStepTitle = document.getElementById("vaultStepTitle");
const vaultList = document.getElementById("vaultList");
const createVaultForm = document.getElementById("createVaultForm");
const newVaultName = document.getElementById("newVaultName");
const newVaultPassword = document.getElementById("newVaultPassword");
const newVaultPasswordConfirm = document.getElementById("newVaultPasswordConfirm");
const createVaultButton = document.getElementById("createVaultButton");
const suggestionsEl = document.getElementById("suggestions");
const suggestionSection = document.getElementById("suggestionSection");
const settingsBox = document.getElementById("settingsBox");
const navigation = document.getElementById("navigation");
const vaultTab = document.getElementById("vaultTab");
const settingsTab = document.getElementById("settingsTab");
const lockNowButton = document.getElementById("lockNowButton");
const headerTools = document.getElementById("headerTools");
const lockTimeout = document.getElementById("lockTimeout");
const sessionMode = document.getElementById("sessionMode");
const detailBox = document.getElementById("detailBox");
const detailContent = document.getElementById("detailContent");
const detailBackButton = document.getElementById("detailBackButton");
const detailEditButton = document.getElementById("detailEditButton");
const detailCancelButton = document.getElementById("detailCancelButton");
const detailSaveButton = document.getElementById("detailSaveButton");
const detailSaveSection = document.getElementById("detailSaveSection");
const detailPasswordInput = document.getElementById("detailMasterPassword");
const detailLegacyNote = document.getElementById("detailLegacyNote");
const SETTINGS_KEY = "extension.lockMinutes";
const DEFAULT_LOCK_MINUTES = 15;
const SESSION_CHECK_MS = 15_000;

document.documentElement.lang = zh ? "zh-Hans" : "en";
for (const element of document.querySelectorAll("[data-zh][data-en]")) {
    element.textContent = t(element.dataset.zh, element.dataset.en);
}
searchInput.placeholder = t("搜索密码库", "Search vault");
searchInput.setAttribute("aria-label", searchInput.placeholder);
refreshButton.title = t("增量同步最新条目", "Sync the latest changes");

document.getElementById("email").placeholder = t("邮箱", "Email");
codeInput.placeholder = t("验证码", "Code");
sendCodeButton.textContent = t("发送验证码", "Send code");
loginButton.textContent = t("登录", "Sign in");
passwordInput.placeholder = t("主密码", "Master password");
unlockButton.textContent = t("解锁", "Unlock");
refreshButton.textContent = t("重新同步", "Sync again");
lockButton.textContent = t("退出登录", "Sign out");
loginStepTitle.textContent = t("第 1 步 · 验证邮箱", "Step 1 · Verify email");

// 后台消息通道(Safari/Firefox 原生 browser.*)
const RUNTIME_SEND = (message) => browser.runtime.sendMessage(message);

const tabs = await browser.tabs.query({ active: true, currentWindow: true });
const tab = tabs[0];
let pageUrl = tab?.url ?? "";
if (!pageUrl) {
    // 生产清单无 tabs 权限:activeTab 在部分场景不给 tab.url,
    // 回落问后台(content script 登记过的页面地址)
    try {
        const reply = await RUNTIME_SEND({ type: "active-location" });
        pageUrl = reply?.href ?? "";
    } catch { /* 后台未应答按无地址处理 */ }
}
const host = canonicalizeHost(hostnameOf(pageUrl));
// host 行只承载域名;取不到(chrome:// 内部页/新标签页)整行隐藏,
// "此页面不可填充"只由下方状态行说一次——避免两行重复提示
hostEl.textContent = host;
hostEl.hidden = !host;
document.getElementById("siteContext").hidden = !host;

async function storageGet(keys) {
    return await browser.storage.local.get(keys);
}
async function storageSet(entries) {
    await browser.storage.local.set(entries);
}

function show(panel) {
    loginBox.hidden = panel !== "login";
    vaultBox.hidden = panel !== "vault";
    unlockBox.hidden = panel !== "unlock";
    itemsBox.hidden = panel !== "items";
    settingsBox.hidden = panel !== "settings";
    detailBox.hidden = panel !== "detail";
    itemsEl.replaceChildren();
    suggestionsEl.replaceChildren();
    if (panel !== "items") searchInput.value = "";
    document.body.dataset.panel = panel;
    const unlocked = panel === "items" || panel === "settings" || panel === "detail";
    stateBadge.textContent = unlocked ? t("已解锁", "Unlocked") : t("已锁定", "Locked");
    footerEl.hidden = panel === "login";
    navigation.hidden = !unlocked;
    headerTools.hidden = !unlocked;
    refreshButton.hidden = !unlocked;
    vaultTab.setAttribute("aria-current", (panel === "items" || panel === "detail") ? "page" : "false");
    settingsTab.setAttribute("aria-current", panel === "settings" ? "page" : "false");
    if (panel === "login") vaultNameEl.textContent = "";
    console.info("[upw] popup panel:", panel);
}

function status(text, isError) {
    statusEl.textContent = text;
    statusEl.className = isError ? "error" : "muted";
}

// MARK: - 登录(邮箱验证码)

// 重新发送倒计时:冷却内禁用按钮并显示剩余秒(服务端冷却 60s,
// Retry-After 对齐);弹窗被销毁后计时随之消失,误点会收到 429 并重启倒计时
let resendTimer = null;
function startResendCountdown(seconds) {
    let left = Math.max(1, Math.ceil(seconds));
    const stop = () => {
        sendCodeButton.disabled = false;
        sendCodeButton.textContent = t("发送验证码", "Send code");
    };
    const tick = () => {
        if (left <= 0) {
            clearInterval(resendTimer);
            resendTimer = null;
            stop();
            return;
        }
        sendCodeButton.textContent = t(`重发 (${left}s)`, `Resend (${left}s)`);
        sendCodeButton.disabled = true;
        left -= 1;
    };
    clearInterval(resendTimer);
    tick();
    resendTimer = setInterval(tick, 1000);
}

async function sendCode() {
    const email = emailInput.value.trim();
    if (!email.includes("@")) {
        status(t("请输入有效邮箱", "Enter a valid email"), true);
        return;
    }
    sendCodeButton.disabled = true;
    try {
        if (!(await ensureRelayPermission())) {
            sendCodeButton.disabled = false;
            status(t(...PERMISSION_DENIED_TEXT), true);
            return;
        }
        await requestCode(email);
        status(t("验证码已发送,请查收邮箱", "Code sent — check your inbox"));
        startResendCountdown(60);
    } catch (error) {
        if (error?.status === 429) {
            status(t("发送太频繁,请稍后再试", "Too many requests — try later"), true);
            startResendCountdown(error?.retryAfter > 0 ? error.retryAfter : 60);
        } else {
            status(t("验证码发送失败", "Failed to send code"), true);
            sendCodeButton.disabled = false;
        }
    }
}

async function login() {
    if (loginButton.disabled) return;
    const email = emailInput.value.trim();
    const code = codeInput.value.trim();
    if (!email.includes("@") || code.length < 4) {
        status(t("请填写邮箱与验证码", "Email and code required"), true);
        return;
    }
    loginButton.disabled = true;
    let operation = ++operationGeneration;
    const isCurrent = () => operation === operationGeneration;
    try {
        if (!(await ensureRelayPermission())) {
            status(t(...PERMISSION_DENIED_TEXT), true);
            return;
        }
        if (!isCurrent()) return;
        const session = await verifyCode(email, code, "Firefox 扩展", "ext-firefox");
        if (!isCurrent()) return;
        const previous = await storageGet([SESSION_KEY, VAULT_KEY]);
        if (!isCurrent()) return;
        const locking = lockSession();
        operation = operationGeneration;
        await locking;
        if (!isCurrent()) return;
        if (previous[SESSION_KEY]?.userId && previous[SESSION_KEY].userId !== session.userId) {
            await encryptedCache.removeAccount(previous[SESSION_KEY].userId);
            if (!isCurrent()) return;
        }
        if (!session.userId || previous[SESSION_KEY]?.userId !== session.userId) {
            await browser.storage.local.remove(VAULT_KEY);
            if (!isCurrent()) return;
        }
        await storageSet({ [SESSION_KEY]: session });
        if (!isCurrent()) return;
        await storageSet({ [DRAFT_KEY]: { email, code: "" } });
        if (!isCurrent()) return;
        if (previous[SESSION_KEY]?.userId === session.userId && previous[VAULT_KEY]) await render();
        else await showVaultPage(session.token);
    } catch (error) {
        if (!isCurrent()) return;
        status(
            error?.code === "invalid_code"
                ? t("验证码错误", "Wrong code")
                : t("登录失败", "Sign-in failed"),
            true,
        );
    } finally {
        loginButton.disabled = false;
    }
}

// MARK: - 第 2 页:选择/创建密码库

async function showVaultPage(token) {
    const operation = operationGeneration;
    const vaults = await listVaults(token).catch(() => []);
    if (operation !== operationGeneration) return;
    show("vault");
    vaultList.replaceChildren();
    if (vaults.length > 0) {
        vaultStepTitle.textContent = t("第 2 步 · 选择密码库", "Step 2 · Choose vault");
        createVaultForm.hidden = true;
        for (const v of vaults) {
            const row = document.createElement("button");
            row.type = "button";
            row.className = "vault-row";
            const nameEl = document.createElement("span");
            nameEl.textContent = v.name;
            const countEl = document.createElement("span");
            countEl.className = "count";
            countEl.textContent = t(`${v.itemCount} 条条目`, `${v.itemCount} items`);
            row.append(nameEl, countEl);
            row.addEventListener("click", async () => {
                await lockSession();
                await storageSet({ [VAULT_KEY]: { id: v.vaultId, name: v.name } });
                justVerifiedEmail = true;
                await render();
            });
            vaultList.appendChild(row);
        }
        status("");
        return;
    }
    vaultStepTitle.textContent = t("第 2 步 · 创建密码库", "Step 2 · Create vault");
    createVaultForm.hidden = false;
    status(t("该邮箱还没有密码库——创建一座开始使用", "No vault yet — create one to get started"));
}

async function createVaultFromForm() {
    const name = newVaultName.value.trim();
    const password = newVaultPassword.value;
    if (!name) {
        status(t("请输入库名", "Vault name required"), true);
        return;
    }
    if (password.length < 4) {
        status(t("主密码至少 4 位", "Master password needs at least 4 characters"), true);
        return;
    }
    if (password !== newVaultPasswordConfirm.value) {
        status(t("两次输入的主密码不一致", "Master passwords don't match"), true);
        return;
    }
    createVaultButton.disabled = true;
    try {
        const { [SESSION_KEY]: session } = await storageGet([SESSION_KEY]);
        const { envelope, vek } = await wrapEnvelope(password);
        vek.fill(0);
        const vaultId = await createVault(session.token, name, bytesToBase64(envelope));
        await lockSession();
        await storageSet({ [VAULT_KEY]: { id: vaultId, name } });
        newVaultPassword.value = "";
        newVaultPasswordConfirm.value = "";
        justVerifiedEmail = true;
        status("");
        await render();
    } catch (error) {
        status(
            error?.code === "name_exists"
                ? t("同名密码库已存在", "A vault with this name already exists")
                : t("创建失败，请重试", "Creation failed — try again"),
            true,
        );
    } finally {
        createVaultButton.disabled = false;
    }
}

// MARK: - 本地密文解锁与增量同步

function cacheScope(session, vault) {
    if (!session?.userId || !vault?.id) throw new Error("account_identity_missing");
    return { userId: session.userId, vaultId: vault.id };
}

function sessionContext(session, vault) {
    return { vaultId: vault.id, token: session.token, userId: session.userId };
}

function projectFragments(fragments) {
    const items = [];
    for (const fragment of fragments) {
        const item = projectVaultFragment(fragment);
        if (item) items.push(item);
    }
    return items;
}

async function unlock() {
    let password = passwordInput.value;
    if (!password || unlockButton.disabled) return;
    const operation = ++operationGeneration;
    let context;
    let ticketGeneration;
    let vek;
    passwordInput.value = "";
    unlockButton.disabled = true;
    status(t("正在解锁本地密码库…", "Unlocking the local vault…"));
    try {
        const bag = await storageGet([SESSION_KEY, VAULT_KEY]);
        const session = bag[SESSION_KEY];
        const vault = bag[VAULT_KEY];
        if (!session || !vault) { await render(); return; }
        const scope = cacheScope(session, vault);
        context = sessionContext(session, vault);
        const validate = async () => {
            const active = await storageGet([SESSION_KEY, VAULT_KEY]);
            if (operation !== operationGeneration || active[SESSION_KEY]?.token !== session.token
                || active[SESSION_KEY]?.userId !== session.userId || active[VAULT_KEY]?.id !== vault.id) {
                throw new Error("operation_cancelled");
            }
        };
        const ticket = await sessionCommand("begin", {}, context);
        if (!ticket.generation) throw new Error("session_unavailable");
        ticketGeneration = ticket.generation;
        let snapshot = await encryptedCache.read(scope);
        await validate();
        let localUnlocked = false;
        if (snapshot) {
            try {
                vek = await unwrapEnvelope(base64ToBytes(snapshot.envelope), password);
                localUnlocked = true;
            } catch (error) {
                if (!(error instanceof VaultCryptoError)) throw error;
            }
        }
        if (!localUnlocked) {
            if (session.expiresAt <= Date.now()) throw new Error("login_required");
            await requireRelayAccess(true);
            status(t("正在初始化加密缓存…", "Initializing the encrypted cache…"));
            const remote = await getVaultEnvelope(session.token, vault.id);
            await validate();
            if (!remote.envelope) throw new Error("envelope_missing");
            vek = await unwrapEnvelope(base64ToBytes(remote.envelope), password);
            password = "";
            snapshot = (await synchronizeVault({
                token: session.token, scope, cache: encryptedCache,
                keyVersion: remote.meta.passwordVersion, validate,
                verifyRows: async rows => {
                    for (const row of rows) {
                        const xml = await decryptItemBody(base64ToBytes(row.bodyB64), vek, row.uuid);
                        projectVaultFragment({ ...row, xml });
                        await validate();
                    }
                },
            })).snapshot;
        }
        password = "";
        const fragments = [];
        for (const row of snapshot.rows) {
            const xml = await decryptItemBody(base64ToBytes(row.bodyB64), vek, row.uuid);
            await validate();
            fragments.push({ ...row, xml });
        }
        const items = projectFragments(fragments);
        await validate();
        const committed = await sessionCommand("commit", {
            generation: ticket.generation, items, vaultKey: Array.from(vek),
            passwordVersion: snapshot.passwordVersion, snapshotVersion: snapshot.version,
        }, context);
        await validate();
        if (!committed.unlocked) throw new Error("session_unavailable");
        console.info("[upw] local vault unlocked; count:", items.length);
        currentView = "vault";
        await render();
        if (localUnlocked) void syncVault(true);
    } catch (error) {
        if (operation !== operationGeneration) return;
        console.warn("[upw] vault unlock failed; code:", error?.code ?? error?.name);
        if (error?.status === 401) {
            if (await markCloudSessionExpired(context, operation, ticketGeneration)) {
                status(t("云端登录已过期，请重新登录；本地加密副本仍保留。", "Cloud sign-in expired. Sign in again. The encrypted local copy is preserved."), true);
            }
            return;
        }
        if (error instanceof VaultCryptoError) {
            status(t("密码错误或本地缓存无法解密；如他端已改密，请输入最新密码并联网重试。", "Wrong password or unreadable cache. If the password changed elsewhere, connect and enter the latest password."), true);
        } else if (error?.message === "login_required" || error?.message === "account_identity_missing") {
            show("login");
            status(t("请重新登录以初始化或更新密码库", "Sign in again to initialize or update the vault"), true);
        } else {
            status(t("无法解锁。已有加密缓存未被覆盖，请检查网络或重新尝试。", "Could not unlock. The existing encrypted cache was preserved. Check your connection and try again."), true);
        }
    } finally {
        vek?.fill(0);
        password = "";
        if (operation === operationGeneration) {
            passwordInput.value = "";
            unlockButton.disabled = false;
        }
    }
}

async function requireRelayAccess(interactive) {
    // Firefox keeps origin permission optional; automatic work never opens a permission prompt.
    if (typeof ensureRelayPermission !== "undefined") {
        const allowed = interactive ? await ensureRelayPermission()
            : await browser.permissions.contains({ origins: ["https://api.upasswords.com/*"] });
        if (!allowed) throw new Error("relay_permission_required");
    }
}

async function markCloudSessionExpired(context, operation, generation) {
    const bag = await storageGet([SESSION_KEY, VAULT_KEY]);
    const session = bag[SESSION_KEY];
    if (!context || operation !== operationGeneration || session?.token !== context.token
        || session?.userId !== context.userId || bag[VAULT_KEY]?.id !== context.vaultId) return false;
    const result = await sessionCommand("lock", { generation }, context);
    if (operation !== operationGeneration || result.code === "session_generation_mismatch") return false;
    const expiredOperation = ++operationGeneration;
    clearUnlockedView();
    const active = await storageGet([SESSION_KEY, VAULT_KEY]);
    if (expiredOperation !== operationGeneration || active[SESSION_KEY]?.token !== context.token
        || active[VAULT_KEY]?.id !== context.vaultId) return false;
    if (session?.userId) await storageSet({ [SESSION_KEY]: { ...session, expiresAt: 0 } });
    else await browser.storage.local.remove([SESSION_KEY, VAULT_KEY]);
    if (expiredOperation !== operationGeneration) return false;
    unlockButton.disabled = false;
    show("login");
    await restoreDraft();
    return expiredOperation === operationGeneration;
}

async function syncVault(auto = false) {
    if (unlockedItems === null || syncInFlight || detailEditing || detailSaving) return;
    if (auto && Date.now() - lastSyncAttempt < SYNC_INTERVAL_MS) return;
    const operation = operationGeneration;
    const generation = unlockedGeneration;
    const expectedSnapshotVersion = unlockedSnapshotVersion;
    const keyVersion = unlockedPasswordVersion;
    if (!Number.isSafeInteger(expectedSnapshotVersion) || !Number.isSafeInteger(keyVersion)) {
        if (!auto) {
            await lockSession();
            await render();
            status(t("升级后请解锁一次本地密码库", "Unlock the local vault once after the update"));
        }
        return;
    }
    syncInFlight = true;
    lastSyncAttempt = Date.now();
    refreshButton.disabled = true;
    if (!auto) status(t("正在同步变化…", "Syncing changes…"));
    let persisted = false;
    let context;
    let published = false;
    try {
        const bag = await storageGet([SESSION_KEY, VAULT_KEY]);
        const session = bag[SESSION_KEY];
        const vault = bag[VAULT_KEY];
        if (!session?.token || session.expiresAt <= Date.now()) throw new Error("login_required");
        context = sessionContext(session, vault);
        const scope = cacheScope(session, vault);
        const cached = await encryptedCache.read(scope);
        if (!cached || cached.version !== expectedSnapshotVersion) throw new Error("cache_changed");
        await requireRelayAccess(!auto);
        const validate = async () => {
            const active = await storageGet([SESSION_KEY, VAULT_KEY]);
            if (operation !== operationGeneration || generation !== unlockedGeneration
                || detailEditing || detailSaving || active[SESSION_KEY]?.token !== context.token
                || active[SESSION_KEY]?.userId !== scope.userId || active[VAULT_KEY]?.id !== scope.vaultId) {
                throw new Error("operation_cancelled");
            }
            const state = await sessionCommand("read", {}, context);
            if (!state.unlocked || state.generation !== generation
                || state.snapshotVersion !== expectedSnapshotVersion) throw new Error("session_changed");
        };
        const fragments = new Map();
        const outcome = await synchronizeVault({
            token: session.token, scope, cache: encryptedCache, keyVersion, validate,
            verifyRows: async rows => {
                const response = await sessionCommand("decrypt", { generation, rows }, context);
                if (!response.unlocked || !response.fragments) throw new Error(response.code ?? "session_key_missing");
                for (const fragment of response.fragments) {
                    projectVaultFragment(fragment);
                    fragments.set(fragment.uuid.toLowerCase(), fragment);
                }
                await validate();
            },
        });
        persisted = outcome.snapshot.version !== expectedSnapshotVersion;
        await validate();
        let items = outcome.rebuilt ? [] : [...unlockedItems];
        const removed = new Set(outcome.deletedIds.map(id => id.toLowerCase()));
        items = items.filter(item => !removed.has(item.id.toLowerCase()));
        for (const row of outcome.changedRows) {
            const fragment = fragments.get(row.uuid.toLowerCase());
            if (!fragment) throw new Error("missing_verified_fragment");
            items = items.filter(item => item.id.toLowerCase() !== row.uuid.toLowerCase());
            const item = projectVaultFragment(fragment);
            if (item) items.push(item);
        }
        if (persisted) {
            const refreshed = await sessionCommand("refresh", {
                generation, expectedSnapshotVersion, snapshotVersion: outcome.snapshot.version,
                passwordVersion: outcome.snapshot.passwordVersion, items,
            }, context);
            if (!refreshed.unlocked) throw new Error("session_changed");
            if (operation === operationGeneration && generation === unlockedGeneration) {
                unlockedItems = items;
                unlockedSnapshotVersion = outcome.snapshot.version;
                unlockedPasswordVersion = outcome.snapshot.passwordVersion;
            }
        }
        published = true;
        if (operation !== operationGeneration) return;
        if (persisted || !auto) await render();
        if (!auto) status(outcome.changedCount === 0
            ? t("已是最新", "Vault is up to date")
            : t(`已同步 ${outcome.changedCount} 项变化`, `Synced ${outcome.changedCount} changes`));
        console.info("[upw] incremental sync complete; changes:", outcome.changedCount);
    } catch (error) {
        if (operation !== operationGeneration) return;
        console.warn("[upw] sync did not finish; code:", error?.code ?? error?.message ?? error?.name);
        if (error?.status === 401) {
            if (!await markCloudSessionExpired(context, operation, generation)) return;
            status(t("云端登录已过期；本地加密副本仍保留，请重新登录。", "Cloud sign-in expired. Your local encrypted copy is preserved. Sign in again."), true);
        } else if (error?.code === "password_changed" || error?.code === "rekey_required") {
            await lockSession();
            await render();
            status(t("主密码已在其他设备更改，请用最新密码重新解锁。", "The master password changed on another device. Unlock with the latest password."), true);
        } else if (persisted || ["session_key_missing", "cache_changed", "session_changed"].includes(error?.message)) {
            await lockSession();
            await render();
            status(t("加密缓存已更新，请重新解锁本地副本。", "The encrypted cache was updated. Unlock the local copy again."), true);
        } else if (error?.message !== "operation_cancelled") {
            if (error?.message === "login_required" && !auto) {
                show("login");
                await restoreDraft();
            }
            status(error?.message === "login_required"
                ? t("本地密码库可继续使用；云同步需要重新登录。", "The local vault is available. Sign in again for cloud sync.")
                : t("同步未完成，保留本地副本；可离线继续查看。", "Sync did not finish. The local copy is preserved and remains available offline."), true);
        }
    } finally {
        if (persisted && !published) {
            await sessionCommand("lock", { generation }, context).catch(() => {
                console.warn("[upw] stale session invalidation failed");
            });
            if (generation === unlockedGeneration) {
                clearUnlockedView();
                await render();
                status(t("加密缓存已更新，请重新解锁本地副本。", "The encrypted cache was updated. Unlock the local copy again."), true);
            }
        }
        syncInFlight = false;
        refreshButton.disabled = false;
    }
}

// MARK: - 候选与填充

function renderCandidates(items) {
    itemsEl.replaceChildren();
    suggestionsEl.replaceChildren();
    const query = searchInput.value.trim().toLocaleLowerCase();
    const candidates = items
        .map((item) => ({ item, ...credentialsOf(item) }))
        .filter(({ item, username }) => !query
            || item.title.toLocaleLowerCase().includes(query)
            || username.toLocaleLowerCase().includes(query));
    const suggestions = candidates.filter(({ item }) => hostMatches(host, item.host));
    suggestionSection.hidden = suggestions.length === 0;
    resultCount.textContent = String(candidates.length);
    emptyState.hidden = candidates.length > 0;
    document.getElementById("emptyTitle").textContent = query
        ? t("没有搜索结果", "No matching items") : t("密码库暂无条目", "Your vault is empty");
    document.getElementById("emptyDescription").textContent = query
        ? t("试试其他标题或用户名。", "Try another title or username.")
        : t("在 App 中添加条目并同步后，在此重新同步。", "Add items in the app, sync them, then sync again here.");
    for (const candidate of suggestions) appendCandidate(candidate, suggestionsEl);
    for (const candidate of candidates) appendCandidate(candidate, itemsEl);
}

function appendCandidate(candidate, list) {
    const li = document.createElement("li");
    li.className = "item";
    const button = document.createElement("button");
    button.type = "button";
    const canFill = Boolean(host && hostMatches(host, candidate.item.host));
    const avatar = document.createElement("span");
    avatar.className = "item-avatar";
    avatar.setAttribute("aria-hidden", "true");
    avatar.textContent = Array.from(candidate.item.title.trim())[0]?.toLocaleUpperCase() || "U";
    const copy = document.createElement("span");
    copy.className = "item-copy";
    const title = document.createElement("span");
    title.className = "title";
    title.textContent = candidate.item.title || t("未命名条目", "Untitled item");
    const user = document.createElement("span");
    user.className = "user";
    user.textContent = candidate.username || candidate.item.host || t("无用户名", "No username");
    copy.append(title, user);
    button.append(avatar, copy);
    button.addEventListener("click", () => { void openItemDetail(candidate.item.id); });
    li.appendChild(button);
    if (canFill) {
        const fillButton = document.createElement("button");
        fillButton.type = "button";
        fillButton.className = "fill-action";
        fillButton.textContent = t("填充", "Fill");
        fillButton.addEventListener("click", () => { void fill(candidate, li); });
        li.appendChild(fillButton);
    }
    list.appendChild(li);
}

async function fill(candidate, li) {
    if (!tab?.id || !/^https?:\/\//i.test(pageUrl) || !hostMatches(host, candidate.item.host)) return;
    const operation = operationGeneration;
    const generation = unlockedGeneration;
    const isCurrent = () => operation === operationGeneration && generation === unlockedGeneration;
    try {
        const state = await sessionCommand("read");
        if (!isCurrent()) return;
        if (!state.unlocked || state.generation !== unlockedGeneration) {
            await render();
            status(t("密码库已锁定，请重新解锁", "Your vault is locked. Unlock it again."), true);
            return;
        }
        const current = state.items?.find(item => item.id === candidate.item.id);
        if (!current || !hostMatches(host, current.host)) return;
        const touched = await sessionCommand("touch");
        if (!isCurrent()) return;
        if (!touched.unlocked || touched.generation !== unlockedGeneration) {
            await render();
            return;
        }
        unlockedExpiresAt = touched.expiresAt;
        const [activeTab] = await browser.tabs.query({ active: true, currentWindow: true });
        if (!isCurrent()) return;
        if (activeTab?.id !== tab.id || !/^https?:\/\//i.test(activeTab.url ?? "")
            || canonicalizeHost(hostnameOf(activeTab.url ?? "")) !== host) {
            status(t("页面已切换，请重新打开插件", "The page changed. Reopen the extension."), true);
            return;
        }
        const { username, password } = credentialsOf(current);
        const fillItem = {
            id: current.id, title: current.title, symbol: current.symbol, host: current.host,
            fields: [
                { name: "", type: "login", value: username, autofill: "username" },
                { name: "", type: "password", value: password, autofill: "current-password" },
            ],
        };
        const response = await browser.tabs.sendMessage(tab.id, {
            type: "fill", expectedOrigin: new URL(activeTab.url).origin,
            candidate: { item: fillItem, username, password },
        });
        if (!isCurrent()) return;
        if (response && response.ok) {
            const mark = document.createElement("span");
            mark.className = "ok";
            mark.textContent = t(" ✓ 已填充", " ✓ Filled");
            li.querySelector(".ok")?.remove();
            li.appendChild(mark);
            console.info("[upw] popup fill succeeded");
        } else {
            console.warn("[upw] popup fill: no form");
            status(t("页面上没找到登录表单", "No login form found on the page"), true);
        }
    } catch {
        if (!isCurrent()) return;
        console.warn("[upw] popup fill: page unavailable");
        status(t("无法访问该页面", "Can't reach this page"), true);
    }
}

// MARK: - Detail and encrypted editing (drafts exist only in this popup DOM)

function clearDetailView() {
    for (const input of [detailTitleInput, detailNotesInput, ...detailFieldInputs]) {
        if (input) {
            input.value = "";
            input.originalValue = "";
            input.initialValue = "";
        }
    }
    detailPasswordInput.value = "";
    detailContent.replaceChildren();
    detailBox.hidden = true;
    detailSaveSection.hidden = true;
    selectedItemId = null;
    detailGeneration = null;
    detailItem = null;
    detailEditing = false;
    detailSaving = false;
    detailTitleInput = null;
    detailNotesInput = null;
    detailFieldInputs = [];
    detailBackButton.disabled = false;
    detailCancelButton.disabled = false;
    detailSaveButton.disabled = false;
}

function leaveDetailView() {
    if (selectedItemId) {
        operationGeneration += 1;
        console.info("[upw] popup detail closed; draft discarded");
    }
    clearDetailView();
}

function detailInput(labelText, value, editing, secret = false, multiline = false) {
    const group = document.createElement("div");
    group.className = "field";
    const label = document.createElement("label");
    label.textContent = labelText;
    const row = document.createElement("div");
    row.className = "detail-value";
    const input = document.createElement(multiline ? "textarea" : "input");
    input.id = `detailValue${detailContent.children.length}`;
    label.setAttribute("for", input.id);
    if (!multiline) input.type = secret ? "password" : "text";
    input.value = value;
    input.originalValue = value;
    input.initialValue = input.value;
    input.wasEdited = false;
    input.addEventListener("input", () => { input.wasEdited = true; });
    input.readOnly = !editing;
    input.autocomplete = "off";
    input.spellcheck = false;
    row.appendChild(input);
    if (secret) {
        const toggle = document.createElement("button");
        toggle.type = "button";
        toggle.className = "secondary reveal-action";
        toggle.textContent = t("显示", "Show");
        toggle.setAttribute("aria-pressed", "false");
        toggle.addEventListener("click", () => {
            // Never reveal on focus, hover, input, session reads or edit entry.
            input.type = input.type === "password" ? "text" : "password";
            const revealed = input.type === "text";
            toggle.textContent = revealed ? t("隐藏", "Hide") : t("显示", "Show");
            toggle.setAttribute("aria-pressed", String(revealed));
        });
        row.appendChild(toggle);
    }
    group.append(label, row);
    detailContent.appendChild(group);
    return input;
}

function paintItemDetail(item, editing) {
    for (const input of [detailTitleInput, detailNotesInput, ...detailFieldInputs]) {
        if (input) {
            input.value = "";
            input.originalValue = "";
            input.initialValue = "";
        }
    }
    detailContent.replaceChildren();
    detailPasswordInput.value = "";
    detailItem = item;
    detailEditing = editing;
    let notes = item.notes ?? "";
    let editable = Boolean(item.source);
    try {
        notes = readItemDetail(item).notes;
    } catch {
        editable = false;
        console.warn("[upw] detail source unsupported; view only");
    }
    editing = editing && editable;
    detailEditing = editing;
    detailTitleInput = detailInput(t("标题", "Title"), item.title, editing);
    detailFieldInputs = item.fields.map((field, index) => detailInput(
        field.name || t(`字段 ${index + 1}`, `Field ${index + 1}`),
        field.value, editing, ["password", "pin", "secret", "one_time_password"].includes(field.type),
        !["password", "pin", "secret", "one_time_password"].includes(field.type) && /[\r\n]/.test(field.value),
    ));
    detailNotesInput = detailInput(t("备注", "Notes"), notes, editing, false, true);
    detailEditButton.disabled = !editable;
    detailEditButton.hidden = editing;
    detailCancelButton.hidden = !editing;
    detailSaveSection.hidden = !editing;
    detailLegacyNote.hidden = editable;
    show("detail");
}

async function openItemDetail(id, editing = false) {
    if (detailSaving) return;
    const operation = operationGeneration;
    const rendering = ++renderGeneration;
    const generation = unlockedGeneration;
    const isCurrent = () => operation === operationGeneration && rendering === renderGeneration
        && generation === unlockedGeneration;
    try {
        const state = await sessionCommand("read");
        if (!isCurrent()) return;
        if (!state.unlocked || state.generation !== generation) {
            clearUnlockedView();
            await render();
            return;
        }
        const item = state.items?.find(item => item.id === id);
        if (!item) {
            leaveDetailView();
            currentView = "vault";
            await render();
            status(t("条目已更改或删除，请重新同步", "This item changed or was deleted. Sync again."), true);
            return;
        }
        if (editing && (!item.source || syncInFlight)) return;
        selectedItemId = id;
        detailGeneration = generation;
        currentView = "detail";
        paintItemDetail(item, editing);
        status("");
        console.info(editing ? "[upw] popup edit opened" : "[upw] popup detail opened");
    } catch {
        if (!isCurrent()) return;
        clearUnlockedView();
        await render();
        status(t("无法读取解锁会话，请重新解锁", "Unlock session is unavailable. Unlock again."), true);
    }
}

async function saveItemDetail() {
    if (!detailEditing || detailSaving || !detailItem?.source || !selectedItemId) return;
    let password = detailPasswordInput.value;
    detailPasswordInput.value = "";
    if (!password) {
        status(t("保存前请输入主密码", "Enter your master password before saving"), true);
        detailPasswordInput.focus();
        return;
    }
    const original = detailItem;
    const generation = detailGeneration;
    const operation = ++operationGeneration;
    const rendering = ++renderGeneration;
    const startedAt = Date.now();
    const isCurrent = () => operation === operationGeneration && rendering === renderGeneration
        && selectedItemId === original.id && detailGeneration === generation
        && unlockedGeneration === generation && detailEditing;
    // Browser form controls normalize line endings. Preserve exact source bytes until edited.
    const editedValue = input => input.wasEdited || input.value !== input.initialValue
        ? input.value : input.originalValue;
    const edit = {
        title: editedValue(detailTitleInput),
        fieldValues: detailFieldInputs.map(editedValue),
        notes: editedValue(detailNotesInput),
    };
    let vek;
    let cloudSaved = false;
    let published = false;
    let context;
    const expectedSnapshotVersion = unlockedSnapshotVersion;
    detailSaving = true;
    for (const input of [detailTitleInput, ...detailFieldInputs, detailNotesInput]) input.readOnly = true;
    detailSaveButton.disabled = true;
    detailBackButton.disabled = true;
    detailCancelButton.disabled = true;
    console.info("[upw] popup encrypted save started");
    status(t("正在加密并保存到云端…", "Encrypting and saving to the cloud…"));
    try {
        const bag = await storageGet([SESSION_KEY, VAULT_KEY]);
        if (!isCurrent()) return;
        const session = bag[SESSION_KEY];
        const vault = bag[VAULT_KEY];
        if (!session?.token || session.expiresAt <= Date.now() || !vault?.id) {
            throw new Error("session_changed");
        }
        context = sessionContext(session, vault);
        await requireRelayAccess(true);
        const scope = cacheScope(session, vault);
        const cached = await encryptedCache.read(scope);
        if (!cached || cached.version !== expectedSnapshotVersion) throw new Error("session_changed");
        const validate = async () => {
            const active = await storageGet([SESSION_KEY, VAULT_KEY]);
            if (!isCurrent()) throw new Error("operation_cancelled");
            if (active[SESSION_KEY]?.token !== context.token
                || active[SESSION_KEY]?.expiresAt <= Date.now()
                || active[VAULT_KEY]?.id !== context.vaultId) throw new Error("session_changed");
            const state = await sessionCommand("read", {}, context);
            if (!isCurrent()) throw new Error("operation_cancelled");
            if (!state.unlocked || state.generation !== generation
                || state.snapshotVersion !== expectedSnapshotVersion) throw new Error("session_changed");
            const current = state.items?.find(item => item.id === original.id);
            if (!current?.source || current.source.revision !== original.source.revision
                || current.source.xml !== original.source.xml) throw new Error("item_changed");
        };
        await validate();
        if (!isCurrent()) return;
        const envelope = await getVaultEnvelope(context.token, context.vaultId);
        if (!isCurrent()) return;
        if (!envelope.envelope || envelope.meta?.passwordVersion !== cached.passwordVersion) {
            throw new Error("envelope_changed");
        }
        vek = await unwrapEnvelope(base64ToBytes(envelope.envelope), password);
        password = "";
        if (!isCurrent()) return;
        const modifiedMs = Date.now();
        const xml = updateItemXml(original.source.xml, edit, modifiedMs);
        const parsed = parseVaultXml(fragmentsToXml([xml]));
        if (parsed.length !== 1 || parsed[0].id.toLowerCase() !== original.id.toLowerCase()) {
            throw new Error("item_changed");
        }
        const body = await encryptItemBody(xml, vek, original.id);
        if (!isCurrent()) return;
        // Reauthentication and encryption can be slow. Refuse a key rotation before writing.
        const freshEnvelope = await getVaultEnvelope(context.token, context.vaultId);
        if (!isCurrent()) return;
        if (freshEnvelope.envelope !== envelope.envelope
            || freshEnvelope.meta?.passwordVersion !== envelope.meta?.passwordVersion) {
            throw new Error("envelope_changed");
        }
        await validate();
        if (!isCurrent()) return;
        const result = await saveVaultItem(context.token, context.vaultId, {
            uuid: original.id, revision: original.source.revision,
            bodyB64: bytesToBase64(body), modifiedMs,
        });
        cloudSaved = true;
        if (!isCurrent()) return;
        await validate();
        const row = {
            uuid: original.id.toLowerCase(), kind: 1, revision: result.revision,
            bodyB64: bytesToBase64(body), modifiedMs,
        };
        const snapshot = await encryptedCache.commit({
            ...cached,
            rows: [...cached.rows.filter(entry => entry.uuid.toLowerCase() !== row.uuid), row],
        }, cached.version);
        if (!isCurrent()) return;
        const updated = { ...parsed[0], source: { xml, revision: result.revision } };
        const replaced = await sessionCommand("replace", {
            generation, item: updated, expectedSnapshotVersion, snapshotVersion: snapshot.version,
        }, context);
        if (!isCurrent()) return;
        if (!replaced.unlocked || replaced.generation !== generation) throw new Error("session_changed");
        // Also reject context changes occurring while the cloud request was in flight.
        const active = await storageGet([SESSION_KEY, VAULT_KEY]);
        if (!isCurrent()) return;
        if (active[SESSION_KEY]?.token !== context.token || active[VAULT_KEY]?.id !== context.vaultId) {
            throw new Error("session_changed");
        }
        published = true;
        unlockedItems = unlockedItems.map(item => item.id === original.id ? updated : item);
        unlockedSnapshotVersion = snapshot.version;
        unlockedExpiresAt = replaced.expiresAt;
        paintItemDetail(updated, false);
        status(t("已加密保存到云端", "Saved encrypted to the cloud"));
        console.info("[upw] popup encrypted save succeeded; ms:", Date.now() - startedAt);
    } catch (error) {
        if (!isCurrent()) return;
        console.warn("[upw] popup encrypted save failed; code:", error?.code ?? error?.name);
        if (error?.status === 401) {
            if (!await markCloudSessionExpired(context, operation, generation)) return;
            status(t("云端登录已过期，请重新登录；本地加密副本仍保留。", "Cloud sign-in expired. Sign in again. The encrypted local copy is preserved."), true);
        } else if (cloudSaved || error?.message === "session_changed") {
            await sessionCommand("lock", { generation }, context);
            clearUnlockedView();
            await render();
            status(cloudSaved
                ? t("已保存到云端，但解锁会话已改变。请重新解锁同步。", "Saved to the cloud, but the unlock session changed. Unlock and sync again.")
                : t("会话已改变，请重新解锁后再编辑", "The session changed. Unlock again before editing."), true);
        } else if (["item_conflict", "item_deleted"].includes(error?.code) || error?.message === "item_changed") {
            status(t("条目已在其他位置更改或删除，未覆盖。请重新同步后再编辑。", "This item changed or was deleted elsewhere. Nothing was overwritten. Sync again before editing."), true);
        } else if (error?.message === "envelope_changed" || error?.code === "rekey_in_progress") {
            status(t("主密码或密钥已更改，未保存。请重新解锁同步。", "The master password or key changed. Not saved. Unlock and sync again."), true);
        } else if (error instanceof VaultCryptoError) {
            status(t("主密码错误或条目无法安全编辑，未保存", "Wrong master password or this item cannot be edited safely. Not saved."), true);
        } else {
            status(t("无法确认保存结果，请重新同步后检查。", "Could not confirm the save. Sync again and check the item."), true);
        }
    } finally {
        if (cloudSaved && !published) {
            await sessionCommand("lock", { generation }, context).catch(() => {
                console.warn("[upw] saved item session invalidation failed");
            });
            if (generation === unlockedGeneration) {
                clearUnlockedView();
                await render();
                status(t("云端已保存，本地需重新解锁同步；请勿重复提交。", "Saved to the cloud. Unlock and sync the local copy; do not submit again."), true);
            }
        }
        vek?.fill(0);
        password = "";
        edit.title = "";
        edit.notes = "";
        edit.fieldValues.fill("");
        if (operation === operationGeneration && selectedItemId === original.id) {
            detailSaving = false;
            if (detailEditing) {
                for (const input of [detailTitleInput, ...detailFieldInputs, detailNotesInput]) input.readOnly = false;
            }
            detailPasswordInput.value = "";
            detailSaveButton.disabled = false;
            detailBackButton.disabled = false;
            detailCancelButton.disabled = false;
        }
    }
}

detailBackButton.addEventListener("click", async () => {
    leaveDetailView();
    currentView = "vault";
    await render();
});
detailEditButton.addEventListener("click", () => openItemDetail(selectedItemId, true));
detailCancelButton.addEventListener("click", () => {
    console.info("[upw] popup edit cancelled");
    return openItemDetail(selectedItemId);
});
detailSaveButton.addEventListener("click", saveItemDetail);

// MARK: - 状态渲染

async function render() {
    const rendering = ++renderGeneration;
    const operation = operationGeneration;
    const isCurrent = () => rendering === renderGeneration && operation === operationGeneration;
    unlockStepTitle.textContent = justVerifiedEmail
        ? t("第 3 步 · 主密码解锁", "Step 3 · Master password")
        : t("主密码解锁", "Master password");
    justVerifiedEmail = false;
    const { [SESSION_KEY]: session } = await storageGet([SESSION_KEY]);
    if (!isCurrent()) return;
    if (!session) {
        await lockSession();
        show("login");
        status("");
        await restoreDraft();
        return;
    }
    if (session.expiresAt <= Date.now() && !session.userId) {
        await lockSession();
        await browser.storage.local.remove([SESSION_KEY, VAULT_KEY]);
        show("login");
        status(t("登录已过期，请重新登录", "Session expired — sign in again"));
        await restoreDraft();
        return;
    }
    const { [VAULT_KEY]: vault } = await storageGet([VAULT_KEY]);
    if (!isCurrent()) return;
    if (!vault) {
        clearUnlockedView();
        if (session.expiresAt <= Date.now()) {
            show("login");
            status(t("云端登录已过期，请重新登录", "Cloud sign-in expired. Sign in again."), true);
            return;
        }
        // 已验证邮箱但尚未选定密码库(首登第 2 页中途关弹窗):回到选库页
        await showVaultPage(session.token);
        return;
    }
    vaultNameEl.textContent = vault.name;
    await restoreUnlockSession();
    if (!isCurrent()) return;
    if (unlockedItems === null) {
        show("unlock");
        status("");
        passwordInput.focus();
        return;
    }
    if (currentView === "detail" && selectedItemId) {
        const item = unlockedItems.find(item => item.id === selectedItemId);
        if (item && detailGeneration === unlockedGeneration) {
            // Session polling validates access without replacing DOM-backed unsaved edits.
            show("detail");
            return;
        }
        clearDetailView();
        currentView = "vault";
    }
    if (currentView === "settings") {
        show("settings");
        const settings = await storageGet([SETTINGS_KEY]);
        if (!isCurrent()) return;
        lockTimeout.value = String(settings[SETTINGS_KEY] ?? DEFAULT_LOCK_MINUTES);
        sessionMode.textContent = sessionPersistent
            ? t("解锁状态仅保存在浏览器会话内存中。", "Unlock state stays in browser session memory only.")
            : t("此浏览器不支持会话存储；后台休眠后需要重新解锁。", "Session storage is unavailable; background suspension locks the vault.");
    } else {
        show("items");
        renderCandidates(unlockedItems);
        searchInput.focus();
    }
    status("");
}

async function saveDraft() {
    await storageSet({ [DRAFT_KEY]: { email: emailInput.value, code: codeInput.value } });
}
async function restoreDraft() {
    const { [DRAFT_KEY]: draft } = await storageGet([DRAFT_KEY]);
    if (!draft) return;
    if (!emailInput.value && draft.email) emailInput.value = draft.email;
    if (!codeInput.value && draft.code) codeInput.value = draft.code;
}
emailInput.addEventListener("input", () => { void saveDraft(); });
codeInput.addEventListener("input", () => { void saveDraft(); });

searchInput.addEventListener("input", () => {
    status("");
    if (unlockedItems !== null) renderCandidates(unlockedItems);
});
searchInput.addEventListener("keydown", (event) => {
    if (event.key === "Escape") {
        event.preventDefault();
        searchInput.value = "";
        if (unlockedItems !== null) renderCandidates(unlockedItems);
    } else if (event.key === "ArrowDown") {
        event.preventDefault();
        (suggestionsEl.querySelector("button:not(:disabled)") ?? itemsEl.querySelector("button:not(:disabled)"))?.focus();
    } else if (event.key === "Enter") {
        (suggestionsEl.querySelector("button:not(:disabled)") ?? itemsEl.querySelector("button:not(:disabled)"))?.click();
    }
});
itemsBox.addEventListener("keydown", (event) => {
    if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return;
    const buttons = Array.from(itemsBox.querySelectorAll("li button:not(:disabled)"));
    const index = buttons.indexOf(document.activeElement);
    if (index < 0) return;
    event.preventDefault();
    if (event.key === "ArrowUp" && index === 0) {
        searchInput.focus();
    } else {
        buttons[index + (event.key === "ArrowDown" ? 1 : -1)]?.focus();
    }
});

createVaultButton.addEventListener("click", () => { void createVaultFromForm(); });

sendCodeButton.addEventListener("click", sendCode);
loginButton.addEventListener("click", login);
unlockButton.addEventListener("click", unlock);
passwordInput.addEventListener("keydown", (event) => {
    if (event.key === "Enter") unlock();
});
codeInput.addEventListener("keydown", (event) => {
    if (event.key === "Enter") login();
});
refreshButton.addEventListener("click", () => syncVault(false));
lockNowButton.addEventListener("click", async () => {
    await lockSession();
    await render();
});
vaultTab.addEventListener("click", async () => {
    leaveDetailView();
    currentView = "vault";
    await render();
});
settingsTab.addEventListener("click", async () => {
    leaveDetailView();
    currentView = "settings";
    await render();
});
lockTimeout.addEventListener("change", async () => {
    const minutes = Number(lockTimeout.value);
    if (![5, 15, 30, 60].includes(minutes)) return;
    await storageSet({ [SETTINGS_KEY]: minutes });
    const state = await sessionCommand("touch");
    if (!state.unlocked) {
        await render();
        return;
    }
    unlockedExpiresAt = state.expiresAt;
    console.info("[upw] auto-lock minutes:", minutes);
    status(t("自动锁定设置已保存", "Auto-lock setting saved"));
});
lockButton.addEventListener("click", async () => {
    const { [SESSION_KEY]: session } = await storageGet([SESSION_KEY]);
    await lockSession();
    await browser.storage.local.remove([SESSION_KEY, VAULT_KEY]);
    try {
        if (session?.userId) await encryptedCache.removeAccount(session.userId);
    } catch {
        console.warn("[upw] encrypted cache removal failed");
        show("login");
        status(t("已锁定，但本地加密缓存未能删除。请清除扩展存储后再登录。", "Locked, but the encrypted cache could not be removed. Clear extension storage before signing in again."), true);
        return;
    }
    await clearItems();
    const { [DRAFT_KEY]: draft } = await storageGet([DRAFT_KEY]);
    if (draft) await storageSet({ [DRAFT_KEY]: { email: draft.email, code: "" } });
    await render();
    if (session?.token) {
        try { await revokeOwnSession(session.token); }
        catch { console.warn("[upw] remote sign-out failed; local session cleared"); }
    }
});

async function sessionCommand(action, extra = {}, context) {
    if (!context && action !== "lock") {
        const bag = await storageGet([SESSION_KEY, VAULT_KEY]);
        context = { vaultId: bag[VAULT_KEY]?.id, token: bag[SESSION_KEY]?.token, userId: bag[SESSION_KEY]?.userId };
    }
    const response = await RUNTIME_SEND({ type: "vault-session", action, context, ...extra });
    if (response?.type !== "vault-session") throw new Error("session_unavailable");
    return response;
}

function clearUnlockedView() {
    clearDetailView();
    currentView = "vault";
    passwordInput.value = "";
    newVaultPassword.value = "";
    newVaultPasswordConfirm.value = "";
    searchInput.value = "";
    unlockedItems = null;
    unlockedGeneration = null;
    unlockedExpiresAt = 0;
    unlockedSnapshotVersion = null;
    unlockedPasswordVersion = null;
    itemsEl.replaceChildren();
    suggestionsEl.replaceChildren();
}

async function lockSession() {
    operationGeneration += 1;
    unlockButton.disabled = false;
    passwordInput.value = "";
    clearUnlockedView();
    currentView = "vault";
    try {
        await sessionCommand("lock");
    } catch {
        await browser.storage.local.remove(VAULT_KEY);
        console.warn("[upw] session lock unavailable; vault binding removed");
    }
}

async function restoreUnlockSession() {
    const operation = operationGeneration;
    try {
        const state = await sessionCommand("read");
        if (operation !== operationGeneration) return;
        if (!state.unlocked) {
            clearUnlockedView();
            return;
        }
        if (Number.isSafeInteger(state.snapshotVersion)) {
            const bag = await storageGet([SESSION_KEY, VAULT_KEY]);
            if (operation !== operationGeneration) return;
            const cached = await encryptedCache.read(cacheScope(bag[SESSION_KEY], bag[VAULT_KEY]));
            if (operation !== operationGeneration) return;
            if (!cached || cached.version !== state.snapshotVersion
                || cached.passwordVersion !== state.passwordVersion) {
                // This popup publishes the session after the encrypted transaction completes.
                if (syncInFlight || detailSaving) return;
                const fresh = await sessionCommand("read");
                if (operation !== operationGeneration) return;
                if (fresh.unlocked && (fresh.generation !== state.generation
                    || fresh.snapshotVersion !== state.snapshotVersion)) {
                    await restoreUnlockSession();
                    return;
                }
                await sessionCommand("lock", { generation: state.generation });
                clearUnlockedView();
                console.warn("[upw] session snapshot is behind encrypted cache; locked");
                return;
            }
        }
        if (unlockedGeneration !== state.generation && selectedItemId) {
            clearDetailView();
            currentView = "vault";
        }
        unlockedItems = state.items ?? [];
        unlockedGeneration = state.generation;
        unlockedExpiresAt = state.expiresAt;
        unlockedSnapshotVersion = state.snapshotVersion ?? null;
        unlockedPasswordVersion = state.passwordVersion ?? null;
        sessionPersistent = state.persistent !== false;
    } catch {
        if (operation !== operationGeneration) return;
        clearUnlockedView();
        console.warn("[upw] session restore unavailable; locked");
    }
}

async function touchSession() {
    if (unlockedItems === null || Date.now() - lastTouchAt < SESSION_CHECK_MS) return;
    lastTouchAt = Date.now();
    const operation = operationGeneration;
    try {
        const state = await sessionCommand("touch");
        if (operation !== operationGeneration) return;
        if (!state.unlocked || state.generation !== unlockedGeneration) {
            clearUnlockedView();
            await render();
        } else {
            unlockedExpiresAt = state.expiresAt;
        }
    } catch {
        if (operation !== operationGeneration) return;
        clearUnlockedView();
        await render();
        status(t("无法读取解锁会话，请重新解锁", "Unlock session is unavailable. Unlock again."), true);
    }
}

for (const eventName of ["pointerdown", "keydown", "input"]) {
    document.addEventListener(eventName, event => {
        if (event.isTrusted) void touchSession();
    });
}
setInterval(async () => {
    if (unlockedItems === null) return;
    if (Date.now() >= unlockedExpiresAt) clearUnlockedView();
    const previous = unlockedGeneration;
    const operation = operationGeneration;
    await restoreUnlockSession();
    if (operation !== operationGeneration) return;
    if (unlockedItems === null || previous !== unlockedGeneration) await render();
    await syncVault(true);
}, SESSION_CHECK_MS);

await render();
await touchSession();
void syncVault(true);
