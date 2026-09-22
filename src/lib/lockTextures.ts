// 17 procedural lock-screen textures replacing the original texture_1..17.jpg
// (mirrors LockTextures in App/AppSettings.swift; CSS gradients).
export const LOCK_TEXTURE_COUNT = 17;

const PALETTES: [string, string][] = [
  ["#5856d6", "#af52de"], ["#14b8a6", "#06b6d4"], ["#f97316", "#ec4899"],
  ["#22c55e", "#14b8a6"], ["#2f7cf6", "#5856d6"], ["#ec4899", "#a855f7"],
  ["#ef4444", "#f97316"], ["#10b981", "#34d399"], ["#06b6d4", "#2f7cf6"],
  ["#eab308", "#f97316"], ["#a855f7", "#5856d6"], ["#14b8a6", "#22c55e"],
  ["#6b7280", "#111827"], ["#8b5e3c", "#f97316"], ["#5856d6", "#10b981"],
  ["#f97316", "#ef4444"], ["#111827", "#5856d6"],
];

export function textureCss(index: number): string {
  const [a, b] = PALETTES[index % PALETTES.length];
  return `linear-gradient(135deg, ${a} 0%, ${b} 100%)`;
}
