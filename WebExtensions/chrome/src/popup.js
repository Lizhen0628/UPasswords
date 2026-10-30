// 职责：邮箱授权、密码库解锁、密文同步、条目编辑与用户主动填充。
// 异步边界：operationGeneration 和解锁 generation 共同阻止旧结果写回新会话。
// 数据边界：持久化缓存只存密文；详情草稿和生成密码仅由当前弹窗持有。
// Relay authentication stays on disk; unlocked entries live only in the trusted browser session.
import {
    base64ToBytes,
    bytesToBase64,
    safeWebsiteUrl,
    canonicalizeHost,
    clearItems,
    sha256BytesHex,
    copyConflictCandidateAttachments,
    createBackupArchive,
    createLocalBackupStore,
    MAX_BACKUP_ARCHIVE_BYTES,
    createVault,
    createItem,
    createLoginItemXml,
    generatePassword,
    createEncryptedCache,
    hydrateMissingAttachments,
    AttachmentDownloadLedger,
    ATTACHMENT_CACHE_BUDGET_BYTES,
    autofillConflictBlocks,
    attachmentVersionKey,
    attachmentReferencesIn,
    attachmentByteCount,
    captureBackupCloudHistory,
    analyzeCardConflict,
    buildAutofillConflictGateEntry,
    classifyAttachmentFailure,
    encryptSyncQuarantinePayload,
    planAttachmentCache,
    readAttachmentReferences,
    synchronizeVault,
    projectVaultFragment,
    credentialsOf,
    decryptItemBody,
    decryptAttachmentVersion,
    encryptItemBody,
    fragmentsToXml,
    getVaultEnvelope,
    getVaultAttachment,
    hostMatches,
    itemMatchesPage,
    hostnameOf,
    listVaultConflicts,
    listVaultAttachmentVersions,
    putVaultAttachment,
    deleteVaultAttachment,
    listVaults,
    parseAutofillConflictGate,
    parseVaultXml,
    inspectBackupArchive,
    openBackupRestoreDependencies,
    prepareBackupRestore,
    readPortableBackupArchive,
    readItemDetail,
    readInlineAttachments,
    composeCardConflict,
    installAttachmentBytes,
    reidentifyItemXml,
    retryQuarantinedRows,
    requestCode,
    resolveVaultConflict,
    saveVaultItem,
    revokeOwnSession,
    unwrapEnvelope,
    updateItemXml,
    wrapEnvelope,
    verifyCode,
    VaultCryptoError,
} from "./shared/index.js";

// Chrome MV3 无 browser.* 命名空间:用 Promise 化的 chrome.* 组装同形 shim,
// 使主体逻辑与 Safari popup 逐字一致(双端行为靠 shared 模块与结构对称保证)。
// Relay API 与页面消息保持 Promise 接口一致。
const browser = {
    tabs: {
        query: (q) => new Promise((resolve) => chrome.tabs.query(q, resolve)),
        create: (options) => chrome.tabs.create(options),
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

console.info("[upw] popup build: r7-click-probe");
const zh = (navigator.language || "").toLowerCase().startsWith("zh");
const t = (zhText, enText) => (zh ? zhText : enText);

const SESSION_KEY = "relay.session"; // {token, expiresAt}
const VAULT_KEY = "relay.vault";     // {id, name}
const VAULT_OWNER_KEY = "relay.vaultOwner";
// 登录草稿 {email, code}:弹窗失焦即被浏览器销毁,输入实时落本地、重开回填,
// 登录成功清除——否则"发码后去查邮件、回来发现邮箱被清空"。
const DRAFT_KEY = "relay.loginDraft";
const AUTOFILL_CONFLICT_GATE_KEY = "extension.autofillConflictGate";
const AUTOFILL_CONFLICT_GATE_MAX_AGE_MS = 5 * 60 * 1000;
const PENDING_CONFLICT_COPY_KEY = "extension.pendingConflictCopy";

let unlockedItems = null;
let syncQuarantineItems = [];
let quarantineRetryInFlight = false;
let unlockedGeneration = null;
let unlockedExpiresAt = 0;
let unlockedSnapshotVersion = null;
let unlockedPasswordVersion = null;
let syncInFlight = false;
let attachmentPublicationInFlight = false;
let lastSyncAttempt = 0;
const encryptedCache = createEncryptedCache();
const SYNC_INTERVAL_MS = 60_000;
let sessionPersistent = true;
let operationGeneration = 0;
let lastTouchAt = 0;
let currentView = "vault";
let pendingBackupFile = null;
let pendingBackupFileName = "";
let pendingBackupReview = null;
let pendingLocalCopyID = null;
let localCopyItems = [];
let selectedLocalCopyItemID = null;
let backupWorkflowGeneration = 0;
let renderGeneration = 0;
let selectedItemId = null;
let detailGeneration = null;
let detailItem = null;
let detailEditing = false;
let detailSaving = false;
let detailTitleInput = null;
let detailNotesInput = null;
let detailFieldInputs = [];
let activePanel = "";
let listScrollTop = 0;
let lastSyncSuccessAt = 0;
let generatedPassword = "";
let newLoginDirty = false;
let newLoginSaving = false;
let newLoginId = null;
let newLoginUncertain = false;
let syncFailed = false;
let switchingVault = false;
let conflictGroups = [];
let conflictsLoading = false;
let conflictResolving = false;
let conflictCopyUncertain = false;
let conflictFetchTask = null;
let conflictRefreshTask = null;
let autofillConflictGate = null;
let autofillConflictGateScopeKey = null;
let attachmentSyncTask = null;
let backgroundAttachmentRequested = false;
let backgroundAttachmentQueue = [];
const priorityAttachmentQueue = [];
const priorityAttachmentTasks = new Map();
const activeAttachmentRows = new Map();
let attachmentPolicyView = null;
let attachmentPolicyReferences = [];
let attachmentPolicyUnavailable = false;
let attachmentPolicyWriteTail = Promise.resolve();
let attachmentRetryTimer = null;
let attachmentAbortController = null;
let attachmentInFlightPrioritized = false;
let attachmentNetworkAvailable = navigator.onLine !== false
    && (navigator.connection ?? navigator.mozConnection ?? navigator.webkitConnection)?.type !== "none";

// 首次两步引导标记:邮箱验证刚通过时,第二页标题带步骤号
let justVerifiedEmail = false;

const hostEl = document.getElementById("host");
const statusEl = document.getElementById("status");
const loginBox = document.getElementById("loginBox");
const unlockBox = document.getElementById("unlockBox");
const itemsEl = document.getElementById("items");
const itemsBox = document.getElementById("itemsBox");
const generatorBox = document.getElementById("generatorBox");
const newLoginBox = document.getElementById("newLoginBox");
const generatorTab = document.getElementById("generatorTab");
const siteFilter = document.getElementById("siteFilter");
const sortItems = document.getElementById("sortItems");
const syncSummary = document.getElementById("syncSummary");
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
const newLoginFields = ["newLoginTitle", "newLoginUsername", "newLoginPassword", "newLoginUrl", "newLoginNotes"]
    .map(id => document.getElementById(id));
const newLoginSiteMatch = document.getElementById("newLoginSiteMatch");
const newLoginAdditionalSites = document.getElementById("newLoginAdditionalSites");
const addLoginWebsiteButton = document.getElementById("addLoginWebsiteButton");
let newLoginSiteAssociations = [];
function addNewLoginSite(url = "", mode = "domain") {
    const group = document.createElement("div");
    group.className = "field";
    const input = document.createElement("input");
    input.type = "url";
    input.value = url;
    input.placeholder = t("https://*.example.com/*", "https://*.example.com/*");
    input.setAttribute("aria-label", t("网站关联地址", "Website association URL"));
    const select = document.createElement("select");
    for (const [value, zhLabel, enLabel] of [["domain", "基于域名", "Domain"], ["wildcard", "基于规则", "Wildcard rule"], ["exactURL", "完全匹配", "Exact URL"]]) {
        const option = document.createElement("option"); option.value = value; option.textContent = t(zhLabel, enLabel); select.appendChild(option);
    }
    select.value = mode;
    const remove = document.createElement("button"); remove.type = "button"; remove.className = "secondary";
    remove.textContent = t("删除", "Remove");
    const association = { group, input, select };
    remove.addEventListener("click", () => { newLoginSiteAssociations = newLoginSiteAssociations.filter(site => site !== association); group.remove(); });
    group.append(input, select, remove);
    newLoginAdditionalSites.appendChild(group);
    newLoginSiteAssociations.push(association);
}
addLoginWebsiteButton.addEventListener("click", () => addNewLoginSite());

const generatedInput = document.getElementById("generatedPassword");
const settingsHeading = document.getElementById("settingsHeading");
const navigation = document.getElementById("navigation");
const vaultTab = document.getElementById("vaultTab");
const settingsTab = document.getElementById("settingsTab");
const lockNowButton = document.getElementById("lockNowButton");
const headerTools = document.getElementById("headerTools");
const lockTimeout = document.getElementById("lockTimeout");
const sessionMode = document.getElementById("sessionMode");
const conflictsStatus = document.getElementById("conflictsStatus");
const conflictsList = document.getElementById("conflictsList");
const refreshConflictsButton = document.getElementById("refreshConflictsButton");
const syncQuarantineBox = document.getElementById("syncQuarantineBox");
const syncQuarantineSummary = document.getElementById("syncQuarantineSummary");
const syncQuarantineList = document.getElementById("syncQuarantineList");
const retrySyncQuarantineButton = document.getElementById("retrySyncQuarantineButton");
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
const UNKNOWN_NETWORK_ATTACHMENT_KEY = "extension.allowUnknownNetworkAttachmentDownloads";
const CELLULAR_ATTACHMENT_KEY = "extension.allowCellularAttachmentDownloads";
const DEFAULT_LOCK_MINUTES = 15;
const SESSION_CHECK_MS = 15_000;
const localBackupStore = createLocalBackupStore();
const localBackupManagerDialog = document.getElementById("localBackupManagerDialog");
const backupRestoreDialog = document.getElementById("backupRestoreDialog");
const localCopyUnlockDialog = document.getElementById("localCopyUnlockDialog");
const localCopyViewerDialog = document.getElementById("localCopyViewerDialog");
const localBackupCopyList = document.getElementById("localBackupCopyList");
const localBackupManagerStatus = document.getElementById("localBackupManagerStatus");
const localBackupFileInput = document.getElementById("localBackupFileInput");
const backupSourcePasswordInput = document.getElementById("backupSourcePassword");
const backupRestoreReview = document.getElementById("backupRestoreReview");
const backupRestoreSummary = document.getElementById("backupRestoreSummary");
const backupRestoreIssues = document.getElementById("backupRestoreIssues");
const allowIncompleteRestoreRow = document.getElementById("allowIncompleteRestoreRow");
const allowIncompleteRestoreInput = document.getElementById("allowIncompleteRestore");
const localCopyNameInput = document.getElementById("localCopyName");
const localCopyPasswordInput = document.getElementById("localCopyPassword");
const localCopyPasswordConfirmInput = document.getElementById("localCopyPasswordConfirm");
const backupRestoreStatus = document.getElementById("backupRestoreStatus");
const localCopyUnlockPasswordInput = document.getElementById("localCopyUnlockPassword");
const localCopyUnlockStatus = document.getElementById("localCopyUnlockStatus");
const localCopyViewerHeading = document.getElementById("localCopyViewerHeading");
const localCopyIntegrityStatus = document.getElementById("localCopyIntegrityStatus");
const localCopySearchInput = document.getElementById("localCopySearch");
const localCopyItemList = document.getElementById("localCopyItemList");
const localCopyDetail = document.getElementById("localCopyDetail");
const backupExportButton = document.getElementById("backupExportButton");
const backupExportStatus = document.getElementById("backupExportStatus");
const openLocalCopiesSettingsButton = document.getElementById("openLocalCopiesSettingsButton");
const importLocalBackupButton = document.getElementById("importLocalBackupButton");
const closeLocalBackupManagerButton = document.getElementById("closeLocalBackupManagerButton");
const closeBackupRestoreButton = document.getElementById("closeBackupRestoreButton");
const reviewBackupButton = document.getElementById("reviewBackupButton");
const restoreBackupButton = document.getElementById("restoreBackupButton");
const closeLocalCopyUnlockButton = document.getElementById("closeLocalCopyUnlockButton");
const unlockLocalCopyButton = document.getElementById("unlockLocalCopyButton");
const closeLocalCopyViewerButton = document.getElementById("closeLocalCopyViewerButton");

document.documentElement.lang = zh ? "zh-Hans" : "en";
for (const element of document.querySelectorAll("[data-zh][data-en]")) {
    element.textContent = t(element.dataset.zh, element.dataset.en);
}
searchInput.placeholder = t("搜索标题、用户名或网站", "Search title, username, or domain");
siteFilter.setAttribute("aria-label", t("筛选条目", "Filter items"));
sortItems.setAttribute("aria-label", t("标题排序", "Sort by title"));
lockNowButton.setAttribute("aria-label", t("立即锁定", "Lock now"));
lockNowButton.title = t("立即锁定并丢弃草稿", "Lock now and discard drafts");
document.getElementById("switchVaultButton").setAttribute("aria-label", t("切换密码库", "Switch vault"));
document.getElementById("switchVaultButton").title = t("切换密码库", "Switch vault");
navigation.setAttribute("aria-label", t("主导航", "Main navigation"));
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

// 后台消息通道(runtime 不在 browser shim 里,直接用平台命名空间)
const RUNTIME_SEND = (message) => chrome.runtime.sendMessage(message);

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
const host = /^https?:\/\//i.test(pageUrl) ? canonicalizeHost(hostnameOf(pageUrl)) : "";
let registrationForm = false;
if (tab?.id) {
    try {
        registrationForm = Boolean(await browser.tabs.sendMessage(tab.id, { type: "registration-check" }));
    } catch { /* No content script means this page cannot receive profile data. */ }
}
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
    generatorBox.hidden = panel !== "generator";
    newLoginBox.hidden = panel !== "new-login";
    detailBox.hidden = panel !== "detail";
    activePanel = panel;
    itemsEl.replaceChildren();
    suggestionsEl.replaceChildren();
    document.body.dataset.panel = panel;
    const unlocked = ["items", "settings", "detail", "generator", "new-login"].includes(panel);
    stateBadge.textContent = unlocked ? t("已解锁", "Unlocked") : t("已锁定", "Locked");
    footerEl.hidden = panel === "login";
    navigation.hidden = !unlocked;
    headerTools.hidden = !unlocked;
    document.getElementById("switchVaultButton").hidden = !unlocked && panel !== "unlock";
    refreshButton.hidden = !unlocked;
    vaultTab.setAttribute("aria-current", (panel === "items" || panel === "detail" || panel === "new-login") ? "page" : "false");
    generatorTab.setAttribute("aria-current", panel === "generator" ? "page" : "false");
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
        const session = await verifyCode(email, code, t("Chrome 扩展", "Chrome extension"), "ext-chrome");
        if (!isCurrent()) return;
        const previous = await storageGet([SESSION_KEY, VAULT_KEY, VAULT_OWNER_KEY]);
        if (!isCurrent()) return;
        const locking = lockSession();
        operation = operationGeneration;
        await locking;
        if (!isCurrent()) return;
        const previousUserId = previous[SESSION_KEY]?.userId;
        if (previousUserId && previousUserId !== session.userId) {
            try {
                await encryptedCache.preserveAccount(previousUserId);
            } catch (error) {
                console.warn("[upw] prior cache fencing failed; data retained:", error?.message ?? error?.name);
            }
            if (!isCurrent()) return;
        }
        const canResumeLocalVault = Boolean(previous[VAULT_KEY] && session.userId && (
            previousUserId === session.userId
            || !previousUserId && previous[VAULT_OWNER_KEY] === session.userId
        ));
        if (canResumeLocalVault) {
            await storageSet({ [VAULT_OWNER_KEY]: session.userId });
        } else {
            await browser.storage.local.remove([VAULT_KEY, VAULT_OWNER_KEY]);
            if (!isCurrent()) return;
        }
        await storageSet({ [SESSION_KEY]: session });
        if (!isCurrent()) return;
        await storageSet({ [DRAFT_KEY]: { email, code: "" } });
        if (!isCurrent()) return;
        if (canResumeLocalVault) await render();
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
    show("vault");
    vaultList.replaceChildren();
    createVaultForm.hidden = true;
    document.getElementById("cancelVaultSwitchButton").hidden = !switchingVault;
    vaultStepTitle.textContent = t("选择密码库", "Choose vault");
    status(t("正在加载密码库…", "Loading vaults…"));
    let vaults;
    try {
        await requireRelayAccess(true);
        vaults = await listVaults(token);
    } catch {
        if (operation !== operationGeneration) return;
        show("vault");
        vaultList.replaceChildren();
        createVaultForm.hidden = true;
        document.getElementById("cancelVaultSwitchButton").hidden = !switchingVault;
        status(t("无法获取密码库列表，请检查网络或重新登录。", "Could not load vaults. Check your connection or sign in again."), true);
        console.warn("[upw] vault listing failed");
        return;
    }
    if (operation !== operationGeneration) return;
    show("vault");
    document.getElementById("cancelVaultSwitchButton").hidden = !switchingVault;
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
                row.disabled = true;
                await lockSession();
                const selection = operationGeneration;
                const active = await storageGet([SESSION_KEY]);
                if (selection !== operationGeneration || active[SESSION_KEY]?.token !== token) return;
                await storageSet({
                    [VAULT_KEY]: { id: v.vaultId, name: v.name },
                    [VAULT_OWNER_KEY]: active[SESSION_KEY].userId,
                });
                if (selection !== operationGeneration) return;
                switchingVault = false;
                justVerifiedEmail = true;
                console.info("[upw] vault selected");
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
        await storageSet({ [VAULT_KEY]: { id: vaultId, name }, [VAULT_OWNER_KEY]: session.userId });
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

/** Verify rows independently so one damaged cloud item does not block unrelated updates. */
async function verifyRowsAndCollect(rows, fragments, { generation, context, validate, vaultKey }) {
    const issues = [];
    let decryptedFragments;
    if (vaultKey) {
        decryptedFragments = [];
        for (const row of rows) {
            try {
                const xml = await decryptItemBody(base64ToBytes(row.bodyB64), vaultKey, row.uuid);
                decryptedFragments.push({ ...row, xml });
            } catch (error) {
                if (!(error instanceof VaultCryptoError)
                    || !["item_decrypt_failed", "invalid_item_encoding"].includes(error.message)) throw error;
                issues.push({ uuid: row.uuid, reason: error.message === "invalid_item_encoding"
                    ? "unsupportedFormat" : "authenticationFailed" });
            }
            await validate();
        }
    } else {
        const response = await sessionCommand("decrypt", { generation, rows }, context);
        if (!response.unlocked || !response.fragments) {
            throw new Error(response.code ?? "session_key_missing");
        }
        if (Array.isArray(response.failures)) issues.push(...response.failures);
        decryptedFragments = response.fragments;
    }
    for (const fragment of decryptedFragments) {
        try {
            projectVaultFragment(fragment);
            fragments.set(fragment.uuid.toLowerCase(), fragment);
        } catch (error) {
            if (!(error instanceof VaultCryptoError)
                || !["bad_xml", "bad_item_identity"].includes(error.message)) throw error;
            issues.push({ uuid: fragment.uuid, reason: "unsupportedFormat" });
        }
    }
    await validate();
    return issues;
}

/** 通过主密码解封库密钥，再验证密文快照并建立可信后台会话。 */
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
                verifyRows: rows => verifyRowsAndCollect(rows, new Map(), { validate, vaultKey: vek }),
                sealQuarantine: (identity, row) => encryptSyncQuarantinePayload(row, vek, identity),
            })).snapshot;
        }
        password = "";
        syncQuarantineItems = snapshot.quarantinedItems ?? [];
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
            envelopeB64: snapshot.envelope,
        }, context);
        await validate();
        if (!committed.unlocked) throw new Error("session_unavailable");
        unlockedGeneration = committed.generation;
        unlockedSnapshotVersion = snapshot.version;
        unlockedPasswordVersion = snapshot.passwordVersion;
        unlockedItems = items;
        console.info("[upw] local vault unlocked; count:", items.length);
        currentView = "vault";
        await render();
        void syncVault(true);
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
    else await browser.storage.local.remove([SESSION_KEY, VAULT_KEY, VAULT_OWNER_KEY]);
    if (expiredOperation !== operationGeneration) return false;
    unlockButton.disabled = false;
    show("login");
    await restoreDraft();
    return expiredOperation === operationGeneration;
}

/** 对当前解锁代次执行同步；先验证并提交密文快照，再更新明文投影。 */
function attachmentPolicyError(error) {
    if (["session_changed", "attachment_sync_deferred", "attachment_policy_version_conflict", "cache_version_conflict"].includes(error?.message)) return;
    attachmentPolicyUnavailable = true;
    updateAttachmentDownloadSummary();
    clearTimeout(attachmentRetryTimer);
    attachmentRetryTimer = null;
    console.warn("[upw] attachment policy unavailable; downloads paused; code:", error?.code ?? error?.name);
    status(t("附件状态无法读取或保存，下载已暂停，现有文件已保留。重新解锁后可重试。", "Attachment state could not be read or saved. Downloads are paused and existing files are preserved. Unlock again to retry."), true);
}

async function attachmentFragments(snapshot, context, generation) {
    const visible = new Map((unlockedItems ?? []).map(item => [item.id.toLowerCase(), item]));
    const fragments = [];
    for (const row of snapshot.rows) {
        if (row.kind !== 1) continue;
        const item = visible.get(row.uuid.toLowerCase());
        let xml = item?.source?.revision === row.revision ? item.source.xml : null;
        if (!xml) {
            const response = await sessionCommand("decrypt", { generation, rows: [row] }, context);
            if (!response.unlocked || !response.fragments?.[0]) throw new Error("session_changed");
            xml = response.fragments[0].xml;
        }
        fragments.push({ row, xml });
    }
    return fragments;
}

