// Popup: shows the canonical host of the active tab and matching items.
import { canonicalizeHost, hostnameOf } from "./shared/index.js";

const hostEl = document.getElementById("host");
const listEl = document.getElementById("items");

const tabs = await browser.tabs.query({ active: true, currentWindow: true });
const host = canonicalizeHost(hostnameOf(tabs[0]?.url ?? ""));
hostEl.textContent = host || "—";

try {
    const response = await browser.runtime.sendMessage({ type: "query", host });
    if (response && response.type === "items") {
        for (const candidate of response.candidates) {
            const li = document.createElement("li");
            // 只展示标题与用户名占位,不展示密码
            li.textContent = `${candidate.item.title} (${candidate.username ? "•" : "—"})`;
            listEl.appendChild(li);
        }
        if (response.candidates.length === 0) {
            const li = document.createElement("li");
            li.textContent = "—";
            listEl.appendChild(li);
        }
    }
} catch (error) {
    hostEl.textContent = String(error);
}
