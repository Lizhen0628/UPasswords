import { execFileSync } from 'node:child_process';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const sourcePath = new URL('./UPasswords-macOS-All-UI.sketch', import.meta.url);
const outputPath = new URL('./UPasswords-macOS-All-UI-Light.sketch', import.meta.url);
const workingDirectory = await mkdtemp(join(tmpdir(), 'upasswords-light-theme-'));

// Aurora Indigo 暗色 → 浅色映射。键与 redesign-aurora.mjs 产出的暗色值一一对应。
const palette = new Map(Object.entries({
  // Canvas / window chrome（蓝调深色 → 蓝调浅色）
  '#08090e': '#e9ebf2',
  '#0a0c13': '#edf0f6',
  '#0a0c14': '#f6f7fb',
  '#0c0e15': '#f1f3f8',
  '#0d1017': '#eff1f7',
  '#0d1019': '#eceff6',
  '#0e1018': '#f2f4f9',
  '#0e111a': '#f7f8fc',
  '#10131c': '#f4f6fb',
  '#12151f': '#f6f7fc',
  '#12162a': '#eef0f8',
  '#151926': '#ffffff',
  '#161b2c': '#e9edf6',
  '#171b28': '#ffffff',
  '#181c2a': '#f0f2f8',
  '#1a1f2e': '#f7f8fb',
  '#1b2140': '#e6e9f7',
  '#20263a': '#ffffff',
  '#252c42': '#e4e8f5',
  // Borders / hairlines
  '#242b3d': '#e2e5ef',
  '#252c3e': '#e2e5ef',
  '#232a3f': '#e5e8f1',
  '#283049': '#dfe3ee',
  '#2c3450': '#d3d8e7',
  '#2f3854': '#d0d6e5',
  '#313a56': '#ccd2e2',
  '#3d4767': '#c9cfdf',
  '#4f5bd5': '#6366f1', // 选中行描边保持靛蓝
  // Text / foreground (inverted)
  '#f2f5fc': '#1a1f2e',
  '#e7ecf7': '#272d42',
  '#d6ddeb': '#3d4457',
  '#b8c2d8': '#4d5569',
  '#8f99b3': '#5b6376',
  '#7e88a3': '#6c7488',
  '#6b7590': '#8b92a5',
  '#5a6480': '#9aa2b4',
  // CTA / 开关 / 头像上的白色文字保持白色（按钮本体为靛蓝渐变，见下）
  '#ffffff': '#ffffff',
  // Accent / gradient stops / glows → 浅色主题加深一档保证对比度
  '#818cf8': '#4f46e5',
  '#8f9bf9': '#5b63e8',
  '#6366f1': '#4f46e5',
  '#8b5cf6': '#7c3aed',
  // Status
  '#34d399': '#059669',
  '#fbbf24': '#b45309',
  '#f87171': '#dc2626',
  // Label dot pastels → saturated light-theme tones
  '#7dd3fc': '#0284c7',
  '#c4b5fd': '#7c3aed',
  '#fcd34d': '#d97706',
}));

function colorHex(color) {
  const channel = value => Math.round(value * 255).toString(16).padStart(2, '0');
  return `#${channel(color.red)}${channel(color.green)}${channel(color.blue)}`.toLowerCase();
}

function mapColors(value, counts) {
  if (Array.isArray(value)) {
    for (let index = 0; index < value.length; index += 1) {
      value[index] = mapColors(value[index], counts);
    }
    return value;
  }
  if (!value || typeof value !== 'object') return value;

  if (value._class === 'color') {
    const original = colorHex(value);
    const replacement = palette.get(original);
    if (replacement) {
      const hex = replacement.slice(1);
      value.red = Number.parseInt(hex.slice(0, 2), 16) / 255;
      value.green = Number.parseInt(hex.slice(2, 4), 16) / 255;
      value.blue = Number.parseInt(hex.slice(4, 6), 16) / 255;
      counts.set(original, (counts.get(original) ?? 0) + 1);
    }
  }

  for (const [key, child] of Object.entries(value)) {
    value[key] = mapColors(child, counts);
  }
  return value;
}

try {
  execFileSync('unzip', ['-q', sourcePath.pathname, '-d', workingDirectory]);
  const documentPath = join(workingDirectory, 'document.json');
  const document = JSON.parse(await readFile(documentPath, 'utf8'));
  const pageReference = document.pages[0];
  const pagePath = join(workingDirectory, `${pageReference._ref}.json`);
  const page = JSON.parse(await readFile(pagePath, 'utf8'));
  const mappedColors = new Map();
  mapColors(page, mappedColors);

  page.name = 'macOS 浅色主题 · 全部 UI';
  for (const layer of page.layers ?? []) {
    if (layer._class !== 'group') continue;
    if (layer.name === 'UPasswords macOS 全部界面画布') {
      layer.name = 'UPasswords macOS 浅色主题画布';
      const background = layer.layers?.find(item => item._class === 'rectangle');
      if (background) background.frame.height = layer.frame.height;
    }
    for (const child of layer.layers ?? []) {
      if (child._class !== 'group' || child.name !== 'UPasswords macOS UI 全部界面') continue;
      child.name = 'UPasswords macOS 浅色主题 · 全部界面';
      const metadata = (child.layers ?? []).filter(item => item._class === 'text');
      if (metadata[0]) {
        metadata[0].name = 'UPasswords · macOS Light UI';
        metadata[0].attributedString.string = metadata[0].name;
      }
      if (metadata[1]) {
        metadata[1].name = 'v1 · light appearance · editable vector source for Sketch';
        metadata[1].attributedString.string = metadata[1].name;
      }
    }
  }

  await writeFile(pagePath, JSON.stringify(page));
  await rm(outputPath.pathname, { force: true }); // zip -r 不会剔除旧条目，先删除再打包
  execFileSync('zip', ['-q', '-r', outputPath.pathname, '.'], { cwd: workingDirectory });
  console.log(`Created ${outputPath.pathname}; remapped ${[...mappedColors.values()].reduce((sum, count) => sum + count, 0)} color values.`);
} finally {
  await rm(workingDirectory, { recursive: true, force: true });
}