/** Serialize local policy commands; row-cache publication still uses independent CAS and epoch checks. */
function updateAttachmentPolicy(update = () => {}) {
    const generation = unlockedGeneration;
    const operation = operationGeneration;
    const task = attachmentPolicyWriteTail.catch(() => undefined).then(async () => {
        if (unlockedItems === null || generation !== unlockedGeneration || operation !== operationGeneration) throw new Error("session_changed");
        const bag = await storageGet([SESSION_KEY, VAULT_KEY]);
        const session = bag[SESSION_KEY];
        const vault = bag[VAULT_KEY];
        const scope = cacheScope(session, vault);
        const context = sessionContext(session, vault);
        const snapshot = await encryptedCache.read(scope);
        if (!snapshot || snapshot.version !== unlockedSnapshotVersion) throw new Error("session_changed");
        const stored = await encryptedCache.readAttachmentLedger(scope);
        if (stored && stored.accountEpoch !== snapshot.accountEpoch) throw new Error("session_changed");
        const ledger = new AttachmentDownloadLedger(stored?.state);
        const fingerprint = await sha256BytesHex(new TextEncoder().encode(session.token));
        ledger.authorize(fingerprint);
        const fragments = await attachmentFragments(snapshot, context, generation);
        const references = attachmentReferencesIn(fragments);
        ledger.reconcile(references);
        update(ledger, references);
        if (unlockedItems === null || generation !== unlockedGeneration || operation !== operationGeneration
            || snapshot.version !== unlockedSnapshotVersion) throw new Error("session_changed");
        const active = await storageGet([SESSION_KEY, VAULT_KEY]);
        if (active[SESSION_KEY]?.token !== session.token || active[SESSION_KEY]?.userId !== session.userId
            || active[VAULT_KEY]?.id !== vault.id || generation !== unlockedGeneration) throw new Error("session_changed");
        const state = ledger.toJSON();
        const result = stored && JSON.stringify(state) === JSON.stringify(stored.state) ? stored
            : await encryptedCache.writeAttachmentLedger({ scope, state, accountEpoch: snapshot.accountEpoch }, stored?.version ?? null);
        if (generation !== unlockedGeneration || operation !== operationGeneration) throw new Error("session_changed");
        attachmentPolicyView = ledger;
        attachmentPolicyReferences = references;
        updateAttachmentDownloadSummary();
        return { stored: result, fragments };
    });
    attachmentPolicyWriteTail = task.catch(() => undefined);
    return task;
}

function attachmentPauseText(version) {
    if (attachmentPolicyUnavailable) return t("附件状态不可用，下载已暂停。", "Attachment state is unavailable; downloads are paused.");
    const record = attachmentPolicyView?.record(version);
    if (record?.evicted) return t("本机缓存已清理，打开条目或重试可重新下载。", "Local cache was cleared. Open the item or retry to download again.");
    switch (record?.failure) {
    case "authorization": return t("云端登录已过期，请重新登录。", "Cloud sign-in expired. Sign in again.");
    case "integrity": return t("附件校验失败，现有文件已保留。", "Attachment verification failed. Existing files were preserved.");
    case "storage": return t("本机空间或缓存预算不足，下载已暂停。", "Device space or cache budget is insufficient; downloads are paused.");
    case "unavailable": return t("服务器上的此附件版本暂不可用。", "This attachment version is unavailable on the server.");
    case "permanent": return t("附件下载已暂停，请解决问题后重试。", "Attachment download is paused. Resolve the cause and retry.");
    case "transient": return record.retryAt === undefined
        ? t("自动重试次数已用尽，可以手动重试。", "Automatic retries are exhausted. Retry manually.")
        : t("下载失败，正在等待自动重试。", "Download failed; waiting for an automatic retry.");
    default: return t("此附件尚未下载到本机。", "This attachment is not downloaded on this device.");
    }
}

function updateAttachmentDownloadSummary() {
    const summary = document.getElementById("attachmentDownloadSummary");
    document.getElementById("downloadAllAttachmentsButton").disabled = attachmentPolicyUnavailable;
    const button = document.getElementById("endDownloadAllAttachmentsButton");
    button.hidden = !attachmentPolicyView?.downloadingAll;
    const total = attachmentPolicyReferences.length;
    const ready = attachmentPolicyReferences.filter(reference => !reference.missing).length;
    summary.textContent = attachmentPolicyUnavailable
        ? t("附件下载已暂停，现有文件已保留。", "Attachment downloads are paused; existing files were preserved.")
        : t(`本机可用 ${ready} / ${total} 个附件`, `${ready} / ${total} attachments available on this device`);
}

async function downloadAllAttachments() {
    try {
        await updateAttachmentPolicy((ledger, references) => ledger.requestAll(references));
        queueBackgroundAttachmentDownloads();
        status(t("已请求下载全部附件，仍受网络策略、重试和可用空间限制。", "All attachments were requested, subject to network policy, retries, and available space."));
        console.info("[upw] all attachments requested");
    } catch (error) { attachmentPolicyError(error); }
}

async function endDownloadAllAttachments() {
    try {
        await updateAttachmentPolicy(ledger => ledger.cancelAll());
        status(t("已结束下载全部请求，正常后台下载规则继续适用。", "The download-all request ended. Normal background download rules still apply."));
        console.info("[upw] whole-library attachment request ended");
    } catch (error) { attachmentPolicyError(error); }
}

function appendOfflineAttachmentControl(row, item, attachment) {
    const version = attachmentVersionKey({ cardID: item.id, id: attachment.id,
        contentVersion: attachment.contentVersion, missing: attachment.state === "missing" });
    if (!version) return;
    const button = document.createElement("button");
    button.type = "button";
    button.className = "secondary attachment-offline";
    const retained = attachmentPolicyView?.isKeptOffline(version) === true;
    button.textContent = retained ? t("允许清理此离线缓存", "Allow clearing this offline cache") : t("保留离线", "Keep offline");
    button.setAttribute("aria-pressed", String(retained));
    button.disabled = attachmentPolicyUnavailable;
    button.addEventListener("click", async () => {
        button.disabled = true;
        let retainedSaved = false;
        try {
            await updateAttachmentPolicy(ledger => ledger.setKeptOffline(version, !retained));
            retainedSaved = true;
            if (selectedItemId?.toLowerCase() !== item.id.toLowerCase() || currentView !== "detail") return;
            const current = unlockedItems?.find(entry => entry.id.toLowerCase() === item.id.toLowerCase());
            if (current) paintItemDetail(current, false);
            console.info("[upw] attachment offline retention changed; retained:", !retained);
            if (!retained && attachment.state === "missing") await requestPriorityAttachmentDownload(item.id, [attachment.id]);
        } catch (error) {
            if (!retainedSaved) attachmentPolicyError(error);
            else status(attachmentPauseText(version), true);
        } finally { button.disabled = attachmentPolicyUnavailable; }
    });
    row.appendChild(button);
}

async function scheduleAttachmentRetry() {
    clearTimeout(attachmentRetryTimer);
    attachmentRetryTimer = null;
    const generation = unlockedGeneration;
    if (unlockedItems === null || attachmentPolicyUnavailable || !attachmentPolicyView
        || syncInFlight || detailEditing || detailSaving || !await canDownloadAttachmentsInBackground()) return;
    if (generation !== unlockedGeneration || unlockedItems === null || !attachmentPolicyView) return;
    const due = attachmentPolicyReferences.some(reference => {
        const version = attachmentVersionKey(reference);
        return reference.missing && version && attachmentPolicyView.record(version)?.failure === "transient"
            && attachmentPolicyView.isReady(version);
    });
    const next = due ? Date.now() : attachmentPolicyView.nextRetry(attachmentPolicyReferences);
    if (next === null) return;
    attachmentRetryTimer = setTimeout(() => {
        attachmentRetryTimer = null;
        queueBackgroundAttachmentDownloads();
    }, Math.min(2_147_483_647, Math.max(0, next - Date.now())));
}

async function attachmentNetworkChanged() {
    const connection = navigator.connection ?? navigator.mozConnection ?? navigator.webkitConnection;
    const available = navigator.onLine !== false && connection?.type !== "none";
    const recovered = !attachmentNetworkAvailable && available;
    attachmentNetworkAvailable = available;
    if (!available || !attachmentInFlightPrioritized && !await canDownloadAttachmentsInBackground()) attachmentAbortController?.abort();
    if (unlockedItems === null) return;
    try {
        if (recovered) await updateAttachmentPolicy(ledger => ledger.recoverNetwork());
        queueBackgroundAttachmentDownloads();
    } catch (error) { attachmentPolicyError(error); }
}

async function canDownloadAttachmentsInBackground() {
    if (navigator.onLine === false) return false;
    const connection = navigator.connection ?? navigator.mozConnection ?? navigator.webkitConnection;
    if (connection?.saveData === true || connection?.type === "none") return false;
    if (connection?.type === "wifi" || connection?.type === "ethernet") return true;
    if (connection?.type === "cellular") {
        const settings = await storageGet([CELLULAR_ATTACHMENT_KEY]);
        return settings[CELLULAR_ATTACHMENT_KEY] === true;
    }
    const settings = await storageGet([UNKNOWN_NETWORK_ATTACHMENT_KEY]);
    return settings[UNKNOWN_NETWORK_ATTACHMENT_KEY] === true;
}

function queueBackgroundAttachmentDownloads() {
    if (unlockedItems !== null) {
        void updateAttachmentPolicy().catch(error => {
            if (!["session_changed", "attachment_sync_deferred"].includes(error?.message)) attachmentPolicyError(error);
        });
    }
    backgroundAttachmentRequested = true;
    void drainAttachmentQueue();
}

function requestPriorityAttachmentDownload(itemID, attachmentIDs) {
    if (attachmentPolicyUnavailable) return Promise.reject(new Error("attachment_policy_unavailable"));
    if (navigator.onLine === false) return Promise.reject(new Error("offline"));
    const key = itemID.toLowerCase();
    const active = activeAttachmentRows.get(key);
    if (active) {
        const generation = unlockedGeneration;
        return active.catch(() => undefined).then(() => {
            if (generation !== unlockedGeneration || unlockedItems === null) throw new Error("session_changed");
            return requestPriorityAttachmentDownload(itemID, attachmentIDs);
        });
    }
    const pending = priorityAttachmentTasks.get(key);
    if (pending) return pending;
    let resolve;
    let reject;
    const promise = new Promise((resolvePromise, rejectPromise) => {
        resolve = resolvePromise;
        reject = rejectPromise;
    });
    const task = { itemID, key, attachmentIDs, resolve, reject, promise };
    priorityAttachmentTasks.set(key, promise);
    priorityAttachmentQueue.push(task);
    void drainAttachmentQueue();
    return promise;
}

async function drainAttachmentQueue() {
    if (attachmentSyncTask || syncInFlight || unlockedItems === null || attachmentPolicyUnavailable) return;
    const workerGeneration = unlockedGeneration;
    attachmentAbortController = new AbortController();
    attachmentSyncTask = (async () => {
        let versionCatalogPromise;
        const listVersions = (token, vaultID) => {
            versionCatalogPromise ??= listVaultAttachmentVersions(token, vaultID);
            return versionCatalogPromise;
        };
        while (!syncInFlight && unlockedItems !== null && workerGeneration === unlockedGeneration && !attachmentPolicyUnavailable) {
            let task = priorityAttachmentQueue.shift();
            let itemID = task?.itemID;
            let attachmentIDs = task?.attachmentIDs;
            if (!task && backgroundAttachmentRequested) {
                backgroundAttachmentRequested = false;
                if (!await canDownloadAttachmentsInBackground()) {
                    console.info("[upw] background attachment downloads paused by network policy");
                    continue;
                }
                try {
                    const bag = await storageGet([SESSION_KEY, VAULT_KEY]);
                    const scope = cacheScope(bag[SESSION_KEY], bag[VAULT_KEY]);
                    const snapshot = await encryptedCache.read(scope);
                    backgroundAttachmentQueue = (snapshot?.rows ?? []).filter(row => row.kind === 1).map(row => row.uuid);
                } catch (error) {
                    console.warn("[upw] attachment queue initialization failed; code:", error?.code ?? error?.name);
                    continue;
                }
                task = priorityAttachmentQueue.shift();
                itemID = task?.itemID;
                attachmentIDs = task?.attachmentIDs;
            }
            if (!task && backgroundAttachmentQueue.length) {
                if (!await canDownloadAttachmentsInBackground()) {
                    console.info("[upw] background attachment downloads paused by network policy");
                    backgroundAttachmentQueue = [];
                    break;
                }
                itemID = backgroundAttachmentQueue.shift();
            }
            if (!itemID || workerGeneration !== unlockedGeneration) break;
            const key = itemID.toLowerCase();
            attachmentInFlightPrioritized = Boolean(task);
            const rowTask = hydrateAndPublishAttachmentRow(itemID, attachmentIDs, listVersions, Boolean(task), task?.firstAttempt !== false);
            const publishedTask = rowTask.then(result => result.item);
            // The worker handles rejection; active callers can also await this projection promise.
            void publishedTask.catch(() => undefined);
            activeAttachmentRows.set(key, publishedTask);
            try {
                const outcome = await rowTask;
                if (task) {
                    task.firstAttempt = false;
                    task.failure ??= outcome.error;
                    if (outcome.more) priorityAttachmentQueue.unshift(task);
                    else {
                        if (task.failure) task.reject(task.failure);
                        else task.resolve(outcome.item);
                        priorityAttachmentTasks.delete(key);
                    }
                } else if (outcome.more) backgroundAttachmentQueue.push(itemID);
            } catch (error) {
                if (["attachment_sync_deferred", "attachment_policy_version_conflict", "cache_version_conflict"].includes(error?.message)
                    && workerGeneration === unlockedGeneration) {
                    if (task) priorityAttachmentQueue.unshift(task);
                    else backgroundAttachmentQueue.unshift(itemID);
                    break;
                }
                task?.reject(error);
                if (task) priorityAttachmentTasks.delete(key);
                console.warn("[upw] attachment queue step stopped; code:", error?.code ?? error?.name);
                if (error?.name === "AbortError" || error?.message === "session_changed") break;
            } finally {
                activeAttachmentRows.delete(key);
                attachmentInFlightPrioritized = false;
            }
        }
    })();
    try {
        await attachmentSyncTask;
    } catch (error) {
        console.warn("[upw] attachment queue stopped; code:", error?.code ?? error?.name);
    } finally {
        attachmentSyncTask = null;
        attachmentAbortController = null;
        if (!syncInFlight && !detailEditing && !detailSaving && unlockedItems !== null && !attachmentPolicyUnavailable
            && (priorityAttachmentQueue.length || backgroundAttachmentRequested || backgroundAttachmentQueue.length)) {
            void drainAttachmentQueue();
        } else {
            void scheduleAttachmentRetry().catch(error => console.warn("[upw] attachment retry scheduling failed; code:", error?.name));
        }
    }
}

async function syncVault(auto = false) {
    if (unlockedItems === null || syncInFlight || attachmentPublicationInFlight
        || quarantineRetryInFlight || detailEditing || detailSaving
        || currentView === "new-login" || newLoginSaving) return;
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
    updateSyncSummary();
    const startedAt = Date.now();
    console.info("[upw] incremental sync started");
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
            verifyRows: rows => verifyRowsAndCollect(rows, fragments, { generation, context, validate }),
            sealQuarantine: async (identity, row) => {
                const response = await sessionCommand("seal-quarantine", {
                    generation, quarantineIdentity: identity, quarantineRow: row,
                }, context);
                if (!response.unlocked || !response.quarantineCipherB64) {
                    throw new Error(response.code ?? "quarantine_encrypt_failed");
                }
                return response.quarantineCipherB64;
            },
        });
        persisted = outcome.snapshot.version !== expectedSnapshotVersion;
        if (persisted) {
            try {
                const attachmentVersions = await listVaultAttachmentVersions(session.token, vault.id);
                await validate();
                await encryptedCache.replaceAttachmentVersions(
                    scope, outcome.snapshot.accountEpoch, outcome.snapshot.version, attachmentVersions,
                );
            } catch (error) {
                console.warn("[upw] attachment metadata refresh deferred; code:", error?.code ?? error?.message ?? error?.name);
            }
        }
        syncQuarantineItems = outcome.snapshot.quarantinedItems ?? [];
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
        lastSyncSuccessAt = Date.now();
        syncFailed = false;
        updateSyncSummary();
        renderSyncQuarantine();
        if (persisted || !auto) await render();
        if (!auto && outcome.quarantinedCount > 0) {
            status(t(`已隔离 ${outcome.quarantinedCount} 条无法验证的云端记录；其他同步已继续。`,
                `Isolated ${outcome.quarantinedCount} unreadable cloud record(s); other changes synced.`));
        } else if (!auto) status(outcome.changedCount === 0
            ? t("已是最新", "Vault is up to date")
            : t(`已同步 ${outcome.changedCount} 项变化`, `Synced ${outcome.changedCount} changes`));
        console.info("[upw] incremental sync complete; changes:", outcome.changedCount);
    } catch (error) {
        if (operation !== operationGeneration) return;
        syncFailed = true;
        console.warn("[upw] sync did not finish; code:", error?.code ?? error?.name);
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
        updateSyncSummary();
        renderSyncQuarantine();
        console.info("[upw] incremental sync finished; ms:", Date.now() - startedAt);
        if (published && operation === operationGeneration && generation === unlockedGeneration) {
            queueBackgroundAttachmentDownloads();
        }
    }
}

// MARK: - 候选与填充

function isPersonalInfoItem(item) {
    return item.recordType === "userProfile";
}

function personalInfoFields(item) {
    const tokens = new Set([
        "given-name", "family-name", "email", "tel", "street-address",
        "address-line1", "address-line2", "address-level1", "address-level2",
        "postal-code", "country-name",
    ]);
    return item.fields.filter((field) => tokens.has(field.autofill) && Boolean(field.value));
}

function canFillPersonalInfo(item) {
    return isPersonalInfoItem(item) && item.autofillEnabled !== false
        && personalInfoFields(item).length > 0;
}

function renderCandidates(items) {
    itemsEl.replaceChildren();
    suggestionsEl.replaceChildren();
    const query = searchInput.value.trim().toLocaleLowerCase();
    const filter = siteFilter.value;
    const candidates = items
        .map((item) => ({ item, ...credentialsOf(item) }))
        .filter(({ item, username }) => (!isPersonalInfoItem(item)
            || (registrationForm && canFillPersonalInfo(item)))
            && (filter !== "favorites" || item.favorite === true)
            && (filter !== "current" || (isPersonalInfoItem(item)
                ? registrationForm && canFillPersonalInfo(item)
                : Boolean(host && itemMatchesPage(pageUrl, item))))
            && (!query || item.title.toLocaleLowerCase().includes(query)
                || username.toLocaleLowerCase().includes(query)
                || item.host.toLocaleLowerCase().includes(query)))
        .sort((left, right) => left.item.title.localeCompare(right.item.title)
            * (sortItems.value === "title-desc" ? -1 : 1));
    suggestionSection.hidden = true;
    resultCount.textContent = String(candidates.length);
    emptyState.hidden = candidates.length > 0;
    document.getElementById("emptyNewLoginButton").hidden = candidates.length > 0;
    const narrowed = query || filter === "favorites" || filter === "current";
    document.getElementById("itemsHeading").textContent = filter === "current" ? t("当前网站", "Current site")
        : filter === "favorites" ? t("收藏条目", "Favorites") : t("全部条目", "All items");
    document.getElementById("emptyTitle").textContent = narrowed
        ? t("没有搜索结果", "No matching items") : t("密码库暂无条目", "Your vault is empty");
    document.getElementById("emptyDescription").textContent = narrowed
        ? t("调整搜索或筛选，也可以新建登录。", "Change the search or filter, or create a new login.")
        : t("新建第一条登录，或同步已有密码。", "Create your first login, or sync existing passwords.");
    for (const candidate of candidates) appendCandidate(candidate, itemsEl);
}

function appendCandidate(candidate, list) {
    if (isPersonalInfoItem(candidate.item)) {
        candidate.item.title = t("个人资料", "Personal information");
    }
    const li = document.createElement("li");
    li.className = "item";
    li.dataset.itemId = candidate.item.id;
    const button = document.createElement("button");
    button.type = "button";
    const canFill = isPersonalInfoItem(candidate.item)
        ? registrationForm && canFillPersonalInfo(candidate.item)
        : Boolean(host && itemMatchesPage(pageUrl, candidate.item));
    const avatar = document.createElement("span");
    avatar.className = "item-avatar";
    avatar.setAttribute("aria-hidden", "true");
    // 头像按标题字符和取色,无需网络图标即可视觉区分条目
    let tint = 0;
    for (const ch of candidate.item.title) tint = (tint + (ch.codePointAt(0) ?? 0)) % 6;
    avatar.dataset.tint = String(tint);
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
    // 匹配当前网站的条目点击即填充(主路径);其余条目点击进详情
    if (canFill) button.title = t("点击填充到当前页面", "Click to fill this page");
    button.addEventListener("click", () => {
        // 入口探针:区分"点击没触发"与"走了某分支"(测试 vm 无 console,用 globalThis 守卫)
        globalThis.console?.info?.("[upw] item row click; canFill:", canFill);
        if (canFill) void fill(candidate, li);
        else void openItemDetail(candidate.item.id);
    });
    li.appendChild(button);
    const actions = document.createElement("div");
    actions.className = "item-actions";
    const copyUsername = document.createElement("button");
    copyUsername.type = "button";
    copyUsername.textContent = t("复制用户名", "Copy user");
    copyUsername.addEventListener("click", () => void copyText({ id: candidate.item.id, field: "username" }));
    actions.appendChild(copyUsername);
    if (candidate.password) {
        const copyPassword = document.createElement("button");
        copyPassword.type = "button";
        copyPassword.textContent = t("复制密码", "Copy password");
        copyPassword.addEventListener("click", () => void copyText({ id: candidate.item.id, field: "password" }));
        actions.appendChild(copyPassword);
    }
    if (canFill) {
        const detailButton = document.createElement("button");
        detailButton.type = "button";
        detailButton.textContent = t("详情", "Detail");
        detailButton.addEventListener("click", () => { void openItemDetail(candidate.item.id); });
        actions.appendChild(detailButton);
        const fillButton = document.createElement("button");
        fillButton.type = "button";
        fillButton.className = "fill-action";
        fillButton.textContent = t("填充", "Fill");
        fillButton.addEventListener("click", () => { void fill(candidate, li); });
        actions.appendChild(fillButton);
    }
    if (canFill) li.classList.add("match");
    li.appendChild(actions);
    list.appendChild(li);
}

