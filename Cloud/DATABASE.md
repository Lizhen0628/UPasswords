# UPasswords v1 数据库设计

> 本文描述当前工作树中的实际数据存储。产品开发版本为 v1；本地容器格式 v2、云同步能力版本 2、API 路径 /v1 与数据库迁移编号（如 0001、0002）是相互独立的版本标识。

## 存储边界

UPasswords 没有本地 SQLite 数据库。原生客户端将领域模型序列化为 XML，再写入 AES-GCM 加密的 .upw 文件；主密码信封保存在同名 .upwkey 文件。同步游标和修订状态保存在 .upwsync 文件。浏览器扩展将逐条密文、信封和同步状态保存在 IndexedDB。

云端生产 API 为 Cloud/api 中的 Go + chi 服务。MariaDB 存账户、会话、库注册表、条目密文、变更日志、附件元数据、改密暂存、审计记录和全局网站目录。附件密文与网站图标字节保存在 R2，不属于 MariaDB 表。

MariaDB 初始化基线为 [0001_init.sql](database/0001_init.sql)，包含 12 张基础表；[0002_user_profiles.sql](database/0002_user_profiles.sql) 增加个人资料专用表与合并视图，合计 13 张表及 1 个视图。Go API 集成测试按文件名顺序加载全部迁移。建库、业务账号和权限单独由部署流程创建，应用账号不应拥有 DDL 权限。后续 schema 变更按序放入 `Cloud/database/`，已在生产应用的迁移不得改写。

## 设计约定

- 引擎：MariaDB 11.4、InnoDB；默认字符集和排序规则为 utf8mb4 / utf8mb4_unicode_ci。
- 时间：以 BIGINT 保存 Unix epoch 毫秒。服务端写入时间与客户端条目修改时间分列保存。
- 密文：条目和 rekey payload 使用二进制列；摘要使用 SHA-256 十六进制字符串。
- 条目身份：客户端生成 UUID。主键以 vault_id 和 item_uuid 组合，避免跨库冲突。
- 同步删除：永久删除时删除对应 vault_items 或 vault_user_profiles 行，并向 item_changes 写 op=2；不保留条目墓碑行。变更日志过期后，客户端通过全量条目重建收敛。
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
    }
    item_changes {
        bigint seq PK
        varchar vault_id FK
        char item_uuid
        tinyint op
        bigint revision
        varchar session_id
        bigint created_ms
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
| item_changes | 增量同步变更日志；seq 全局自增主键，(vault_id, seq) 支持游标扫描。op=1 表示 upsert，op=2 表示永久删除，op=3 表示库级 rekey。 |
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
- 增量下行按 (vault_id, seq) 扫描 item_changes，再通过 vault_sync_items 读取当前密文；永久删除事件由日志返回，不需要墓碑行。
- 附件通过 (vault_id, attach_uuid) 定位，并使用 (vault_id, card_uuid) 清理卡片附件。
- 条目 upsert/delete、revision、变更日志、高水位和配额计数在同一个 MariaDB 事务中更新。R2 对象操作不与 MariaDB 构成分布式事务，使用暂存对象、提交登记和清理任务处理失败重试。
- 改密以 rekeys 行作为短期库写锁，先暂存完整新密文，再以事务内替换条目、附件 DEK、信封和 password_version。

## SQL

基础表定义见 [0001_init.sql](database/0001_init.sql)，个人资料扩展见 [0002_user_profiles.sql](database/0002_user_profiles.sql)。两者均可重复执行，假设目标数据库已创建，不包含生产口令或应用账号。首次部署时由 DBA 先执行数据库与最小权限账号初始化，再对目标库应用 DDL：

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
~~~

应用运行账号不授予 CREATE、ALTER、DROP 或 mysql.* 权限。生产端迁移和环境变量管理按 [Cloud/api/README.md](api/README.md) 执行；不要将真实凭据写入仓库。

## 本地加密库模型

本地明文数据由 Swift Core 编码为 XML 根元素 database，包含 cards、labels 和 userProfiles。card 包含 fields、notes、labelIds、images、files、创建/修改时间及归档、收藏、回收站状态；label 通过 UUID 被卡片引用；field 包含类型、值、autofill 标记与历史值；user_profile 保存独立个人资料。该模型与 MariaDB 行模型不同，不在本地拆成关系表。

跨端字段定义见 [upw-database.schema.json](../Contracts/schemas/upw-database.schema.json)，编码实现见 [DatabaseXML.swift](../SwiftPackages/Core/Sources/UPasswordsCore/DatabaseXML.swift)，实体字段见 [CoreModels.swift](../SwiftPackages/Core/Sources/UPasswordsCore/CoreModels.swift) 与 [UserProfile.swift](../SwiftPackages/Core/Sources/UPasswordsCore/UserProfile.swift)。

## 当前边界与待讨论

以下区分当前实现、上线前置条件与仍需讨论的事项；备选方案不代表已实现能力。

| 事项 | 当前实现 | 发布前置条件或待讨论的决策及影响 |
|---|---|---|
| 个人资料云同步 | Swift、扩展及 Go API 使用 kind=3，专用密文表参与增量、分页、配额、删除和改密；旧个人资料卡通过匹配 CAS 的 1→3 转换迁入专表。 | 发布时先备份并应用 0002，再启动匹配镜像；服务端不能解密识别个人资料，迁移由升级客户端发起。 |
| 原生附件云同步 | 原生图片/文件内嵌在本地 `.upw`；Go API 有附件登记与 R2 密文接口，原生客户端尚未打通上传、下载、删除和恢复流程。 | 决定是否纳入当前开发版本的验收范围；若纳入，需明确本地附件迁移、离线队列、R2 失败补偿、配额和跨设备恢复行为。 |
| TOTP 账户列 | `users.totp_secret` 存在于 DDL，但当前账户 API 未实现 TOTP 二次验证，也未使用该列。 | 决定移除预留列、保留为未启用字段，或先确定密钥加密和账户恢复方案再实现；当前不可描述为可用安全能力。 |
| DDL 维护入口 | 初始化 DDL 与后续迁移位于 `Cloud/database/`，供 Go API 集成测试与生产部署使用。 | 新迁移按序新增；部署前验证兼容性并备份数据库，已应用迁移保持不可变。 |
