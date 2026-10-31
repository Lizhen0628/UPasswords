import { execFileSync } from 'node:child_process';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const sketchPath = new URL('./UPasswords-macOS-All-UI.sketch', import.meta.url);
const workingDirectory = await mkdtemp(join(tmpdir(), 'upasswords-sketch-layers-'));

try {
  execFileSync('unzip', ['-q', sketchPath.pathname, '-d', workingDirectory]);
  const documentPath = join(workingDirectory, 'document.json');
  const document = JSON.parse(await readFile(documentPath, 'utf8'));
  let renamedCount = 0;

  for (const pageReference of document.pages) {
    const pagePath = join(workingDirectory, `${pageReference._ref}.json`);
    const page = JSON.parse(await readFile(pagePath, 'utf8'));
    page.name = 'macOS 全部 UI';

    function renameGenericGroups(layer) {
      for (const child of layer.layers ?? []) renameGenericGroups(child);
      if (layer._class === 'group' && layer.name === 'UPasswords-macOS-all-ui') {
        layer.name = 'UPasswords macOS 全部界面画布';
      }
      if (layer._class !== 'group' || layer.name !== '编组') return;

      const labels = [];
      function collectText(node) {
        if (node._class === 'text' && node.name) labels.push(node.name);
        for (const child of node.layers ?? []) collectText(child);
      }
      for (const child of layer.layers ?? []) collectText(child);

      if (labels.includes('UPasswords · macOS UI board')) {
        layer.name = 'UPasswords macOS UI 全部界面';
        renamedCount += 1;
        return;
      }

      const sectionLabel = labels.find(label => /^(0[3-6]) · /.test(label));
      if (sectionLabel) {
        layer.name = sectionLabel.replace(/^0[3-6] · /, '');
        renamedCount += 1;
        return;
      }

      if (labels.includes('通用') && labels.includes('锁定屏幕')) {
        layer.name = '偏好设置页签导航';
        renamedCount += 1;
        return;
      }

      const meaningfulLabel = labels.find(label => {
        const trimmed = label.trim();
        return trimmed.length > 1
          && !/^(取消|关闭|完成|保存|添加|继续|返回|恢复|应用|选择|解锁|导出|导入|复制|今天|昨天|昨天)$/.test(trimmed)
          && !/^([0-9]+|[⌘⌃⌥⇧]+)$/.test(trimmed);
      });

      if (meaningfulLabel) {
        layer.name = meaningfulLabel.length > 38
          ? `${meaningfulLabel.slice(0, 35)}...`
          : meaningfulLabel;
      } else {
        layer.name = `控件组 ${layer.do_objectID.slice(0, 8)}`;
      }
      renamedCount += 1;
    }

    for (const layer of page.layers ?? []) renameGenericGroups(layer);
    await writeFile(pagePath, JSON.stringify(page));
  }

  execFileSync('zip', ['-q', '-r', sketchPath.pathname, '.'], { cwd: workingDirectory });
  console.log(`Renamed ${renamedCount} generic Sketch groups.`);
} finally {
  await rm(workingDirectory, { recursive: true, force: true });
}