async function copyText(value) {
    const operation = operationGeneration;
    const generation = unlockedGeneration;
    try {
        const state = await sessionCommand("read");
        if (operation !== operationGeneration || generation !== unlockedGeneration
            || !state.unlocked || state.generation !== generation) return;
        const fresh = state.items?.find(item => item.id === value.id);
        if (!fresh) return;
        if (Number.isInteger(value.index) && value.revision !== undefined
            && fresh.source?.revision !== value.revision) {
            status(t("条目已更新，请重新打开详情后复制。", "This item changed. Reopen its details before copying."), true);
            return;
        }
        const text = value.field === "username" ? credentialsOf(fresh).username
            : value.field === "password" ? credentialsOf(fresh).password
            : value.field === "title" ? fresh.title
            : value.field === "notes" ? readItemDetail(fresh).notes
            : Number.isInteger(value.index) ? fresh.fields[value.index]?.value : "";
        if (!text) return;
        await navigator.clipboard.writeText(text);
        status(t("已复制。内容会留在剪贴板，直到被覆盖。", "Copied. Clipboard contents remain until overwritten."));
        console.info("[upw] clipboard copy completed");
    } catch {
        status(t("无法写入剪贴板，请检查浏览器权限。", "Could not write to clipboard. Check browser permissions."), true);
        console.warn("[upw] clipboard write failed");
    }
}


async function quickFillCurrentSite() {
    console.info("[upw] site banner quick fill requested");
    status(t("正在查找当前网站的匹配项…", "Finding a matching item for this site…"));
    try {
        const state = await sessionCommand("read");
        if (!state.unlocked || state.generation !== unlockedGeneration) {
            await render();
            status(t("密码库已锁定，请重新解锁后重试。", "Your vault is locked. Unlock it again and retry."), true);
            return;
        }
        const currentItems = state.items ?? [];
        const candidatesFor = items => items
            .filter(item => itemMatchesPage(pageUrl, item) && Boolean(credentialsOf(item).password))
            .map(item => ({ item, ...credentialsOf(item) }))
            .sort((left, right) => left.item.title.localeCompare(right.item.title)
                * (sortItems.value === "title-desc" ? -1 : 1));
        const candidates = candidatesFor(unlockedItems ?? currentItems);
        const candidate = candidates[0] ?? candidatesFor(currentItems)[0];
        if (!candidate) {
            const hostMatchesCount = currentItems.filter(item => itemMatchesPage(pageUrl, item)).length;
            const passwordItemCount = currentItems.filter(item => Boolean(credentialsOf(item).password)).length;
            console.warn("[upw] site banner quick fill unavailable:", {
                sessionItems: currentItems.length,
                hostMatches: hostMatchesCount,
                passwordItems: passwordItemCount,
            });
            status(t("当前解锁会话中没有找到此网站的密码项。请重新同步密码库；若仍不行，请检查条目中的网站地址和密码字段。", "No password entry for this site was found in the current unlocked session. Sync the vault, then check the item's website and password field if needed."), true);
            return;
        }
        const row = [...itemsEl.children].find(element => element.dataset.itemId === candidate.item.id) ?? null;
        await fill(candidate, row);
    } catch {
        console.warn("[upw] site banner quick fill failed: session unavailable");
        status(t("无法读取密码库，请重新打开扩展后重试。", "Could not read the vault. Reopen the extension and try again."), true);
    }
}

