# UPasswords v1 数据库设计

> 本文描述仓库内 `Cloud/` 源码快照的数据存储。产品开发版本为 v1；本地容器格式、云同步协议、API 路径与数据库迁移编号是相互独立的版本标识。生产已于 2026-10-28 运行同步协议 5，数据库迁移 `0001`–`0010` 已应用；生产部署状态以 `service-admin` 的镜像标签和运行记录为准；源码须与受信任 `main` 一致。

## 存储边界

UPasswords 没有本地 SQLite 数据库。原生客户端的主条目数据仍由领域模型序列化为 XML，再写入 AES-GCM 加密的 `.upw` 文件；主密码信封保存在同名 `.upwkey` 文件，同步游标和修订状态保存在 `.upwsync` 文件。SwiftData 已承接独立个人资料与附件记录；旧 `.upw` 仍作为兼容/回退源双写。浏览器扩展将逐条密文、信封和同步状态保存在 IndexedDB。

本地业务表映射已完成。已确认以 `service-admin` 工作树的
MariaDB 迁移作为密码库共享业务 schema 规范；macOS/iOS 的 SwiftData 模型与浏览器
IndexedDB object store 映射相同的业务表字段和语义。本地库仅保存该用户自己的密码库数据，
云端 MariaDB 则保存所有用户的数据，并承担服务端认证、审计和维护状态。客户端不复制其他用户
[`DECISIONS.md`](../DECISIONS.md)。

| 云端业务表 | macOS/iOS SwiftData | 浏览器 IndexedDB | 说明 |
|---|---|---|---|
| `vaults` | `LocalVaultRecord` | `vaults` | 保留本地有语义的库身份、信封、密码版本和时间列；用户 ID、配额、日志水位等服务端运营列不复制。 |
| `vault_items` | `LocalVaultItemRecord` | `vault_items` | 行密文、真实字节数、SHA-256、revision、修改时间与来源快照一致。 |
| `vault_user_profiles` | `LocalVaultProfileRecord` | `vault_user_profiles` | kind=3 独立分表；旧 kind=3 行初始化事务迁移。 |
| `attachments` | 当前引用由附件版本模型推导 | `attachments` | 当前版本元数据；对象路径等服务端存储细节不暴露给客户端。 |
| `attachment_versions` | `LocalAttachmentRecord` | `attachment_versions` | 版本身份、DEK 包装、摘要、字节数、创建/退役时间对齐；缓存淘汰状态为本地额外列。 |
| 附件对象字节 | `LocalAttachmentContentRecord` | `attachmentContent` | 云端 R2 对象的已验证密文字节缓存，不属于 MariaDB 表。 |
| `item_changes`/墓碑/冲突/rekey | `.upwsync` 及按需冲突 API | snapshot/vault 状态与按需冲突 API | 同步生命周期状态以原子 sidecar/快照表示，不复制服务端日志或纯运营表。 |

详细边界及实施规则见
[`DECISIONS.md`](../DECISIONS.md)。

云端生产 API 为 Cloud/api 中的 Go + chi 服务。MariaDB 存账户、会话、库注册表、条目密文、变更日志、附件元数据、改密暂存、审计记录和全局网站目录。附件密文与网站图标字节保存在 R2，不属于 MariaDB 表。

本地仓库的初始化基线为 [0001_init.sql](database/0001_init.sql)，包含 12 张基础表；
[0002_user_profiles.sql](database/0002_user_profiles.sql) 增加个人资料专用表与合并视图。
`Cloud/database/` 包含 `0003_conflict_candidates.sql` 至
`0010_rekey_conflict_candidates.sql`，其中 0003–0007 增加冲突候选、裁决和删除证据，
0008–0010 增加附件版本及冲突候选 rekey 支持。生产 `upasswords` 数据库已于
2026-10-27 应用 `0001`–`0010`，包含 22 张基础表和 `vault_sync_items` 视图；当前运行 API
镜像和维护调度器状态见 [数据库操作记录](database/README.md)。建库、业务账号和权限由部署流程
创建，应用账号不应拥有 DDL 权限。后续 schema 变更以受信任 main 的迁移为规范，已应用迁移不得改写。

## 设计约定

