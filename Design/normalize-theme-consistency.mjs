// ⚠️ DEPRECATED — 本脚本内置的是旧版蓝灰配色的映射表。
// 当前设计稿已迁移到 Graphite Monochrome 设计系统（见 README.md），
// 运行本脚本会把旧颜色写回新稿，破坏设计。请勿执行；保留仅供参考。
throw new Error('normalize-theme-consistency.mjs is deprecated; see README.md');

import { execFileSync } from 'node:child_process';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const svgPath = new URL('./UPasswords-macOS-all-ui.svg', import.meta.url);
const sketchPath = new URL('./UPasswords-macOS-All-UI.sketch', import.meta.url);
const workingDirectory = await mkdtemp(join(tmpdir(), 'upasswords-theme-normalize-'));

const setupColors = new Map(Object.entries({
  '#f3f5f7': '#24292e',
  '#c4cbd0': '#515b64',
  '#e7ebee': '#30363c',
  '#25303a': '#eef2f5',
  '#2e73b6': '#438bd0',
  '#1f2a33': '#f3f5f7',
  '#66727d': '#aeb8c0',
  '#6c7882': '#9ca5ae',
  '#d4dbe0': '#414a52',
  '#3e8fd4': '#438bd0',
  '#89949d': '#9ca5ae',
  '#26333d': '#f3f5f7',
  '#6b7680': '#aeb8c0',
  '#58646e': '#aeb8c0',
  '#ffffff': '#2d343a',
  '#b8c2ca': '#515b64',
  '#303b44': '#e3e8ec',
  '#9ba5ac': '#9ca5ae',
  '#65717b': '#aeb8c0',
  '#d9e0e5': '#414a52',
  '#59bd8f': '#66d39a',
  '#4fa47e': '#66d39a',
  '#d8dee2': '#414a52',
  '#bcc6ce': '#515b64',
  '#4a5660': '#aeb8c0',
}));
const sharedSurfaceColors = new Map(Object.entries({
  '#30353a': '#30363c',
  '#25292d': '#292f34',
  '#4e5962': '#515b64',
  '#343d45': '#30363c',
  '#4c5965': '#394149',
  '#22272c': '#24292e',
}));
const namedLayerColors = new Map(Object.entries({
  'edit-card-window': new Map(Object.entries({
    '#30373d': '#2d343a',
    '#353e46': '#30363c',
    '#2d363d': '#30363c',
    '#58636c': '#515b64',
    '#596671': '#515b64',
    '#475057': '#414a52',
    '#46515a': '#414a52',
    '#3c78ad': '#438bd0',
    '#4c95dd': '#438bd0',
  })),
  'generator-window': new Map(Object.entries({
    '#1a2025': '#2d343a',
    '#53606b': '#515b64',
    '#56616a': '#515b64',
    '#62a8e9': '#5aa8ff',
    '#3e8fd4': '#438bd0',
    '#4c95dd': '#438bd0',
  })),
  'lock-window': new Map(Object.entries({
    '#111820': '#2d343a',
    '#4e5962': '#515b64',
  })),
  'add-card-window': new Map(Object.entries({
    '#f2f4f6': '#24292e',
    '#c4cbd0': '#515b64',
    '#27333c': '#eef2f5',
    '#596671': '#aeb8c0',
    '#ffffff': '#2d343a',
    '#bac5cd': '#515b64',
    '#74808a': '#9ca5ae',
    '#a0a9b0': '#9ca5ae',
    '#3e8fd4': '#438bd0',
    '#bcc6ce': '#515b64',
    '#4f5c66': '#e3e8ec',
  })),
  'sync-window': new Map(Object.entries({
    '#f2f4f6': '#24292e',
    '#c4cbd0': '#515b64',
    '#27333c': '#eef2f5',
    '#f1bd61': '#f0b35a',
    '#4c3920': '#24292e',
    '#25303a': '#f3f5f7',
    '#6a7780': '#aeb8c0',
    '#ffffff': '#2d343a',
    '#c7d0d6': '#515b64',
    '#e6eef7': '#30363c',
    '#2e73b6': '#5aa8ff',
    '#3e8fd4': '#438bd0',
    '#72808a': '#9ca5ae',
    '#6b7781': '#aeb8c0',
  })),
  tokens: new Map(Object.entries({
    '#1b1f23': '#24292e',
    '#30373d': '#30363c',
    '#4c95dd': '#438bd0',
  })),
}));

function replaceSvgLayer(svg, layerID, replacements, nextMarker) {
  const start = svg.indexOf(`<g id="${layerID}"`);
  if (start < 0) throw new Error(`Unable to locate ${layerID} in SVG.`);
  let depth = 0;
  let end = -1;
  const tags = /<g(?:\s|>)|<\/g>/g;
  tags.lastIndex = start;
  for (const match of svg.slice(start).matchAll(tags)) {
    if (match[0] === '</g>') depth -= 1;
    else depth += 1;
    if (depth === 0) {
      end = start + match.index + match[0].length;
      break;
    }
  }
  if (end < 0) throw new Error(`Unable to find closing group for ${layerID}.`);
  let group = svg.slice(start, end);
  for (const [original, replacement] of replacements) group = group.replaceAll(original, replacement);
  return `${svg.slice(0, start)}${group}${svg.slice(end)}`;
}

