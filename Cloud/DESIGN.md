# UPasswords 云同步设计（账户中继 + 服务端加密库体）

状态：**v6 · 已实施**（macOS/iOS main，2026-10-13）。

> 本文只描述当前实现。同步通道为**账户中继单通道**：注册表信封决胜 +
> 服务端 R2 加密库体副本；客户端不内置任何网盘（WebDAV/iCloud）通道。

## 1. 目标与架构

**目标**：API 服务器提供强一致的账户、改密传播、变更短路与版本可见性，
并以 R2 承载加密库体副本（零知识密文）；服务端对库内容零知识。

```
macOS / iOS App
  └── API（api.upasswords.com，Worker + D1 + R2，HSTS）
        账户（邮箱码登录/会话）、vault 注册表（版本元数据/哈希/信封）、统计、
        R2 加密库体副本（vault body，库密钥密文）
```

关键性质：

- **绑定即推库体**：库绑定账户的瞬间即上传库体镜像与双哈希（不依赖任何
  开关），此后每轮同步读-改-写提交——服务端始终持有可恢复副本；
- **零知识**：服务器只见密文（信封/库体）与哈希/元数据，永无主密码、
  库密钥或明文；
- **local-first**：API 是协调器与加速器，永远不是本地功能的依赖。

## 2. 账户与用户状态

### 2.1 用户旅程（两层凭证分离）

| 层 | 凭证 | 出现时机 |
|---|---|---|
| 账户层（授权） | 邮箱 + 验证码 | 登录新设备、敏感操作（注销/解绑/换绑）；验证通过自动注册并签发 90 天会话 |
| 库层（解密） | (账户 + vault_id) 定位库 + 该库主密码 | 每次解锁；每库独立密码独立解锁 |

```
新设备:  装App → 账户邮箱+验证码登录（首次自动注册，必经步骤）
   ├─ 新用户: 创建库(命名+设主密码) → 解锁后自动绑定 → 信封+库体镜像上 API
   └─ 老用户: 在线恢复页自动列出账户库 → 选库 → 输主密码
              → API 取信封解 VEK → R2 拉库体 → 解密落库直接进入应用
日常:    解锁只输主密码(本地信封验证+在线版本检查)；验证码不再出现
```

- 注册/登录：邮箱验证码（6 位、TTL 10 分钟、**单活跃码**、≤5 次尝试、
  重发冷却 60s、每邮箱 10 封/h、每 IP 20 次/h；响应恒定防枚举）；
- 会话令牌：32B 随机，D1 只存 SHA-256，90 天滑动（活动即续期），逐设备
  可撤销；会话可自命名（设备型号展示）；
- 用户状态：`normal（普通）| subscription（订阅）| permanent（永久）`，
  外加 `deregistered（注销）`；注销 = 用户发起（需新鲜敏感验证码）→
  **立即吊销全部会话并清空敏感列 + R2 库体**，仅保留状态行供统计，
  30 天保留期后由每日 cron 物理清除（本地库与备份不受影响）；
- 敏感操作（注销账户、解绑 vault 注册、换绑邮箱）需当次新鲜验证码。

### 2.2 账户与本地隔离

- vault 注册表、信封、库体、会话全部按 user_id 行级隔离，跨账户不可见；
- 同一设备可登录多个账户（每账户一个会话令牌，Keychain 按邮箱隔离）；
  本地多库按库名并存，每个本地库记住所属账户与 vault_id，同步使用对应
  账户会话；
- 一个库同时只归属一个账户；换绑邮箱经 `/transfer` 端点完成（注册表整体
  迁移到新邮箱名下，vaultId/信封/哈希/库体不变），需当前账户 sensitive 码
  + 新邮箱验证码双门槛。

## 3. vault 密码（主密码）变更传播

### 3.1 原理（复用 v2 双密钥架构，无新增密码存储）