/** 在点击时重新确认当前页面与会话有效性，只注入本次填充所需字段。 */
async function fill(candidate, li) {
    const profile = isPersonalInfoItem(candidate.item);
    if (!tab?.id || !/^https?:\/\//i.test(pageUrl)
        || (profile ? !registrationForm || !canFillPersonalInfo(candidate.item)
            : !itemMatchesPage(pageUrl, candidate.item))) {
        console.warn("[upw] fill skipped: page context not fillable");
        status(t("当前页面不可填充，请重新打开扩展后重试。", "This page cannot be filled. Reopen the extension and try again."), true);
        return;
    }
    console.info("[upw] fill started");
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
        if (!current || (profile
            ? !canFillPersonalInfo(current) || !registrationForm
            : !itemMatchesPage(pageUrl, current))) {
            console.warn("[upw] fill aborted: item missing or host mismatch in session");
            status(t("条目已变化或与当前网站不匹配，请刷新后重试。", "The item changed or no longer matches this site. Refresh and try again."), true);
            return;
        }
        const gateKnown = await ensureAutofillConflictGate();
        if (!isCurrent()) return;
        const { username, password } = profile ? { username: "", password: "" } : credentialsOf(current);
        const fieldTokens = profile
            ? personalInfoFields(current).map(field => field.autofill)
            : [
                ...(username ? ["username"] : []),
                ...(password ? ["current-password"] : []),
            ];
        if (!gateKnown) {
            status(t("暂时无法确认此条目的同步冲突，请联网刷新后重试。", "This item's sync conflicts could not be checked. Connect and refresh before filling."), true);
            return;
        }
        if (autofillConflictBlocks(autofillConflictGate, current.id, fieldTokens)) {
            status(t("此条目的相关字段存在待处理冲突，请先处理冲突。", "The fields needed for this fill have unresolved conflicts. Resolve them first."), true);
            return;
        }
        const touched = await sessionCommand("touch");
        if (!isCurrent()) return;
        if (!touched.unlocked || touched.generation !== unlockedGeneration) {
            await render();
            status(t("密码库已锁定，请重新解锁后重试。", "Your vault is locked. Unlock it again and retry."), true);
            return;
        }
        unlockedExpiresAt = touched.expiresAt;
        const [activeTab] = await browser.tabs.query({ active: true, currentWindow: true });
        if (!isCurrent()) return;
        const activePageURL = activeTab?.url ?? "";
        if (activeTab?.id !== tab.id || !/^https?:\/\//i.test(activePageURL)
            || canonicalizeHost(hostnameOf(activePageURL)) !== host
            || (!profile && !itemMatchesPage(activePageURL, current))) {
            console.warn("[upw] fill aborted: active tab changed");
            status(t("页面已切换，请重新打开插件后重试。", "The page changed. Reopen the extension and try again."), true);
            return;
        }
        if (new URL(activeTab.url).protocol === "http:" && !window.confirm(t(
            profile ? "此页面使用不安全的 HTTP 连接。仍要填充个人资料吗？" : "此页面使用不安全的 HTTP 连接。仍要填充密码吗？",
            profile ? "This page uses an insecure HTTP connection. Fill personal info anyway?" : "This page uses an insecure HTTP connection. Fill the password anyway?",
        ))) return;
        const fillItem = {
            id: current.id, title: current.title, symbol: current.symbol, host: current.host,
            ...(profile ? { recordType: "userProfile" } : {}),
            autofillEnabled: current.autofillEnabled,
            fields: profile ? personalInfoFields(current)
                : [
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
            li?.querySelector(".ok")?.remove();
            li?.appendChild(mark);
            console.info("[upw] popup fill succeeded");
            // 填充完成自动收起弹窗;测试环境无 close 时跳过
            window.close?.();
        } else {
            console.warn("[upw] popup fill: no form");
            status(profile
                ? t("没有找到可填入的空白个人资料字段。", "No empty personal information fields were found.")
                : t("页面上没找到可填充的登录表单，请确认页面表单可见后重试。", "No fillable login form was found. Make sure the login form is visible and try again."), true);
        }
    } catch {
        if (!isCurrent()) return;
        console.warn("[upw] popup fill: page unavailable");
        status(t("无法访问该页面，请刷新页面或重新加载扩展后重试。", "Can't access this page. Refresh it or reload the extension and try again."), true);
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

async function hydrateAndPublishAttachmentRow(itemID, attachmentIDs, listVersions, interactive, beginRequest = true) {
    if (syncInFlight || detailEditing || detailSaving) throw new Error("attachment_sync_deferred");
    const generation = unlockedGeneration;
    const expectedSnapshotVersion = unlockedSnapshotVersion;
    const bag = await storageGet([SESSION_KEY, VAULT_KEY]);
    const session = bag[SESSION_KEY];
    const vault = bag[VAULT_KEY];
    if (!session?.token || !vault?.id || session.expiresAt <= Date.now()) throw new Error("session_changed");
    const context = sessionContext(session, vault);
    await requireRelayAccess(interactive);
    const scope = cacheScope(session, vault);
    const cached = await encryptedCache.read(scope);
    if (!cached || cached.version !== expectedSnapshotVersion) throw new Error("attachment_sync_deferred");
    const validate = async () => {
        if (unlockedItems === null || generation !== unlockedGeneration) throw new Error("session_changed");
        if (syncInFlight || detailEditing || detailSaving) throw new Error("attachment_sync_deferred");
        const active = await storageGet([SESSION_KEY, VAULT_KEY]);
        if (active[SESSION_KEY]?.token !== session.token || active[SESSION_KEY]?.userId !== session.userId
            || active[VAULT_KEY]?.id !== vault.id) throw new Error("session_changed");
        const state = await sessionCommand("read", {}, context);
        if (!state.unlocked || state.generation !== generation) throw new Error("session_changed");
        attachmentAbortController?.signal.throwIfAborted();
        if (state.snapshotVersion !== expectedSnapshotVersion) throw new Error("attachment_sync_deferred");
    };
    const row = cached.rows.find(entry => entry.uuid.toLowerCase() === itemID.toLowerCase());
    const currentItem = () => unlockedItems?.find(item => item.id.toLowerCase() === itemID.toLowerCase()) ?? null;
    if (!row || row.kind !== 1) return { item: currentItem(), more: false };
    await validate();
    let prepared;
    try {
        prepared = await updateAttachmentPolicy((ledger, references) => {
            if (!interactive || !beginRequest) return;
            for (const reference of references.filter(entry => entry.cardID === itemID.toLowerCase()
                && (!attachmentIDs || attachmentIDs.some(id => id.toLowerCase() === entry.id)))) {
                const version = attachmentVersionKey(reference);
                if (!version) continue;
                ledger.access(version);
                ledger.request(version, Boolean(attachmentIDs));
            }
        });
    } catch (error) {
        attachmentPolicyError(error);
        throw error;
    }
    await validate();
    const ledger = new AttachmentDownloadLedger(prepared.stored.state);
    const source = prepared.fragments.find(fragment => fragment.row.uuid.toLowerCase() === itemID.toLowerCase());
    if (!source) throw new Error("attachment_policy_corrupt");
    const missing = readAttachmentReferences(source.xml, row.uuid).filter(reference => reference.missing
        && (!attachmentIDs || attachmentIDs.some(id => id.toLowerCase() === reference.id)));
    const ready = missing.find(reference => {
        const version = attachmentVersionKey({ cardID: row.uuid, ...reference });
        return version && ledger.isReady(version);
    });
    if (!ready) {
        if (selectedItemId?.toLowerCase() === itemID.toLowerCase() && currentView === "detail" && currentItem()) {
            paintItemDetail(currentItem(), false);
        }
        return { item: currentItem(), more: false,
            ...(interactive && missing.length ? { error: new Error("attachment_paused") } : {}) };
    }
    const versionKey = attachmentVersionKey({ cardID: row.uuid, ...ready });
    const crypto = {
        signal: attachmentAbortController?.signal,
        listVersions: () => listVersions(session.token, vault.id),
        decryptRow: async value => {
            const response = await sessionCommand("decrypt", { generation, rows: [value] }, context);
            if (!response.unlocked || !response.fragments?.[0]) throw new Error(response.code ?? "session_key_missing");
            return response.fragments[0].xml;
        },
        encryptRow: async (value, xml) => {
            const response = await sessionCommand("encrypt", { generation, uuid: value.uuid, xml }, context);
            if (!response.unlocked || !response.bodyB64) throw new Error(response.code ?? "session_key_missing");
            return response.bodyB64;
        },
        decryptAttachment: async (cipher, version) => {
            const response = await sessionCommand("decrypt-attachment", {
                generation, attachmentID: version.attachmentId, contentVersion: version.contentVersion,
                cipherB64: bytesToBase64(cipher), dekWrappedB64: version.dekWrapped,
            }, context);
            if (!response.unlocked || typeof response.attachmentB64 !== "string") throw new Error(response.code ?? "attachment_decrypt_failed");
            return base64ToBytes(response.attachmentB64);
        },
        storeAttachment: async (version, cipher) => {
            await encryptedCache.writeAttachmentContent(
                scope, cached.accountEpoch, cached.version, version, cipher,
            );
        },
    };
    let persisted = false;
    const startedAt = Date.now();
    try {
        console.info("[upw] attachment download started; item:", row.uuid, "attachment:", ready.id);
        const [hydrated] = await hydrateMissingAttachments(
            session.token, vault.id, [row], cached.rows, validate, crypto, [ready.id],
        );
        if (hydrated.bodyB64 === row.bodyB64) return { item: currentItem(), more: false };
        if (hydrated.uuid.toLowerCase() !== row.uuid.toLowerCase() || hydrated.revision !== row.revision
            || hydrated.kind !== row.kind || hydrated.modifiedMs !== row.modifiedMs) throw new Error("attachment_row_identity_changed");
        await validate();
        const xml = await crypto.decryptRow(hydrated);
        const fragments = prepared.fragments.map(fragment => fragment.row.uuid.toLowerCase() === row.uuid.toLowerCase()
            ? { row: hydrated, xml } : fragment);
        const references = attachmentReferencesIn(fragments);
        const installed = references.find(reference => attachmentVersionKey(reference) === versionKey);
        if (!installed || installed.missing) throw new Error("attachment_integrity_failure");
        ledger.succeed(versionKey);
        const cachedBytes = references.reduce((sum, reference) => sum + attachmentByteCount(reference.base64), 0);
        const overBudget = cachedBytes > ATTACHMENT_CACHE_BUDGET_BYTES;
        const versions = overBudget ? await listVersions(session.token, vault.id) : [];
        const conflicts = overBudget ? await listVaultConflicts(session.token, vault.id) : [];
        await validate();
        const plan = planAttachmentCache({ fragments, ledger, remoteVersions: versions,
            budgetBytes: ATTACHMENT_CACHE_BUDGET_BYTES,
            conflictCardIDs: new Set(conflicts.map(conflict => conflict.itemUuid.toLowerCase())),
            protectedCardIDs: new Set([row.uuid.toLowerCase(), selectedItemId?.toLowerCase()].filter(Boolean)),
        });
        if (!plan.hasCapacity) throw new Error("attachment_cache_full");
        const nextRows = new Map(cached.rows.map(value => [value.uuid.toLowerCase(), value]));
        const projections = new Map();
        nextRows.set(row.uuid.toLowerCase(), hydrated);
        for (const fragment of plan.fragments) {
            const original = fragments.find(value => value.row.uuid.toLowerCase() === fragment.row.uuid.toLowerCase());
            const isSelected = fragment.row.uuid.toLowerCase() === row.uuid.toLowerCase();
            if (original.xml !== fragment.xml) {
                nextRows.set(fragment.row.uuid.toLowerCase(), { ...fragment.row,
                    bodyB64: await crypto.encryptRow(fragment.row, fragment.xml) });
                await validate();
            }
            if (isSelected || original.xml !== fragment.xml) {
                projections.set(fragment.row.uuid.toLowerCase(), projectVaultFragment({ ...fragment.row, xml: fragment.xml }));
            }
        }
        const finalReferences = attachmentReferencesIn(plan.fragments);
        plan.ledger.reconcile(finalReferences);
        const items = unlockedItems.flatMap(entry => projections.has(entry.id.toLowerCase())
            ? [projections.get(entry.id.toLowerCase())].filter(Boolean) : [entry]);
        await validate();
        attachmentPublicationInFlight = true;
        const snapshot = await encryptedCache.commit({ ...cached, rows: [...nextRows.values()] }, cached.version,
            { state: plan.ledger.toJSON(), expectedVersion: prepared.stored.version });
        persisted = true;
        const refreshed = await sessionCommand("refresh", {
            generation, expectedSnapshotVersion, snapshotVersion: snapshot.version,
            passwordVersion: snapshot.passwordVersion, items,
        }, context);
        if (!refreshed.unlocked || refreshed.generation !== generation) throw new Error("session_changed");
        unlockedItems = items;
        unlockedSnapshotVersion = snapshot.version;
        unlockedPasswordVersion = snapshot.passwordVersion;
        unlockedExpiresAt = refreshed.expiresAt;
        attachmentPolicyView = plan.ledger;
        attachmentPolicyReferences = finalReferences;
        updateAttachmentDownloadSummary();
        const updated = currentItem();
        if (updated && selectedItemId?.toLowerCase() === row.uuid.toLowerCase() && currentView === "detail" && !detailEditing) paintItemDetail(updated, false);
        const more = finalReferences.some(reference => reference.cardID === row.uuid.toLowerCase() && reference.missing
            && (!attachmentIDs || attachmentIDs.some(id => id.toLowerCase() === reference.id))
            && attachmentVersionKey(reference) && plan.ledger.isReady(attachmentVersionKey(reference)));
        console.info("[upw] attachment download finished; ms:", Date.now() - startedAt, "evicted:", plan.evictedVersions.length);
        return { item: updated, more };
    } catch (error) {
        if (persisted && generation === unlockedGeneration) {
            await sessionCommand("lock", { generation }, context).catch(() => console.warn("[upw] stale attachment session invalidation failed"));
            if (generation === unlockedGeneration) {
                clearUnlockedView();
                await render();
                status(t("加密缓存已更新，请重新解锁本地副本。", "The encrypted cache was updated. Unlock the local copy again."), true);
            }
            throw error;
        }
        const failure = classifyAttachmentFailure(error);
        if (!failure) throw error;
        await validate();
        try {
            await updateAttachmentPolicy(policy => policy.fail(versionKey, failure.failure, Date.now(), failure.minimumDelay));
        } catch (policyError) {
            attachmentPolicyError(policyError);
            throw policyError;
        }
        const more = missing.some(reference => {
            const key = attachmentVersionKey({ cardID: row.uuid, ...reference });
            return key && attachmentPolicyView.isReady(key);
        });
        if (selectedItemId?.toLowerCase() === row.uuid.toLowerCase() && currentView === "detail" && currentItem()) paintItemDetail(currentItem(), false);
        console.warn("[upw] attachment download failed; ms:", Date.now() - startedAt, "code:", error?.code ?? error?.name);
        return { item: currentItem(), more, error };
    } finally {
        attachmentPublicationInFlight = false;
    }
}

function downloadDetailAttachment(itemID, attachmentID) {
    return requestPriorityAttachmentDownload(itemID, [attachmentID]);
}

function detailInput(labelText, value, editing, secret = false, multiline = false, copySource) {
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
    if (copySource && !editing) {
        const copyButton = document.createElement("button");
        copyButton.type = "button";
        copyButton.className = "secondary";
        copyButton.textContent = t("复制", "Copy");
        copyButton.setAttribute("aria-label", t(`复制${labelText}`, `Copy ${labelText}`));
        copyButton.addEventListener("click", () => copyText(copySource));
        row.appendChild(copyButton);
    }
    input.detailGroup = group;
    group.append(label, row);
    detailContent.appendChild(group);
    return input;
}

function appendInlineAttachments(item) {
    let attachments;
    try {
        attachments = readInlineAttachments(item);
    } catch {
        console.warn("[upw] attachment preview metadata unavailable");
        return;
    }
    const previews = attachments;
    if (!previews.length) return;

    const section = document.createElement("section");
    section.className = "detail-attachments";
    const heading = document.createElement("h3");
    heading.textContent = t("附件", "Attachments");
    section.appendChild(heading);

    for (const attachment of previews) {
        const row = document.createElement("div");
        row.className = "detail-attachment";
        row.dataset.cardId = item.id;
        row.dataset.attachmentState = attachment.state;
        row.dataset.attachmentVersion = attachmentVersionKey({ cardID: item.id, id: attachment.id,
            contentVersion: attachment.contentVersion, missing: attachment.state === "missing" }) ?? "";
        const rowHeading = document.createElement("div");
        rowHeading.className = "detail-attachment-heading";
        const name = document.createElement("span");
        name.className = "detail-attachment-name";
        name.textContent = attachment.name || t("未命名图片", "Unnamed image");
        rowHeading.appendChild(name);
        row.appendChild(rowHeading);

        if (attachment.state !== "previewable" || !attachment.base64 || !attachment.mimeType) {
            const note = document.createElement("p");
            note.className = "detail-attachment-note";
            const version = attachmentVersionKey({ cardID: item.id, id: attachment.id,
                contentVersion: attachment.contentVersion, missing: attachment.state === "missing" });
            note.textContent = attachment.state === "missing"
                ? version ? attachmentPauseText(version) : t("此附件尚未下载到本机。", "This attachment is not downloaded on this device.")
                : attachment.state === "too_large"
                    ? t("图片超过预览大小限制。", "This image exceeds the preview size limit.")
                    : attachment.state === "not_image"
                        ? t("文件已保存在本机，可通过“保留离线”避免自动清理。", "File is available locally. Keep it offline to prevent automatic cleanup.")
                        : t("此附件当前无法预览。", "This attachment cannot be previewed right now.");
            row.appendChild(note);
            if (attachment.state === "missing" && attachment.id && attachment.contentVersion) {
                const download = document.createElement("button");
                download.type = "button";
                download.className = "secondary";
                download.textContent = attachment.kind === "image" ? t("立即下载并预览", "Download and preview") : t("立即下载", "Download now");
                download.addEventListener("click", async () => {
                    download.disabled = true;
                    download.textContent = t("正在下载…", "Downloading…");
                    try {
                        const updated = await downloadDetailAttachment(item.id, attachment.id);
                        if (updated) paintItemDetail(updated, false);
                        const preview = [...detailContent.querySelectorAll("button[data-attachment-id]")]
                            .find(button => button.dataset.attachmentId === attachment.id);
                        preview?.click();
                    } catch (error) {
                        download.disabled = false;
                        download.textContent = t("重试下载", "Retry download");
                        const failedReference = attachmentPolicyReferences.find(reference =>
                            reference.cardID === item.id.toLowerCase() && reference.id === attachment.id && reference.missing);
                        const failedVersion = failedReference ? attachmentVersionKey(failedReference) : null;
                        status(failedVersion ? attachmentPauseText(failedVersion)
                            : error?.status === 401
                                ? t("云端登录已过期，请重新登录后下载附件。", "Cloud sign-in expired. Sign in again to download this attachment.")
                                : t("附件下载未完成，现有数据已保留。请检查网络后重试。", "Attachment download failed. Existing data was preserved. Check the connection and retry."), true);
                        console.warn("[upw] priority attachment download failed; code:", error?.code ?? error?.name);
                    }
                });
                row.appendChild(download);
            }
            appendOfflineAttachmentControl(row, item, attachment);
            section.appendChild(row);
            continue;
        }

        const previewButton = document.createElement("button");
        previewButton.type = "button";
        previewButton.className = "secondary";
        previewButton.textContent = t("预览", "Preview");
        previewButton.dataset.attachmentId = attachment.id ?? "";
        rowHeading.appendChild(previewButton);

        const image = document.createElement("img");
        image.className = "detail-attachment-preview";
        image.alt = attachment.name || t("图片附件预览", "Image attachment preview");
        image.hidden = true;
        row.appendChild(image);

        const controls = document.createElement("div");
        controls.className = "detail-attachment-controls";
        controls.hidden = true;
        let zoom = 1;
        const setZoom = value => {
            zoom = Math.max(0.5, Math.min(3, value));
            image.style.transform = `scale(${zoom})`;
        };
        const zoomOut = document.createElement("button");
        zoomOut.type = "button";
        zoomOut.className = "secondary";
        zoomOut.textContent = "−";
        zoomOut.title = t("缩小图片", "Zoom out");
        zoomOut.setAttribute("aria-label", zoomOut.title);
        zoomOut.addEventListener("click", () => setZoom(zoom - 0.25));
        const resetZoom = document.createElement("button");
        resetZoom.type = "button";
        resetZoom.className = "secondary";
        resetZoom.textContent = t("重置", "Reset");
        resetZoom.title = t("重置图片大小", "Reset image size");
        resetZoom.setAttribute("aria-label", resetZoom.title);
        resetZoom.addEventListener("click", () => setZoom(1));
        const zoomIn = document.createElement("button");
        zoomIn.type = "button";
        zoomIn.className = "secondary";
        zoomIn.textContent = "+";
        zoomIn.title = t("放大图片", "Zoom in");
        zoomIn.setAttribute("aria-label", zoomIn.title);
        zoomIn.addEventListener("click", () => setZoom(zoom + 0.25));
        controls.append(zoomOut, resetZoom, zoomIn);
        row.appendChild(controls);

        image.addEventListener("error", () => {
            image.hidden = true;
            controls.hidden = true;
            previewButton.hidden = false;
            const note = document.createElement("p");
            note.className = "detail-attachment-note";
            note.textContent = t("图片数据无法解码。", "The image data could not be decoded.");
            row.appendChild(note);
        });
        previewButton.addEventListener("click", () => {
            image.src = `data:${attachment.mimeType};base64,${attachment.base64}`;
            image.hidden = false;
            controls.hidden = false;
            previewButton.hidden = true;
            setZoom(1);
        });
        appendOfflineAttachmentControl(row, item, attachment);
        section.appendChild(row);
    }
    detailContent.appendChild(section);
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
    detailTitleInput = detailInput(t("标题", "Title"), item.title, editing, false, false, { id: item.id, field: "title" });
    const fieldLabels = {
        login: t("用户名", "Username"), email: t("邮箱", "Email"), password: t("密码", "Password"),
        website: t("网站", "Website"), pin: "PIN", secret: t("秘密", "Secret"),
        one_time_password: t("验证码密钥", "OTP secret"),
    };
    detailFieldInputs = item.fields.map((field, index) => {
        const label = field.name && !field.name.startsWith("@string/")
            ? field.name : fieldLabels[field.type] ?? t(`字段 ${index + 1}`, `Field ${index + 1}`);
        const input = detailInput(label, field.value, editing,
            ["password", "pin", "secret", "one_time_password"].includes(field.type),
            !["password", "pin", "secret", "one_time_password"].includes(field.type) && /[\r\n]/.test(field.value),
            { id: item.id, index, revision: item.source?.revision });
        input.fieldName = field.name || label;
        input.fieldType = field.type;
        input.fieldAutofill = field.autofill || "off";
        input.siteMatch = field.siteMatch ?? "domain";
        input.fieldID = field.id;
        if (editing && field.type === "website") {
            const mode = document.createElement("select");
            for (const [value, zhLabel, enLabel] of [["domain", "基于域名", "Domain"], ["wildcard", "基于规则", "Wildcard rule"], ["exactURL", "完全匹配", "Exact URL"]]) {
                const option = document.createElement("option"); option.value = value; option.textContent = t(zhLabel, enLabel); mode.appendChild(option);
            }
            mode.value = input.siteMatch;
            mode.setAttribute("aria-label", t("网站匹配方式", "Website match mode"));
            mode.hidden = field.type !== "website";
            mode.addEventListener("change", () => { input.siteMatch = mode.value; });
            input.detailGroup.children[1].appendChild(mode);
            const fieldName = document.createElement("input"); fieldName.value = input.fieldName;
            fieldName.setAttribute("aria-label", t("字段名称", "Field name"));
            fieldName.addEventListener("input", () => { input.fieldName = fieldName.value; });
            const remove = document.createElement("button");
            remove.type = "button"; remove.className = "secondary"; remove.textContent = t("删除字段", "Remove field");
            remove.addEventListener("click", () => {
                detailFieldInputs = detailFieldInputs.filter(fieldInput => fieldInput !== input);
                input.detailGroup.remove();
            });
            input.detailGroup.children[1].append(fieldName, remove);
        }
        if (!editing && field.type === "website" && safeWebsiteUrl(field.value)) {
            const open = document.createElement("button");
            open.type = "button";
            open.className = "secondary";
            open.textContent = t("打开", "Open");
            open.setAttribute("aria-label", t("打开网站", "Open website"));
            open.addEventListener("click", () => openWebsite(item.id, index));
            detailContent.children[detailContent.children.length - 1].children[1].appendChild(open);
        }
        return input;
    });
    if (editing) {
        const addField = document.createElement("button");
        addField.type = "button"; addField.className = "secondary"; addField.textContent = t("添加网站", "Add website");
        addField.addEventListener("click", () => {
            const field = { id: crypto.randomUUID(), name: t("网站", "Website"), type: "website", value: "", autofill: "url", siteMatch: "domain" };
            const input = detailInput(field.name, "", true);
            input.fieldName = field.name; input.fieldType = field.type; input.fieldAutofill = field.autofill;
            input.siteMatch = field.siteMatch; input.fieldID = undefined;
            const fieldName = document.createElement("input"); fieldName.value = field.name;
            fieldName.addEventListener("input", () => { input.fieldName = fieldName.value; });
            input.detailGroup.children[1].appendChild(fieldName);
            const mode = document.createElement("select");
            for (const [value, zhLabel, enLabel] of [["domain", "基于域名", "Domain"], ["wildcard", "基于规则", "Wildcard rule"], ["exactURL", "完全匹配", "Exact URL"]]) {
                const option = document.createElement("option"); option.value = value; option.textContent = t(zhLabel, enLabel); mode.appendChild(option);
            }
            mode.setAttribute("aria-label", t("网站匹配方式", "Website match mode"));
            mode.addEventListener("change", () => { input.siteMatch = mode.value; });
            input.detailGroup.children[1].appendChild(mode);
            const remove = document.createElement("button"); remove.type = "button"; remove.className = "secondary"; remove.textContent = t("删除字段", "Remove field");
            remove.addEventListener("click", () => { detailFieldInputs = detailFieldInputs.filter(fieldInput => fieldInput !== input); input.detailGroup.remove(); });
            input.detailGroup.children[1].appendChild(remove);
            detailFieldInputs.push(input);
            const next = { ...item, fields: [...item.fields, { ...field, id: undefined }] };
            paintItemDetail(next, true);
        });
        detailContent.appendChild(addField);
    }
    detailNotesInput = detailInput(t("备注", "Notes"), notes, editing, false, true, { id: item.id, field: "notes" });
    appendInlineAttachments(item);
    detailEditButton.disabled = !editable;
    detailEditButton.hidden = editing;
    detailCancelButton.hidden = !editing;
    detailSaveSection.hidden = !editing;
    detailLegacyNote.hidden = editable;
    if (activePanel === "items") listScrollTop = document.querySelector("main").scrollTop;
    show("detail");
    document.querySelector("main").scrollTop = 0;
}

function prioritizeMissingAttachments(item) {
    try {
        if (!readInlineAttachments(item).some(attachment => attachment.state === "missing"
            && attachment.id && attachment.contentVersion)) return;
    } catch {
        console.warn("[upw] attachment priority metadata unavailable");
        return;
    }
    markAttachmentDownloadsInProgress(item.id, true);
    status(t("正在优先下载此密码项的附件…", "Prioritizing attachments for this item…"));
    void requestPriorityAttachmentDownload(item.id).catch(error => {
        console.warn("[upw] priority attachment download failed; code:", error?.code ?? error?.name);
        if (selectedItemId?.toLowerCase() === item.id.toLowerCase() && currentView === "detail") {
            const reference = attachmentPolicyReferences.find(entry => entry.cardID === item.id.toLowerCase() && entry.missing);
            const version = reference ? attachmentVersionKey(reference) : null;
            status(version ? attachmentPauseText(version)
                : t("附件尚未下载；联网后可重试。", "Attachment is not downloaded. Retry when online."), true);
        }
    }).finally(() => markAttachmentDownloadsInProgress(item.id, false));
}

function markAttachmentDownloadsInProgress(itemID, downloading) {
    if (selectedItemId?.toLowerCase() !== itemID.toLowerCase() || currentView !== "detail") return;
    const visit = node => {
        if (node.className === "detail-attachment" && node.dataset?.cardId
            && node.dataset.cardId.toLowerCase() === itemID.toLowerCase()
            && node.dataset.attachmentState === "missing") {
            const note = [...node.children].find(child => child.className === "detail-attachment-note");
            if (note) note.textContent = downloading
                ? t("正在下载…", "Downloading…")
                : node.dataset.attachmentVersion ? attachmentPauseText(node.dataset.attachmentVersion)
                    : t("此附件尚未下载到本机。", "This attachment is not downloaded on this device.");
            const button = [...node.children].find(child => child.tagName === "BUTTON");
            if (button && downloading) {
                button.disabled = true;
                button.textContent = t("正在下载…", "Downloading…");
            } else if (button && !downloading) {
                button.disabled = false;
                button.textContent = t("重试下载", "Retry download");
            }
        }
        for (const child of node.children ?? []) visit(child);
    };
    for (const child of detailContent.children) visit(child);
}

async function openItemDetail(id, editing = false) {
    console.info("[upw] detail open requested");
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
        if (editing && (!item.source || syncInFlight || attachmentPublicationInFlight)) return;
        try { await updateAttachmentPolicy(); } catch (error) { attachmentPolicyError(error); }
        if (!isCurrent()) return;
        selectedItemId = id;
        detailGeneration = generation;
        currentView = "detail";
        paintItemDetail(item, editing);
        status("");
        console.info(editing ? "[upw] popup edit opened" : "[upw] popup detail opened");
        if (!editing) {
            prioritizeMissingAttachments(item);
            void drainAttachmentQueue();
        }
    } catch {
        if (!isCurrent()) return;
        clearUnlockedView();
        await render();
        console.warn("[upw] detail open failed");
        status(t("无法读取解锁会话，请重新解锁", "Unlock session is unavailable. Unlock again."), true);
    }
}

/** 使用详情打开时的 XML 与 CAS revision 保存编辑；冲突不自动覆盖重试。 */
async function saveItemDetail() {
    if (!detailEditing || detailSaving || attachmentPublicationInFlight
        || !detailItem?.source || !selectedItemId) return;
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
        fields: detailFieldInputs.map((input, index) => ({
            id: input.fieldID,
            name: input.fieldName ?? detailItem.fields.find(field => field.id === input.fieldID)?.name ?? "",
            type: input.fieldType ?? detailItem.fields.find(field => field.id === input.fieldID)?.type ?? "text",
            value: editedValue(input),
            autofill: input.fieldAutofill ?? detailItem.fields.find(field => field.id === input.fieldID)?.autofill ?? "off",
            ...(input.siteMatch ? { siteMatch: input.siteMatch } : {}),
        })),
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
        const nextFields = edit.fields.map(field => ({ ...field }));
        for (const field of nextFields) if (!field.id) field.id = crypto.randomUUID();
        const xml = updateItemXml(original.source.xml, { ...edit, fields: nextFields }, modifiedMs);
        const parsed = parseVaultXml(fragmentsToXml([xml]));
        if (parsed.length !== 1 || parsed[0].id.toLowerCase() !== original.id.toLowerCase()) {
            throw new Error("item_changed");
        }
        const attachmentRefs = readAttachmentReferences(xml, original.id).map(reference => {
            if (!reference.id || !reference.contentVersion) throw new Error("bad_attachment_reference");
            return { attachmentId: reference.id, contentVersion: reference.contentVersion };
        });
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
            bodyB64: bytesToBase64(body), modifiedMs, attachmentRefs,
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
        void drainAttachmentQueue();
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
        edit.fields.forEach(field => { field.value = ""; });
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

detailBackButton.addEventListener("click", () => navigate("vault"));
detailEditButton.addEventListener("click", () => openItemDetail(selectedItemId, true));
detailCancelButton.addEventListener("click", () => {
    if (!confirmDiscard()) return;
    console.info("[upw] popup edit cancelled");
    return openItemDetail(selectedItemId);
});
detailSaveButton.addEventListener("click", saveItemDetail);

async function openWebsite(id, index) {
    const operation = operationGeneration;
    const generation = unlockedGeneration;
    try {
        const state = await sessionCommand("read");
        if (operation !== operationGeneration || generation !== unlockedGeneration
            || !state.unlocked || state.generation !== generation) return;
        const item = state.items?.find(item => item.id === id);
        const field = item?.fields[index];
        const url = field?.type === "website" ? safeWebsiteUrl(field.value) : null;
        if (!url) return;
        await browser.tabs.create({ url });
        console.info("[upw] website opened");
    } catch {
        console.warn("[upw] website open failed");
        status(t("无法打开网站", "Could not open the website"), true);
    }
}

async function regeneratePassword() {
    const operation = operationGeneration;
    const generation = unlockedGeneration;
    try {
        const state = await sessionCommand("read");
        if (operation !== operationGeneration || generation !== unlockedGeneration
            || !state.unlocked || state.generation !== generation) return;
        generatedPassword = generatePassword({
            length: Number(document.getElementById("generatorLength").value),
            uppercase: document.getElementById("genUppercase").checked,
            lowercase: document.getElementById("genLowercase").checked,
            digits: document.getElementById("genDigits").checked,
            symbols: document.getElementById("genSymbols").checked,
        });
        generatedInput.value = generatedPassword;
        generatedInput.type = "password";
        document.getElementById("revealGeneratedButton").textContent = t("显示", "Show");
        status("");
        console.info("[upw] generator result refreshed");
    } catch {
        generatedPassword = "";
        generatedInput.value = "";
        status(t("长度须为 8–128，且至少选择一类字符。", "Choose a length of 8–128 and at least one character class."), true);
        console.warn("[upw] password generation unavailable");
    }
}

async function openNewLogin(password = "") {
    if (syncInFlight || attachmentPublicationInFlight) return;
    await navigate("new-login");
    if (activePanel !== "new-login" || unlockedItems === null || newLoginId) return;
    newLoginId = crypto.randomUUID();
    newLoginFields[0].value = host;
    newLoginFields[2].value = password;
        const websiteURL = /^https?:\/\//i.test(pageUrl) ? new URL(pageUrl).origin : "";
    newLoginFields[3].value = websiteURL;
    newLoginSiteMatch.value = "domain";
    newLoginAdditionalSites.replaceChildren();
    newLoginSiteAssociations = [];
    newLoginDirty = Boolean(password);
    newLoginFields[0].focus();
    console.info("[upw] new login opened");
}

async function createNewLogin() {
    if (newLoginSaving || newLoginUncertain || attachmentPublicationInFlight
        || currentView !== "new-login" || unlockedItems === null) return;
    const [titleInput, usernameInput, passwordField, urlInput, notesInput] = newLoginFields;
    const sites = newLoginSiteAssociations.map(site => ({ url: site.input.value.trim(), mode: site.select.value }));
    const draft = { id: newLoginId ?? crypto.randomUUID(), title: titleInput.value.trim(),
        username: usernameInput.value, password: passwordField.value, url: urlInput.value.trim(), siteMatch: newLoginSiteMatch.value, sites, notes: notesInput.value };
    newLoginId = draft.id;
    const masterPassword = document.getElementById("newLoginMasterPassword");
    let authorization = masterPassword.value;
    masterPassword.value = "";
    const siteInputs = [{ url: draft.url, mode: draft.siteMatch }, ...draft.sites];
    if (!draft.title || siteInputs.some(site => site.url && !safeWebsiteUrl(site.mode === "wildcard" ? site.url.replaceAll("*", "wildcard-token") : site.url))) {
        status(t("请输入标题及有效的 HTTP(S) 网站地址（可留空）。", "Enter a title and a valid HTTP(S) website URL, or leave the URL empty."), true);
        authorization = "";
        return;
    }
    if (!authorization) {
        status(t("保存前请输入主密码。", "Enter your master password before saving."), true);
        return;
    }
    const operation = ++operationGeneration;
    const generation = unlockedGeneration;
    const expectedSnapshotVersion = unlockedSnapshotVersion;
    const passwordVersion = unlockedPasswordVersion;
    const startedAt = Date.now();
    const isCurrent = () => operation === operationGeneration && generation === unlockedGeneration
        && currentView === "new-login" && newLoginId === draft.id;
    let vek;
    let cloudSaved = false;
    let postStarted = false;
    let published = false;
    let context;
    newLoginSaving = true;
    const saveButton = document.getElementById("createLoginSaveButton");
    saveButton.disabled = true;
    for (const input of newLoginFields) input.readOnly = true;
    console.info("[upw] encrypted login creation started");
    status(t("正在加密并创建…", "Encrypting and creating…"));
    try {
        const bag = await storageGet([SESSION_KEY, VAULT_KEY]);
        if (!isCurrent()) return;
        const session = bag[SESSION_KEY], vault = bag[VAULT_KEY];
        if (!session?.token || session.expiresAt <= Date.now() || !vault?.id) throw new Error("session_changed");
        context = sessionContext(session, vault);
        const scope = cacheScope(session, vault);
        const cached = await encryptedCache.read(scope);
        if (!isCurrent()) return;
        if (!cached || cached.version !== expectedSnapshotVersion || cached.passwordVersion !== passwordVersion) throw new Error("session_changed");
        const validate = async (version = expectedSnapshotVersion) => {
            if (!isCurrent()) throw new Error("operation_cancelled");
            const active = await storageGet([SESSION_KEY, VAULT_KEY]);
            if (!isCurrent()) throw new Error("operation_cancelled");
            if (active[SESSION_KEY]?.token !== context.token || active[SESSION_KEY]?.userId !== context.userId
                || active[SESSION_KEY]?.expiresAt <= Date.now() || active[VAULT_KEY]?.id !== context.vaultId) throw new Error("session_changed");
            const state = await sessionCommand("read", {}, context);
            if (!isCurrent()) throw new Error("operation_cancelled");
            if (!state.unlocked || state.generation !== generation || state.snapshotVersion !== version
                || state.passwordVersion !== passwordVersion) throw new Error("session_changed");
            return state;
        };
        const original = await validate();
        await requireRelayAccess(true);
        await validate();
        const envelope = await getVaultEnvelope(context.token, context.vaultId);
        if (!isCurrent()) return;
        if (!envelope.envelope || envelope.meta.passwordVersion !== passwordVersion) throw new Error("envelope_changed");
        vek = await unwrapEnvelope(base64ToBytes(envelope.envelope), authorization);
        authorization = "";
        await validate();
        const modifiedMs = Date.now();
        const xml = createLoginItemXml({
            ...draft,
            fields: [
                { name: "@string/login_field", type: "login", autofill: "username", value: draft.username },
                { name: "@string/password_field", type: "password", autofill: "current-password", value: draft.password },
                { name: "@string/url_field", type: "website", autofill: "url", value: draft.url, siteMatch: draft.siteMatch },
                ...draft.sites.map((site, index) => ({ name: `Website ${index + 2}`, type: "website", autofill: "url", value: site.url, siteMatch: site.mode })),
            ],
        }, modifiedMs);
        const body = await encryptItemBody(xml, vek, draft.id);
        await validate();
        const freshEnvelope = await getVaultEnvelope(context.token, context.vaultId);
        if (!isCurrent()) return;
        if (freshEnvelope.envelope !== envelope.envelope || freshEnvelope.meta.passwordVersion !== passwordVersion) throw new Error("envelope_changed");
        await validate();
        postStarted = true;
        const saved = await createItem(context.token, context.vaultId, {
            uuid: draft.id, bodyB64: bytesToBase64(body), modifiedMs, attachmentRefs: [],
        });
        cloudSaved = true;
        await validate();
        const row = { uuid: draft.id.toLowerCase(), kind: 1, revision: saved.revision, bodyB64: bytesToBase64(body), modifiedMs };
        const item = projectVaultFragment({ ...row, xml });
        if (!item) throw new Error("created_item_unavailable");
        const snapshot = await encryptedCache.commit({ ...cached, rows: [...cached.rows, row] }, cached.version);
        if (!isCurrent()) return;
        const items = [...original.items, item];
        const refreshed = await sessionCommand("refresh", {
            generation, expectedSnapshotVersion, snapshotVersion: snapshot.version,
            passwordVersion: snapshot.passwordVersion, items,
        }, context);
        if (!isCurrent()) return;
        if (!refreshed.unlocked || refreshed.generation !== generation) throw new Error("session_changed");
        await validate(snapshot.version);
        unlockedItems = items;
        unlockedSnapshotVersion = snapshot.version;
        unlockedExpiresAt = refreshed.expiresAt;
        published = true;
        clearNewLoginForm();
        currentView = "vault";
        siteFilter.value = "all";
        searchInput.value = "";
        await render();
        status(t("登录已加密创建并同步。", "Login encrypted, created, and synced."));
        console.info("[upw] login creation succeeded; ms:", Date.now() - startedAt);
    } catch (error) {
        if (!isCurrent()) return;
        console.warn("[upw] login creation failed; code:", error?.code ?? error?.name);
        if (error?.status === 401) {
            await markCloudSessionExpired(context, operation, generation);
            status(t("云端登录已过期；本地副本仍保留，请重新登录。", "Cloud sign-in expired. The local copy is preserved. Sign in again."), true);
        } else if (cloudSaved || error?.message === "session_changed") {
            await sessionCommand("lock", { generation }, context);
            if (generation === unlockedGeneration) {
                clearUnlockedView();
                await render();
                status(cloudSaved
                    ? t("已保存到云端，请重新解锁同步，不要重复提交。", "Saved to the cloud. Unlock and sync; do not submit again.")
                    : t("会话已改变，请重新解锁。", "The session changed. Unlock again."), true);
            }
        } else if (postStarted) {
            newLoginUncertain = true;
            status(t("无法确认创建结果，请返回并同步检查；不要重复提交。", "Could not confirm the save. Return to the vault and sync before creating again."), true);
        } else if (error instanceof VaultCryptoError) {
            status(t("主密码错误或条目格式无效，未创建。", "Wrong master password or invalid item data. Nothing was created."), true);
        } else {
            status(t("无法安全创建，请检查网络和主密码。", "Could not safely create the login. Check your connection and master password."), true);
        }
    } finally {
        vek?.fill(0);
        authorization = "";
        for (const key of ["title", "username", "password", "url", "notes"]) draft[key] = "";
        if (cloudSaved && !published) {
            await sessionCommand("lock", { generation }, context).catch(() => console.warn("[upw] created item invalidation failed"));
            if (generation === unlockedGeneration) {
                clearUnlockedView();
                await render();
                status(t("已保存到云端，请重新解锁同步，不要重复提交。", "Saved to the cloud. Unlock and sync; do not submit again."), true);
            }
        }
        if (operation === operationGeneration) {
            newLoginSaving = false;
            saveButton.disabled = newLoginUncertain;
            for (const input of newLoginFields) input.readOnly = false;
        }
        console.info("[upw] login creation finished; ms:", Date.now() - startedAt);
    }
}

function clearNewLoginForm() {
    for (const input of newLoginFields) { input.value = ""; input.readOnly = false; }
    document.getElementById("newLoginMasterPassword").value = "";
    document.getElementById("createLoginSaveButton").disabled = false;
    newLoginDirty = false;
    newLoginSaving = false;
    newLoginUncertain = false;
    newLoginId = null;
}

// MARK: - 状态渲染

/** 根据当前授权和解锁状态渲染弹窗；异步结果须仍属于当前渲染代次。 */
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
        await browser.storage.local.remove([SESSION_KEY, VAULT_KEY, VAULT_OWNER_KEY]);
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
            // Preserve drafts, but refresh read-only controls when a remote item changes.
            if (!detailEditing && (item.source?.revision !== detailItem?.source?.revision
                || item.source?.xml !== detailItem?.source?.xml)) paintItemDetail(item, false);
            else show("detail");
            return;
        }
        clearDetailView();
        currentView = "vault";
    }
    updateSyncSummary();
    if (currentView === "generator") {
        show("generator");
        return;
    }
    if (currentView === "new-login") {
        show("new-login");
        return;
    }
    if (currentView === "settings") {
        show("settings");
        const account = await storageGet([DRAFT_KEY]);
        if (!isCurrent()) return;
        document.getElementById("accountInfo").textContent = account[DRAFT_KEY]?.email ?? t("已登录账户", "Signed-in account");
        const settings = await storageGet([SETTINGS_KEY, UNKNOWN_NETWORK_ATTACHMENT_KEY, CELLULAR_ATTACHMENT_KEY]);
        if (!isCurrent()) return;
        lockTimeout.value = String(settings[SETTINGS_KEY] ?? DEFAULT_LOCK_MINUTES);
        document.getElementById("allowUnknownNetworkAttachments").checked = settings[UNKNOWN_NETWORK_ATTACHMENT_KEY] === true;
        document.getElementById("allowCellularAttachmentDownloads").checked = settings[CELLULAR_ATTACHMENT_KEY] === true;
        sessionMode.textContent = sessionPersistent
            ? t("解锁状态仅保存在浏览器会话内存中。", "Unlock state stays in browser session memory only.")
            : t("此浏览器不支持会话存储；后台休眠后需要重新解锁。", "Session storage is unavailable; background suspension locks the vault.");
        renderSyncQuarantine();
        await refreshConflicts(false);
    } else {
        show("items");
        renderCandidates(unlockedItems);
        document.querySelector("main").scrollTop = listScrollTop;
        searchInput.focus({ preventScroll: true });
    }
    status("");
}

