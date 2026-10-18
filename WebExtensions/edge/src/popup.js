// Popup(standalone):邮箱验证码登录 → 选库 → 主密码解锁 → 站点候选/填充。
// 数据通路直连 relay API /v2(信封 + 行级条目快照),不依赖桌面 App 或原生桥;
// 解密链与 Swift DatabaseCipher/RowSyncCipher 字节级对齐(shared/vault-crypto,
// 向量测试把关)。解锁后的条目明文只驻留 popup 内存(关闭弹窗即锁定,
// 绝不写盘);storage.local 只保留会话令牌与库标识。首次使用两步走:
// 邮箱验证 → 主密码解锁;之后每次打开只输主密码,退出登录才需重新验证邮箱。
import {
    base64ToBytes,
    bytesToBase64,
    canonicalizeHost,
    clearItems,
    createVault,
    credentialsOf,
    decryptItemBody,
    fragmentsToXml,
    getVaultEnvelope,
    hostMatches,
    hostnameOf,
    listAllVaultItems,
    listVaults,
    parseVaultXml,
    requestCode,
    revokeOwnSession,
    unwrapEnvelope,
    wrapEnvelope,
    verifyCode,
    VaultCryptoError,
} from "./shared/index.js";

// Chrome MV3 无 browser.* 命名空间:用 Promise 化的 chrome.* 组装同形 shim,
// 使主体逻辑与 Safari popup 逐字一致(双端行为靠 shared 模块与结构对称保证)。
// 数据通路与红线同 Safari:直连 relay API,解锁明文只驻留内存/storage.local。
const browser = {
    tabs: {
        query: (q) => new Promise((resolve) => chrome.tabs.query(q, resolve)),
        // lastError 必须在回调内消费;有错时 reject 以对齐 browser.* 的抛错语义
        sendMessage: (tabId, message) => new Promise((resolve, reject) => {
            chrome.tabs.sendMessage(tabId, message, (response) => {
                const err = chrome.runtime.lastError;
                if (err) reject(new Error(err.message));
                else resolve(response);
            });
        }),
    },
    storage: {
        local: {
            get: (keys) => new Promise((resolve) => chrome.storage.local.get(keys, resolve)),
            set: (entries) => new Promise((resolve) => chrome.storage.local.set(entries, resolve)),
            remove: (keys) => new Promise((resolve) => chrome.storage.local.remove(keys, resolve)),
        },
    },
};

const zh = (navigator.language || "").toLowerCase().startsWith("zh");
const t = (zhText, enText) => (zh ? zhText : enText);

const SESSION_KEY = "relay.session"; // {token, expiresAt}
const VAULT_KEY = "relay.vault";     // {id, name}
// 登录草稿 {email, code}:弹窗失焦即被浏览器销毁,输入实时落本地、重开回填,
// 登录成功清除——否则"发码后去查邮件、回来发现邮箱被清空"。
const DRAFT_KEY = "relay.loginDraft";

// 本次 popup 生命周期内解锁的条目(仅内存;关闭弹窗即锁定)
let unlockedItems = [];

// 首次两步引导标记:邮箱验证刚通过时,第二页标题带步骤号
let justVerifiedEmail = false;

const hostEl = document.getElementById("host");
const statusEl = document.getElementById("status");
const loginBox = document.getElementById("loginBox");
const unlockBox = document.getElementById("unlockBox");
const itemsEl = document.getElementById("items");
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

document.getElementById("email").placeholder = t("邮箱", "Email");
codeInput.placeholder = t("验证码", "Code");
sendCodeButton.textContent = t("发送验证码", "Send code");
loginButton.textContent = t("登录", "Sign in");
passwordInput.placeholder = t("主密码", "Master password");
unlockButton.textContent = t("解锁", "Unlock");
refreshButton.textContent = t("刷新", "Refresh");
lockButton.textContent = t("退出登录", "Sign out");
loginStepTitle.textContent = t("第 1 步 · 验证邮箱", "Step 1 · Verify email");

