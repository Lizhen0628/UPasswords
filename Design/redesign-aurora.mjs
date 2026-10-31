// redesign-aurora.mjs — 将主源 SVG 从 Graphite Monochrome 迁移到 Aurora Indigo 设计系统。
//
// 处理顺序（均幂等，旧值不在新值集合中，可安全重复执行）：
//   1. 结构性替换：tokens 区块重写、品牌文案、渐变定义、头像/光晕/滑杆等上下文相关元素
//   2. 全局颜色重映射：纯灰石墨色 → 蓝调深色中性色 + 靛蓝强调色
//   3. 校验：报告任何未被映射的旧色值
//
// 注意：appendix（03–06 区块）由 extend-all-ui.mjs 直接生成新配色，本脚本只处理
// 9 个主窗口、defs 与 tokens。若 SVG 中仍存在旧配色 appendix，请先运行 extend-all-ui.mjs。

import { readFile, writeFile } from 'node:fs/promises';

const path = new URL('./UPasswords-macOS-all-ui.svg', import.meta.url);
let svg = await readFile(path, 'utf8');

// ---------- 全局颜色重映射表（Graphite → Aurora Indigo） ----------
const palette = new Map(Object.entries({
  // 画布 / 窗口表面（纯灰 → 蓝调深色）
  '#050505': '#08090e',
  '#08080b': '#0a0c13',
  '#0b0b0d': '#0e1018',
  '#0c0c0e': '#0d1017',
  '#0c0c12': '#0d1019',
  '#0d0d0f': '#0e111a',
  '#0e0e10': '#10131c',
  '#101012': '#12151f',
  '#121214': '#151926',
  '#131316': '#171b28',
  '#141416': '#181c2a',
  '#151517': '#1a1f2e',
  '#15151c': '#161b2c',
  '#161618': '#1a1f2e',
  '#1c1c1f': '#20263a',
  '#1f1f22': '#252c42',
  // 边框 / 分隔线
  '#222225': '#242b3d',
  '#232326': '#252c3e',
  '#232328': '#232a3f',
  '#242426': '#283049',
  '#262629': '#283049',
  '#26262a': '#283049',
  '#2a2a2d': '#2c3450',
  '#2c2c31': '#2f3854',
  '#2e2e33': '#313a56',
  '#34343a': '#4f5bd5', // 选中行描边 → 靛蓝
  '#3a3a3f': '#3d4767',
  // 文本（微蓝调）
  '#f5f5f5': '#f2f5fc',
  '#ededef': '#e7ecf7',
  '#edefef': '#e7ecf7',
  '#e4e4e7': '#d6ddeb',
  '#d4d4d8': '#b8c2d8',
  '#9c9ca1': '#8f99b3',
  '#8e8e93': '#7e88a3',
  '#7a7a80': '#6b7590',
  '#5e5e63': '#5a6480',
  // 强调 / 状态
  '#0a84ff': '#818cf8', // 链接与次级强调 → 浅靛蓝
  '#30d158': '#34d399',
  '#ffb224': '#fbbf24',
  '#ff453a': '#f87171',
  // 亮表面上的深色文字/图形（白色 CTA、开关、头像字母）→ 白色
  '#0a0a0a': '#ffffff',
}));

// ---------- 结构性替换 ----------

// 1. CTA 渐变：白渐变 → 靛蓝渐变（id 保持 whiteBtn，引用无需改动）
svg = svg.replace(
  /<linearGradient id="whiteBtn"[\s\S]*?<\/linearGradient>/,
  `<linearGradient id="whiteBtn" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#818cf8"/>
      <stop offset="1" stop-color="#6366f1"/>
    </linearGradient>
    <linearGradient id="avatarGrad" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#8f9bf9"/>
      <stop offset="1" stop-color="#6366f1"/>
    </linearGradient>`,
);

// 2. 锁屏背景渐变：更深的靛蓝夜色
svg = svg.replace(
  /<linearGradient id="lockBg"[\s\S]*?<\/linearGradient>/,
  `<linearGradient id="lockBg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#1b2140"/>
      <stop offset="0.5" stop-color="#12162a"/>
      <stop offset="1" stop-color="#0a0c14"/>
    </linearGradient>`,
);

// 3. 氛围光晕：白色微光 → 靛蓝 Aurora 光晕，并在右下补一抹紫色
svg = svg.replace(
  '<ellipse cx="900" cy="-200" rx="1400" ry="600" fill="#ffffff" opacity=".03" filter="url(#soft)"/>',
  `<ellipse cx="900" cy="-200" rx="1400" ry="600" fill="#6366f1" opacity=".10" filter="url(#soft)"/>
  <ellipse cx="3300" cy="2600" rx="1200" ry="800" fill="#8b5cf6" opacity=".05" filter="url(#soft)"/>`,
);
svg = svg.replace(
  '<circle cx="90" cy="430" r="90" fill="#f5f5f5" opacity=".05" filter="url(#soft)"/>',
  '<circle cx="90" cy="430" r="90" fill="#6366f1" opacity=".14" filter="url(#soft)"/>',
);

// 4. 头像圆形（r=9/11/17 的实心白圆）→ 靛蓝渐变
svg = svg.replace(/<circle (cx="[^"]+" cy="[^"]+" r="(?:9|11|17)") fill="#f5f5f5"\/>/g, '<circle $1 fill="url(#avatarGrad)"/>');
// 侧栏选中项圆点 → 浅靛蓝
svg = svg.replace('<circle cx="52" cy="170" r="4" fill="#f5f5f5"/>', '<circle cx="52" cy="170" r="4" fill="#818cf8"/>');