- 主密码 → 信封（`.upwkey`，PBKDF2-SHA256 ×600,000（新信封；兼容下限
  100,000）包裹库密钥 VEK）→ VEK 加密本体；
- 改密**始终轮换 VEK 并重加密本体**：旧密文（历史残留/备份/泄露副本）对
  旧密码永久作废，本地信封即密码记录，解开即验证，离线天然可用；
- 服务端只存**版本元数据**：`password_version`（单调）+ `password_changed_at`。
  不存任何密码衍生物或验证子——拖库也无法用于爆破主密码。

### 3.2 解锁流程

```
在线：GET /v1/vaults/{id} 注册表
   ├─ password_version == 本地已知 → 正常输密码解锁（本地信封验证）
   └─ password_version > 本地 → 提示"密码已在其他设备修改，请使用新密码"
        → 用户输新密码 → 取服务端最新信封 → 重裹本地/采纳 → 解锁
离线：直接本地信封验证（无网络依赖）
```

实现约束：客户端持久化各库**已见 password_version** 作比对基准；任何在线
读注册表时，服务端信封 changedAt 比本地新则顺手持久化到本地 `.upwkey`
（**信封先行**）——设备上线过一次后即可离线用新密码解锁。残余死区仅为
"改密后从未上过线的设备"，属固有合理约束。

### 3.3 信封决胜（强一致传播）

- 服务端存信封（~100B 密文）：改密秒级强一致传播，对端立刻可用新密码解锁；
- 信封经 **APP_KEK 应用层加密**后入库（见 3.5）：拖库 alone 拿不到可爆破物；
- 改密时信封 PUT 失败则排队自动重试直到成功（changedAt 幂等，可安全重试）；
- 时钟偏斜防御：信封 changedAt 偏离服务器时间超过 ±300s（可配
  `CHANGED_AT_MAX_SKEW_SECONDS`）时钳制为接收时间——防坏钟设备永胜；
- 过期写拒绝：changedAt 不新于服务端现值时返回 `stale`（服务端保留现值），
  客户端以注册表为准收敛。

### 3.4 离线与降级矩阵

核心事实：远端信封与本体都在服务端，本地信封是离线验证源。

| 场景 | 行为 |
|---|---|
| 离线解锁 | 本地信封验证照常；即使密码已被他机修改，本机旧密码仍可解锁本地副本；联网后版本检查提示改密、拉新信封换入（本体随后收敛） |
| 离线保存/同步 | 本地保存照常（local-first）；同步挂起联网补 |
| 离线改密 | 允许：本地重裹+轮换 → 联网上传信封与本体；双端离线各改 → 服务器 changedAt 决胜，败方被强制锁定后输胜方密码接管，数据经合并零丢失 |
| API 不可达 | 本地功能全部照常；同步/版本检查延后重试（自动同步带失败退避） |
| 新设备首次加入 | 需网络（邮箱码登录）——唯一硬依赖，合理约束 |

### 3.5 拖库防御（三层）

**L1 降低概率**：D1/R2 无公网入口（仅 Worker 绑定）；CF 账户二步验证 +
最小权限 Token；全参数化查询；管理面只读 + CF Access + IP 白名单；WAF 限速。

**L2 拖库无害化（核心）**：`APP_KEK`（32B，Worker secret，不入库不入 git，
版本化可轮换）：

| 存储项 | 形态 | 拖库后攻击者所得 |
|---|---|---|
| 信封（D1） | AES-GCM(APP_KEK) + kek 版本标 | 密文，无从爆破主密码 |
| 库体（R2） | 库密钥 AES-256-GCM 密文（本就零知识） | 无 VEK 不可解 |
| 邮箱（D1） | HMAC(APP_KEK) 键控哈希（查询键）+ AES-GCM 加密列 | 不能还原、不能关联注册关系 |
| 会话令牌（D1） | SHA-256(256bit 随机) | 不可逆 |
| 验证码（D1） | 键控哈希 | 密文 + 10 分钟时效，无价值 |
| 库名/审计（D1） | 明文（已决策；审计无 PII） | 低敏元数据 |