const tabs = await browser.tabs.query({ active: true, currentWindow: true });
const tab = tabs[0];
const host = canonicalizeHost(hostnameOf(tab?.url ?? ""));
hostEl.textContent = host || t("此页面不可填充", "This page can't be filled");

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
    itemsEl.replaceChildren();
    footerEl.hidden = panel === "login";
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
    const email = emailInput.value.trim();
    const code = codeInput.value.trim();
    if (!email.includes("@") || code.length < 4) {
        status(t("请填写邮箱与验证码", "Email and code required"), true);
        return;
    }
    loginButton.disabled = true;
    try {
        const session = await verifyCode(email, code, t("Edge 扩展", "Edge extension"), "ext-edge");
        await storageSet({ [SESSION_KEY]: session });
        // 登录成功:验证码草稿作废;邮箱保留(退出登录后回填,免去重输)
        await storageSet({ [DRAFT_KEY]: { email: emailInput.value.trim(), code: "" } });
        // 进入第 2 页:选择(或新建)密码库
        await showVaultPage(session.token);
    } catch (error) {
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
    const vaults = await listVaults(token).catch(() => []);
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
        const { envelope } = await wrapEnvelope(password);
        const vaultId = await createVault(session.token, name, bytesToBase64(envelope));
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

// MARK: - 解锁(信封 + 行级条目快照 → 逐条解密 → 条目)

async function unlock() {
    const password = passwordInput.value;
    if (!password) return;
    unlockButton.disabled = true;
    status(t("正在拉取并解密密码库…", "Fetching and decrypting vault…"));
    try {
        const bag = await storageGet([SESSION_KEY, VAULT_KEY]);
        const session = bag[SESSION_KEY];
        const vault = bag[VAULT_KEY];
        if (!session || !vault) {
            await render();
            return;
        }
        const { envelope } = await getVaultEnvelope(session.token, vault.id);
        if (!envelope) {
            status(t("云端还没有密钥信封——请先在 App 端同步一次", "No key envelope on the server — sync once in the app"), true);
            return;
        }
        let vek;
        try {
            vek = await unwrapEnvelope(base64ToBytes(envelope), password);
        } catch (error) {
            if (error instanceof VaultCryptoError) {
                status(t("密码错误，或主密码已在其他设备修改——请输入最新密码", "Wrong password, or the master password was changed on another device — enter the latest one"), true);
            }
            throw error;
        }
        // v7 行级快照:全量分页拉取,逐条 AES-GCM(AAD=uuid) 解密;
        // 单条解不开(他端改密窗口)跳过,与 Swift 端"按删除收敛"的宽容一致
        const rows = await listAllVaultItems(session.token, vault.id);
        const fragments = [];
        for (const row of rows) {
            if (row.kind !== 1) continue; // 1=card;2=label(填充不需要)
            try {
                fragments.push(await decryptItemBody(base64ToBytes(row.bodyB64), vek, row.uuid));
            } catch {
                console.warn("item undecryptable, dropped:", row.uuid.slice(0, 8));
            }
        }
        const items = fragments.length > 0 ? parseVaultXml(fragmentsToXml(fragments)) : [];
        unlockedItems = items;
        // 迁移卫生:清掉旧版本遗留在 storage 的明文(本版起明文只驻内存)
        await clearItems();
        passwordInput.value = "";
        await render();
        if (items.length === 0) {
            // render 会把空库重置为解锁提示,空库文案要放在其后补写
            status(t("解锁成功——云端库还没有条目", "Unlocked — the vault is empty on the server"), true);
        }
    } catch (error) {
        // 会话失效(过期/被他端撤销):清会话回登录页
        if (error?.status === 401) {
            await browser.storage.local.remove([SESSION_KEY, VAULT_KEY]);
            unlockedItems = [];
            show("login");
            status(t("登录已过期，请重新登录", "Session expired — sign in again"), true);
            return;
        }
        // 只记错误名/错误码定位问题;message 可能含上下文,不打出
        console.warn("unlock failed:", error?.name, error?.code ?? "");
        if (!statusEl.className.includes("error")) {
            status(t("Unlock failed, please try again later", "Unlock failed — try again later"), true);
        }
    } finally {
        unlockButton.disabled = false;
    }
}

// MARK: - 候选与填充

function renderCandidates(items) {
    if (!host) {
        status(t("此页面不可填充", "This page can't be filled"));
        return;
    }
    const candidates = items
        .filter((item) => hostMatches(host, item.host))
        .map((item) => ({ item, ...credentialsOf(item) }));
    if (candidates.length === 0) {
        status(t("没有该站点的条目", "No items for this site"));
        return;
    }
    for (const candidate of candidates) {
        const li = document.createElement("li");
        li.className = "item";
        const title = document.createElement("span");
        title.className = "title";
        title.textContent = candidate.item.title;
        const user = document.createElement("span");
        user.className = "user";
        user.textContent = candidate.username || "—";
        li.append(title, user);
        li.addEventListener("click", () => fill(candidate, li));
        itemsEl.appendChild(li);
    }
}

async function fill(candidate, li) {
    if (!tab?.id) return;
    try {
        const response = await browser.tabs.sendMessage(tab.id, { type: "fill", candidate });
        if (response && response.ok) {
            const mark = document.createElement("span");
            mark.className = "ok";
            mark.textContent = t(" ✓ 已填充", " ✓ Filled");
            li.appendChild(mark);
        } else {
            status(t("页面上没找到登录表单", "No login form found on the page"), true);
        }
    } catch {
        status(t("无法访问该页面", "Can't reach this page"), true);
    }
}

// MARK: - 状态渲染

async function render() {
    unlockStepTitle.textContent = justVerifiedEmail
        ? t("第 3 步 · 主密码解锁", "Step 3 · Master password")
        : t("主密码解锁", "Master password");
    justVerifiedEmail = false;
    const { [SESSION_KEY]: session } = await storageGet([SESSION_KEY]);
    if (!session) {
        show("login");
        status(t("首次使用请用邮箱登录", "Sign in with email to get started"));
        await restoreDraft();
        return;
    }
    if (session.expiresAt < Date.now()) {
        await browser.storage.local.remove(SESSION_KEY);
        show("login");
        status(t("登录已过期，请重新登录", "Session expired — sign in again"));
        await restoreDraft();
        return;
    }
    const { [VAULT_KEY]: vault } = await storageGet([VAULT_KEY]);
    if (!vault) {
        // 已验证邮箱但尚未选定密码库(首登第 2 页中途关弹窗):回到选库页
        await showVaultPage(session.token);
        return;
    }
    if (unlockedItems.length === 0) {
        show("unlock");
        status(t(`输入主密码解锁 “${vault.name}”`, `Unlock “${vault.name}” with the master password`));
        passwordInput.focus();
        return;
    }
    show("items");
    status("");
    renderCandidates(unlockedItems);
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
refreshButton.addEventListener("click", async () => {
    // 刷新 = 回到主密码步骤(重新拉云端最新;不退出登录)
    unlockedItems = [];
    await render();
});
lockButton.addEventListener("click", async () => {
    // 退出登录 = 彻底退出:服务端自撤销会话,内存明文/盘上遗留/会话一并清除;
    // 下次使用回到第一步(邮箱验证)
    const { [SESSION_KEY]: session } = await storageGet([SESSION_KEY]);
    if (session?.token) {
        await revokeOwnSession(session.token).catch(() => undefined);
    }
    unlockedItems = [];
    await clearItems();
    await browser.storage.local.remove([SESSION_KEY, VAULT_KEY]);
    const { [DRAFT_KEY]: draft } = await storageGet([DRAFT_KEY]);
    if (draft) {
        await storageSet({ [DRAFT_KEY]: { email: draft.email, code: "" } });
    }
    await render();
});

await render();