- 引擎：MariaDB 11.4、InnoDB；默认字符集和排序规则为 utf8mb4 / utf8mb4_unicode_ci。
- 时间：以 BIGINT 保存 Unix epoch 毫秒。服务端写入时间与客户端条目修改时间分列保存。
- 密文：条目和 rekey payload 使用二进制列；摘要使用 SHA-256 十六进制字符串。
- 条目身份：客户端生成 UUID。主键以 vault_id 和 item_uuid 组合，避免跨库冲突。
- 同步删除：永久删除时删除对应 vault_items 或 vault_user_profiles 行，在同一事务写 item_changes op=2 和 item_tombstones。变更日志按期清理，但最小删除证据保留至云库删除；普通 upsert 不能复用已删除 UUID，恢复必须使用新 UUID。0005 迁移只能从仍保留的删除事件回填墓碑。
- 外键：用户删除会级联删除会话和库；库删除会级联删除条目、变更、附件和改密任务；改密任务删除会级联删除暂存内容。
- 逻辑引用：attachments.card_uuid 指向加密条目中的卡片 ID，不设外键，因为服务端无法解密并验证条目种类。维护任务清理孤儿元数据和对象。

## ER 图

~~~mermaid
erDiagram
    users ||--o{ sessions : owns
    users ||--o{ vaults : owns
    users ||..o{ audit_log : "logical user id"
    vaults ||--o{ vault_items : stores
    vaults ||--o{ vault_user_profiles : stores
    vaults ||--o{ item_changes : records
    vaults ||--o{ item_tombstones : retains
    vaults ||--o{ item_conflicts : tracks
    item_conflicts ||--o{ item_conflict_candidates : contains
    vaults ||--o{ attachments : registers
    vaults ||--o{ rekeys : locks
    rekeys ||--o{ rekey_staging : stages
    websites ||--o{ website_domains : maps
    vault_items ||..o{ attachments : "card_uuid logical reference"
    email_codes

    users {
        varchar id PK
        varchar email_hmc UK
        text email_enc
        varchar state
        varchar plan
        text totp_secret
        bigint created_ms
        bigint last_login_ms
        bigint deregistered_at_ms
    }
    email_codes {
        varchar email_hmc PK
        varchar purpose PK
        varchar code_hash
        varchar ip
        bigint expires_ms
        int attempts
        bigint used_ms
        bigint created_ms
    }
    sessions {
        varchar id PK
        varchar user_id FK
        char token_hash UK
        varchar device_name
        varchar platform
        bigint created_ms
        bigint last_seen_ms
        bigint expires_ms
        bigint revoked_ms
    }
    vaults {
        varchar vault_id PK
        varchar user_id FK
        varchar name
        bigint password_version
        bigint password_changed_ms
        text envelope_enc
        bigint envelope_changed_ms
        bigint head_seq
        bigint changes_floor_seq
        int item_count
        bigint attach_bytes
        bigint created_ms
        bigint updated_ms
    }
    vault_items {
        varchar vault_id PK
        char item_uuid PK
        tinyint kind
        bigint revision
        blob body
        char body_sha256
        int body_bytes
        bigint modified_ms
        bigint created_ms
        bigint updated_ms
        varchar origin_session_id
        varchar origin_device_name
        varchar origin_platform
    }
    vault_user_profiles {
        varchar vault_id PK
        char item_uuid PK
        tinyint kind
        bigint revision
        blob body
        char body_sha256
        int body_bytes
        bigint modified_ms
        bigint created_ms
        bigint updated_ms
        varchar origin_session_id
        varchar origin_device_name
        varchar origin_platform
    }
    item_changes {
        bigint seq PK
        varchar vault_id FK
        char item_uuid
        tinyint op
        bigint revision
        char resolved_item_uuid
        varchar conflict_id
        bigint base_revision
        varchar winner_candidate_id
        tinyint winner_kind
        tinyint winner_op
        varchar session_id
        bigint created_ms
    }
    item_tombstones {
        varchar vault_id PK
        char item_uuid PK
        bigint revision
        bigint seq
        bigint deleted_ms
        varchar session_id
        varchar device_name
        varchar platform
    }
    item_conflicts {
        varchar conflict_id PK
        varchar vault_id FK
        char item_uuid
        bigint base_revision
        bigint current_revision
        bigint current_deleted_seq
        bigint generation
        varchar status
        bigint created_ms
        bigint updated_ms
        bigint resolved_ms
        bigint expires_ms
        varchar selected_candidate_id
        char resolved_item_uuid
    }
    item_conflict_candidates {
        varchar candidate_id PK
        varchar conflict_id FK
        tinyint kind
        tinyint op
        bigint revision
        blob body
        char body_sha256
        char candidate_fingerprint
        bigint modified_ms
        varchar source_session_id
        varchar source_device_name
        varchar source_platform
        bigint committed_ms
        varchar disposition
        bigint expires_ms
    }
    attachments {
        varchar vault_id PK
        char attach_uuid PK
        char card_uuid
        varchar object_key
        varbinary dek_wrapped
        char sha256
        bigint bytes
        bigint created_ms
    }
    rekeys {
        varchar rekey_id PK
        varchar vault_id FK
        text new_envelope_enc
        bigint new_password_version
        int item_total
        int dek_total
        int item_staged
        int dek_staged
        bigint expires_ms
        bigint created_ms
    }
    rekey_staging {
        varchar rekey_id PK
        char item_uuid PK
        tinyint kind
        blob payload
        char sha256
    }
    audit_log {
        bigint id PK
        varchar user_id
        varchar vault_id
        varchar action
        varchar detail
        bigint ts_ms
    }
    websites {
        bigint site_id PK
        varchar name_zh
        varchar name_en
        varchar home_url
        char icon_sha256
        varchar icon_mime
        int icon_bytes
        bigint icon_updated_ms
        tinyint status
        bigint created_ms
        bigint updated_ms
    }
    website_domains {
        varchar domain PK
        bigint site_id FK
        boolean is_primary
    }
~~~

email_codes 通过 HMAC 邮箱键匹配用户，没有外键；这使首次注册前也能保存验证码。audit_log 的 user_id 和 vault_id 是可空审计属性，不设外键，以便保留注销或删除后的审计记录。ER 图中的附件到卡片关系也是逻辑关系，不是数据库约束。

## 表与约束

| 表 | 用途、主键与关键索引 |
|---|---|
| users | 账户主体；id 主键，email_hmc 唯一。邮箱查询键为应用密钥 HMAC，email_enc 为应用层加密邮箱。state 与 plan 由服务端业务逻辑约束。 |
| email_codes | 验证码状态；(email_hmc, purpose) 复合主键，限制每种用途一个当前验证码。保存键控 code_hash、IP 限流字段、有效期、尝试次数和使用时间。 |
| sessions | 设备授权；id 主键，token_hash 唯一，user_id 外键级联。按 (user_id, expires_ms) 查询用户设备和有效期。数据库不保存原始 bearer token。 |
| vaults | 用户密码库注册表；vault_id 主键，(user_id, name) 唯一，user_id 外键级联。保存信封、密码版本、head_seq、变更保留地板及配额计数。 |
| vault_items | 卡片与标签的行级密文；(vault_id, item_uuid) 复合主键。按 (vault_id, updated_ms, item_uuid) 建索引，服务全量重建的 keyset 分页。本表存 kind=1 卡片、kind=2 标签。 |
| vault_user_profiles | 个人资料的 kind=3 密文行；列结构和分页索引与 vault_items 一致，kind 受 CHECK 约束，vault_id 外键级联。姓名、联系方式和偏好保存在客户端密文中。 |
| vault_sync_items（视图） | UNION ALL 合并 vault_items 和 vault_user_profiles，统一读取、计数和改密身份检查；写入按已验证的固定种类选择物理表。UUID 跨表唯一由同一库行锁及 API 写入规则保证。 |
| item_changes | 增量同步变更日志；seq 全局自增主键，(vault_id, seq) 支持游标扫描。op=1 表示 upsert，op=2 表示永久删除，op=3 表示库级 rekey，op=4 表示原子冲突裁决；裁决事件保留原 UUID、最终身份、共同 revision 和获胜候选身份。 |
| item_tombstones | 持久删除证据；(vault_id, item_uuid) 主键，保存删除 revision、变更序号和来源快照。只随云库删除清理，不能因变更日志过期而删除。 |
| item_conflicts | 条目冲突集合；保存共同/current revision、当前删除序号、候选代次、裁决状态、选中候选和结果身份。未解决集合不设置到期时间；已解决集合在 30 天后由维护任务级联清理。 |
| item_conflict_candidates | 候选条目版本；只保存客户端加密密文、密文摘要、VEK 派生的 HMAC 指纹、条目类型/操作、客户端修改时间、来源设备快照、裁决 disposition 与到期时间。未解决候选不自动到期，未选候选在裁决后保留 30 天。 |
| attachments | 附件密文登记；(vault_id, attach_uuid) 复合主键，按 (vault_id, card_uuid) 索引清理卡片附件。object_key 指向 R2，dek_wrapped 保存经 VEK 包裹的 DEK。 |
| rekeys | 每库改密任务；rekey_id 主键，vault_id 外键级联并有索引。有效任务使普通写入进入 rekey 锁定状态。 |
| rekey_staging | 改密分块暂存；(rekey_id, item_uuid) 复合主键，rekey_id 外键级联。kind 标识条目密文或附件 DEK 包装数据。 |
| audit_log | 服务端操作记录；id 自增主键，(user_id, ts_ms) 索引。detail 不得包含邮箱、令牌、密码或库内容。 |
| websites | 全局网站目录；site_id 自增主键。名称、主页、图标摘要与图标元数据是公开目录数据。 |
| website_domains | 网站域名映射；domain 主键、site_id 外键级联，并按 site_id 建索引。一站可关联多个规范化域名。 |

## 索引与事务

- 登录通过 users.email_hmc 唯一索引定位账户；会话鉴权通过 sessions.token_hash 唯一索引。
- 库列表使用 vaults.user_id；库变更轮询读取 vaults.head_seq。
- 条目写入通过 (vault_id, item_uuid) 点查并比较 baseRevision；只有 revision 匹配时才写入。
- 增量下行按 (vault_id, seq) 扫描 item_changes，再通过 vault_sync_items 读取当前密文；删除事件被清理后，item_tombstones 继续阻止旧 UUID 复活并支撑长期离线冲突登记。
- 附件通过 (vault_id, attach_uuid) 定位，并使用 (vault_id, card_uuid) 清理卡片附件。
- 条目 upsert/delete、revision、变更日志、高水位和配额计数在同一个 MariaDB 事务中更新。R2 对象操作不与 MariaDB 构成分布式事务，使用暂存对象、提交登记和清理任务处理失败重试。
- 冲突裁决锁定云库与冲突组，比较 generation、完整候选 ID 集、当前 revision 和删除序号；最终行/墓碑、单条 op=4 事件、游标高水位及未选候选 30 天保留在一个 SQL 事务中。删除后以新 UUID 恢复时，原身份墓碑序号同步指向该裁决事件。普通行 CAS 与候选裁决的附件引用激活/退役、候选 rekey 已部署；含附件候选可完整裁决。
- 变更事件默认保留 90 天；游标过期且客户端存在待上传修改或待裁决标记时，原生端保护性阻止全量重建，并在 macOS/iOS 同步设置提示本机数据已保留。该提示不提供比较、另存或裁决操作；超过保留期的裁决事件仍没有客户端人工恢复界面，不能自动保证离线设备完成收敛。
- 改密以 rekeys 行作为短期库写锁，先暂存完整新密文，再以事务内替换条目、附件 DEK、信封和 password_version。

## SQL

基础表定义见 [0001_init.sql](database/0001_init.sql)，个人资料扩展见
[0002_user_profiles.sql](database/0002_user_profiles.sql)，后续 schema 迁移按 `0003`–`0010` 顺序执行。
包括冲突候选及指纹扩展 `0003_conflict_candidates.sql`、`0004_conflict_candidate_fingerprint.sql`、
`0005_conflict_resolution.sql`、`0006_conflict_resolution_change_events.sql` 与
`0007_composed_conflict_resolutions.sql`，以及附件版本和 rekey 扩展 `0008`–`0010`。首次部署时由 DBA 先执行数据库与最小权限账号初始化，再按序对目标库应用 DDL：

~~~sql
CREATE DATABASE upasswords
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

CREATE USER 'upw_app'@'%' IDENTIFIED BY '<由部署者生成的强随机口令>' REQUIRE SSL;
GRANT SELECT, INSERT, UPDATE, DELETE ON upasswords.* TO 'upw_app'@'%';
~~~

在已有目标数据库上应用表结构：

~~~sh
mariadb --defaults-extra-file=/secure/path/mariadb-client.cnf --default-character-set=utf8mb4 upasswords < Cloud/database/0001_init.sql
mariadb --defaults-extra-file=/secure/path/mariadb-client.cnf --default-character-set=utf8mb4 upasswords < Cloud/database/0002_user_profiles.sql
mariadb --defaults-extra-file=/secure/path/mariadb-client.cnf --default-character-set=utf8mb4 upasswords < Cloud/database/0003_conflict_candidates.sql
mariadb --defaults-extra-file=/secure/path/mariadb-client.cnf --default-character-set=utf8mb4 upasswords < Cloud/database/0004_conflict_candidate_fingerprint.sql
mariadb --defaults-extra-file=/secure/path/mariadb-client.cnf --default-character-set=utf8mb4 upasswords < Cloud/database/0005_conflict_resolution.sql
mariadb --defaults-extra-file=/secure/path/mariadb-client.cnf --default-character-set=utf8mb4 upasswords < Cloud/database/0006_conflict_resolution_change_events.sql
mariadb --defaults-extra-file=/secure/path/mariadb-client.cnf --default-character-set=utf8mb4 upasswords < Cloud/database/0007_composed_conflict_resolutions.sql
mariadb --defaults-extra-file=/secure/path/mariadb-client.cnf --default-character-set=utf8mb4 upasswords < Cloud/database/0008_attachment_versions.sql
mariadb --defaults-extra-file=/secure/path/mariadb-client.cnf --default-character-set=utf8mb4 upasswords < Cloud/database/0009_attachment_purge_state.sql
mariadb --defaults-extra-file=/secure/path/mariadb-client.cnf --default-character-set=utf8mb4 upasswords < Cloud/database/0010_rekey_conflict_candidates.sql
~~~

应用运行账号不授予 CREATE、ALTER、DROP 或 mysql.* 权限。生产端迁移和环境变量管理按 [Cloud/api/README.md](api/README.md) 执行；不要将真实凭据写入仓库。

## 本地加密库模型

本地明文数据由 Swift Core 编码为 XML 根元素 database，包含 cards、labels 和 userProfiles。card 包含 fields、notes、labelIds、images、files、创建/修改时间及归档、收藏、回收站状态；label 通过 UUID 被卡片引用；field 包含类型、值、autofill 标记与历史值；user_profile 保存独立个人资料。解锁后的领域值仍使用上述值类型；持久层另以 SwiftData/IndexedDB 密文行映射共享业务表，不保存明文关系表。

跨端字段定义见 [upw-database.schema.json](../Contracts/schemas/upw-database.schema.json)，编码实现见 [DatabaseXML.swift](../SwiftPackages/Core/Sources/UPasswordsCore/DatabaseXML.swift)，实体字段见 [CoreModels.swift](../SwiftPackages/Core/Sources/UPasswordsCore/CoreModels.swift) 与 [UserProfile.swift](../SwiftPackages/Core/Sources/UPasswordsCore/UserProfile.swift)。

## 当前实现与已确认规格

以下区分当前实现、已确认的 v1 目标和正式开放前要求；确认范围不代表已实现能力。

| 事项 | 当前实现 | 已确认规则与实施要求 |
|---|---|---|
| 本地业务表结构 | macOS/iOS 的主条目仍使用加密 `.upw` 与 `.upwsync` sidecar；个人资料、附件有独立 SwiftData 记录并与旧格式双写。浏览器使用保存逐条密文快照的 IndexedDB stores。 | 以受信任 main 的迁移为密码库业务 schema 规范；SwiftData 与 IndexedDB object store 映射相同业务表结构。本地只保存本用户数据，云端保存全体用户数据及服务端运营数据。`.upw` 继续作为兼容/回退双写源；正式退役前需完成逐端生产验收。 |
| 个人资料云同步 | Swift、扩展及 Go API 使用 kind=3，专用密文表参与增量、分页、配额、删除和改密；旧个人资料卡通过匹配 CAS 的 1→3 转换迁入专表。个人资料本地记录使用独立 SwiftData 表，旧 `.upw` 数据初始化时事务迁移。 | 生产迁移 `0002` 与匹配 API 已部署。开发期数据库可重建仅适用于隔离 `_test` 环境；生产库禁止作为测试数据清空，迁移前须备份并验证恢复。服务端不能解密识别个人资料，迁移由升级客户端发起。 |
| 原生附件云同步 | 原生与浏览器客户端已接入附件版本上传/下载、优先下载、缓存策略和图片预览；服务端不可变版本、普通行引用事务、删除/恢复及 R2 清理已部署。 | 附件 ID/内容版本判定、后台与当前条目下载优先级、网络策略、离线/备份、退出保护和跨端恢复规则已定稿。候选附件裁决已实现，生产跨端端到端验收仍待完成；服务端上传与单库额度限制已配置，版本保留、候选引用及清理阶段的总额度核算仍需端到端验证。默认额度见 ../DECISIONS.md。 |
| TOTP 账户列 | `users.totp_secret` 存在于 DDL，但当前账户 API 未实现 TOTP 二次验证，也未使用该列。 | 2026-10-25 已取消账户 TOTP 功能计划，不再列入 v1 实施范围。该未使用列的清理需另行迁移，本轮仅更新范围说明；库内网站 TOTP 继续保留，见 ../DECISIONS.md。 |
| DDL 维护入口 | 初始化 DDL 与后续迁移位于 `Cloud/database/`，供 Go API 集成测试与生产部署使用；生产已应用至 `0010`。 | 新迁移按序新增；部署前验证兼容性，已应用迁移保持不可变。仅隔离 `_test` 数据库可丢弃；生产备份与恢复已配置并持续演练，当前烟测不证明生产规模 RTO。 |