function normalizeSketchColors(value) {
  if (Array.isArray(value)) {
    for (let index = 0; index < value.length; index += 1) {
      normalizeSketchColors(value[index]);
    }
    return;
  }
  if (!value || typeof value !== 'object') return;

  if (value._class === 'color') {
    const toByte = channel => Math.round(channel * 255).toString(16).padStart(2, '0');
    const original = `#${toByte(value.red)}${toByte(value.green)}${toByte(value.blue)}`;
    const replacement = setupColors.get(original);
    if (replacement) {
      value.red = Number.parseInt(replacement.slice(1, 3), 16) / 255;
      value.green = Number.parseInt(replacement.slice(3, 5), 16) / 255;
      value.blue = Number.parseInt(replacement.slice(5, 7), 16) / 255;
    }
  }
  for (const child of Object.values(value)) normalizeSketchColors(child);
}

try {
  let svg = await readFile(svgPath, 'utf8');
  for (const [original, replacement] of sharedSurfaceColors) {
    svg = svg.replaceAll(original, replacement);
  }
  for (const [layerID, replacements] of namedLayerColors) {
    svg = replaceSvgLayer(svg, layerID, replacements);
  }
  const setupStart = svg.indexOf('<g id="setup-window"');
  const setupEnd = svg.indexOf('<!-- PREFERENCES -->', setupStart);
  if (setupStart < 0 || setupEnd < 0) throw new Error('Unable to locate setup window section in SVG.');

  let setup = svg.slice(setupStart, setupEnd);
  for (const [original, replacement] of setupColors) {
    setup = setup.replaceAll(original, replacement);
  }
  svg = `${svg.slice(0, setupStart)}${setup}${svg.slice(setupEnd)}`;
  await writeFile(svgPath, svg);

  execFileSync('unzip', ['-q', sketchPath.pathname, '-d', workingDirectory]);
  const document = JSON.parse(await readFile(join(workingDirectory, 'document.json'), 'utf8'));
  const pageReference = document.pages[0];
  const pagePath = join(workingDirectory, `${pageReference._ref}.json`);
  const page = JSON.parse(await readFile(pagePath, 'utf8'));
  for (const layer of page.layers ?? []) normalizeSharedSurfaceColors(layer);
  for (const [layerID, replacements] of namedLayerColors) {
    const target = findLayer(page, layerID);
    if (!target) throw new Error(`Unable to locate ${layerID} in Sketch document.`);
    normalizeLayerColors(target, replacements);
  }
  let setupGroup;

  function findSetup(layer) {
    if (layer.name === 'setup-window') setupGroup = layer;
    for (const child of layer.layers ?? []) findSetup(child);
  }
  findSetup(page);
  if (!setupGroup) throw new Error('Unable to locate setup-window group in Sketch document.');
  normalizeSketchColors(setupGroup);
  await writeFile(pagePath, JSON.stringify(page));
  execFileSync('zip', ['-q', '-r', sketchPath.pathname, '.'], { cwd: workingDirectory });
  console.log('Normalized setup-window to the shared dark theme palette.');
} finally {
  await rm(workingDirectory, { recursive: true, force: true });
}

function normalizeSharedSurfaceColors(value) {
  if (Array.isArray(value)) {
    for (const item of value) normalizeSharedSurfaceColors(item);
    return;
  }
  if (!value || typeof value !== 'object') return;
  if (value._class === 'color') {
    const channel = item => Math.round(item * 255).toString(16).padStart(2, '0');
    const original = `#${channel(value.red)}${channel(value.green)}${channel(value.blue)}`;
    const replacement = sharedSurfaceColors.get(original);
    if (replacement) {
      value.red = Number.parseInt(replacement.slice(1, 3), 16) / 255;
      value.green = Number.parseInt(replacement.slice(3, 5), 16) / 255;
      value.blue = Number.parseInt(replacement.slice(5, 7), 16) / 255;
    }
  }
  for (const child of Object.values(value)) normalizeSharedSurfaceColors(child);
}

function findLayer(layer, name) {
  if (layer.name === name) return layer;
  for (const child of layer.layers ?? []) {
    const found = findLayer(child, name);
    if (found) return found;
  }
  return undefined;
}

function normalizeLayerColors(value, replacements) {
  if (Array.isArray(value)) {
    for (const item of value) normalizeLayerColors(item, replacements);
    return;
  }
  if (!value || typeof value !== 'object') return;
  if (value._class === 'color') {
    const toByte = channel => Math.round(channel * 255).toString(16).padStart(2, '0');
    const original = `#${toByte(value.red)}${toByte(value.green)}${toByte(value.blue)}`;
    const replacement = replacements.get(original);
    if (replacement) {
      value.red = Number.parseInt(replacement.slice(1, 3), 16) / 255;
      value.green = Number.parseInt(replacement.slice(3, 5), 16) / 255;
      value.blue = Number.parseInt(replacement.slice(5, 7), 16) / 255;
    }
  }
  for (const child of Object.values(value)) normalizeLayerColors(child, replacements);
}