function confirmDiscard() {
    if (detailSaving || newLoginSaving) return false;
    const dirty = newLoginDirty || (currentView === "new-login" && newLoginFields.some(input => input.value)) || (detailEditing && [detailTitleInput, detailNotesInput, ...detailFieldInputs]
        .some(input => input?.value !== input?.initialValue));
    return !dirty || window.confirm(t("放弃尚未保存的修改？", "Discard unsaved changes?"));
}

async function navigate(view) {
    if (!confirmDiscard()) return;
    if (activePanel === "items") listScrollTop = document.querySelector("main").scrollTop;
    leaveDetailView();
    clearNewLoginForm();
    currentView = view;
    await render();
}

function updateSyncSummary() {
    const text = syncInFlight ? t("正在同步…", "Syncing…")
        : navigator.onLine === false ? t("离线 · 使用本地加密副本", "Offline · using local encrypted copy")
        : syncFailed ? t("同步未完成 · 本地副本已保留", "Sync incomplete · local copy preserved")
        : syncQuarantineItems.length ? t(`有 ${syncQuarantineItems.length} 条云端记录已隔离`, `${syncQuarantineItems.length} cloud record(s) isolated`)
        : lastSyncSuccessAt ? t(`上次同步 ${new Date(lastSyncSuccessAt).toLocaleTimeString()}`, `Last synced ${new Date(lastSyncSuccessAt).toLocaleTimeString()}`)
        : t("本地副本 · 尚未在此弹窗同步", "Local copy · not synced in this popup yet");
    syncSummary.textContent = text;
    document.getElementById("settingsSyncStatus").textContent = text;
}

function renderSyncQuarantine() {
    if (!syncQuarantineBox) return;
    const items = [...syncQuarantineItems].sort((left, right) => left.id.localeCompare(right.id));
    syncQuarantineBox.hidden = items.length === 0;
    syncQuarantineSummary.textContent = t(
        `有 ${items.length} 条云端记录暂时无法验证。本机可读数据已保留。`,
        `${items.length} cloud record(s) could not be verified. Readable local data was preserved.`,
    );
    syncQuarantineList.replaceChildren();
    for (const item of items) {
        const row = document.createElement("div");
        row.className = "sync-quarantine-item";
        const label = document.createElement("span");
        label.textContent = item.source === "change"
            ? t(`变更 ${item.sequence} · ${item.uuid.slice(0, 8)}`, `Change ${item.sequence} · ${item.uuid.slice(0, 8)}`)
            : t(`快照 · ${item.uuid.slice(0, 8)}`, `Snapshot · ${item.uuid.slice(0, 8)}`);
        const reason = document.createElement("span");
        reason.textContent = item.reason === "authenticationFailed"
            ? t("认证失败", "Authentication failed")
            : t("格式不受支持或数据损坏", "Unsupported or malformed format");
        row.append(label, reason);
        syncQuarantineList.appendChild(row);
    }
    retrySyncQuarantineButton.disabled = quarantineRetryInFlight || syncInFlight
        || detailEditing || detailSaving || attachmentPublicationInFlight;
}

async function retrySyncQuarantine() {
    if (!syncQuarantineItems.length || quarantineRetryInFlight || syncInFlight
        || unlockedItems === null || !unlockedGeneration || !Number.isSafeInteger(unlockedSnapshotVersion)) return;
    const operation = operationGeneration;
    const generation = unlockedGeneration;
    const expectedSnapshotVersion = unlockedSnapshotVersion;
    let persisted = false;
    quarantineRetryInFlight = true;
    renderSyncQuarantine();
    try {
        const bag = await storageGet([SESSION_KEY, VAULT_KEY]);
        const session = bag[SESSION_KEY];
        const vault = bag[VAULT_KEY];
        if (!session?.token || !vault?.id) throw new Error("session_changed");
        const context = sessionContext(session, vault);
        const scope = cacheScope(session, vault);
        const cached = await encryptedCache.read(scope);
        if (!cached || cached.version !== expectedSnapshotVersion) throw new Error("cache_changed");
        const validate = async () => {
            if (operation !== operationGeneration || generation !== unlockedGeneration) throw new Error("operation_cancelled");
            const active = await storageGet([SESSION_KEY, VAULT_KEY]);
            if (active[SESSION_KEY]?.token !== context.token || active[SESSION_KEY]?.userId !== context.userId
                || active[VAULT_KEY]?.id !== context.vaultId) throw new Error("session_changed");
            const state = await sessionCommand("read", {}, context);
            if (!state.unlocked || state.generation !== generation
                || state.snapshotVersion !== expectedSnapshotVersion) throw new Error("session_changed");
        };
        const fragments = new Map();
        const recovered = await retryQuarantinedRows({
            quarantinedItems: cached.quarantinedItems,
            rows: cached.rows,
            openQuarantine: async item => {
                await validate();
                const response = await sessionCommand("open-quarantine", {
                    generation, quarantine: item,
                }, context);
                if (!response.unlocked || !response.quarantineRow) {
                    const error = new Error(response.code ?? "quarantine_decrypt_failed");
                    error.code = response.code ?? "quarantine_decrypt_failed";
                    throw error;
                }
                await validate();
                return response.quarantineRow;
            },
            verifyRows: rows => verifyRowsAndCollect(rows, fragments, { generation, context, validate }),
        });
        if (recovered.recoveredCount === 0) {
            status(t("暂时仍无法恢复这些记录；隔离数据已保留。", "These records are still unreadable. Their isolated data was kept."), true);
            return;
        }
        let items = [...unlockedItems];
        for (const row of recovered.restoredRows) {
            const fragment = fragments.get(row.uuid.toLowerCase());
            if (!fragment) throw new Error("missing_verified_fragment");
            items = items.filter(item => item.id.toLowerCase() !== row.uuid.toLowerCase());
            const projected = projectVaultFragment(fragment);
            if (projected) items.push(projected);
        }
        await validate();
        const snapshot = await encryptedCache.commit({
            ...cached,
            rows: recovered.rows,
            quarantinedItems: recovered.quarantinedItems,
        }, cached.version);
        persisted = true;
        syncQuarantineItems = snapshot.quarantinedItems;
        const refreshed = await sessionCommand("refresh", {
            generation, expectedSnapshotVersion, snapshotVersion: snapshot.version,
            passwordVersion: snapshot.passwordVersion, items,
        }, context);
        if (!refreshed.unlocked || refreshed.generation !== generation) throw new Error("session_changed");
        if (operation !== operationGeneration || generation !== unlockedGeneration) return;
        unlockedItems = items;
        unlockedSnapshotVersion = snapshot.version;
        unlockedPasswordVersion = snapshot.passwordVersion;
        unlockedExpiresAt = refreshed.expiresAt;
        persisted = false;
        await render();
        status(t(`已恢复 ${recovered.recoveredCount} 条隔离记录。`, `Recovered ${recovered.recoveredCount} isolated record(s).`));
    } catch (error) {
        if (operation !== operationGeneration) return;
        console.warn("[upw] quarantine retry failed; code:", error?.code ?? error?.message ?? error?.name);
        if (persisted) {
            await lockSession();
            await render();
            status(t("隔离记录已安全保存，请重新解锁以更新本地会话。", "The isolated records were saved. Unlock again to refresh the local session."), true);
        } else if (error?.message !== "operation_cancelled") {
            status(t("重试未完成；隔离数据和本机副本均已保留。", "Retry did not finish. Isolated data and the local copy were preserved."), true);
        }
    } finally {
        quarantineRetryInFlight = false;
        renderSyncQuarantine();
    }
}

function conflictGateScopeKey(context) {
    return context?.userId && context?.vaultId
        ? `${context.userId}\u0000${context.vaultId}` : null;
}

async function loadAutofillConflictGate(context) {
    const scopeKey = conflictGateScopeKey(context);
    if (scopeKey === autofillConflictGateScopeKey) return;
    autofillConflictGateScopeKey = scopeKey;
    autofillConflictGate = null;
    if (!scopeKey) return;
    try {
        const bag = await storageGet([AUTOFILL_CONFLICT_GATE_KEY]);
        const gate = parseAutofillConflictGate(bag[AUTOFILL_CONFLICT_GATE_KEY]);
        if (gate && conflictGateScopeKey(gate) === scopeKey) autofillConflictGate = gate;
    } catch {
        console.warn("[upw] autofill conflict gate unavailable");
    }
}

async function persistAutofillConflictGate(groups, context) {
    const entries = groups.map(group => {
        const currentItem = unlockedItems?.find(item =>
            item.id.toLowerCase() === group.conflict.itemUuid.toLowerCase());
        return buildAutofillConflictGateEntry({
            itemID: group.conflict.itemUuid,
            currentItem,
            candidateItems: group.candidates
                .filter(decoded => decoded.candidate.op === "upsert")
                .map(decoded => decoded.item),
            hasUnreadableCandidate: group.candidates.some(decoded =>
                decoded.candidate.op === "upsert" && decoded.unreadable),
            hasDeleteCandidate: group.candidates.some(decoded => decoded.candidate.op === "delete"),
            currentDeleted: group.conflict.currentDeletedSeq > 0,
        });
    });
    const gate = {
        version: 1,
        userId: context.userId,
        vaultId: context.vaultId,
        checkedAt: Date.now(),
        entries,
    };
    autofillConflictGateScopeKey = conflictGateScopeKey(gate);
    autofillConflictGate = parseAutofillConflictGate(gate);
    if (!autofillConflictGate) throw new Error("autofill_conflict_gate_invalid");
    try {
        await storageSet({ [AUTOFILL_CONFLICT_GATE_KEY]: gate });
    } catch {
        // The in-memory gate still protects the current popup; a later refresh retries persistence.
        console.warn("[upw] autofill conflict gate persistence failed");
    }
}

async function fetchConflictGroups(interactive = false) {
    if (conflictFetchTask) return conflictFetchTask;
    const operation = operationGeneration;
    const generation = unlockedGeneration;
    const task = (async () => {
        try {
            const bag = await storageGet([SESSION_KEY, VAULT_KEY]);
            const session = bag[SESSION_KEY];
            const vault = bag[VAULT_KEY];
            if (!session?.token || !vault?.id) throw new Error("login_required");
            const context = sessionContext(session, vault);
            await requireRelayAccess(interactive);
            const state = await sessionCommand("read", {}, context);
            if (operation !== operationGeneration || generation !== unlockedGeneration
                || !state.unlocked || state.generation !== generation) throw new Error("session_changed");
            const conflicts = await listVaultConflicts(session.token, vault.id);
            const groups = [];
            for (const conflict of conflicts) {
                const candidates = [];
                for (const candidate of conflict.candidates) {
                    candidates.push(await decodeConflictCandidate(conflict, candidate, generation, context));
                    if (operation !== operationGeneration || generation !== unlockedGeneration) {
                        throw new Error("operation_cancelled");
                    }
                }
                groups.push({ conflict, candidates });
            }
            return { context, groups };
        } finally {
            if (conflictFetchTask === task) conflictFetchTask = null;
        }
    })();
    conflictFetchTask = task;
    return task;
}

async function refreshAutofillConflictGate(interactive = false) {
    if (unlockedItems === null || !unlockedGeneration) return false;
    const operation = operationGeneration;
    const generation = unlockedGeneration;
    try {
        const result = await fetchConflictGroups(interactive);
        const active = await storageGet([SESSION_KEY, VAULT_KEY]);
        if (operation !== operationGeneration || generation !== unlockedGeneration
            || active[VAULT_KEY]?.id !== result.context.vaultId
            || active[SESSION_KEY]?.userId !== result.context.userId) return false;
        await persistAutofillConflictGate(result.groups, result.context);
        return true;
    } catch (error) {
        console.warn("[upw] autofill conflict refresh failed; code:", error?.code ?? error?.message ?? error?.name);
        return false;
    }
}

async function ensureAutofillConflictGate() {
    const bag = await storageGet([SESSION_KEY, VAULT_KEY]);
    const context = sessionContext(bag[SESSION_KEY], bag[VAULT_KEY]);
    await loadAutofillConflictGate(context);
    const scopeKey = conflictGateScopeKey(context);
    const hasGate = autofillConflictGateScopeKey === scopeKey && autofillConflictGate !== null;
    if (hasGate && Date.now() - autofillConflictGate.checkedAt <= AUTOFILL_CONFLICT_GATE_MAX_AGE_MS) {
        return true;
    }
    if (navigator.onLine !== false && await refreshAutofillConflictGate(false)) return true;
    return hasGate;
}

function conflictRootSummary(xml, kind) {
    if (!xml || typeof DOMParser === "undefined") return kind === 2 ? t("标签", "Label") : t("不可读条目", "Unreadable item");
    try {
        const root = new DOMParser().parseFromString(xml, "application/xml").documentElement;
        if (!root || root.tagName === "parsererror") return t("不可读条目", "Unreadable item");
        return root.getAttribute("title") || root.getAttribute("name")
            || (kind === 3 ? t("个人资料", "Personal information") : t("无标题条目", "Untitled item"));
    } catch {
        return t("不可读条目", "Unreadable item");
    }
}

async function decodeConflictCandidate(conflict, candidate, generation, context) {
    if (candidate.op === "delete") return { candidate, item: null, xml: null, unreadable: false };
    if (!candidate.bodyB64) return { candidate, item: null, xml: null, unreadable: true };
    try {
        const body = base64ToBytes(candidate.bodyB64);
        if (!candidate.sha256 || await sha256BytesHex(body) !== candidate.sha256) {
            throw new Error("candidate_digest_mismatch");
        }
        const response = await sessionCommand("decrypt", {
            generation,
            rows: [{
                uuid: conflict.itemUuid,
                bodyB64: candidate.bodyB64,
                revision: Math.max(1, candidate.revision),
                kind: candidate.kind,
                modifiedMs: candidate.modifiedMs,
            }],
        }, context);
        const fragment = response.fragments?.[0];
        if (!response.unlocked || !fragment) throw new Error("candidate_decrypt_failed");
        const document = new DOMParser().parseFromString(fragment.xml, "application/xml");
        if (document.querySelector("parsererror")) throw new Error("candidate_xml_invalid");
        const root = document.documentElement;
        const hasAttachments = Array.from(root.children).some((element) =>
            element.tagName === "image" || element.tagName === "file");
        return {
            candidate,
            item: projectVaultFragment(fragment),
            xml: fragment.xml,
            hasAttachments,
            unreadable: false,
        };
    } catch {
        return { candidate, item: null, xml: null, unreadable: true };
    }
}

function appendConflictPreview(container, decoded) {
    if (decoded.candidate.op === "delete") {
        const text = document.createElement("p");
        text.className = "conflict-meta";
        text.textContent = t("这是删除版本。选择它会保留删除。", "This is a deletion version. Choosing it keeps the item deleted.");
        container.appendChild(text);
        return;
    }
    if (decoded.unreadable || !decoded.xml) {
        const warning = document.createElement("p");
        warning.className = "conflict-warning";
        warning.textContent = t("此候选无法安全解密，不能直接裁决。", "This candidate could not be decrypted safely and cannot be selected.");
        container.appendChild(warning);
        return;
    }
    if (decoded.hasAttachments) {
        const warning = document.createElement("p");
        warning.className = "conflict-warning";
        warning.textContent = t("选择此版本也会一并采用该版本的附件。", "Choosing this version also selects its attachment versions.");
        container.appendChild(warning);
    }
    const item = decoded.item;
    if (!item) {
        const summary = document.createElement("p");
        summary.className = "conflict-meta";
        summary.textContent = conflictRootSummary(decoded.xml, decoded.candidate.kind);
        container.appendChild(summary);
        return;
    }
    const title = document.createElement("p");
    title.className = "conflict-candidate-title";
    title.textContent = item.title;
    container.appendChild(title);
    const fields = document.createElement("div");
    fields.className = "conflict-fields";
    const sensitive = new Set(["password", "pin", "secret", "one_time_password"]);
    let revealed = false;
    const values = [];
    for (const field of item.fields.slice(0, 12)) {
        const row = document.createElement("div");
        row.className = "conflict-field";
        const name = document.createElement("span");
        name.className = "conflict-field-name";
        name.textContent = field.name || field.type;
        const value = document.createElement("span");
        value.className = "conflict-field-value";
        const hidden = sensitive.has(field.type);
        const masked = hidden && field.value ? "••••••••" : field.value || t("空", "Empty");
        value.textContent = masked;
        values.push({ value, field, hidden });
        row.append(name, value);
        fields.appendChild(row);
    }
    if (item.fields.length > 12) {
        const more = document.createElement("div");
        more.className = "conflict-meta";
        more.textContent = t(`还有 ${item.fields.length - 12} 个字段`, `${item.fields.length - 12} more fields`);
        fields.appendChild(more);
    }
    let notes = "";
    try {
        notes = readItemDetail(item).notes;
    } catch {
        notes = "";
    }
    if (notes) {
        const note = document.createElement("div");
        note.className = "conflict-field";
        const name = document.createElement("span");
        name.className = "conflict-field-name";
        name.textContent = t("备注", "Notes");
        const value = document.createElement("span");
        value.className = "conflict-field-value";
        value.textContent = "••••••••";
        note.append(name, value);
        fields.appendChild(note);
        values.push({ value, field: { value: notes }, hidden: true });
    }
    container.appendChild(fields);
    if (values.some((entry) => entry.hidden)) {
        const reveal = document.createElement("button");
        reveal.type = "button";
        reveal.className = "secondary";
        reveal.textContent = t("显示隐藏内容", "Reveal hidden values");
        reveal.addEventListener("click", () => {
            revealed = !revealed;
            for (const entry of values) {
                if (!entry.hidden) continue;
                entry.value.textContent = revealed
                    ? entry.field.value || t("空", "Empty") : "••••••••";
            }
            reveal.textContent = revealed ? t("隐藏敏感内容", "Hide sensitive values") : t("显示隐藏内容", "Reveal hidden values");
        });
        container.appendChild(reveal);
    }
}