// 5. 白色实心按钮与开关（rect）→ CTA 靛蓝渐变
svg = svg.replace(/(<rect [^>]*?)fill="#f5f5f5"/g, '$1fill="url(#whiteBtn)"');

// 6. 滑杆进度 → 浅靛蓝
svg = svg.replaceAll('stroke="#f5f5f5" stroke-width="5"', 'stroke="#818cf8" stroke-width="5"');

// 7. tokens 区块重写为 Aurora Indigo 令牌展示
const tokensStart = svg.indexOf('<g id="tokens"');
if (tokensStart < 0) throw new Error('Unable to locate tokens group.');
let depth = 0;
let tokensEnd = -1;
for (const match of svg.slice(tokensStart).matchAll(/<g(?:\s|>)|<\/g>/g)) {
  depth += match[0] === '</g>' ? -1 : 1;
  if (depth === 0) {
    tokensEnd = tokensStart + match.index + match[0].length;
    break;
  }
}
if (tokensEnd < 0) throw new Error('Unable to find closing tag for tokens group.');
const swatches = [
  ['Background', '#0d1017', '#2c3450'],
  ['Surface', '#181c2a', null],
  ['Elevated', '#20263a', null],
  ['Border', '#2f3854', null],
  ['Primary', 'url(#whiteBtn)', null],
  ['Accent', '#818cf8', null],
  ['Success', '#34d399', null],
  ['Warning', '#fbbf24', null],
  ['Danger', '#f87171', null],
];
let tokens = `<g id="tokens" transform="translate(2280 2050)">
    <text x="0" y="-28" class="screen-name">Tokens · 设计语言 · Aurora Indigo</text>
    <rect width="1200" height="470" rx="14" fill="#12151f" stroke="#283049"/>
    <text x="40" y="56" class="label title">颜色</text>`;
swatches.forEach(([name, fill, stroke], i) => {
  const x = 40 + i * 116;
  tokens += `<rect x="${x}" y="82" width="104" height="54" rx="10" fill="${fill}"${stroke ? ` stroke="${stroke}"` : ''}/>`;
  tokens += `<text x="${x + 52}" y="166" class="muted" font-size="12" text-anchor="middle">${name}</text>`;
  tokens += `<text x="${x + 52}" y="186" class="subtle" font-size="11" text-anchor="middle">${fill.startsWith('#') ? fill : '#818cf8→#6366f1'}</text>`;
});
tokens += `<circle cx="46" cy="228" r="6" fill="#7dd3fc"/><circle cx="72" cy="228" r="6" fill="#c4b5fd"/><circle cx="98" cy="228" r="6" fill="#fcd34d"/>`;
tokens += `<text x="124" y="234" class="muted" font-size="13">标签点缀 · #7dd3fc / #c4b5fd / #fcd34d</text>`;
tokens += `<text x="640" y="234" class="muted" font-size="13">文本层级 · </text><text x="724" y="234" font-size="13" fill="#f2f5fc">主要 #f2f5fc</text><text x="836" y="234" font-size="13" fill="#8f99b3">次要 #8f99b3</text><text x="948" y="234" font-size="13" fill="#5a6480">弱化 #5a6480</text>`;
tokens += `<text x="40" y="292" class="label title">Typography</text>`;
tokens += `<text x="40" y="336" class="label" font-size="25" font-weight="700">Window Title · 26 / Bold</text>`;
tokens += `<text x="40" y="372" class="label body">Body text · 20 / Regular</text>`;
tokens += `<text x="540" y="336" class="muted small">Caption · 15 / Regular</text>`;
tokens += `<text x="540" y="372" class="subtle section">SECTION LABEL · 15 / SEMIBOLD</text>`;
tokens += `<rect x="900" y="300" width="240" height="52" rx="12" fill="url(#whiteBtn)"/><text x="1020" y="332" font-size="15" font-weight="600" fill="#ffffff" text-anchor="middle" font-family="-apple-system,BlinkMacSystemFont,'Helvetica Neue',Arial,sans-serif">Primary CTA</text>`;
tokens += `<text x="1020" y="382" class="subtle" font-size="11" text-anchor="middle">#818cf8 → #6366f1</text>`;
tokens += `<rect x="900" y="404" width="240" height="40" rx="20" fill="url(#avatarGrad)"/><text x="1020" y="430" font-size="14" font-weight="600" fill="#ffffff" text-anchor="middle" font-family="-apple-system,BlinkMacSystemFont,'Helvetica Neue',Arial,sans-serif">Avatar Gradient</text>`;
tokens += `
  </g>`;
svg = `${svg.slice(0, tokensStart)}${tokens}${svg.slice(tokensEnd)}`;

// 8. 品牌副标题
svg = svg.replace('v1 · graphite monochrome system', 'v1 · aurora indigo system');

// ---------- 全局颜色重映射 ----------
for (const [original, replacement] of palette) {
  svg = svg.replaceAll(original, replacement);
}

// ---------- 校验：不应残留旧石墨色 ----------
const kept = new Set(['#ff5f57', '#febc2e', '#28c840', '#7dd3fc', '#c4b5fd', '#fcd34d', '#000', '#8b5cf6']);
const leftovers = new Set();
for (const match of svg.matchAll(/#[0-9a-fA-F]{6}\b/g)) {
  const hex = match[0].toLowerCase();
  if (palette.has(hex) && !kept.has(hex)) leftovers.add(hex);
}
if (leftovers.size > 0) throw new Error(`Unmapped legacy colors remain: ${[...leftovers].join(', ')}`);

await writeFile(path, svg);
console.log(`Redesigned to Aurora Indigo: ${palette.size} colors remapped, tokens group rewritten.`);