效果：D1 全量导出在手，既无法爆破任何主密码、也无法得到用户名单。残余
风险收敛为"Worker 运行时被完整攻破"（同时得密文与 KEK）的极端情形。
KEK 轮换：新版本 + 后台重加密（行数少，秒级）。

**L3 检测与恢复**：全量审计；CF 账户操作告警；每月 D1 导出离线备份（导出物
本身已密文化）；KEK 轮换预案。

## 4. 同步协议

### 4.1 哈希注册表

每 vault 记录（客户端在库体提交成功后上报）：

- `cipher_sha256`：库体密文字节哈希（副本身份）；
- `xml_sha256`：**明文 XML** 哈希（内容身份）。

**为什么两个**：密文每次保存因随机 nonce 都变，拿它判"内容是否变化"会误触发
无谓上传；`xml_sha256` 才能正确实现"无变化则跳过"。

### 4.2 同步流程（每轮同步）

```
1. GET /v1/vaults/{id} 注册表（强一致）
   ├─ 信封决胜：远端 changedAt 更新 → 会话密码可解 → 采纳远端 VEK、收敛库身份；
   │   解不开且 version 前进 → 他机改密 → 强制锁定等新密码；解不开且版本未进
   │   → 远端不可解密态，挂修复入口（接管/覆盖）
   ├─ 本地信封更新（含首次接入）→ 自愈推送信封
   └─ 短路：本地明文 XML 哈希 == 服务端 xml_sha256 → 本轮结束（零库体往返）
2. GET /v1/vaults/{id}/body 库体
   └─ 404 = 该库首次接入 → 本轮直接上传本地
3. 解密（信封阶段确认的 VEK）→ 条目级合并（mtime 决胜 + 墓碑抑制复活）
   ├─ 双方自基线都有修改 → 冲突弹窗交用户裁决（本地覆盖远端 / 远端覆盖本地）
   ├─ 双方均无变化 → 跳过上传（防无意义重传乒乓）
   └─ 合并后内容 == 远端 → 只拉不推（避免刷新 nonce 制造对端误判）
4. 读-改-写护栏：提交前再取一次库体，与第 2 步所见不同（窗口内他机提交）
   → 先合并新远端再提交；解不开则中止走接管
5. PUT body（staging 暂存）→ POST commit（校验 sha256 后原子换入生效副本）
   → PUT hashes 上报双哈希 → 记录基线
```

### 4.3 数据完整性分层

服务端 R2 副本 → 设备本地库 → 设备本地备份（默认保留 10 份）→ 对端设备
本地库。任一层失守都不丢数据；`.upw`/`.upwkey` 文件对导出/本地还原提供
跨云逃生通道（文件可手动存任意网盘/硬盘，App 不内置网盘客户端）。

### 4.4 时间戳与回收站（数据模型约束）

- 每个密码项自动维护创建/修改时间（Unix epoch 毫秒），系统写入，UI 无手改
  入口（测试锁定）；
- 删除两段式中的第一段已实现：删除 → `trashed`（回收站，前端可见可恢复）；
  回收站再删除 = 墓碑（同步层抑制复活）；
- **隐藏态 + 365 天内容硬清除为规划项**（见 §10），当前实现停留在两段式。

## 5. API 规范（v1）

通用：Bearer 会话鉴权；错误体 `{error, message}`；日志只记 ID 前缀/动作/
尺寸/结果（令牌/验证码/邮箱全量不进日志）；`GET /v1/` 能力协商；HSTS。

### 5.1 账户