function appendConflictComposition(container, group, composition) {
    const details = document.createElement("details");
    details.className = "conflict-composition";
    const summary = document.createElement("summary");
    summary.textContent = t("组合字段", "Combine fields");
    details.appendChild(summary);

    const sources = group.candidates.map((decoded) => ({
        value: decoded.candidate.candidateId,
        label: `${decoded.candidate.deviceName || t("未知设备", "Unknown device")} · ${decoded.candidate.platform || t("未知平台", "Unknown platform")} · ${new Date(decoded.candidate.committedMs).toLocaleString()}`,
    }));
    const selectControl = (labelText, options) => {
        const label = document.createElement("label");
        label.className = "conflict-composition-control";
        const title = document.createElement("span");
        title.textContent = labelText;
        const select = document.createElement("select");
        const placeholder = document.createElement("option");
        placeholder.value = "";
        placeholder.textContent = t("请选择版本", "Choose a version");
        select.appendChild(placeholder);
        for (const option of options) {
            const element = document.createElement("option");
            element.value = option.value;
            element.textContent = option.label;
            select.appendChild(element);
        }
        label.append(title, select);
        details.appendChild(label);
        return select;
    };

    const baseSelect = selectControl(t("条目资料来源", "Item details from"), sources);
    const fieldSelects = new Map();
    for (const field of composition.fieldGroups) {
        if (!field.requiresChoice) continue;
        const options = field.options.map((option) => {
            const source = sources.find(({ value }) => value === option.candidateId);
            return {
                value: option.candidateId,
                label: `${source?.label ?? option.candidateId}${option.present ? "" : ` · ${t("已移除", "removed")}`}`,
            };
        });
        fieldSelects.set(field.fieldId, selectControl(
            field.title || t("字段", "Field"),
            options,
        ));
    }
    let notesSelect = null;
    if (composition.notesRequireChoice) {
        notesSelect = selectControl(t("备注来源", "Notes from"), sources);
    }

    const action = document.createElement("button");
    action.type = "button";
    action.className = "secondary";
    action.textContent = t("应用字段组合", "Apply field combination");
    action.disabled = true;
    const updateAvailability = () => {
        action.disabled = conflictResolving || !baseSelect.value
            || [...fieldSelects.values()].some((select) => !select.value)
            || (notesSelect !== null && !notesSelect.value);
    };
    for (const select of [baseSelect, ...fieldSelects.values(), ...(notesSelect ? [notesSelect] : [])]) {
        select.addEventListener("change", updateAvailability);
    }
    updateAvailability();
    action.addEventListener("click", () => {
        const fieldSources = Object.fromEntries([...fieldSelects].map(([fieldId, select]) => [fieldId, select.value]));
        void resolveBrowserComposition(group, {
            baseCandidateId: baseSelect.value,
            fieldSources,
            ...(notesSelect ? { notesCandidateId: notesSelect.value } : {}),
        });
    });
    details.appendChild(action);
    container.appendChild(details);
}

async function resolveBrowserComposition(group, selection) {
    if (conflictResolving || group.conflict.currentDeletedSeq > 0) return;
    if (!window.confirm(t(
        "确认应用所选字段组合？未选版本将在保留期后清理。",
        "Apply this field combination? Unselected versions will be retained temporarily and then cleaned up.",
    ))) return;
    conflictResolving = true;
    renderConflictGroups();
    const operation = operationGeneration;
    const generation = unlockedGeneration;
    const startedAt = Date.now();
    try {
        const bag = await storageGet([SESSION_KEY, VAULT_KEY]);
        const session = bag[SESSION_KEY];
        const vault = bag[VAULT_KEY];
        if (!session?.token || !vault?.id) throw new Error("login_required");
        const context = sessionContext(session, vault);
        const state = await sessionCommand("read", {}, context);
        if (!state.unlocked || state.generation !== generation) throw new Error("session_changed");

        const candidates = group.candidates.map(({ candidate, xml }) => ({ ...candidate, xml }));
        const composed = composeCardConflict(candidates, { ...selection, nowMs: Date.now() });
        const encrypted = await sessionCommand("encrypt", {
            generation,
            uuid: group.conflict.itemUuid,
            xml: composed.xml,
        }, context);
        if (!encrypted.unlocked || encrypted.generation !== generation || !encrypted.bodyB64) {
            throw new Error("item_encrypt_failed");
        }
        if (operation !== operationGeneration || generation !== unlockedGeneration) return;

        await resolveVaultConflict(session.token, vault.id, {
            conflictId: group.conflict.conflictId,
            generation: group.conflict.generation,
            candidateIds: group.conflict.candidates.map((candidate) => candidate.candidateId),
            winnerCandidateId: selection.baseCandidateId,
            expectedCurrentRevision: group.conflict.currentRevision,
            expectedDeletedSeq: group.conflict.currentDeletedSeq,
            attachmentRefs: [],
            mergedBodyB64: encrypted.bodyB64,
            mergedModifiedMs: composed.modifiedMs,
        });
        if (operation !== operationGeneration || generation !== unlockedGeneration) return;
        status(t("字段组合已提交，正在同步结果。", "Field combination submitted; syncing the result."));
        await syncVault(false);
        await refreshConflicts(false);
        console.info("[upw] browser conflict composed; ms:", Date.now() - startedAt);
    } catch (error) {
        if (operation === operationGeneration) {
            status(error?.status === 409
                ? t("冲突候选已变化，请刷新后重新选择。", "The candidate set changed. Refresh and choose again.")
                : t("字段组合未完成，原数据已保留。", "Field composition did not complete. The original data was preserved."), true);
            await refreshConflicts(false);
        }
        console.warn("[upw] browser conflict composition failed; code:", error?.code ?? error?.message ?? error?.name);
    } finally {
        conflictResolving = false;
        renderConflictGroups();
    }
}

function renderConflictGroups() {
    conflictsList.replaceChildren();
    if (conflictGroups.length === 0) {
        conflictsStatus.textContent = t("没有待处理的冲突。", "No unresolved conflicts.");
        return;
    }
    conflictsStatus.textContent = t(`${conflictGroups.length} 组冲突需要选择版本。`, `${conflictGroups.length} conflict group(s) need a version choice.`);
    for (const group of conflictGroups) {
        const section = document.createElement("section");
        section.className = "conflict-group";
        const heading = document.createElement("div");
        heading.className = "conflict-group-heading";
        const headingCopy = document.createElement("div");
        const title = document.createElement("h4");
        title.className = "conflict-group-title";
        const first = group.candidates.find((candidate) => candidate.item)?.item;
        title.textContent = first?.title || conflictRootSummary(group.candidates.find((candidate) => candidate.xml)?.xml, group.conflict.candidates[0]?.kind);
        const meta = document.createElement("p");
        meta.className = "conflict-meta";
        meta.textContent = group.conflict.currentDeletedSeq > 0
            ? t("当前条目已删除；选择可读版本会以新身份恢复。", "The current item was deleted; choosing a readable version restores it with a new identity.")
            : t(`${group.conflict.candidates.length} 个加密版本`, `${group.conflict.candidates.length} encrypted versions`);
        headingCopy.append(title, meta);
        heading.appendChild(headingCopy);
        section.appendChild(heading);
        if (group.conflict.currentDeletedSeq === 0
            && group.candidates.length === group.conflict.candidates.length
            && group.candidates.every((decoded) => !decoded.unreadable && !decoded.hasAttachments)) {
            const composition = analyzeCardConflict(group.candidates.map(({ candidate, xml }) => ({ ...candidate, xml })));
            if (composition) appendConflictComposition(section, group, composition);
        }
        for (const decoded of group.candidates) {
            const card = document.createElement("article");
            card.className = "conflict-candidate";
            const header = document.createElement("div");
            header.className = "conflict-candidate-header";
            const copy = document.createElement("div");
            copy.className = "conflict-candidate-copy";
            const source = document.createElement("p");
            source.className = "conflict-candidate-source";
            const candidate = decoded.candidate;
            source.textContent = `${candidate.deviceName || t("未知设备", "Unknown device")} · ${candidate.platform || t("未知平台", "Unknown platform")} · ${new Date(candidate.committedMs).toLocaleString()}`;
            copy.appendChild(source);
            header.appendChild(copy);
            card.appendChild(header);
            appendConflictPreview(card, decoded);
            const actions = document.createElement("div");
            actions.className = "conflict-actions";
            if (decoded.unreadable) {
                const retry = document.createElement("button");
                retry.type = "button";
                retry.className = "secondary";
                retry.textContent = t("重新读取此版本", "Retry loading this version");
                retry.disabled = conflictResolving;
                retry.addEventListener("click", async () => { await refreshConflicts(true); });
                actions.appendChild(retry);
                const protect = document.createElement("button");
                protect.type = "button";
                protect.className = "secondary";
                protect.textContent = t("导出保护备份", "Export protected backup");
                protect.disabled = conflictResolving;
                protect.addEventListener("click", () => { void exportPortableBackup(); });
                actions.appendChild(protect);
            }
            const resolve = document.createElement("button");
            resolve.type = "button";
            resolve.className = "secondary";
            resolve.textContent = group.conflict.currentDeletedSeq > 0 && candidate.op === "upsert"
                ? t("恢复此版本", "Restore this version")
                : candidate.op === "delete" ? t("保留删除", "Keep deleted") : t("保留此版本", "Keep this version");
            resolve.disabled = conflictResolving || decoded.unreadable;
            resolve.addEventListener("click", () => { void resolveBrowserConflict(group, decoded); });
            actions.appendChild(resolve);
            if (candidate.op === "upsert" && candidate.kind === 1 && !decoded.unreadable) {
                const copy = document.createElement("button");
                copy.type = "button";
                copy.className = "secondary";
                copy.textContent = t("另存为新条目", "Save as new item");
                copy.disabled = conflictResolving || conflictCopyUncertain;
                copy.addEventListener("click", () => { void copyBrowserConflictCandidate(group, decoded); });
                actions.appendChild(copy);
            }
            card.appendChild(actions);
            section.appendChild(card);
        }
        conflictsList.appendChild(section);
    }
}

async function refreshConflicts(interactive = false) {
    if (unlockedItems === null || !unlockedGeneration) return;
    if (conflictRefreshTask) {
        if (!interactive) return conflictRefreshTask;
        try {
            await conflictRefreshTask;
        } catch {
            // The active refresh reports its own error; an explicit retry still starts a new request.
        }
        return refreshConflicts(true);
    }
    const operation = operationGeneration;
    const generation = unlockedGeneration;
    let task;
    task = (async () => {
        conflictsLoading = true;
        refreshConflictsButton.disabled = true;
        conflictsStatus.textContent = t("正在加载冲突…", "Loading conflicts…");
        try {
            await reconcilePendingConflictCopy();
            if (operation !== operationGeneration || generation !== unlockedGeneration) return;
            const result = await fetchConflictGroups(interactive);
            if (operation !== operationGeneration || generation !== unlockedGeneration) {
                throw new Error("session_changed");
            }
            const { context, groups } = result;
            conflictGroups = groups.sort((left, right) => right.conflict.updatedMs - left.conflict.updatedMs);
            await persistAutofillConflictGate(conflictGroups, context);
            renderConflictGroups();
        } catch (error) {
            if (operation !== operationGeneration) return;
            conflictGroups = [];
            conflictsList.replaceChildren();
            conflictsStatus.textContent = error?.message === "relay_permission_required"
                ? t("需要允许同步服务访问，点击刷新后授权。", "Allow access to the sync service, then refresh.")
                : error?.message === "login_required"
                    ? t("请先登录云端账户。", "Sign in to the cloud account first.")
                    : t("无法加载冲突，请检查网络后重试。", "Could not load conflicts. Check the connection and retry.");
            console.warn("[upw] conflict list failed; code:", error?.code ?? error?.message ?? error?.name);
        } finally {
            conflictsLoading = false;
            refreshConflictsButton.disabled = false;
            if (conflictRefreshTask === task) conflictRefreshTask = null;
        }
    })();
    conflictRefreshTask = task;
    return task;
}

async function reconcilePendingConflictCopy() {
    const bag = await storageGet([SESSION_KEY, VAULT_KEY, PENDING_CONFLICT_COPY_KEY]);
    const pending = bag[PENDING_CONFLICT_COPY_KEY];
    const session = bag[SESSION_KEY];
    const vault = bag[VAULT_KEY];
    if (!pending) {
        conflictCopyUncertain = false;
        return;
    }
    if (!session?.userId || !vault?.id
        || pending.userId !== session.userId || pending.vaultId !== vault.id) {
        conflictCopyUncertain = false;
        return;
    }

    conflictCopyUncertain = true;
    if (unlockedItems === null || !unlockedGeneration) return;
    const operation = operationGeneration;
    const generation = unlockedGeneration;
    try {
        await syncVault(false);
        if (operation !== operationGeneration || generation !== unlockedGeneration) return;
        const created = unlockedItems?.some(item => item.id.toLowerCase() === pending.itemUUID);
        if (!created) {
            status(t(
                "仍无法确认上次另存结果；再次刷新检查前不会重试或清理附件。",
                "The previous save is still unconfirmed. Refresh to check again; retry and attachment cleanup remain disabled.",
            ), true);
            return;
        }
        await browser.storage.local.remove([PENDING_CONFLICT_COPY_KEY]);
        conflictCopyUncertain = false;
        status(t(
            "已同步确认上次另存成功，未重复创建条目。",
            "The previous save was confirmed by sync. No duplicate item was created.",
        ));
    } catch (error) {
        conflictCopyUncertain = true;
        console.warn("[upw] pending conflict copy reconciliation failed; code:", error?.code ?? error?.message ?? error?.name);
    }
}

async function resolveBrowserConflict(group, decoded) {
    if (conflictResolving || decoded.unreadable) return;
    const candidate = decoded.candidate;
    const action = group.conflict.currentDeletedSeq > 0 && candidate.op === "upsert"
        ? t("恢复此版本", "Restore this version")
        : candidate.op === "delete" ? t("保留删除", "Keep deleted") : t("保留此版本", "Keep this version");
    if (!window.confirm(t(`确认${action}？其他未选版本将在保留期后清理。`, `Confirm “${action}”? Other versions will be retained temporarily and then cleaned up.`))) return;
    conflictResolving = true;
    renderConflictGroups();
    const operation = operationGeneration;
    const generation = unlockedGeneration;
    const startedAt = Date.now();
    try {
        const bag = await storageGet([SESSION_KEY, VAULT_KEY]);
        const session = bag[SESSION_KEY];
        const vault = bag[VAULT_KEY];
        if (!session?.token || !vault?.id) throw new Error("login_required");
        const context = sessionContext(session, vault);
        const state = await sessionCommand("read", {}, context);
        if (!state.unlocked || state.generation !== generation) throw new Error("session_changed");
        const attachmentRefs = candidate.op === "upsert" && candidate.kind === 1
            ? readAttachmentReferences(decoded.xml, group.conflict.itemUuid).map(reference => {
                if (!reference.id || !reference.contentVersion) throw new Error("bad_attachment_identity");
                return {
                    attachmentId: reference.id,
                    contentVersion: reference.contentVersion,
                    restoreDeleted: true,
                };
            })
            : [];
        let restoreItemUuid;
        let bodyB64;
        if (group.conflict.currentDeletedSeq > 0 && candidate.op === "upsert") {
            if (!decoded.xml) throw new Error("candidate_decrypt_failed");
            restoreItemUuid = crypto.randomUUID();
            const restoredXml = reidentifyItemXml(decoded.xml, restoreItemUuid, Math.max(Date.now(), candidate.modifiedMs + 1));
            const encrypted = await sessionCommand("encrypt", {
                generation, uuid: restoreItemUuid, xml: restoredXml,
            }, context);
            if (!encrypted.unlocked || !encrypted.bodyB64) throw new Error("item_encrypt_failed");
            bodyB64 = encrypted.bodyB64;
        }
        await resolveVaultConflict(session.token, vault.id, {
            conflictId: group.conflict.conflictId,
            generation: group.conflict.generation,
            candidateIds: group.conflict.candidates.map((entry) => entry.candidateId),
            winnerCandidateId: candidate.candidateId,
            expectedCurrentRevision: group.conflict.currentRevision,
            expectedDeletedSeq: group.conflict.currentDeletedSeq,
            attachmentRefs,
            ...(restoreItemUuid === undefined ? {} : { restoreItemUuid, bodyB64 }),
        });
        if (operation !== operationGeneration || generation !== unlockedGeneration) return;
        status(t("冲突裁决已提交，正在同步结果。", "Conflict choice submitted; syncing the result."));
        await syncVault(false);
        await refreshConflicts(false);
        console.info("[upw] browser conflict resolved; ms:", Date.now() - startedAt);
    } catch (error) {
        if (operation === operationGeneration) {
            status(error?.status === 409
                ? t("冲突候选已变化，请刷新后重新选择。", "The candidate set changed. Refresh and choose again.")
                : t("冲突裁决未完成，原数据已保留。", "Conflict resolution did not complete. The original data was preserved."), true);
            await refreshConflicts(false);
        }
        console.warn("[upw] browser conflict resolution failed; code:", error?.code ?? error?.message ?? error?.name);
    } finally {
        conflictResolving = false;
        renderConflictGroups();
    }
}

async function copyBrowserConflictCandidate(group, decoded) {
    const candidate = decoded.candidate;
    if (conflictResolving || conflictCopyUncertain || decoded.unreadable
        || candidate.op !== "upsert" || candidate.kind !== 1 || !decoded.xml) return;
    if (!window.confirm(t(
        "将此版本另存为独立条目，并复制全部附件？原冲突和候选版本不会被删除。",
        "Save this version as a separate item with all attachments? The conflict and its candidates will remain unchanged.",
    ))) return;

    conflictResolving = true;
    renderConflictGroups();
    const operation = operationGeneration;
    const generation = unlockedGeneration;
    const expectedSnapshotVersion = unlockedSnapshotVersion;
    const passwordVersion = unlockedPasswordVersion;
    const destinationItemUUID = crypto.randomUUID();
    const startedAt = Date.now();
    let context;
    let scope;
    let cached;
    let copied;
    let postStarted = false;
    let cloudSaved = false;
    let published = false;
    const isCurrent = () => operation === operationGeneration
        && generation === unlockedGeneration;

    try {
        const bag = await storageGet([SESSION_KEY, VAULT_KEY]);
        const session = bag[SESSION_KEY];
        const vault = bag[VAULT_KEY];
        if (!session?.token || session.expiresAt <= Date.now() || !vault?.id) {
            throw new Error("login_required");
        }
        context = sessionContext(session, vault);
        scope = cacheScope(session, vault);
        cached = await encryptedCache.read(scope);
        if (!cached || cached.version !== expectedSnapshotVersion
            || cached.passwordVersion !== passwordVersion) throw new Error("cache_changed");

        const validate = async () => {
            if (!isCurrent()) throw new Error("operation_cancelled");
            const active = await storageGet([SESSION_KEY, VAULT_KEY]);
            if (!isCurrent() || active[SESSION_KEY]?.token !== context.token
                || active[SESSION_KEY]?.userId !== context.userId
                || active[SESSION_KEY]?.expiresAt <= Date.now()
                || active[VAULT_KEY]?.id !== context.vaultId) throw new Error("session_changed");
            const state = await sessionCommand("read", {}, context);
            if (!isCurrent() || !state.unlocked || state.generation !== generation
                || state.snapshotVersion !== expectedSnapshotVersion
                || state.passwordVersion !== passwordVersion) throw new Error("session_changed");
            const currentCache = await encryptedCache.read(scope);
            if (!currentCache || currentCache.version !== expectedSnapshotVersion
                || currentCache.passwordVersion !== passwordVersion) throw new Error("cache_changed");
        };

        await requireRelayAccess(true);
        await validate();
        const confirmCandidateSet = async () => {
            await validate();
            const conflicts = await listVaultConflicts(context.token, context.vaultId);
            await validate();
            const latest = conflicts.find(entry => entry.conflictId === group.conflict.conflictId);
            const expectedIDs = group.conflict.candidates.map(entry => entry.candidateId).sort();
            const latestIDs = latest?.candidates.map(entry => entry.candidateId).sort() ?? [];
            const latestCandidate = latest?.candidates.find(entry => entry.candidateId === candidate.candidateId);
            if (!latest || latest.generation !== group.conflict.generation
                || latest.currentRevision !== group.conflict.currentRevision
                || latest.currentDeletedSeq !== group.conflict.currentDeletedSeq
                || expectedIDs.length !== latestIDs.length
                || expectedIDs.some((id, index) => id !== latestIDs[index])
                || !latestCandidate || latestCandidate.op !== candidate.op
                || latestCandidate.kind !== candidate.kind
                || latestCandidate.bodyB64 !== candidate.bodyB64
                || latestCandidate.sha256 !== candidate.sha256) {
                throw new Error("conflict_candidates_changed");
            }
        };

        await confirmCandidateSet();
        status(t("正在复制候选版本及附件…", "Copying the candidate and its attachments…"));
        copied = await copyConflictCandidateAttachments({
            sourceItemUUID: group.conflict.itemUuid,
            destinationItemUUID,
            sourceXML: decoded.xml,
            nowMs: Date.now(),
            validate,
            listVersions: () => listVaultAttachmentVersions(
                context.token, context.vaultId, group.conflict.itemUuid,
            ),
            downloadCipher: version => getVaultAttachment(context.token, context.vaultId, version),
            decryptAttachment: async (cipher, version) => {
                const response = await sessionCommand("decrypt-attachment", {
                    generation,
                    attachmentID: version.attachmentId,
                    contentVersion: version.contentVersion,
                    cipherB64: bytesToBase64(cipher),
                    dekWrappedB64: version.dekWrapped,
                }, context);
                if (!response.unlocked || response.generation !== generation
                    || typeof response.attachmentB64 !== "string") {
                    throw new Error(response.code ?? "attachment_decrypt_failed");
                }
                return base64ToBytes(response.attachmentB64);
            },
            encryptAttachment: async (plaintext, attachmentID, contentVersion) => {
                const response = await sessionCommand("encrypt-attachment", {
                    generation,
                    attachmentID,
                    contentVersion,
                    plaintextB64: bytesToBase64(plaintext),
                }, context);
                if (!response.unlocked || response.generation !== generation
                    || !response.cipherB64 || !response.dekWrappedB64) {
                    throw new Error(response.code ?? "attachment_encrypt_failed");
                }
                return {
                    cipher: base64ToBytes(response.cipherB64),
                    dekWrapped: base64ToBytes(response.dekWrappedB64),
                };
            },
            uploadAttachment: (attachmentID, contentVersion, cardUUID, cipher, dekWrapped) =>
                putVaultAttachment(
                    context.token,
                    context.vaultId,
                    attachmentID,
                    contentVersion,
                    cardUUID,
                    cipher,
                    dekWrapped,
                ),
            deleteAttachment: attachmentID =>
                deleteVaultAttachment(context.token, context.vaultId, attachmentID),
            checkpoint: confirmCandidateSet,
        });

        await confirmCandidateSet();
        const modifiedMs = Date.now();
        const encrypted = await sessionCommand("encrypt", {
            generation,
            uuid: destinationItemUUID,
            xml: copied.xml,
        }, context);
        if (!encrypted.unlocked || encrypted.generation !== generation || !encrypted.bodyB64) {
            throw new Error(encrypted.code ?? "item_encrypt_failed");
        }
        await validate();
        await confirmCandidateSet();

        await storageSet({
            [PENDING_CONFLICT_COPY_KEY]: {
                userId: context.userId,
                vaultId: context.vaultId,
                itemUUID: destinationItemUUID.toLowerCase(),
                attachmentIDs: copied.uploadedAttachmentIDs,
                conflictId: group.conflict.conflictId,
                candidateId: candidate.candidateId,
                createdAt: Date.now(),
            },
        });
        postStarted = true;
        const created = await createItem(context.token, context.vaultId, {
            uuid: destinationItemUUID,
            bodyB64: encrypted.bodyB64,
            modifiedMs,
            attachmentRefs: copied.attachmentRefs,
        });
        cloudSaved = true;
        await validate();

        const row = {
            uuid: destinationItemUUID.toLowerCase(),
            kind: 1,
            revision: created.revision,
            bodyB64: encrypted.bodyB64,
            modifiedMs,
        };
        const item = projectVaultFragment({ ...row, xml: copied.xml });
        if (!item) throw new Error("created_item_unavailable");
        const snapshot = await encryptedCache.commit({
            ...cached,
            rows: [...cached.rows.filter(entry => entry.uuid !== row.uuid), row],
        }, cached.version);
        if (!isCurrent()) return;
        const state = await sessionCommand("read", {}, context);
        if (!state.unlocked || state.generation !== generation
            || state.snapshotVersion !== expectedSnapshotVersion) throw new Error("session_changed");
        const items = [...(state.items ?? unlockedItems ?? []), item];
        const refreshed = await sessionCommand("refresh", {
            generation,
            expectedSnapshotVersion,
            snapshotVersion: snapshot.version,
            passwordVersion: snapshot.passwordVersion,
            items,
        }, context);
        if (!refreshed.unlocked || refreshed.generation !== generation) throw new Error("session_changed");
        await validateWithSnapshot(snapshot.version);
        unlockedItems = items;
        unlockedSnapshotVersion = snapshot.version;
        unlockedPasswordVersion = snapshot.passwordVersion;
        unlockedExpiresAt = refreshed.expiresAt;
        published = true;
        await browser.storage.local.remove([PENDING_CONFLICT_COPY_KEY]);
        conflictCopyUncertain = false;
        await render();
        status(t("候选已另存为新条目，冲突版本仍保留。", "Candidate saved as a new item; the conflict versions remain unchanged."));
        await refreshConflicts(false);
        console.info("[upw] browser conflict candidate copied; ms:", Date.now() - startedAt);

        async function validateWithSnapshot(snapshotVersion) {
            if (!isCurrent()) throw new Error("operation_cancelled");
            const active = await storageGet([SESSION_KEY, VAULT_KEY]);
            if (active[SESSION_KEY]?.token !== context.token
                || active[SESSION_KEY]?.userId !== context.userId
                || active[VAULT_KEY]?.id !== context.vaultId) throw new Error("session_changed");
            const state = await sessionCommand("read", {}, context);
            if (!state.unlocked || state.generation !== generation
                || state.snapshotVersion !== snapshotVersion) throw new Error("session_changed");
        }
    } catch (error) {
        const definiteCreateRejection = postStarted && Number.isInteger(error?.status)
            && error.status >= 400 && error.status < 500;
        if (copied && !cloudSaved && (!postStarted || definiteCreateRejection)) {
            for (const attachmentID of copied.uploadedAttachmentIDs) {
                try {
                    await deleteVaultAttachment(context.token, context.vaultId, attachmentID);
                } catch {
                    console.warn("[upw] orphan conflict attachment cleanup failed");
                }
            }
        }
        if (!cloudSaved && (!postStarted || definiteCreateRejection)) {
            await browser.storage.local.remove([PENDING_CONFLICT_COPY_KEY]).catch(() => undefined);
            conflictCopyUncertain = false;
        }
        if (operation === operationGeneration) {
            if (postStarted && !cloudSaved && !definiteCreateRejection) {
                conflictCopyUncertain = true;
                status(t(
                    "无法确认新条目是否已创建。请先同步检查，不要重复另存。",
                    "The item creation result is uncertain. Sync and check before trying again.",
                ), true);
            } else if (cloudSaved) {
                status(t("已保存到云端；本地状态需要重新同步确认。", "Saved to the cloud; sync again to refresh the local state."), true);
            } else if (error?.message === "conflict_candidates_changed" || error?.status === 409) {
                status(t("候选版本已变化，请刷新后重新操作。", "The candidate set changed. Refresh before trying again."), true);
            } else {
                status(t("候选未能另存，原冲突和数据均已保留。", "The candidate was not copied. The conflict and its data were preserved."), true);
            }
            if (error?.status === 401 && context) {
                await markCloudSessionExpired(context, operation, generation);
            }
            await refreshConflicts(false);
        }
        console.warn("[upw] browser conflict candidate copy failed; code:", error?.code ?? error?.message ?? error?.name);
    } finally {
        copied = null;
        conflictResolving = false;
        renderConflictGroups();
    }
}

