/**
 * 兼容旧式 browser.storage.local 快照的存取与清理。
 * 当前生产解锁流程使用 unlock-session；不要把此模块当作新明文持久化入口。
 *
 * 安全模型:明文条目只允许短驻留——TTL 过期后读取即自毁(空闲自动锁定);
 * 浏览器重启/扩展更新由 background 主动清空。令牌/会话由调用方管理,
 * 本模块绝不触碰密钥材料。
 */

import type { ExtensionItem } from "../core/types.js";

const itemsKey = "vault.items";
const updatedAtKey = "vault.updatedAt";

/** 明文条目驻留上限:超时即视为已锁定,读取时清除并返回空(免 idle 权限)。 */
export const ITEMS_TTL_MS = 5 * 60 * 1000;

interface BrowserStorageArea {
    get(keys: string[]): Promise<Record<string, unknown>>;
    set(entries: Record<string, unknown>): Promise<void>;
}

/** Injected by the platform adapters (WebExtension polyfill shape). */
export function setStorageArea(area: BrowserStorageArea): void {
    storageArea = area;
}

let storageArea: BrowserStorageArea | null = null;

/** 惰性接线:未显式注入时直接取全局命名空间(popup/background 四端通用)。 */
function resolveArea(): BrowserStorageArea | null {
    if (storageArea) return storageArea;
    const ns = globalThis as {
        browser?: { storage?: { local?: BrowserStorageArea } };
        chrome?: { storage?: { local?: BrowserStorageArea } };
    };
    return ns.browser?.storage?.local ?? ns.chrome?.storage?.local ?? null;
}

/** 写入旧式明文快照并记录 TTL 起点；新解锁流程使用 unlock-session。 */
export async function saveItems(items: ExtensionItem[]): Promise<void> {
    const area = resolveArea();
    if (!area) {
        throw new Error("storage area not configured");
    }
    await area.set({ [itemsKey]: items, [updatedAtKey]: Date.now() });
}

/** 读取旧式快照，超时则先清除再返回空数组；不延长快照时限。 */
export async function loadItems(): Promise<ExtensionItem[]> {
    const area = resolveArea();
    if (!area) {
        return [];
    }
    const bag = await area.get([itemsKey, updatedAtKey]);
    const value = bag[itemsKey];
    if (!Array.isArray(value)) {
        return [];
    }
    const ts = typeof bag[updatedAtKey] === "number" ? (bag[updatedAtKey] as number) : 0;
    if (Date.now() - ts > ITEMS_TTL_MS) {
        // 空闲超时 = 自动锁定:明文条目即刻清除
        await clearItems();
        return [];
    }
    return value as ExtensionItem[];
}

/** 主动擦除:过期的明文立即清除(不等下次读取)。供 background 周期闹钟调用,
 * 消除"popup 关闭后 SW 挂起、明文在磁盘驻留远超 TTL"的静态缺口。 */
export async function purgeIfStale(): Promise<void> {
    const area = resolveArea();
    if (!area) {
        return;
    }
    const bag = await area.get([itemsKey, updatedAtKey]);
    const value = bag[itemsKey];
    if (!Array.isArray(value)) {
        return;
    }
    const ts = typeof bag[updatedAtKey] === "number" ? (bag[updatedAtKey] as number) : 0;
    if (Date.now() - ts > ITEMS_TTL_MS) {
        await clearItems();
    }
}

/** 清空明文条目缓存(锁定/浏览器启动/扩展更新时调用)。 */
export async function clearItems(): Promise<void> {
    const area = resolveArea();
    if (!area) {
        return;
    }
    await area.set({ [itemsKey]: null, [updatedAtKey]: 0 });
}

/** 读取旧式快照的更新时间，单位为 Unix 毫秒；未配置或缺失时返回 0。 */
export async function updatedAt(): Promise<number> {
    const area = resolveArea();
    if (!area) {
        return 0;
    }
    const bag = await area.get([updatedAtKey]);
    return typeof bag[updatedAtKey] === "number" ? (bag[updatedAtKey] as number) : 0;
}
