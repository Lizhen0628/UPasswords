// Safe access to the Tauri window handle — returns null outside a Tauri
// webview (plain browser dev server), where the window APIs don't exist.
import type { Window as TauriWindow } from "@tauri-apps/api/window";

export async function currentWindow(): Promise<TauriWindow | null> {
  try {
    const internals = (globalThis as Record<string, unknown>).__TAURI_INTERNALS__;
    if (!internals) return null;
    const { getCurrentWindow } = await import("@tauri-apps/api/window");
    return getCurrentWindow();
  } catch {
    return null;
  }
}
