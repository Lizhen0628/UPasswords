import { readFile, writeFile } from 'node:fs/promises';

const path = new URL('./UPasswords-macOS-all-ui.svg', import.meta.url);
let svg = await readFile(path, 'utf8');
svg = svg.replace(/height="2460" viewBox="0 0 3600 2460"/, 'height="10300" viewBox="0 0 3600 10300"');
// 幂等剥离：新格式用 START/END 标记包裹；兼容旧版「正文在前、标记在尾」的布局
svg = svg.replace(/\n?<!-- COMPLETE-UI-APPENDIX-START -->[\s\S]*?<!-- COMPLETE-UI-APPENDIX-END -->\n?/, '\n');
svg = svg.replace(/\n<g><text x="120" y="2520"[\s\S]*?(?=<\/svg>)/, '\n');
svg = svg.replace(/\n?\s*<!-- COMPLETE-UI-APPENDIX -->\n?/, '\n');

const setup = [
  ['账号注册 / Sign In', '欢迎使用 UPasswords', '创建账号，启用安全同步', ['邮箱地址|输入邮箱地址', '验证码|发送验证码', '密码|至少 12 个字符', '确认密码|再次输入密码', '勾选|我已阅读服务条款'], '继续|已有账号？登录'],
  ['个人资料 / Personal Info', '保存个人资料', '用于自动填充，可稍后补充', ['名|Alex', '姓|Morgan', '邮箱|alex@example.com', '电话|+1 555 0100', '地址|街道地址 / 城市 / 地区 / 邮编 / 国家'], '跳过|继续'],
  ['创建密码库 / Create Vault', '创建本地密码库', '主密码只保存在本机', ['名称|Personal Vault', '主密码|输入强主密码', '确认密码|再次输入', 'Touch ID|启用快速解锁', '安全提示|主密码无法找回'], '从云端恢复|从本地恢复|创建'],
  ['云端恢复 / Restore Cloud', '恢复云端密码库', '选择账户中的一个备份', ['账户|alex@example.com', '密码库|Personal Vault', '备份时间|今天 14:20', '主密码|输入备份密码'], '返回|检查备份|恢复'],
  ['本地恢复 / Restore Local', '从备份恢复', '选择 UPasswords 备份文件', ['备份文件|选择 .upbackup 文件', '密码库名称|Personal Vault', '原主密码|验证备份', '状态|等待选择文件'], '返回|选择文件|恢复'],
];

const preferences = [
  ['通用 / Appearance', '外观与列表行为', ['语言|跟随系统', '排序|标题 A-Z', '收藏置顶|开', '显示项目数量|开', '隐藏密码|关', '网站图标|开', '按标签搜索|开', '搜索密码|关']],
  ['安全 / Security', '锁定与安全检查', ['重新验证|每 8 小时', '剪贴板清除|30 秒', '失败次数限制|不限', '空闲自动锁定|5 分钟', 'Touch ID|开启', '泄露检查|每 7 天', '检查结果|上次检查：昨天', '操作|立即检查 / 修改主密码']],
  ['自动备份 / Auto Backup', '备份与恢复', ['自动备份|开', '备份频率|每天', '保留数量|10 份', '保存位置|选择文件夹', '最近备份|今天 09:00', '备份列表|日期 / 大小 / 还原 / 删除', '操作|立即备份 / 从备份恢复']],
  ['自动填充 / Autofill', '浏览器与个人资料', ['浏览器扩展|Safari 已连接', 'Safari|打开扩展设置', '自动填充|启用', '默认资料|个人信息', '个人资料|管理个人信息', '表单行为|提交前确认', '状态|最后连接：今天']],
  ['锁定屏幕 / Lock Screen', '锁定窗口外观', ['背景|系统壁纸模糊', '纹理|预览缩略图网格', '图片|选择图片', '文字颜色|白色 / 黑色', '快速解锁|Touch ID', '预览|实时锁屏预览']],
  ['云同步 / Cloud Sync', '账户与同步状态', ['服务|UPasswords Relay', '账户|alex@example.com', '同步状态|已同步', '设备|此 Mac / iPhone', '冲突|查看待复核项目', '账户操作|换绑邮箱 / 退出登录', '同步操作|立即同步 / 配置']],
  ['快捷键 / Shortcuts', '键盘快捷键', ['显示主窗口|⌃⌥P', '快速搜索|⌘⇧F', '新建项目|⌘N', '锁定数据库|⌘L', '复制用户名|⌘⇧U', '复制密码|⌘⇧P', '录制器|点击快捷键重新录制']],
];