| 端点 | 说明 |
|---|---|
| `POST /v1/auth/code` `{email, purpose?}` | 发验证码（login/sensitive），单活跃码，限速 |
| `POST /v1/auth/verify` `{email, code, deviceName?}` | `200 {token, expiresAt, userId}`（不存在则建户） |
| `GET /v1/auth/sessions` | 设备列表 |
| `DELETE /v1/auth/sessions/{id}` | 撤销设备 |
| `PATCH /v1/auth/session` `{deviceName}` | 会话自命名（设备型号展示） |
| `DELETE /v1/account` `{code}` | 注销（sensitive 码）→ 立即清敏感列+R2+撤会话，30 天物理清除 |

### 5.2 vault 注册表与库体

| 端点 | 说明 |
|---|---|
| `POST /v1/vaults` `{name}` | 登记 vault（随机 vaultId；每用户上限 `VAULT_LIMIT_PER_USER`，默认 10） |
| `GET /v1/vaults` | 列表（vaultId、名、passwordVersion、哈希、库体元数据；不含信封密文） |
| `GET /v1/vaults/{id}` | 单条（含信封 b64——解锁/恢复数据源） |
| `PUT /v1/vaults/{id}/envelope` | 改密上报新信封（changedAt 决胜 + ±300s 钳制；过期写返回 stale） |
| `PUT /v1/vaults/{id}/hashes` | 库体提交成功后上报 `{cipherSha256, xmlSha256}` |
| `PUT /v1/vaults/{id}/body?upload=UID` | 库体暂存（单请求完整密文，octet-stream；须带 content-length 预判配额；上限 `VAULT_BODY_MAX_BYTES` 默认 50MB；暂存数配额 `VAULT_STAGING_MAX_OBJECTS` 默认 4） |
| `POST /v1/vaults/{id}/body/commit` `{uploadId, sha256}` | 校验 sha256 后原子换入生效副本（commit 前对读端不可见） |
| `GET /v1/vaults/{id}/body` | 拉取生效库体（无副本 404） |
| `PATCH /v1/vaults/{id}` `{name}` | 改名（vaultId 不变；客户端先本地改名再调本端点） |
| `DELETE /v1/vaults/{id}` `{code}` | 解绑注册（sensitive 码；清 R2 副本与 staging；本地库与备份不动） |
| `POST /v1/vaults/{id}/transfer` `{email, code, currentCode, deviceName}` | 换绑邮箱：注册表迁移到新账户，返回新账户会话 |

JSON 载荷（信封/哈希等）另受 64KB 读取上限约束。

### 5.3 统计（只读管理面，`X-Admin-Token` + CF Access）

| 端点 | 说明 |
|---|---|
| `GET /v1/admin/stats` | 按状态/套餐计数、活跃 vault（近 365 天）、会话、SMTP 量等实时聚合 |

**只读**：无启停用户、无删库、无任何写操作。

## 6. 存储

### 6.1 D1（upasswords-sync）

```sql
CREATE TABLE users (
  id            TEXT PRIMARY KEY,
  email_hmac    TEXT NOT NULL UNIQUE,        -- HMAC(APP_KEK, 规范化邮箱)：登录查询键
  email_enc     TEXT NOT NULL,               -- AES-GCM(APP_KEK, 邮箱)：发码时解密
  state         TEXT NOT NULL DEFAULT 'active',   -- active|deregistered
  plan          TEXT NOT NULL DEFAULT 'normal',   -- normal|subscription|permanent
  totp_secret   TEXT,                        -- 规划（同样 APP_KEK 加密）
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
  vault_id            TEXT PRIMARY KEY,      -- 随机 hex
  user_id             TEXT NOT NULL REFERENCES users(id),
  name                TEXT NOT NULL,         -- 明文（已决策）
  password_version    INTEGER NOT NULL DEFAULT 1,
  password_changed_at REAL NOT NULL,
  envelope_enc        TEXT,                  -- AES-GCM(APP_KEK, 信封) + kek 版本标
  envelope_changed_at REAL,
  cipher_sha256       TEXT,                  -- 库体密文哈希（客户端上报）
  xml_sha256          TEXT,                  -- 明文 XML 哈希（短路判据）
  body_sha256         TEXT,                  -- R2 生效副本 SHA-256
  body_bytes          INTEGER,               -- 库体字节数
  body_updated_at     REAL,
  created_at REAL NOT NULL, updated_at REAL NOT NULL
);
CREATE UNIQUE INDEX idx_vaults_user_name ON vaults(user_id, name);

CREATE TABLE audit_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id TEXT, vault_id TEXT, action TEXT, detail TEXT, ts REAL NOT NULL
);
```

