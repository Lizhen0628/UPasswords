# UPasswords 云同步设计（API 协调 + 网盘载文件）

状态：**v5 · P0 服务端已实施并上线（2026-10-09，端到端验证通过）** · 2026-10-09
v5 变更：信封上 API 定稿（方案一）；新增 §3.4 离线与降级矩阵、§3.5 拖库防御
（APP_KEK 应用层加密：信封与邮箱加密存储、键控哈希查询）。
v4 变更（响应 Apple 合规调整）：**服务端不存储密码库文件**（回到网盘做文件载体）；
API 服务器只做协调层（账户/信封/哈希注册表/版本元数据/统计）；管理后台降为只读统计；
新增回收站 365 天清除与 `.upw.old` 备份规则；取消 R2/快照/存储配额。

已定决策汇总（2026-10-09）：

1. 登录 = 邮箱验证码（注册即首次登录，无账户密码），TOTP 后期可选；
2. 开放注册；用户状态：**注销 / 普通 / 订阅 / 永久**；
3. **密码库文件（`.upw` 本体）只存用户自己的网盘**（iCloud/WebDAV），API 服务器零库文件；
4. 服务端记录 `[邮箱+vault_id+vault_name]` 的：密码版本元数据 +（方案一）信封 +
   网盘文件哈希注册表（sha256）；
5. 解锁时优先查服务端密码版本：落后则提示"vault 密码已被修改，请用新密码解锁"；
   离线时用本地信封验证（现状既有能力）；
6. 同步短路：本地明文 XML 哈希 == 服务端注册哈希 → 本轮完全不碰网盘；
7. 合并冲突：条目级 mtime 决胜（现为毫秒精度，系统维护不可手改）+ 墓碑抑制复活；
8. 回收站两段式：入回收站可见 → 删除后**隐藏态**（前端不可感知）→ 365 天后
   **内容硬清除**（长期保留 id+删除时间极小标记，防长期离线设备复活已删项）；
9. `.upw.old` 双重作用：上代备份 + **上传失败恢复点**（即时回滚/下轮恢复/
   云端恢复兜底；`.upw` 缺失时跳过改名直接上传）；
10. 管理后台**只读统计**（按状态分组的用户计数等），无任何管理操作；
11. 旧 api.upasswords.com 信封中继删除；WebDAV/iCloud 回到设置 UI（文件通道）。

---

## 1. 目标与架构

**目标**：API 服务器解决云盘的"弱一致与状态不可见"（账户、改密传播、变更短路、
版本可见性），网盘只做它擅长的文件存储；服务端对库内容零知识；符合平台合规
（服务器不存密码库文件）。

```
macOS / iOS App
  ├── API（api.upasswords.com，Worker + D1，HSTS）
  │     账户（邮箱码登录/会话）、vault 注册表（版本元数据/哈希/信封）、统计
  └── 网盘（iCloud Drive / WebDAV，用户自有存储）
        vault_name.upw（本体）/ vault_name.upw.old（上代备份）/ vault_name.upwkey（信封副本）
```

**与 v3 的差异**：取消 R2 与快照（服务器不再存文件）、取消存储配额；
网盘重新成为必需配置项（回到设置 UI）；
CloudDriver（WebDAV/iCloud）继续承担文件读写，API 客户端承担协调。

---

## 2. 账户与用户状态

### 2.1 用户旅程（两层凭证分离）

| 层 | 凭证 | 出现时机 |
|---|---|---|
| 账户层（授权） | 邮箱 + 验证码 | 登录新设备、敏感操作（注销/解绑库）；验证通过自动注册并签发 90 天会话 |
| 库层（解密） | (邮箱 + vault_id) 定位库 + 该库 vault 密码 | 每次解锁；每库独立密码独立解锁 |

```
新设备:  装App → 本地使用无需账户；启用云同步 → 邮箱+验证码登录（首次自动注册）
   ├─ 新用户: 库列表为空 → 创建库(命名+设vault密码) → 本地生成VEK
   │          → 信封传API、本体传网盘
   └─ 老用户: 选库 → 输该库vault密码 → API取信封解VEK → 网盘拉本体 → 解锁
日常:    解锁只输vault密码(本地信封验证+在线版本检查)；验证码不再出现
```