const sheets = [
  ['新增项目 / Add Card', '创建密码条目', ['模板|登录', '标题|项目名称', '用户名|name@example.com', '密码|生成强密码'], '取消|添加'],
  ['新增笔记 / Add Note', '创建安全笔记', ['标题|笔记标题', '内容|仅加密保存在数据库', '标签|选择标签'], '取消|添加'],
  ['新增标签 / Add Label', '创建标签', ['名称|标签名称', '颜色|色板选择'], '取消|添加'],
  ['编辑标签 / Edit Label', '编辑标签', ['名称|工作', '颜色|色板选择', '置顶|切换'], '取消|保存'],
  ['标签颜色 / Label Color', '选择标签颜色', ['选中色|蓝色', '色板|12 个颜色圆点'], '取消|选择'],
  ['排序 / Sorting', '列表排序', ['标题升序|单选', '最近修改|单选', '创建时间|单选', '收藏置顶|开关'], '取消|应用'],
  ['密码生成器 / Generator', '生成安全密码', ['生成结果|••••••••••••••••', '长度|18', '大写|开', '数字|开', '符号|开', '历史|最近生成'], '重新生成|复制'],
  ['设置标签 / Set Labels', '为项目分配标签', ['搜索|查找标签', '工作|复选', '个人|复选', '财务|复选', '新增|创建标签'], '取消|完成'],
  ['选择图标 / Symbol Picker', '选择项目图标', ['搜索|图标名称', '分类|常用 / 网站 / 金融 / 旅行', '图标网格|可选图标', '当前|GitHub'], '取消|选择'],
  ['选择颜色 / Color Picker', '选择项目颜色', ['色板|可选颜色', '当前颜色|蓝色', '图标预览|实时更新'], '取消|选择'],
  ['选择纹理 / Texture Picker', '选择锁屏纹理', ['预览网格|渐变与纹理', '文字颜色|白色 / 黑色', '当前选择|纹理 03'], '取消|应用'],
  ['选择模板 / Template Picker', '选择项目模板', ['搜索|模板名称', '登录|用户名 / 密码 / 网站', '银行卡|持卡人 / 卡号 / 有效期', '安全笔记|标题 / 内容'], '取消|选择'],
  ['导出数据 / Export', '导出密码库', ['格式|加密备份 / CSV / JSON / PDF', '范围|全部 / 当前筛选', '附件|包含附件', '加密|设置导出密码'], '取消|导出'],
  ['导入数据 / Import', '导入密码', ['来源|1Password / Bitwarden / CSV', '文件|选择导出文件', '预览|条目数量', '冲突|跳过 / 替换'], '取消|预览导入'],
  ['数据库信息 / Vault Info', '数据库信息', ['名称|Personal Vault', '项目|24', '归档|2', '回收站|1', '标签|5', '加密|AES-256-GCM', '文件大小|2.4 MB'], '关闭'],
  ['个人信息 / Personal Info', '管理自动填充资料', ['姓名|Alex Morgan', '邮箱|alex@example.com', '电话|+1 555 0100', '地址|街道 / 城市 / 地区 / 邮编 / 国家'], '取消|保存'],
  ['泄露检查 / Compromised', '安全检查结果', ['风险摘要|发现 2 个风险项目', '重复密码|1 个项目', '已泄露密码|1 个项目', '项目列表|名称 / 风险 / 立即修改'], '关闭|查看项目'],
  ['修改主密码 / Change Password', '更改主密码', ['当前密码|••••••••', '新密码|••••••••', '确认密码|••••••••', '强度|很强', '提示|其他设备需要重新验证'], '取消|更改密码'],
  ['配置云同步 / Configure Cloud', '连接云同步', ['服务地址|默认 / 自定义', '账户邮箱|alex@example.com', '验证码|输入验证码', '同步选项|同步附件 / 自动同步'], '取消|连接'],
  ['抹除数据 / Erase Data', '永久删除本地数据？', ['警告|密码库与本机备份将被删除', '云端|不影响其他设备', '确认|输入 ERASE 确认'], '取消|删除数据'],
  ['管理数据库 / Manage Databases', '本地数据库', ['Personal Vault|主数据库 / 当前', 'Travel Vault|最近修改：昨天', '操作菜单|设为主库 / 重命名 / 删除', '新建|创建数据库'], '关闭'],
  ['跨库导入 / Import Cards', '从另一个数据库导入', ['源数据库|Travel Vault', '目标数据库|Personal Vault', '密码|验证源数据库', '条目清单|选择可导入项目', '冲突|逐项处理'], '取消|检查|导入所选'],
  ['选择数据库 / Select Database', '打开数据库', ['Personal Vault|最近打开', 'Travel Vault|本地数据库', '锁定状态|需要主密码', '新建|创建数据库'], '取消|打开'],
  ['关于 / About', 'UPasswords', ['版本|v1.0', '说明|本地优先密码管理器', '支持|联系支持', '许可|许可证信息'], '关闭'],
  ['新版本说明 / What’s New', '本次更新', ['加密|安全加密数据库', '验证码|内置 TOTP', '同步|跨设备同步', '导入|迁移密码数据', '启动时显示|开关'], '完成'],
  ['许可证 / Premium', '许可证状态', ['状态|许可证有效', '邮箱|输入购买邮箱', '激活|输入许可证', '恢复购买|操作入口'], '关闭|激活'],
  ['设置计划 / Setup Plan', '完成安全设置', ['步骤|主密码已设置', '自动填充|启用 Safari 扩展', '恢复方式|创建安全备份', '安全检查|检查密码健康度'], '稍后|继续设置'],
  ['即将到期 / Expired Cards', '即将到期的项目', ['卡片|银行卡 · 12/26', '卡片|旅行卡 · 01/27', '状态|按到期时间排序'], '关闭|查看项目'],
  ['恢复模板 / Restore Templates', '恢复内置模板？', ['说明|恢复缺少的默认模板', '不会覆盖|已有的自定义模板', '模板|登录 / 银行卡 / 身份证'], '取消|恢复'],
  ['密码历史 / Password History', '字段修改历史', ['条目|示例站点 · 密码', '历史值|••••••••••', '时间|今天 14:20', '操作|复制历史值'], '关闭'],
  ['字段编辑 / Field Editor', '编辑自定义字段', ['字段名称|恢复代码', '字段类型|文本 / 密码 / 隐藏', '字段值|输入内容', '自动填充|启用'], '取消|保存'],
  ['选择数据库密码 / Enter Password', '解锁数据库', ['数据库|Personal Vault', '主密码|••••••••', 'Touch ID|使用 Touch ID', '错误状态|密码不正确'], '取消|解锁'],
  ['邮件换绑 / Relay Transfer', '换绑账户邮箱', ['主密码|本机验证', '当前邮箱验证码|发送验证码', '新邮箱|new@example.com', '新邮箱验证码|发送验证码'], '取消|换绑邮箱'],
  ['偏好设置弹层 / Preferences Sheet', '偏好设置', ['页签|通用 / 安全 / 备份 / 自动填充', '当前页|通用设置', '设置|语言 / 排序 / 显示选项'], '关闭'],
];

