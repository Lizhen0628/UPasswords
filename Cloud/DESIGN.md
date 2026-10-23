# UPasswords v1 云服务设计

> 当前生产服务由 Cloud/api 的 Go + chi 实现。Cloud/worker 保留为兼容与回退运行时。产品开发版本 v1 不等同于 API 路径版本或同步协议版本。

## 版本约定

| 标识 | 当前含义 |
|---|---|
| 产品开发版本 | v1，本文及项目文档统一采用 |
| HTTP 路径 | 客户端使用 /v1；服务端保留 /v2 兼容别名 |
| 能力协商 | version: 2 表示行级同步协议版本 |
| 本地加密容器 | UPWDB2 / UPWKEY1，容器格式版本 2 |
| SQL | Cloud/worker/sql/0001_init.sql 为当前初始化 DDL |

这些版本独立演进。不要把 /v1 路径解释为同步协议版本 1。

## 架构与数据边界

~~~mermaid
flowchart LR
    subgraph clients ["客户端，本地优先"]
        MAC["macOS App<br/>加密 .upw"]
        IOS["iOS App / AutoFill<br/>App Group 加密库"]
        EXT["浏览器扩展<br/>IndexedDB 密文快照"]
    end
    subgraph ingress ["公网入口"]
        CF["Cloudflare<br/>TLS / WAF / DNS"]
        NGINX["Nginx 反向代理"]
    end
    API["Go + chi API<br/>Cloud/api"]
    DB[("MariaDB 11.4<br/>Cloud/worker/sql/0001_init.sql")]
    R2[("Cloudflare R2<br/>附件密文 / 站点图标")]
    SMTP["SMTP 邮件服务"]
    CF --> NGINX --> API
    MAC -->|HTTPS /v1| CF
    IOS -->|HTTPS /v1| CF
    EXT -->|HTTPS /v1| CF
    API -->|TLS| DB
    API --> R2
    API --> SMTP
~~~

原生端以 .upw 加密文件作为离线数据源。浏览器扩展保留加密条目快照。云端不解密密码库内容：MariaDB 存储行级 AEAD 密文和必要同步元数据；R2 存加密对象。网站目录是公开的全局元数据，不属于用户密码库。完整表结构、字段和 SQL 见 [DATABASE.md](DATABASE.md)。

## 密钥与隐私

库主密码不离开设备。它通过 PBKDF2-SHA256 派生密钥打开 .upwkey 信封并取得 VEK；VEK 加密本地库。云同步时每条卡片或标签片段由 VEK 使用 AES-GCM 加密，当前客户端 AAD 为该条目的 UUID。服务端只保存密文、摘要、长度、UUID、kind、revision 和时间戳。

账户层与库层分离：邮箱验证码用于云账户授权；库主密码用于解密库。服务端使用 APP_KEK 对邮箱和密码库信封进行应用层保护，email_hmc 用于邮箱查询；会话数据库仅保存随机 bearer token 的 SHA-256 摘要，验证码仅保存键控摘要。

日志只保留操作类型、对象标识、数量、字节数、错误和耗时。禁止记录邮箱、验证码、bearer token、库密钥、密码、字段值、笔记和附件明文。泄露检查只提交 SHA-1 前缀，服务端转发 HIBP 时不记录查询前缀。

## 行级同步

每个云条目由 (vault_id, item_uuid) 唯一标识，客户端持有 revision 作为 CAS 基线。客户端先保存本地加密库，再以批量请求提交脏条目。服务端在事务内验证 baseRevision、写入或删除当前行、追加 item_changes，并推进 vaults.head_seq。

下行先轮询 head_seq，再以游标读取 item_changes。上行冲突时客户端解密远端条目并按条目修改时间裁决；修改时间较新者胜出，时间相同保留本地。永久删除胜出，不保留 vault_items 墓碑行。删除事件在变更日志保留期内传播；游标过期时客户端按云端现行条目集合全量重建。

macOS/iOS 原生同步状态包括游标、revision、脏修改与删除集合，存入 .upwsync。浏览器扩展将密文快照与同步状态用 IndexedDB 事务保持一致，解锁期间的 VEK 留在受信任扩展会话存储或后台内存。同步失败不阻止已有本地库使用。

跨设备改密使用 rekey staging：开始任务后暂时拒绝普通写入，客户端上传新 VEK 下的条目密文和附件 DEK 包装，提交时在事务内替换数据、信封并增加 password_version。其他设备检测到 rekey 事件后需使用新密码解锁并重建本地状态。

## 账户与附件

邮箱验证码账户可拥有多个密码库和多设备会话。用户可撤销设备会话；解绑、注销和邮箱转移由敏感操作验证码保护。当前是单用户的个人多设备同步，没有家庭成员、共享库或逐条目授权模型。

服务端附件 API 采用暂存上传、校验摘要、登记元数据、R2 对象提交的流程。MariaDB 保存附件 UUID、所属卡片 UUID、R2 object_key、密文摘要和 DEK 包装；原生客户端当前仍将附件嵌入本地加密库，独立云附件同步尚未完整接入。删除卡片会在事务内删除附件登记，R2 清理失败由维护任务补偿。

网站目录由 websites 和 website_domains 提供公开名称、域名映射和图标元数据；图标按摘要寻址存入 R2。站点查询不应把域名写入应用日志。

## API 与运行

公开 API 的当前路径、请求字段及错误行为以[服务端 API 与运维说明](README.md)和 Go 路由实现为准。生产入口为 Cloudflare → Nginx → Go API；MariaDB 通过私网 TLS 访问；每日维护任务执行到期清理、日志保留、附件清扫、计数核对和审计保留。

Cloudflare Worker 的 TypeScript 代码与 Go API 共用 MariaDB 初始化 DDL，保留作回退实现，不是当前生产请求处理路径。Worker 部署细节和 Go API 部署检查分别见 [Cloud/README.md](README.md) 与 [api/README.md](api/README.md)。

## 当前缺口与待讨论

- UserProfile 已进入本地数据模型，RowSync 使用 kind=3；当前 Go API 与 Worker 只接受 kind=1/2，个人资料的云同步尚未实现。存储方案待定，见 [DATABASE.md](DATABASE.md)。
- 独立附件云存储的服务端接口已实现，原生客户端尚未将附件生命周期接入该接口。
- 服务端提供只读运营统计，但客户端没有可配置服务器地址或自托管切换流程。
- /v2 兼容别名的下线时机尚未确定；下线前需要用客户端最低支持版本和实际请求数据评估。

## 维护入口

- 生产 API：Cloud/api
- 回退 Worker：Cloud/worker
- MariaDB 初始化 DDL：Cloud/worker/sql/0001_init.sql
- 隔离 Go API 集成测试：Cloud/api/compose.test.yaml
- Worker 测试：Cloud/TESTING.md
- 部署与生产检查：Cloud/api/README.md