- 注册/登录：邮箱验证码（6 位、TTL 10 分钟、**单活跃码**、≤5 次尝试、
  重发冷却 60s、每邮箱 10 封/h、每 IP 20 次/h；响应恒定防枚举）；
- 会话令牌：32B 随机，D1 只存 SHA-256，90 天滑动，逐设备可撤销；
- 用户状态：`normal（普通）| subscription（订阅）| permanent（永久）`，
  外加 `deregistered（注销）`；注销 = 用户发起（需新鲜敏感验证码）→
  `deregistered`：**立即吊销全部会话并清空敏感列**（email_enc / envelope_enc 等），
  仅保留状态行供统计，30 天后全量物理清除；网盘文件不动；
- 敏感操作（注销账户、解绑 vault 注册）需当次新鲜验证码；
- TOTP 后期可选。

### 2.2 多账户与云端隔离（多邮箱 / 共用网盘 / iCloud）

一个用户可有多个邮箱账户，隔离分三层互不串扰：

| 层 | 隔离方式 |
|---|---|
| API 账户层 | 邮箱=账户：vault 注册表、信封、会话全部按 user_id 隔离，跨账户不可见 |
| 网盘文件层 | 网盘通道跟随**设备/配置**而非邮箱：多账户共用同一网盘时，默认按账户子目录 `UPasswords/<邮箱前缀哈希>/` 隔离（同邮箱多设备哈希确定、路径一致；跨邮箱同名库不冲突）；WebDAV 可按账户配不同服务器/路径 |
| 本地存储层 | 每个云端库对应一个本地库；本地按账户分组 `Databases/<账户前缀>/<库名>.upw`，跨账户同名库不冲突；库切换器按账户分组显示 |

- 同一设备可同时登录多个账户：每账户一个会话令牌（Keychain 按账户隔离），
  每个本地库记住所属账户与 vault_id，同步时使用对应账户会话；
- iCloud 特别说明：iCloud Drive 跟随**设备 Apple ID** 而非邮箱——同一 Apple ID 的
  设备自动看到相同账户子目录；**跨不同 Apple ID 的设备各自 iCloud Drive 独立**，
  这类组合应选 WebDAV 作通道；
- 边界：一个库只归属一个账户；换绑邮箱/库跨账户转移暂不支持
  （需要时在新账户下重新登记：注册表换归属，网盘文件不动，本地照常解锁）。

---

## 3. vault 密码（主密码）变更传播

### 3.1 原理（复用 v2 双密钥架构，无新增密码存储）

- 主密码 → 信封（`.upwkey`，PBKDF2×600k 包裹库密钥 VEK）→ VEK 加密本体；
- **本地"维护的密码记录" = 本地信封**：解开信封即验证密码，离线天然可用（现状）；
- 服务端只存**版本元数据**：`password_version`（单调）+ `password_changed_at`。
  不存任何密码衍生物，不存验证子——服务器被拖库也无法用于爆破主密码。

### 3.2 解锁流程

```
在线：GET /v1/vaults/{id} 注册表
   ├─ password_version == 本地已知 → 正常输密码解锁（本地信封验证）
   └─ password_version > 本地 → 提示"vault 密码已在其他设备修改，请使用新密码"
        → 用户输新密码 + 取服务端最新信封（方案一）→ 重裹本地/采纳 → 解锁
离线：直接本地信封验证（现状能力，无网络依赖）
```

实现约束：客户端持久化各库**已见 password_version** 作比对基准；任何在线读注册表时，
服务端信封 changedAt 比本地新则顺手持久化到本地 `.upwkey`（**信封先行**）——设备
上线过一次后即可离线用新密码解锁。残余死区仅为"改密后从未上过线的设备"
（只记得新密码则需等网络），属方案一固有合理约束。

### 3.3 已定：方案一（信封上 API）+ 应用层加密加固