const states = [
  ['空密码库 / Empty Vault', '还没有密码项目', ['空状态图标|保险箱', '说明|添加第一个项目开始使用', '主操作|新增项目', '次操作|导入数据']],
  ['无搜索结果 / No Results', '没有找到匹配项目', ['搜索条件|github', '说明|试试其他关键词', '清除|清除搜索']],
  ['回收站 / Trash', '已删除项目', ['项目行|标题 / 删除日期', '恢复|还原到密码库', '清空|永久清空回收站']],
  ['同步进行中 / Syncing', '正在同步', ['状态|上传加密数据', '进度|进度条', '设备|此 Mac', '取消|停止同步']],
  ['同步失败 / Sync Error', '同步未完成', ['状态|网络连接失败', '说明|本地数据安全保存', '操作|重试 / 查看日志']],
  ['复制提示 / Clipboard Toast', '已复制到剪贴板', ['提示|密码已复制', '清除倒计时|30 秒后自动清除', '状态|轻量浮层']],
  ['菜单栏 / Menu Bar', '快速访问', ['搜索|搜索密码', '最近项目|GitHub / Apple ID', '操作|锁定 / 打开主窗口 / 设置']],
  ['右键菜单 / Context Menus', '项目快捷操作', ['复制用户名|⌘⇧U', '复制密码|⌘⇧P', '编辑|打开编辑器', '标签|管理标签', '删除|移至回收站']],
];

const esc = value => value.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');
const text = (x, y, value, size = 18, color = '#f2f5fc', weight = 400) =>
  `<text x="${x}" y="${y}" font-family="-apple-system,BlinkMacSystemFont,Arial,sans-serif" font-size="${size}px" font-weight="${weight}" fill="${color}">${esc(value)}</text>`;

