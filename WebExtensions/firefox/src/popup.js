// Popup(standalone, Firefox):邮箱验证码登录 → 选库 → 主密码解锁 → 站点候选/填充。
// 数据通路全部直连 relay API(信封+库体副本),不依赖桌面 App 或原生桥;
// 解密链与 Swift DatabaseCipher 字节级对齐(shared/vault-crypto,向量测试把关)。
// 解锁后的条目明文缓存于 browser.storage.local(本机浏览器配置文件内,
// 锁定即清空);主密码与库密钥绝不落盘,仅在解锁瞬间驻留内存。
import {
    base64ToBytes,
    canonicalizeHost,
    clearItems,
    credentialsOf,
    decryptBody,
    getVaultBody,
    getVaultEnvelope,
    hostMatches,
    hostnameOf,
    listVaults,
    loadItems,
    parseVaultXml,
    requestCode,
    saveItems,
    unwrapEnvelope,
    verifyCode,
    VaultCryptoError,
} from "./shared/index.js";

const zh = (navigator.language || "").toLowerCase().startsWith("zh");
const t = (zhText, enText) => (zh ? zhText : enText);

// Firefox MV3 的 host_permissions 不随安装授予:网络调用前须在用户手势内
// 经 permissions.request 授予(contains 查询不受手势限制,已授予则零打扰)。
const RELAY_ORIGIN_PERMISSION = "https://api.upasswords.com/*";
const PERMISSION_DENIED_TEXT = ["需要授权连接同步服务(api.upasswords.com)", "Allow access to api.upasswords.com to continue"];

async function ensureRelayPermission() {
    const has = await browser.permissions.contains({ origins: [RELAY_ORIGIN_PERMISSION] });
    if (has) return true;
    return await browser.permissions.request({ origins: [RELAY_ORIGIN_PERMISSION] }) === true;
}

const SESSION_KEY = "relay.session"; // {token, expiresAt, email}
const VAULT_KEY = "relay.vault";     // {id, name}

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

document.getElementById("email").placeholder = t("邮箱", "Email");
codeInput.placeholder = t("验证码", "Code");
sendCodeButton.textContent = t("发送验证码", "Send code");
loginButton.textContent = t("登录", "Sign in");
passwordInput.placeholder = t("主密码", "Master password");
unlockButton.textContent = t("解锁", "Unlock");
refreshButton.textContent = t("刷新", "Refresh");
lockButton.textContent = t("锁定", "Lock");

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
    unlockBox.hidden = panel !== "unlock";
    itemsEl.replaceChildren();
    footerEl.hidden = panel === "login";
}

function status(text, isError) {
    statusEl.textContent = text;
    statusEl.className = isError ? "error" : "muted";
}

// MARK: - 登录(邮箱验证码)

async function sendCode() {
    const email = emailInput.value.trim();
    if (!email.includes("@")) {
        status(t("请输入有效邮箱", "Enter a valid email"), true);
        return;
    }
    sendCodeButton.disabled = true;
    try {
        if (!(await ensureRelayPermission())) {
            status(t(...PERMISSION_DENIED_TEXT), true);
            return;
        }
        await requestCode(email);
        status(t("验证码已发送,请查收邮箱", "Code sent — check your inbox"));
    } catch (error) {
        status(
            error?.status === 429
                ? t("发送太频繁,请稍后再试", "Too many requests — try later")
                : t("验证码发送失败", "Failed to send code"),
            true,
        );
    } finally {
        sendCodeButton.disabled = false;
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
        if (!(await ensureRelayPermission())) {
            status(t(...PERMISSION_DENIED_TEXT), true);
            return;
        }
        const session = await verifyCode(email, code, "Firefox 扩展");
        await storageSet({ [SESSION_KEY]: session });
        await pickVault(session.token);
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

async function pickVault(token) {
    const vaults = await listVaults(token);
    if (vaults.length === 0) {
        status(t("该邮箱下还没有密码库——请先在任意设备 App 端登录并开启同步", "No vault under this email yet — sign in on a device app first"), true);
        show("login");
        return;
    }
    // 单库直选;多库时暂用第一座(后续可加选择器)
    const chosen = vaults[0];
    await storageSet({ [VAULT_KEY]: { id: chosen.vaultId, name: chosen.name } });
    await render();
}

// MARK: - 解锁(信封+库体 → 解密 → 条目)

async function unlock() {
    const password = passwordInput.value;
    if (!password) return;
    unlockButton.disabled = true;
    status(t("正在拉取并解密密码库…", "Fetching and decrypting vault…"));
    try {
        if (!(await ensureRelayPermission())) {
            status(t(...PERMISSION_DENIED_TEXT), true);
            return;
        }
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
        const body = await getVaultBody(session.token, vault.id).catch((error) => {
            if (error?.code === "body_not_found") {
                status(t("云端还没有库体副本——请在 App 端同步一次推送副本", "No vault body replica yet — sync once in the app"), true);
                return null;
            }
            throw error;
        });
        if (!body) return;
        const xml = await decryptBody(body, vek);
        const items = parseVaultXml(xml);
        await saveItems(items);
        passwordInput.value = "";
        status("");
        await render();
    } catch (error) {
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
    const { [SESSION_KEY]: session } = await storageGet([SESSION_KEY]);
    if (!session) {
        show("login");
        status(t("首次使用请用邮箱登录", "Sign in with email to get started"));
        return;
    }
    if (session.expiresAt * 1000 < Date.now()) {
        await browser.storage.local.remove(SESSION_KEY);
        show("login");
        status(t("登录已过期，请重新登录", "Session expired — sign in again"));
        return;
    }
    const items = await loadItems();
    if (items.length === 0) {
        show("unlock");
        status(t("输入主密码解锁密码库", "Unlock your vault with the master password"));
        passwordInput.focus();
        return;
    }
    show("items");
    status("");
    renderCandidates(items);
}

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
    // 刷新 = 清缓存重新解锁(重新拉云端最新)
    await saveItems([]);
    await render();
});
lockButton.addEventListener("click", async () => {
    // 锁定 = 彻底退出:明文条目与会话令牌一并清除
    await clearItems();
    await browser.storage.local.remove(SESSION_KEY);
    await render();
});

await render();