- 服务端存信封（~100B 密文）：改密秒级强一致传播，对端立刻可用新密码解锁；
- 信封经 **APP_KEK 应用层加密**后入库（见 3.5）：拖库 alone 拿不到可爆破物；
- **不存任何密码验证子**：版本元数据已覆盖其全部用途，验证子纯增爆破风险；
- 网盘上仍保留信封副本（`.upwkey`，随本体上传），API 持久版本为权威；
- 改密时信封 PUT 失败则排队自动重试直到成功（changedAt 幂等，可安全重试）；
- 时钟偏斜防御：信封 changedAt 偏离服务器时间超过 ±5 分钟时，服务端钳制为
  接收时间——防坏钟设备的 changedAt 永胜。

### 3.4 离线与降级矩阵

核心事实：**改密不换 VEK**（只换信封）→ 离线设备用旧密码也能解锁同一份最新数据。

| 场景 | 行为 |
|---|---|
| 离线解锁 | 本地信封验证照常；即使密码已被他机修改，本机旧密码仍可解锁（VEK 相同）；联网后版本检查提示改密、拉新信封重裹 |
| 离线保存/同步 | 本地保存照常（local-first 现状）；同步挂起联网补 |
| 离线改密 | 允许：本地重裹（同一 VEK）→ 联网上传信封；双端离线各改 → 服务器 changedAt 决胜，败方提示后输胜方密码，数据零风险 |
| API 不可达、网盘可达 | 同步回退现有"网盘直连 + 本地基线哈希"路径（syncNow 既有能力），失去短路与版本提示 |
| 网盘不可达、API 可达 | 信封/版本/哈希照常更新，本体同步延后重试 |
| 新设备首次加入 | 需网络（邮箱码登录）——唯一硬依赖，合理约束 |

**原则：API 是协调器与加速器，永远不是本地功能的依赖。**

### 3.5 拖库防御（三层）

**L1 降低概率**：D1 无公网入口（仅 Worker 绑定）；CF 账户二步验证 + 最小权限
Token（弃 Global Key）；全参数化查询；管理面只读 + CF Access + IP 白名单；WAF 限速。

**L2 拖库无害化（核心）**：`APP_KEK`（32B，Worker secret，不入库不入 git，与 D1
物理隔离，版本化可轮换）：

| D1 字段 | 存储形态 | 拖库后攻击者所得 |
|---|---|---|
| 信封 | AES-GCM(APP_KEK) 加密 + kek 版本标 | 密文，无从爆破主密码 |
| 邮箱 | HMAC(APP_KEK) 键控哈希（登录查询）+ AES-GCM 加密列（发码时解密） | 不能还原、不能关联注册关系 |
| 会话令牌 | SHA-256(256bit 随机) | 随机数不可逆，本就无害 |
| 验证码 | 键控哈希 | 密文 + 10 分钟时效，无价值 |
| 库名/审计 | 明文（已决策；审计无 PII） | 低敏元数据 |

效果：D1 全量导出在手，既无法爆破任何主密码、也无法得到用户名单。方案一相对
零密文方案的安全差距，收敛为"Worker 运行时被完整攻破"（同时得密文与 KEK）的
极端情形。KEK 轮换：新版本 + 后台重加密（行数少，秒级）。

**L3 检测与恢复**：全量审计；CF 账户操作告警；每月 D1 导出离线备份（导出物本身
已密文化）；KEK 轮换预案。

---

## 4. 同步协议

### 4.1 服务端哈希注册表

每 vault 记录两个哈希（客户端在上传成功后上报）：

- `cipher_sha256`：网盘上 `.upw` 密文字节哈希（网盘文件身份）；
- `xml_sha256`：**明文 XML** 哈希（内容身份）。

**为什么两个**：密文每次保存因随机 nonce 都变，拿它判"内容是否变化"会误触发
无谓上传；`xml_sha256` 才能正确实现"无变化则跳过"。

### 4.2 同步流程（每轮自动同步）