function tile(x, y, title, subtitle, rows, footer = '') {
  let out = `<g transform="translate(${x} ${y})"><rect width="720" height="414" rx="14" fill="#12151f" stroke="#283049"/>`;
  out += `<rect width="720" height="42" rx="14" fill="#1a1f2e"/><rect x="0" y="28" width="720" height="14" fill="#1a1f2e"/><line x1="0" y1="42" x2="720" y2="42" stroke="#242b3d"/>`;
  out += `<circle cx="19" cy="21" r="5" fill="#ff5f57"/><circle cx="37" cy="21" r="5" fill="#febc2e"/><circle cx="55" cy="21" r="5" fill="#28c840"/>`;
  out += text(78, 27, title, 16, '#e7ecf7', 700);
  out += text(34, 83, subtitle, 21, '#f2f5fc', 700);
  const visible = rows.slice(0, 6);
  visible.forEach((row, i) => {
    const [label, value] = row.split('|');
    const yy = 111 + i * 39;
    out += `<rect x="32" y="${yy}" width="656" height="32" rx="8" fill="${i % 2 ? '#1a1f2e' : '#181c2a'}"/>`;
    out += text(45, yy + 21, label, 13, '#7e88a3', 500);
    const color = /开|启用|已同步|有效|很强/.test(value) ? '#34d399' : '#d6ddeb';
    out += text(210, yy + 21, value.length > 54 ? `${value.slice(0, 52)}…` : value, 14, color, 400);
  });
  if (footer) {
    out += `<line x1="32" y1="365" x2="688" y2="365" stroke="#242b3d"/>`;
    const buttons = footer.split('|');
    let bx = 688;
    for (let i = buttons.length - 1; i >= 0; i--) {
      const label = buttons[i];
      const width = Math.max(74, Math.min(148, label.length * 14 + 30));
      bx -= width;
      const primary = i === buttons.length - 1;
      out += `<rect x="${bx}" y="378" width="${width}" height="27" rx="8" fill="${primary ? 'url(#whiteBtn)' : '#20263a'}"${primary ? '' : ' stroke="#2f3854"'}/>`;
      out += text(bx + width / 2, 396, label, 12, primary ? '#ffffff' : '#e7ecf7', 600).replace('<text ', '<text text-anchor="middle" ');
      bx -= 9;
    }
  }
  return out + '</g>';
}

function section(title, subtitle, items, startY, columns = 4, rowsOnly = false) {
  let out = `<g><text x="120" y="${startY}" font-family="-apple-system,BlinkMacSystemFont,Arial,sans-serif" font-size="30px" font-weight="700" fill="#f2f5fc">${esc(title)}</text>`;
  out += `<text x="120" y="${startY + 28}" font-family="-apple-system,BlinkMacSystemFont,Arial,sans-serif" font-size="15px" fill="#7e88a3">${esc(subtitle)}</text>`;
  const top = startY + 54;
  const gapX = 36;
  const gapY = 28;
  items.forEach((item, index) => {
    const x = 120 + (index % columns) * (720 + gapX);
    const y = top + Math.floor(index / columns) * (414 + gapY);
    out += tile(x, y, ...item);
  });
  const height = Math.ceil(items.length / columns) * (414 + gapY);
  return { out: out + '</g>', nextY: top + height + 90 };
}

let y = 2520;
let appendix = '';
for (const [title, subtitle, data] of [
  ['03 · 首次启动流程 / First Run', '每个 SetupMode 分支独立绘制；注册、个人资料、创建新库、云端恢复与本地恢复。', setup.map(([title, subtitle, description, rows, footer]) => [title, `${subtitle} · ${description}`, rows, footer])],
  ['04 · 偏好设置全部页签 / All Preferences', '七个实际页签：通用、安全、自动备份、自动填充、锁定屏幕、云同步、快捷键。', preferences.map(([title, subtitle, rows]) => [title, subtitle, rows, '取消|保存'])],
  ['05 · 全部弹窗与工作流 / All Sheets', '覆盖 SheetFactory 路由与编辑器本地弹层；字段、模板、符号、颜色、导入导出、账户和安全流程。', sheets],
  ['06 · 系统状态与菜单 / States & Menus', '空状态、搜索、回收站、同步反馈、剪贴板提示、菜单栏与右键菜单。', states.map(([title, subtitle, rows]) => [title, subtitle, rows, '关闭|操作'])],
]) {
  const result = section(title, subtitle, data, y);
  appendix += `${result.out}\n`;
  y = result.nextY;
}

const finalHeight = Math.max(10300, y);
svg = svg.replace(/height="10300" viewBox="0 0 3600 10300"/, `height="${finalHeight}" viewBox="0 0 3600 ${finalHeight}"`);
svg = svg.replace(/<rect width="3600" height="\d+" fill="url\(#canvas\)"\/>/, `<rect width="3600" height="${finalHeight}" fill="url(#canvas)"/>`);
svg = svg.replace('</svg>', `<!-- COMPLETE-UI-APPENDIX-START -->\n${appendix}<!-- COMPLETE-UI-APPENDIX-END -->\n</svg>`);
await writeFile(path, svg);
console.log(`Wrote complete UI board: ${Math.max(10300, y)}px tall, ${setup.length} setup paths, ${preferences.length} preferences panes, ${sheets.length} sheets, ${states.length} UI states.`);