/** 保存邮箱登录表单草稿，供弹窗失焦重开后恢复；不保存主密码。 */
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
refreshConflictsButton.addEventListener("click", () => { void refreshConflicts(true); });
lockNowButton.addEventListener("click", async () => {
    await lockSession();
    await render();
});
vaultTab.addEventListener("click", () => navigate("vault"));
settingsTab.addEventListener("click", () => navigate("settings"));
retrySyncQuarantineButton.addEventListener("click", () => { void retrySyncQuarantine(); });
generatorTab.addEventListener("click", async () => {
    await navigate("generator");
    if (activePanel === "generator" && !generatedPassword) await regeneratePassword();
});
for (const control of [siteFilter, sortItems]) control.addEventListener("change", () => {
    listScrollTop = 0;
    if (unlockedItems !== null) renderCandidates(unlockedItems);
});
// 站点横幅快速填充:从解锁会话重新解析匹配项,不依赖当前渲染列表/筛选状态
document.getElementById("siteContext").addEventListener("click", () => {
    void quickFillCurrentSite();
});
document.getElementById("newLoginButton").addEventListener("click", () => openNewLogin());
document.getElementById("emptyNewLoginButton").addEventListener("click", () => openNewLogin());
document.getElementById("newLoginBackButton").addEventListener("click", () => navigate("vault"));
document.getElementById("createLoginSaveButton").addEventListener("click", createNewLogin);
for (const input of newLoginFields) input.addEventListener("input", () => { newLoginDirty = true; });
document.getElementById("regenerateButton").addEventListener("click", regeneratePassword);
document.getElementById("revealGeneratedButton").addEventListener("click", async () => {
    const operation = operationGeneration;
    const generation = unlockedGeneration;
    const state = await sessionCommand("read");
    if (operation !== operationGeneration || generation !== unlockedGeneration
        || !state.unlocked || state.generation !== generation) return;
    generatedInput.type = generatedInput.type === "password" ? "text" : "password";
    document.getElementById("revealGeneratedButton").textContent = generatedInput.type === "text" ? t("隐藏", "Hide") : t("显示", "Show");
});
document.getElementById("copyGeneratedButton").addEventListener("click", async () => {
    const operation = operationGeneration;
    const generation = unlockedGeneration;
    try {
        const state = await sessionCommand("read");
        if (operation !== operationGeneration || generation !== unlockedGeneration
            || !state.unlocked || state.generation !== generation || !generatedPassword) return;
        await navigator.clipboard.writeText(generatedPassword);
        status(t("已复制，请在使用后覆盖剪贴板。", "Copied. Overwrite the clipboard after use."));
        console.info("[upw] generated password copied");
    } catch {
        status(t("复制失败，请检查权限。", "Copy failed. Check permissions."), true);
        console.warn("[upw] generated password copy failed");
    }
});
document.getElementById("useGeneratedButton").addEventListener("click", () => openNewLogin(generatedPassword));
document.getElementById("switchVaultButton").addEventListener("click", async () => {
    if (!confirmDiscard()) return;
    const bag = await storageGet([SESSION_KEY]);
    const session = bag[SESSION_KEY];
    if (!session || session.expiresAt <= Date.now()) {
        await lockSession();
        show("login");
        status(t("切换密码库需要重新登录。", "Sign in again to switch vaults."), true);
        return;
    }
    await lockSession();
    switchingVault = true;
    console.info("[upw] vault switching started");
    await showVaultPage(session.token);
});
document.getElementById("cancelVaultSwitchButton").addEventListener("click", async () => {
    operationGeneration += 1;
    switchingVault = false;
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
document.getElementById("allowUnknownNetworkAttachments").addEventListener("change", async event => {
    await storageSet({ [UNKNOWN_NETWORK_ATTACHMENT_KEY]: event.currentTarget.checked });
    await attachmentNetworkChanged();
    console.info("[upw] unknown-network attachment policy updated");
    status(t("附件后台下载设置已保存。", "Background attachment download setting saved."));
});
document.getElementById("allowCellularAttachmentDownloads").addEventListener("change", async event => {
    await storageSet({ [CELLULAR_ATTACHMENT_KEY]: event.currentTarget.checked });
    await attachmentNetworkChanged();
    console.info("[upw] cellular attachment policy updated");
    status(t("蜂窝网络附件后台下载设置已保存。", "Cellular attachment download setting saved."));
});
lockButton.addEventListener("click", async () => {
    if (!detailSaving && !newLoginSaving && !confirmDiscard()) return;
    const { [SESSION_KEY]: session } = await storageGet([SESSION_KEY]);
    await lockSession();
    let preservationFailed = false;
    try {
        if (session?.userId) {
            await encryptedCache.preserveAccount(session.userId);
            await storageSet({ [VAULT_OWNER_KEY]: session.userId });
        } else {
            await browser.storage.local.remove([VAULT_KEY, VAULT_OWNER_KEY]);
        }
    } catch (error) {
        preservationFailed = true;
        console.warn("[upw] sign-out cache fencing failed; data retained:", error?.message ?? error?.name);
    }
    await browser.storage.local.remove(SESSION_KEY);
    await clearItems();
    const { [DRAFT_KEY]: draft } = await storageGet([DRAFT_KEY]);
    if (draft) await storageSet({ [DRAFT_KEY]: { email: draft.email, code: "" } });
    await render();
    if (preservationFailed) {
        status(t(
            "已退出登录，本机加密副本仍保留；重新登录后请先同步。",
            "Signed out. The local encrypted copy is retained; sync after signing in again.",
        ), true);
    }
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

async function exportPortableBackup() {
    if (unlockedItems === null || !unlockedGeneration || backupExportButton.disabled || syncInFlight) return;
    const operation = operationGeneration;
    const generation = unlockedGeneration;
    backupExportButton.disabled = true;
    backupExportStatus.textContent = t("正在验证本地副本并创建加密备份…", "Verifying the local copy and creating an encrypted backup…");
    console.info("[upw] portable backup export started");
    try {
        const bag = await storageGet([SESSION_KEY, VAULT_KEY]);
        const session = bag[SESSION_KEY];
        const vault = bag[VAULT_KEY];
        if (!session?.token || !vault?.id || session.expiresAt <= Date.now()) throw new Error("login_required");
        const context = sessionContext(session, vault);
        const scope = cacheScope(session, vault);
        const snapshot = await encryptedCache.read(scope);
        if (!snapshot || snapshot.version !== unlockedSnapshotVersion
            || snapshot.passwordVersion !== unlockedPasswordVersion) throw new Error("backup_snapshot_changed");

        const validateSnapshot = async () => {
            if (operation !== operationGeneration || generation !== unlockedGeneration) {
                throw new Error("operation_cancelled");
            }
            const active = await storageGet([SESSION_KEY, VAULT_KEY]);
            if (active[SESSION_KEY]?.token !== session.token
                || active[SESSION_KEY]?.userId !== session.userId
                || active[VAULT_KEY]?.id !== vault.id) throw new Error("session_changed");
            const state = await sessionCommand("read", {}, context);
            if (!state.unlocked || state.generation !== generation
                || state.snapshotVersion !== snapshot.version
                || state.passwordVersion !== snapshot.passwordVersion) throw new Error("session_changed");
            const latest = await encryptedCache.read(scope);
            if (!latest || latest.version !== snapshot.version || latest.envelope !== snapshot.envelope) {
                throw new Error("backup_snapshot_changed");
            }
        };
        await validateSnapshot();
        const decrypted = await sessionCommand("decrypt", {
            generation,
            rows: snapshot.rows,
        }, context);
        if (!decrypted.unlocked || decrypted.generation !== generation
            || decrypted.snapshotVersion !== snapshot.version
            || decrypted.failures?.length || decrypted.fragments?.length !== snapshot.rows.length) {
            throw new Error(decrypted.code ?? "backup_snapshot_verification_failed");
        }
        for (const fragment of decrypted.fragments) projectVaultFragment(fragment);
        const xml = fragmentsToXml(decrypted.fragments.map(fragment => fragment.xml));
        await validateSnapshot();

        const cloudCapture = await captureBackupCloudHistory({
            token: session.token,
            vaultId: vault.id,
            localCursor: snapshot.cursor,
            localPasswordVersion: snapshot.passwordVersion,
            fragments: decrypted.fragments,
            validate: validateSnapshot,
            verifyCandidate: async row => {
                const candidate = await sessionCommand("decrypt", { generation, rows: [row] }, context);
                if (!candidate.unlocked || candidate.generation !== generation
                    || candidate.snapshotVersion !== snapshot.version
                    || candidate.passwordVersion !== snapshot.passwordVersion
                    || candidate.failures?.length || candidate.fragments?.length !== 1) {
                    throw new Error(candidate.code ?? "backup_candidate_verification_failed");
                }
                projectVaultFragment(candidate.fragments[0]);
            },
            onProgress: (phase, completed, total) => {
                backupExportStatus.textContent = phase === "attachments"
                    ? t(`正在采集附件版本 ${completed}/${total}…`, `Collecting attachment versions ${completed}/${total}…`)
                    : t(`正在验证冲突候选 ${completed}/${total}…`, `Verifying conflict groups ${completed}/${total}…`);
            },
        });
        await validateSnapshot();

        const sealed = await sessionCommand("seal-backup", {
            generation,
            backupXml: xml,
            backupMetadata: {
                createdAtMs: Date.now(),
                headSequence: cloudCapture.headSequence,
                attachments: cloudCapture.attachments,
                conflicts: cloudCapture.conflicts,
                issues: cloudCapture.issues,
            },
        }, context);
        if (!sealed.unlocked || sealed.generation !== generation || !sealed.bodyB64
            || !sealed.backupManifestB64 || !sealed.backupInfo || sealed.backupInfo.isComplete
            || sealed.backupInfo.issueCount < 1 || "vaultKey" in sealed) {
            throw new Error(sealed.code ?? "backup_seal_failed");
        }
        await validateSnapshot();
        const archive = createBackupArchive({
            body: base64ToBytes(sealed.bodyB64),
            manifest: base64ToBytes(sealed.backupManifestB64),
            info: sealed.backupInfo,
        }, base64ToBytes(snapshot.envelope), cloudCapture.payloadFiles);
        const timestamp = new Date().toISOString().replace(/[-:]/g, "").replace(/\.\d{3}Z$/, "Z");
        const baseName = String(vault.name ?? "UPasswords").replace(/[<>:"/\\|?*\u0000-\u001f]/g, "-").trim() || "UPasswords";
        const anchor = document.createElement("a");
        const objectURL = URL.createObjectURL(archive);
        anchor.href = objectURL;
        anchor.download = `${baseName}-${timestamp}.upwbackup`;
        anchor.hidden = true;
        document.body.append(anchor);
        anchor.click();
        anchor.remove();
        setTimeout(() => URL.revokeObjectURL(objectURL), 60_000);
        backupExportStatus.textContent = t(
            `已导出不完整备份，包含 ${sealed.backupInfo.issueCount} 项未采集内容。`,
            `Incomplete backup exported with ${sealed.backupInfo.issueCount} uncaptured item(s).`,
        );
        status(backupExportStatus.textContent);
        console.info("[upw] portable backup exported; issues:", sealed.backupInfo.issueCount);
    } catch (error) {
        if (operation !== operationGeneration) return;
        const message = error?.message === "backup_snapshot_too_large"
            ? t("本地快照超过扩展备份大小限制；请在桌面或移动应用中创建备份。", "The local snapshot exceeds the extension backup size limit. Create the backup in the desktop or mobile app.")
            : error?.message === "backup_snapshot_changed" || error?.message === "session_changed"
                ? t("备份期间密码库发生变化，请同步完成后重新导出。", "The vault changed during export. Finish syncing and export again.")
                : t("备份未创建；本地副本未更改，请重新解锁后重试。", "Backup was not created. The local copy is unchanged; unlock again and retry.");
        backupExportStatus.textContent = message;
        status(message, true);
        console.warn("[upw] portable backup export failed; code:", error?.message ?? error?.name);
    } finally {
        backupExportButton.disabled = false;
    }
}

function backupIssueMessage(issue) {
    const kind = Object.keys(issue ?? {})[0];
    const messages = {
        cloudInventoryUnavailable: t("云端附件清单不可用。", "Cloud attachment inventory was unavailable."),
        cloudInventoryChanged: t("备份期间云端附件清单发生变化。", "Cloud attachment inventory changed during backup."),
        retainedConflictHistoryUnavailable: t("已裁决冲突历史不可用。", "Resolved conflict history was unavailable."),
        localSnapshotBehindCloud: t("本地快照落后于云端。", "The local snapshot was behind the cloud."),
        localConflictUnavailable: t("有冲突候选未能采集。", "A conflict candidate could not be captured."),
        attachmentIdentityUnavailable: t("附件身份无法验证。", "An attachment identity could not be verified."),
        attachmentVersionUnavailable: t("有附件版本未能恢复。", "An attachment version could not be restored."),
        conflictCandidateUnavailable: t("有冲突候选未能恢复。", "A conflict candidate could not be restored."),
    };
    return messages[kind] ?? t("备份包含未验证的内容。", "The backup contains unverified content.");
}

function countBackupRecords(xml) {
    const parsed = new DOMParser().parseFromString(xml, "application/xml");
    if (parsed.doctype || parsed.querySelector("parsererror")) throw new Error("backup_snapshot_invalid");
    return parsed.querySelectorAll("card, user_profile").length;
}

function showBackupReview(inspection) {
    const issues = Array.isArray(inspection.issues) ? inspection.issues : [];
    backupRestoreReview.hidden = false;
    backupRestoreSummary.textContent = inspection.isComplete
        ? t(
            `已验证 ${inspection.itemCount} 个条目、${inspection.info.attachmentVersionCount} 个附件版本和 ${inspection.info.conflictCount} 组冲突。`,
            `Verified ${inspection.itemCount} entries, ${inspection.info.attachmentVersionCount} attachment versions, and ${inspection.info.conflictCount} conflicts.`,
        )
        : t(
            `已验证 ${inspection.itemCount} 个条目；发现 ${issues.length} 项不完整内容。`,
            `Verified ${inspection.itemCount} entries; found ${issues.length} incomplete item(s).`,
        );
    backupRestoreIssues.replaceChildren();
    const visibleIssues = issues.slice(0, 50);
    for (const issue of visibleIssues) {
        const entry = document.createElement("li");
        entry.textContent = backupIssueMessage(issue);
        backupRestoreIssues.append(entry);
    }
    if (issues.length > visibleIssues.length) {
        const entry = document.createElement("li");
        entry.textContent = t(
            `另有 ${issues.length - visibleIssues.length} 项。`,
            `${issues.length - visibleIssues.length} more item(s).`,
        );
        backupRestoreIssues.append(entry);
    }
    allowIncompleteRestoreRow.hidden = inspection.isComplete;
    if (inspection.isComplete) allowIncompleteRestoreInput.checked = false;
    updateRestoreButtonState();
}

function updateRestoreButtonState() {
    const reviewReady = Boolean(pendingBackupFile && pendingBackupReview);
    const sourceReady = Boolean(backupSourcePasswordInput.value);
    const nameReady = Boolean(localCopyNameInput.value.trim());
    const password = localCopyPasswordInput.value;
    const passwordReady = password.length >= 4 && password === localCopyPasswordConfirmInput.value;
    const incompleteAllowed = pendingBackupReview?.isComplete !== false || allowIncompleteRestoreInput.checked;
    restoreBackupButton.disabled = !reviewReady || !sourceReady || !nameReady || !passwordReady || !incompleteAllowed;
}

async function openLocalBackupManager() {
    if (!localBackupManagerDialog.open) localBackupManagerDialog.showModal();
    await renderLocalBackupCopies();
}

async function renderLocalBackupCopies() {
    localBackupCopyList.replaceChildren();
    localBackupManagerStatus.textContent = t("正在读取本地副本…", "Loading local copies…");
    try {
        const copies = await localBackupStore.list();
        if (copies.length === 0) {
            localBackupManagerStatus.textContent = t("尚无本地备份或副本。", "No local backups or copies yet.");
            return;
        }
        localBackupManagerStatus.textContent = t(`${copies.length} 个本地副本`, `${copies.length} local copy/copies`);
        for (const copy of copies) {
            const row = document.createElement("div");
            row.className = "local-copy-row";
            const details = document.createElement("div");
            details.className = "local-copy-summary";
            const title = document.createElement("strong");
            title.textContent = copy.name;
            const metadata = document.createElement("p");
            const completeness = copy.isComplete
                ? t("完整", "Complete")
                : t(`${copy.issueCount} 项不完整`, `${copy.issueCount} incomplete`);
            metadata.textContent = t(
                `${new Date(copy.createdAt).toLocaleString()} · ${copy.itemCount} 个条目 · ${completeness}`,
                `${new Date(copy.createdAt).toLocaleString()} · ${copy.itemCount} entries · ${completeness}`,
            );
            details.append(title, metadata);
            const actions = document.createElement("div");
            actions.className = "local-copy-actions";
            const openButton = document.createElement("button");
            openButton.type = "button";
            openButton.className = "secondary";
            openButton.textContent = t("打开", "Open");
            openButton.addEventListener("click", () => openLocalCopy(copy.id));
            const deleteButton = document.createElement("button");
            deleteButton.type = "button";
            deleteButton.className = "secondary";
            deleteButton.textContent = t("删除", "Delete");
            deleteButton.addEventListener("click", () => { void deleteLocalCopy(copy); });
            actions.append(openButton, deleteButton);
            row.append(details, actions);
            localBackupCopyList.append(row);
        }
    } catch (error) {
        localBackupManagerStatus.textContent = t("无法读取本地副本；本地数据未更改。", "Could not read local copies. Local data was not changed.");
        console.warn("[upw] local backup list failed; code:", error?.message ?? error?.name);
    }
}

function chooseLocalBackupFile() {
    localBackupManagerStatus.textContent = "";
    localBackupFileInput.click();
}

function beginLocalBackupRestore(event) {
    const file = event.currentTarget.files?.[0] ?? event.target.files?.[0];
    localBackupFileInput.value = "";
    if (!file || typeof file.arrayBuffer !== "function") return;
    if (!Number.isSafeInteger(file.size) || file.size < 1 || file.size > MAX_BACKUP_ARCHIVE_BYTES) {
        localBackupManagerStatus.textContent = t("备份文件为空或超过 512 MiB。", "The backup is empty or exceeds 512 MiB.");
        return;
    }
    pendingBackupFile = file;
    pendingBackupFileName = String(file.name ?? "").replace(/\.upwbackup$/i, "").slice(0, 128);
    pendingBackupReview = null;
    backupSourcePasswordInput.value = "";
    backupRestoreReview.hidden = true;
    backupRestoreSummary.textContent = "";
    backupRestoreIssues.replaceChildren();
    backupRestoreStatus.textContent = "";
    localCopyNameInput.value = pendingBackupFileName;
    localCopyPasswordInput.value = "";
    localCopyPasswordConfirmInput.value = "";
    allowIncompleteRestoreInput.checked = false;
    allowIncompleteRestoreRow.hidden = true;
    restoreBackupButton.disabled = true;
    localBackupManagerDialog.close();
    backupRestoreDialog.showModal();
}

async function reviewBackupFile() {
    if (!pendingBackupFile || reviewBackupButton.disabled) return;
    if (!backupSourcePasswordInput.value) {
        backupRestoreStatus.textContent = t("请输入备份原主密码。", "Enter the backup's source master password.");
        return;
    }
    const sourcePassword = backupSourcePasswordInput.value;
    const operation = ++backupWorkflowGeneration;
    reviewBackupButton.disabled = true;
    backupSourcePasswordInput.disabled = true;
    pendingBackupReview = null;
    backupRestoreReview.hidden = true;
    restoreBackupButton.disabled = true;
    backupRestoreStatus.textContent = t("正在验证备份…", "Verifying backup…");
    try {
        const inspection = await inspectBackupArchive(pendingBackupFile, sourcePassword);
        if (operation !== backupWorkflowGeneration || sourcePassword !== backupSourcePasswordInput.value) return;
        pendingBackupReview = {
            info: inspection.info,
            isComplete: inspection.isComplete,
            issues: inspection.issues,
            verificationToken: inspection.verificationToken,
            itemCount: countBackupRecords(inspection.xml),
        };
        showBackupReview(pendingBackupReview);
        backupRestoreStatus.textContent = inspection.isComplete
            ? t("备份验证通过。", "Backup verified.")
            : t("备份可读取，但恢复结果不完整；创建前须明确确认。", "The backup is readable but incomplete. Confirm before creating the copy.");
    } catch (error) {
        if (operation !== backupWorkflowGeneration || sourcePassword !== backupSourcePasswordInput.value) return;
        pendingBackupReview = null;
        backupRestoreReview.hidden = true;
        backupRestoreStatus.textContent = t(
            "无法验证备份；请检查文件和原主密码。",
            "Could not verify the backup. Check the file and source password.",
        );
        console.warn("[upw] backup review failed; code:", error?.message ?? error?.name);
    } finally {
        if (operation === backupWorkflowGeneration) {
            backupSourcePasswordInput.disabled = false;
            reviewBackupButton.disabled = false;
            updateRestoreButtonState();
        }
    }
}

async function createLocalCopyFromBackup() {
    if (restoreBackupButton.disabled || !pendingBackupFile || !pendingBackupReview) return;
    if (localCopyPasswordInput.value.length < 4) {
        backupRestoreStatus.textContent = t("新副本主密码至少 4 位。", "The new copy password needs at least 4 characters.");
        return;
    }
    if (localCopyPasswordInput.value !== localCopyPasswordConfirmInput.value) {
        backupRestoreStatus.textContent = t("两次输入的新主密码不一致。", "The new master passwords do not match.");
        return;
    }
    const allowIncomplete = allowIncompleteRestoreInput.checked;
    const operation = ++backupWorkflowGeneration;
    const restoreInputs = [
        backupSourcePasswordInput,
        localCopyNameInput,
        localCopyPasswordInput,
        localCopyPasswordConfirmInput,
        allowIncompleteRestoreInput,
    ];
    for (const input of restoreInputs) input.disabled = true;
    restoreBackupButton.disabled = true;
    backupRestoreStatus.textContent = t("正在创建独立本地副本…", "Creating an independent local copy…");
    let prepared = null;
    try {
        prepared = await prepareBackupRestore(pendingBackupFile, {
            sourcePassword: backupSourcePasswordInput.value,
            destinationPassword: localCopyPasswordInput.value,
            expectedVerificationToken: pendingBackupReview.verificationToken,
            allowIncomplete,
        });
        if (operation !== backupWorkflowGeneration) {
            prepared.historyCipher.fill(0);
            return;
        }
        if (!prepared.isComplete && !allowIncomplete) {
            pendingBackupReview = {
                ...pendingBackupReview,
                isComplete: false,
                issues: prepared.issues,
            };
            showBackupReview(pendingBackupReview);
            backupRestoreStatus.textContent = t(
                "恢复时发现额外的不完整内容；请确认后再次创建。",
                "Restore found additional incomplete content. Confirm and create the copy again.",
            );
            prepared.historyCipher.fill(0);
            prepared = null;
            return;
        }
        const copyID = crypto.randomUUID();
        await localBackupStore.create({
            id: copyID,
            name: localCopyNameInput.value.trim(),
            createdAt: Date.now(),
            itemCount: pendingBackupReview.itemCount,
            attachmentVersionCount: prepared.info.attachmentVersionCount,
            conflictCount: prepared.info.conflictCount,
            issueCount: prepared.issues.length,
            isComplete: prepared.isComplete,
            archive: prepared.archive,
            historyCipher: prepared.historyCipher,
        });
        if (operation !== backupWorkflowGeneration) {
            try {
                await localBackupStore.remove(copyID);
            } catch (error) {
                console.warn("[upw] cancelled local backup cleanup failed; code:", error?.message ?? error?.name);
            }
            return;
        }
        prepared.historyCipher.fill(0);
        prepared = null;
        console.info("[upw] local backup copy created", { items: pendingBackupReview.itemCount });
        clearBackupRestoreWorkflow();
        backupRestoreDialog.close();
        await openLocalBackupManager();
        localBackupManagerStatus.textContent = t("本地副本已创建。", "Local copy created.");
    } catch (error) {
        if (operation !== backupWorkflowGeneration) return;
        const messages = {
            backup_package_changed: t("备份在验证后发生变化，请重新选择并验证。", "The backup changed after verification. Select and verify it again."),
            backup_incomplete_confirmation_required: t("请确认创建不完整副本。", "Confirm creation of an incomplete copy."),
            local_backup_store_invalid_copy: t("副本未保存；名称或备份数据无效。", "The copy was not saved. Its name or backup data is invalid."),
        };
        backupRestoreStatus.textContent = messages[error?.message]
            ?? t("本地副本未创建；请检查密码和可用存储空间。", "The local copy was not created. Check the passwords and available storage.");
        backupSourcePasswordInput.value = "";
        localCopyPasswordInput.value = "";
        localCopyPasswordConfirmInput.value = "";
        console.warn("[upw] local backup restore failed; code:", error?.message ?? error?.name);
    } finally {
        prepared?.historyCipher.fill(0);
        if (operation === backupWorkflowGeneration) {
            for (const input of restoreInputs) input.disabled = false;
            updateRestoreButtonState();
        }
    }
}

function clearBackupRestoreWorkflow() {
    backupWorkflowGeneration += 1;
    pendingBackupFile = null;
    pendingBackupFileName = "";
    pendingBackupReview = null;
    backupSourcePasswordInput.value = "";
    localCopyPasswordInput.value = "";
    localCopyPasswordConfirmInput.value = "";
    localCopyNameInput.value = "";
    allowIncompleteRestoreInput.checked = false;
    backupSourcePasswordInput.disabled = false;
    localCopyNameInput.disabled = false;
    localCopyPasswordInput.disabled = false;
    localCopyPasswordConfirmInput.disabled = false;
    allowIncompleteRestoreInput.disabled = false;
    backupRestoreReview.hidden = true;
    allowIncompleteRestoreRow.hidden = true;
    backupRestoreSummary.textContent = "";
    backupRestoreIssues.replaceChildren();
    backupRestoreStatus.textContent = "";
    reviewBackupButton.disabled = false;
    restoreBackupButton.disabled = true;
}

function openLocalCopy(copyID) {
    pendingLocalCopyID = copyID;
    localCopyUnlockPasswordInput.value = "";
    localCopyUnlockStatus.textContent = "";
    localCopyUnlockDialog.showModal();
    localCopyUnlockPasswordInput.focus();
}

async function unlockLocalCopy() {
    if (!pendingLocalCopyID || unlockLocalCopyButton.disabled) return;
    const copyID = pendingLocalCopyID;
    const password = localCopyUnlockPasswordInput.value;
    if (!password) {
        localCopyUnlockStatus.textContent = t("请输入本地副本主密码。", "Enter the local copy master password.");
        return;
    }
    const operation = ++backupWorkflowGeneration;
    unlockLocalCopyButton.disabled = true;
    localCopyUnlockStatus.textContent = t("正在验证本地副本…", "Verifying local copy…");
    try {
        const copy = await localBackupStore.read(copyID);
        if (!copy) throw new Error("local_backup_copy_missing");
        const inspection = await inspectBackupArchive(copy.archive, password);
        if (operation !== backupWorkflowGeneration || copyID !== pendingLocalCopyID) return;
        localCopyItems = parseLocalCopyItems(inspection.xml);
        selectedLocalCopyItemID = null;
        localCopyViewerHeading.textContent = copy.name;
        localCopySearchInput.value = "";
        localCopyIntegrityStatus.textContent = inspection.isComplete
            ? t("副本完整性验证通过。", "Copy integrity verified.")
            : t(`副本含 ${inspection.issues.length} 项不完整内容。`, `Copy contains ${inspection.issues.length} incomplete item(s).`);
        renderLocalCopyItems();
        localCopyUnlockPasswordInput.value = "";
        localCopyUnlockDialog.close();
        localBackupManagerDialog.close();
        localCopyViewerDialog.showModal();
        pendingLocalCopyID = null;
    } catch (error) {
        if (operation !== backupWorkflowGeneration) return;
        localCopyUnlockPasswordInput.value = "";
        localCopyUnlockStatus.textContent = t("无法打开副本；请检查副本主密码或数据完整性。", "Could not open the copy. Check its password and integrity.");
        console.warn("[upw] local backup copy unlock failed; code:", error?.message ?? error?.name);
    } finally {
        if (operation === backupWorkflowGeneration) unlockLocalCopyButton.disabled = false;
    }
}

function parseLocalCopyItems(xml) {
    const parsed = new DOMParser().parseFromString(xml, "application/xml");
    if (parsed.doctype || parsed.querySelector("parsererror")) throw new Error("backup_snapshot_invalid");
    return Array.from(parsed.querySelectorAll("card, user_profile"), card => ({
        id: card.getAttribute("id") ?? "",
        title: card.tagName === "user_profile"
            ? t("个人资料", "Personal information")
            : card.getAttribute("title") ?? t("未命名条目", "Untitled item"),
        archived: card.getAttribute("archived") === "true",
        trashed: card.getAttribute("trashed") === "true",
        fields: Array.from(card.children)
            .filter(field => field.localName === "field" && !field.namespaceURI)
            .map(field => ({
                name: field.getAttribute("name") ?? "",
                type: field.getAttribute("type") ?? "text",
                value: field.textContent ?? "",
            })),
        notes: Array.from(card.children).find(child => child.localName === "note" && !child.namespaceURI)?.textContent ?? "",
        attachments: Array.from(card.children)
            .filter(child => ["image", "file"].includes(child.localName) && !child.namespaceURI)
            .map(child => child.getAttribute("name") ?? t("附件", "Attachment")),
    }));
}

function renderLocalCopyItems() {
    const query = localCopySearchInput.value.trim().toLowerCase();
    const filtered = localCopyItems.filter(item => {
        const searchable = [item.title, ...item.fields
            .filter(field => !["password", "pin", "secret", "one_time_password"].includes(field.type))
            .map(field => field.value)].join(" ").toLowerCase();
        return !query || searchable.includes(query);
    });
    localCopyItemList.replaceChildren();
    for (const item of filtered) {
        const button = document.createElement("button");
        button.type = "button";
        button.className = "local-copy-item";
        const title = document.createElement("strong");
        title.textContent = item.title;
        const metadata = document.createElement("span");
        metadata.textContent = t(
            `${item.fields.length} 个字段${item.trashed ? " · 回收站" : item.archived ? " · 已归档" : ""}`,
            `${item.fields.length} fields${item.trashed ? " · Trash" : item.archived ? " · Archived" : ""}`,
        );
        button.append(title, metadata);
        button.addEventListener("click", () => renderLocalCopyItemDetail(item.id));
        localCopyItemList.append(button);
    }
    if (filtered.length === 0) {
        const empty = document.createElement("p");
        empty.textContent = t("没有匹配的条目。", "No matching entries.");
        localCopyItemList.append(empty);
    }
    if (selectedLocalCopyItemID && !filtered.some(item => item.id === selectedLocalCopyItemID)) {
        selectedLocalCopyItemID = null;
        localCopyDetail.replaceChildren();
        localCopyDetail.hidden = true;
    }
}

function localCopyFieldLabel(field) {
    if (field.name && !field.name.startsWith("@string/")) return field.name;
    const names = {
        login: t("用户名", "Username"),
        password: t("密码", "Password"),
        website: t("网站", "Website"),
        email: t("电子邮件", "Email"),
        phone: t("电话", "Phone"),
        one_time_password: "TOTP",
    };
    return names[field.type] ?? t("文本", "Text");
}

function renderLocalCopyItemDetail(itemID) {
    const item = localCopyItems.find(value => value.id === itemID);
    if (!item) return;
    selectedLocalCopyItemID = itemID;
    localCopyDetail.replaceChildren();
    localCopyDetail.hidden = false;
    const title = document.createElement("h3");
    title.textContent = item.title;
    localCopyDetail.append(title);
    for (const field of item.fields) {
        const row = document.createElement("div");
        row.className = "local-copy-field";
        const label = document.createElement("span");
        label.className = "local-copy-field-label";
        label.textContent = localCopyFieldLabel(field);
        const value = document.createElement("span");
        value.className = "local-copy-field-value";
        const masked = ["password", "pin", "secret", "one_time_password"].includes(field.type);
        let revealed = false;
        const paintValue = () => { value.textContent = masked && !revealed ? "••••••••" : field.value; };
        paintValue();
        row.append(label, value);
        if (masked) {
            const reveal = document.createElement("button");
            reveal.type = "button";
            reveal.className = "secondary";
            reveal.textContent = t("显示", "Show");
            reveal.addEventListener("click", () => {
                revealed = !revealed;
                paintValue();
                reveal.textContent = revealed ? t("隐藏", "Hide") : t("显示", "Show");
            });
            row.append(reveal);
        }
        localCopyDetail.append(row);
    }
    if (item.notes) {
        const notes = document.createElement("p");
        notes.className = "local-copy-notes";
        notes.textContent = item.notes;
        localCopyDetail.append(notes);
    }
    if (item.attachments.length > 0) {
        const attachments = document.createElement("p");
        attachments.className = "local-copy-attachments";
        attachments.textContent = t(
            `包含 ${item.attachments.length} 个附件：${item.attachments.join("、")}`,
            `Contains ${item.attachments.length} attachment(s): ${item.attachments.join(", ")}`,
        );
        localCopyDetail.append(attachments);
    }
}

function clearLocalCopyViewer() {
    backupWorkflowGeneration += 1;
    localCopyItems = [];
    selectedLocalCopyItemID = null;
    pendingLocalCopyID = null;
    localCopyUnlockPasswordInput.value = "";
    localCopySearchInput.value = "";
    localCopyIntegrityStatus.textContent = "";
    localCopyItemList.replaceChildren();
    localCopyDetail.replaceChildren();
    localCopyDetail.hidden = true;
    if (localCopyUnlockDialog.open) localCopyUnlockDialog.close();
    if (localCopyViewerDialog.open) localCopyViewerDialog.close();
}

function closeBackupRestore() {
    clearBackupRestoreWorkflow();
    backupRestoreDialog.close();
}

function closeLocalCopyUnlock() {
    backupWorkflowGeneration += 1;
    pendingLocalCopyID = null;
    localCopyUnlockPasswordInput.value = "";
    localCopyUnlockStatus.textContent = "";
    unlockLocalCopyButton.disabled = false;
    localCopyUnlockDialog.close();
}

async function deleteLocalCopy(copy) {
    if (!confirm(t(`删除本地副本“${copy.name}”？此操作无法撤销。`, `Delete local copy “${copy.name}”? This cannot be undone.`))) return;
    try {
        await localBackupStore.remove(copy.id);
        await renderLocalBackupCopies();
        localBackupManagerStatus.textContent = t("本地副本已删除。", "Local copy deleted.");
    } catch (error) {
        localBackupManagerStatus.textContent = t("无法删除本地副本；数据未更改。", "Could not delete the local copy. Data was not changed.");
        console.warn("[upw] local backup delete failed; code:", error?.message ?? error?.name);
    }
}

function clearUnlockedView() {
    clearBackupRestoreWorkflow();
    if (backupRestoreDialog.open) backupRestoreDialog.close();
    if (localBackupManagerDialog.open) localBackupManagerDialog.close();
    localBackupCopyList.replaceChildren();
    localBackupManagerStatus.textContent = "";
    clearLocalCopyViewer();
    attachmentAbortController?.abort();
    clearTimeout(attachmentRetryTimer);
    attachmentRetryTimer = null;
    attachmentPolicyView = null;
    attachmentPolicyReferences = [];
    attachmentPolicyUnavailable = false;
    document.getElementById("attachmentDownloadSummary").textContent = "";
    document.getElementById("endDownloadAllAttachmentsButton").hidden = true;
    backgroundAttachmentRequested = false;
    backgroundAttachmentQueue = [];
    for (const task of priorityAttachmentQueue) task.reject(new Error("session_changed"));
    priorityAttachmentQueue.length = 0;
    priorityAttachmentTasks.clear();
    clearDetailView();
    clearNewLoginForm();
    generatedPassword = "";
    generatedInput.value = "";
    generatedInput.type = "password";
    lastSyncSuccessAt = 0;
    listScrollTop = 0;
    lastSyncAttempt = 0;
    currentView = "vault";
    passwordInput.value = "";
    newVaultPassword.value = "";
    newVaultPasswordConfirm.value = "";
    searchInput.value = "";
    unlockedItems = null;
    syncQuarantineItems = [];
    unlockedGeneration = null;
    unlockedExpiresAt = 0;
    unlockedSnapshotVersion = null;
    unlockedPasswordVersion = null;
    conflictGroups = [];
    autofillConflictGate = null;
    autofillConflictGateScopeKey = null;
    conflictsStatus.textContent = "";
    conflictsList.replaceChildren();
    itemsEl.replaceChildren();
    suggestionsEl.replaceChildren();
}

/** 主动失效当前解锁会话，并清除弹窗持有的明文与编辑状态。 */
async function lockSession() {
    operationGeneration += 1;
    unlockButton.disabled = false;
    passwordInput.value = "";
    clearUnlockedView();
    currentView = "vault";
    try {
        await sessionCommand("lock");
    } catch {
        await browser.storage.local.remove([VAULT_KEY, VAULT_OWNER_KEY]);
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
                if (syncInFlight || attachmentPublicationInFlight || detailSaving || newLoginSaving) return;
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
            syncQuarantineItems = cached.quarantinedItems ?? [];
        }
        if (unlockedGeneration && unlockedGeneration !== state.generation) {
            clearUnlockedView();
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

document.getElementById("downloadAllAttachmentsButton").addEventListener("click", () => { void downloadAllAttachments(); });
document.getElementById("endDownloadAllAttachmentsButton").addEventListener("click", () => { void endDownloadAllAttachments(); });
backupExportButton.addEventListener("click", () => { void exportPortableBackup(); });
openLocalCopiesSettingsButton.addEventListener("click", () => { void openLocalBackupManager(); });
importLocalBackupButton.addEventListener("click", chooseLocalBackupFile);
localBackupFileInput.addEventListener("change", beginLocalBackupRestore);
closeLocalBackupManagerButton.addEventListener("click", () => localBackupManagerDialog.close());
closeBackupRestoreButton.addEventListener("click", closeBackupRestore);
reviewBackupButton.addEventListener("click", () => { void reviewBackupFile(); });
restoreBackupButton.addEventListener("click", () => { void createLocalCopyFromBackup(); });
closeLocalCopyUnlockButton.addEventListener("click", closeLocalCopyUnlock);
unlockLocalCopyButton.addEventListener("click", () => { void unlockLocalCopy(); });
closeLocalCopyViewerButton.addEventListener("click", clearLocalCopyViewer);
localCopySearchInput.addEventListener("input", renderLocalCopyItems);
backupSourcePasswordInput.addEventListener("input", () => {
    if (pendingBackupReview) {
        pendingBackupReview = null;
        backupRestoreReview.hidden = true;
        backupRestoreSummary.textContent = "";
        backupRestoreIssues.replaceChildren();
        allowIncompleteRestoreRow.hidden = true;
        allowIncompleteRestoreInput.checked = false;
    }
    updateRestoreButtonState();
});
for (const input of [localCopyNameInput, localCopyPasswordInput, localCopyPasswordConfirmInput]) {
    input.addEventListener("input", updateRestoreButtonState);
}
allowIncompleteRestoreInput.addEventListener("change", updateRestoreButtonState);
backupRestoreDialog.addEventListener("close", clearBackupRestoreWorkflow);
localCopyUnlockDialog.addEventListener("close", () => {
    pendingLocalCopyID = null;
    localCopyUnlockPasswordInput.value = "";
    unlockLocalCopyButton.disabled = false;
});
localCopyViewerDialog.addEventListener("close", clearLocalCopyViewer);
window.addEventListener("online", () => { void attachmentNetworkChanged(); });
window.addEventListener("offline", () => { void attachmentNetworkChanged(); });
(navigator.connection ?? navigator.mozConnection ?? navigator.webkitConnection)?.addEventListener?.("change", () => { void attachmentNetworkChanged(); });

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