```
1. GET /v1/vaults/{id} 注册表
2. 短路：本地明文 XML 哈希 == 服务端 xml_sha256 → 本轮结束（零网盘操作）
3. 否则：网盘下载 .upw
   ├─ 404/缺失：若 .upw.old 存在且校验通过 → 以 .old 为远端基线继续（见 4.3）；
   │          否则视为首次上传
   └─ 成功：会话 VEK（或采纳后的远端 VEK）解密 → 条目级合并
        （每项 mtime 决胜 + 墓碑抑制复活，现有 merge 逻辑）
4. 上传前复查（两道）：① 重取云端文件哈希，若与合并基线不同 → 回到 3 重合并
   （现有 fresh-check 逻辑）；② 再读注册表确认服务端 xml_sha256 未变——
   变了说明对端已完成上传 → 回到 1（借强一致 API 压缩网盘 check-then-act 竞态）
5. 替换上传：.upw → .upw.old（改名，改名不可用时降级为"下载旧件→上传为 .old"；
   **`.upw` 缺失（恢复路径）时跳过改名直接上传**）；
   上传新 .upw（+ 信封副本 .upwkey，小文件直接覆盖）
   ├─ 上传成功 → PUT /v1/vaults/{id}/hashes 上报新 cipher_sha256 + xml_sha256
   └─ 上传失败 → 立即回滚：尝试把 .upw.old 改名回 .upw（恢复同步前云端原状）；
        回滚也失败 → 保留 .old、本轮报错结束（见 4.3 恢复规则）
6. .old 只保留一代（新备份覆盖旧备份）
```

### 4.3 `.upw.old`：上代备份 + 上传失败恢复点

`.old` 的双重作用：① 正常路径的上代版本备份；② **上传失败的恢复点**——改名后
新件上传失败时，云端至少保有上一份完整库，任何设备（含重装后的设备）都可从
`.old` 恢复密码库。

恢复规则（按优先级）：

1. **即时回滚**（上传失败的设备）：改名 `.old → .upw` 恢复同步前云端原状；
   回滚失败则保留 `.old` 等待下轮；
2. **下轮同步恢复**（任何设备）：`.upw` 缺失而 `.old` 存在 → 下载 `.old`、
   **校验后**作为远端基线（v2 魔数 + GCM 解密成功才可用，防半截/损坏文件），
   合并本地后走正常替换上传，云端随之重建 `.upw`；
3. **云端恢复流程兜底**（重装/换设备）：从网盘恢复库时，`.upw` 缺失同样回退
   `.old`（校验同上）；
4. **双失守兜底**：`.upw` 与 `.old` 均缺失/损坏时，不视为"云端空库"覆盖上传——
   以本地库（local-first）为准上传重建，本地每日备份（保留 10 份）与对端设备
   本地副本是最后防线。

**分层保障结论**：网盘层 `.old`（上代） → 设备本地库 → 设备本地备份 → 对端设备
本地库。上传失败在任何一层都不丢数据。

### 4.4 时间戳与回收站（数据模型约束）

### 4.3 时间戳与回收站（数据模型约束）

- 每个密码项自动维护创建/修改时间（现 XML 为 **Unix epoch 毫秒**，满足"精确到秒"），
  由系统写入，UI 不提供手改入口（现状即如此，实现阶段加测试锁定）；
- 删除两段式：
  1. 删除 → `trashed`（回收站，前端可见可恢复）——现状已有；
  2. 从回收站再删除 → **隐藏态**（任何前端界面不可感知，仅同步层墓碑保留）
     ——新增 `purgedAt` 时间戳；
  3. 隐藏态保留 **365 天**后**内容硬清除**（XML 中移除条目的字段/笔记等全部数据），
     但**长期保留 `(id, 删除时间)` 极小标记**（几字节，无内容）——
     客户端定时任务 + 打开库时惰性扫描双保险；
- 标记必须保留的原因：若连墓碑一并删除，离线超 365 天的设备本地仍持有
  "该已删条目"，重连合并时双方均无墓碑可抑制 → 已删密码复活并扩散
  （经典墓碑 GC 问题）。保留标记彻底堵死复活路径，同时满足
  "密码数据 365 天后彻底清除"的要求（标记不含任何内容）。

---

## 5. API 规范（v1）

通用：Bearer 会话鉴权；错误体 `{error, message}`；日志只记 ID 前缀/动作/尺寸/结果
（令牌/验证码/邮箱全量不进日志）；`GET /v1/` 能力协商；HSTS。

### 5.1 账户

