// Popup: 展示当前站点匹配的凭据,点击即填充;扩展侧未解锁时提供主密码解锁。
// 文案极简中英双语(随浏览器语言);密码只经 background 转发原生桥,不落地。
import { canonicalizeHost, hostnameOf } from "./shared/index.js";

const zh = (navigator.language || "").toLowerCase().startsWith("zh");
const t = (zhText, enText) => (zh ? zhText : enText);

const hostEl = document.getElementById("host");
const listEl = document.getElementById("items");
const statusEl = document.getElementById("status");
const unlockBox = document.getElementById("unlockBox");
const passwordInput = document.getElementById("masterPassword");
const unlockButton = document.getElementById("unlockButton");

passwordInput.placeholder = t("主密码", "Master password");
unlockButton.textContent = t("解锁", "Unlock");

const tabs = await browser.tabs.query({ active: true, currentWindow: true });
const tab = tabs[0];
const host = canonicalizeHost(hostnameOf(tab?.url ?? ""));
hostEl.textContent = host || "—";

async function query() {
    statusEl.textContent = "";
    unlockBox.hidden = true;
    listEl.replaceChildren();
    if (!host) {
        statusEl.textContent = t("此页面不可填充", "This page can't be filled");
        return;
    }
    let response;
    try {
        response = await browser.runtime.sendMessage({ type: "query", host });
    } catch {
        statusEl.textContent = t("后台脚本无响应", "Background script unreachable");
        return;
    }
    if (!response) return;
    if (response.type === "locked") {
        statusEl.textContent = t("输入主密码解锁密码库", "Unlock your vault with the master password");
        unlockBox.hidden = false;
        passwordInput.focus();
        return;
    }
    if (response.type !== "items") {
        statusEl.textContent = response.message || t("查询失败", "Query failed");
        return;
    }
    if (response.candidates.length === 0) {
        statusEl.textContent = t("没有该站点的条目", "No items for this site");
        return;
    }
    for (const candidate of response.candidates) {
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
        listEl.appendChild(li);
    }
}

async function fill(candidate, li) {
    if (!tab?.id) return;
    try {
        const response = await browser.tabs.sendMessage(tab.id, { type: "fill", candidate });
        if (response && response.ok) {
            statusEl.textContent = "";
            const mark = document.createElement("span");
            mark.className = "ok";
            mark.textContent = t(" ✓ 已填充", " ✓ Filled");
            li.appendChild(mark);
        } else {
            statusEl.textContent = t("页面上没找到登录表单", "No login form found on the page");
        }
    } catch {
        statusEl.textContent = t("无法访问该页面", "Can't reach this page");
    }
}

async function unlock() {
    const password = passwordInput.value;
    if (!password) return;
    unlockButton.disabled = true;
    try {
        const response = await browser.runtime.sendMessage({ type: "unlock", password });
        if (response && response.type === "unlocked" && response.ok) {
            passwordInput.value = "";
            await query();
        } else {
            statusEl.textContent = t("密码错误，或主密码已在其他设备修改——请输入最新密码",
                                     "Wrong password, or the master password was changed on another device — enter the latest one");
            statusEl.className = "error";
        }
    } catch {
        statusEl.textContent = t("原生桥不可用", "Native bridge unavailable");
    } finally {
        unlockButton.disabled = false;
    }
}

unlockButton.addEventListener("click", unlock);
passwordInput.addEventListener("keydown", (event) => {
    if (event.key === "Enter") unlock();
});

await query();