### 6.2 R2（桶 `VAULTS`）

- 生效副本：`vaults/<vaultId>`（单对象，commit 原子换入）；
- 上传暂存：`vaults/staging/<vaultId>/<uploadId>`（每上传会话一对象，
  commit 换入或超量清扫）；
- 解绑/注销：库体与 staging 前缀一并删除。

## 7. 邮件（验证码通道）

Worker `cloudflare:sockets` → smtp.163.com:465；`From: 16621660628@163.com` +
`Reply-To: register@upasswords.com`；`SMTP_USER/SMTP_PASSWORD` 只进 Worker
secret。163 单点 = 新设备登录受限（存量会话与本地使用不受影响），运维监控。

## 8. 客户端实现要点（当前状态）

- **Persistence**：`RelayClient`（账户/注册表/库体 API 客户端，零知识红线）；
  `RelaySync`（绑定、令牌钥匙串缓存、版本高水位）；`CloudSync`（SyncConflict
  基线判定与哈希工具）；
- **同步编排**（macOS `AppContext+Sync` / iOS `Vault+Sync`）：信封决胜 →
  短路 → 库体合并/冲突裁决 → 读-改-写提交 → 基线记录；锁屏禁止同步；
  自动同步 ticker + 失败退避（iOS）；
- **绑定即推库体**（macOS `AppContext+Relay` / iOS `Vault+Relay`）：
  登录启用与解锁后自动补绑都会立即上传库体镜像+双哈希；
- **新设备恢复**：向导/锁屏页从 `listVaults` 列账户库 → 有镜像的库凭主密码
  直接恢复；离线迁移走 `.upw`/`.upwkey` 文件对本地还原；
- **他机改密**：版本前进+信封解不开 → 强制锁定换新信封；解锁/同步带远端
  兜底收敛（`unlockWithRemoteFallback`）；接管/覆盖修复入口；
- **浏览器扩展**：relay 会话登录/解锁/填充，读 R2 副本快照（TTL 自动锁定）。

## 9. 服务端实现与部署

- `Cloud/worker` TypeScript（零依赖）：`src/{index,auth,vaults,stats,smtp,db,util}.ts`
  + `migrations/0001_init.sql`、`0002_vault_body.sql`；
- 绑定：D1（upasswords-sync）+ R2（桶 VAULTS）；每日 cron 04:00 UTC 清扫
  注销到期账户与过期 staging；
- vitest + `@cloudflare/vitest-pool-workers`（D1/SMTP mock）：登录/单活跃码/
  限速/信封决胜/哈希上报/库体 staging-commit 配额/注销清除/越权访问/
  常量时间比较；
- Secrets：`ADMIN_TOKEN`、`SMTP_USER`、`SMTP_PASSWORD`、`APP_KEK`（版本化，
  支持轮换重加密）；
- 域名：api.upasswords.com（`/v1/admin/*` 由 CF Access 保护）；
- 运维加固：最小权限 Token、二步验证、凭据轮换、每月 D1 导出加密离线。

## 10. 规划（未实施）

1. 回收站隐藏态（`purgedAt`）+ 365 天内容硬清除（保留 id+删除时间极小标记
   防离线复活；客户端定时 + 惰性扫描双保险）；
2. TOTP 可选双因子；
3. 订阅/永久状态的判定与开通方式（服务端手工标记 or 预留字段）；
4. SMTP 品牌发件 + SPF/DKIM。