| 端点 | 说明 |
|---|---|
| `POST /v1/auth/code` `{email, purpose?}` | 发验证码（login/sensitive），单活跃码 |
| `POST /v1/auth/verify` `{email, code, deviceName?}` | `200 {token, expiresAt, userId}`（不存在则建户） |
| `GET /v1/auth/sessions` / `DELETE …/{id}` | 设备列表 / 撤销 |
| `DELETE /v1/account` | 注销（需 sensitive 码）→ deregistered，30 天清除 |
| `POST /v1/auth/totp/*` | （后期）可选双因子 |

### 5.2 vault 注册表

| 端点 | 说明 |
|---|---|
| `POST /v1/vaults` `{name}` | 登记 vault（服务端发随机 vaultId；查每用户上限，默认 10） |
| `GET /v1/vaults` | 列表（vaultId、名、passwordVersion、哈希、updatedAt） |
| `GET /v1/vaults/{id}` | 单条（含信封，方案一） |
| `PUT /v1/vaults/{id}/envelope` | 改密时上报新信封（changedAt 决胜，version++） |
| `PUT /v1/vaults/{id}/hashes` | 网盘上传成功后上报 `{cipherSha256, xmlSha256}` |
| `PATCH /v1/vaults/{id}` `{name}` | 改名（先网盘侧改名 .upw/.upwkey/.old，成功后才更新注册表） |
| `DELETE /v1/vaults/{id}` | 解绑注册（需 sensitive 码；不动网盘文件） |

注意：网盘文件名含库名——**多个账户共用同一 WebDAV 目录或同一 iCloud Drive 时，
同名库会互相覆盖**。默认按账户子目录隔离（如 `/UPasswords/<账户前缀哈希>/`），
路径仍允许用户自定义。

### 5.3 统计（只读管理面，`X-Admin-Token` + CF Access）

| 端点 | 说明 |
|---|---|
| `GET /v1/admin/stats` | 按状态计数（注销/普通/订阅/永久）、注册趋势、
  活跃 vault 数、SMTP 发送量、请求量 |

**只读**：无启停用户、无删库、无任何写操作（已按合规要求降权）。

---

## 6. 存储（仅 D1，无 R2）

```sql
CREATE TABLE users (
  id            TEXT PRIMARY KEY,
  email_hmac    TEXT NOT NULL UNIQUE,        -- HMAC(APP_KEK, 规范化邮箱)：登录查询键
  email_enc     TEXT NOT NULL,               -- AES-GCM(APP_KEK, 邮箱)：发码时解密
  state         TEXT NOT NULL DEFAULT 'active',   -- active|deregistered
  plan          TEXT NOT NULL DEFAULT 'normal',   -- normal|subscription|permanent
  totp_secret   TEXT,                        -- 后期（同样 APP_KEK 加密）
  created_at    REAL NOT NULL,
  last_login_at REAL
);

CREATE TABLE email_codes (
  email_hmac TEXT NOT NULL, code_hash TEXT NOT NULL,   -- 键控哈希
  purpose TEXT NOT NULL DEFAULT 'login',     -- login|sensitive
  expires_at REAL NOT NULL, attempts INTEGER NOT NULL DEFAULT 0,
  used_at REAL, created_at REAL NOT NULL
);

CREATE TABLE sessions (
  id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id),
  token_hash TEXT NOT NULL,                  -- SHA-256(256bit 随机令牌)，拖库无害
  device_name TEXT NOT NULL DEFAULT '',
  created_at REAL NOT NULL, last_seen_at REAL NOT NULL,
  expires_at REAL NOT NULL, revoked_at REAL
);

CREATE TABLE vaults (
  vault_id            TEXT PRIMARY KEY,      -- 16B 随机 hex
  user_id             TEXT NOT NULL REFERENCES users(id),
  name                TEXT NOT NULL,         -- 明文（已决策）
  password_version    INTEGER NOT NULL DEFAULT 1,
  password_changed_at REAL NOT NULL,
  envelope_enc        TEXT,                  -- AES-GCM(APP_KEK, 信封) + kek 版本标
  envelope_changed_at REAL,
  cipher_sha256       TEXT,                  -- 网盘 .upw 哈希（客户端上报）
  xml_sha256          TEXT,                  -- 明文 XML 哈希（短路判据）
  created_at REAL NOT NULL, updated_at REAL NOT NULL
);
CREATE UNIQUE INDEX idx_vaults_user_name ON vaults(user_id, name);

CREATE TABLE audit_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id TEXT, vault_id TEXT, action TEXT, detail TEXT, ts REAL NOT NULL
);
```

---

## 7. 邮件（验证码通道）

同 v3：Worker `cloudflare:sockets` → smtp.163.com:465；一期
`From: 16621660628@163.com` + `Reply-To: register@upasswords.com`；
二期品牌发件 + SPF/DKIM；`SMTP_USER/SMTP_PASSWORD` 只进 Worker secret；
163 单点 = 新设备登录受限（存量会话与本地使用不受影响），运维监控。

---

## 8. 客户端改造清单

| 位置 | 改动 |
|---|---|
| Core | 回收站隐藏态：`Card.purgedAt` + 365 天内容硬清除（保留 id+删除时间标记防复活）；时间戳不可变性测试 |
| Persistence | API 客户端（auth/vaults 注册表）；同步编排：哈希短路 + `.upw.old` 改名/恢复 + 上传后上报哈希；信封通道改走 API（方案一） |
| macOS/iOS | 邮箱码登录与会话管理 UI（多账户会话按账户入 Keychain，库切换器按账户分组）；同步设置 = 云同步（API）+ 网盘通道选择（iCloud/WebDAV 回到 UI）；解锁前版本检查与"密码已修改"提示 |
| 删除 | `CloudEnvelopeService` 与其开关/文案（被新注册表信封端点取代） |
| 保留 | WebDAV/iCloud 驱动、本地备份、导出导入；`joinRemoteVaultIdentity` 收敛机制 |

---

## 9. 服务端实现与部署

- `Cloud/worker` TypeScript（零依赖）：`src/{index,auth,vaults,stats,smtp,db,util}.ts`
  + `migrations/0001_init.sql`；**无 R2、无 KV**（旧 VAULTS KV 命名空间删除）；
- vitest + `@cloudflare/vitest-pool-workers`（D1/SMTP mock）：登录/单活跃码/限速/
  信封 changedAt 决胜/哈希上报/注销清除/越权访问/常量时间比较；
- Secrets：`ADMIN_TOKEN`、`SMTP_USER`、`SMTP_PASSWORD`、`APP_KEK`（应用层加密主键，
  版本化，支持轮换重加密）；
- 域名：api.upasswords.com（管理统计端点同域，CF Access 保护 `/v1/admin/*`）；
- 运维加固清单（v3 §10.1 继续有效）：弃用 Global API Key 换最小权限 Token、
  CF/163 开二步验证、轮换聊天中出现过的凭据、每月 D1 导出加密离线。

---

## 10. 分阶段实施

| 阶段 | 内容 | 验收 |
|---|---|---|
| P0 服务端 | Worker + D1：账户（邮箱码/会话/注销）+ vault 注册表（版本/信封/哈希）+ 只读统计 + SMTP + vitest + 部署 | vitest 全绿；curl 走通注册→登录→登记→改密版本→哈希上报 |
| P1 客户端 | 双端登录 UI + 注册表客户端 + 同步编排（短路/.old/上报）+ 解锁版本检查 + 回收站隐藏态/365 天清除 + 删 CloudEnvelopeService | 四 Swift 包 swift test 全绿；make-app.sh 部署双端真机验证（含改密传播、离线解锁、.old 恢复） |
| P2 运维 | 统计页（只读）、cron（注销 30 天清除）、告警邮件、凭据轮换、TOTP（可选） | 加固清单核销 |

---

## 11. 遗留开放问题

1. TOTP 时机；SMTP 品牌发件方案（二期）；
2. 订阅/永久状态的判定与开通方式（服务端手工标记 or 预留字段即可）；
3. 网盘上 `.upwkey` 信封副本是否随本体一起 `.old` 备份（建议：信封小，直接覆盖，
   API 持久版本为权威）。
