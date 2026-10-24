# Cloud — UPasswords 云同步服务

项目开发版本统一为 **v1**。生产 API 是 `api/` 中的 Go + chi 服务；数据库设计见
[`DATABASE.md`](DATABASE.md)，运行结构见 [`DESIGN.md`](DESIGN.md)，测试与人工验收见
[`TESTING.md`](TESTING.md)。服务端不解密密码库条目：MariaDB 保存行级密文和同步元数据，
Cloudflare R2 保存附件密文与网站目录图标。
本次云资源退役的核查结果与保留项见 [`RETIREMENT.md`](RETIREMENT.md)。

## 组成

云 API 部署于 `service-admin`，由 Docker Compose 管理。MariaDB 继续位于内网数据库主机，
API 通过私网 TLS 连接；Nginx 在现有 Docker 网络中将 `api.upasswords.com` 请求转发到
仅绑定回环地址的 API。附件与网站图标保存在 R2，验证码邮件由 163 SMTP 经 TLS 发送。

| 组件 | 说明 |
|---|---|
| Go + chi API | `api/{cmd,internal}`；主路径 `/v1`，保留 `/v2` 兼容别名 |
| MariaDB 11.4 | 自管数据库 `upasswords`；初始化 DDL 与后续迁移位于 `database/` |
| Cloudflare R2 | `upasswords` 桶保存附件密文 `vaults/<id>/attachments/…` 与目录图标 `sites/icons/<sha256>` |
| SMTP | `smtp.163.com:465`；验证码邮件回复地址按用途设置 |
| 每日维护 | Go Compose scheduler 于 04:00 UTC 执行到期清除、变更日志保留、改密暂存清理、附件孤儿清扫、计数核对和审计保留 |

## 隐私边界

- 库主密码、VEK 与条目明文不离开设备；服务端仅接收逐条目密文、哈希和同步元数据。
- `APP_KEK` 用于加密账户邮箱和密码库信封；数据库仅以 HMAC 邮箱键查询用户。
- 会话令牌只以 SHA-256 摘要保存；验证码使用键控摘要、单活跃码、次数限制与速率限制。
- 泄漏检测只提交 SHA-1 前缀，由 API 代理到 HIBP；站点域名和查询前缀不写入应用日志。

## API

客户端使用 `/v1/`；`/v2/` 为兼容旧客户端的别名。能力协商中的 `version: 2` 是行级同步
协议版本，与产品开发版本和 HTTP 路径版本相互独立。

```text
GET  /v1/                                      能力协商
POST /v1/auth/code        {email, purpose?}    发验证码
POST /v1/auth/verify      {email, code, ...}   登录并签发会话
GET  /v1/auth/sessions    Bearer               查看设备会话
PATCH /v1/auth/session   {deviceName}          重命名当前设备
DELETE /v1/auth/session  Bearer                撤销当前会话
DELETE /v1/auth/sessions/{id}                  撤销指定设备
DELETE /v1/account       {code}                注销账户
GET/POST /v1/vaults                           列出/创建密码库
GET/PATCH/DELETE /v1/vaults/{id}               读取/重命名/删除密码库
GET  /v1/vaults/{id}/seq                       同步序列与密码版本
POST /v1/vaults/{id}/transfer                  双验证码换绑
POST /v1/vaults/{id}/items                     批量 CAS 写入密文条目
GET  /v1/vaults/{id}/changes                   增量下行
GET  /v1/vaults/{id}/items                     全量 keyset 分页
PUT/GET/DELETE /v1/vaults/{id}/attachments/{uuid}  暂存/下载/删除附件
POST /v1/vaults/{id}/attachments/{uuid}/commit     发布附件
POST /v1/vaults/{id}/rekey/begin               开始改密
POST /v1/vaults/{id}/rekey/{rekeyId}/chunk     暂存改密数据
POST /v1/vaults/{id}/rekey/{rekeyId}/commit    原子提交改密
DELETE /v1/vaults/{id}/rekey/{rekeyId}        放弃改密
GET  /v1/sites/lookup                          查询网站目录
GET  /v1/sites/icon/{sha256}                   获取目录图标
POST /v1/admin/sites                            批量更新目录
GET  /v1/breach/range/{prefix}                 泄漏检测代理
GET  /v1/admin/stats                            只读运营统计
```

## 测试与运维

在 `Cloud/api` 运行隔离 MariaDB 集成测试、race 检查和 `go vet`：

```sh
docker compose -f compose.test.yaml up --abort-on-container-exit --exit-code-from test
```

测试数据库使用临时存储，测试代码只允许名称以 `_test` 结尾的数据库。生产配置、依赖检查、
Go 镜像发布与回滚步骤见 [`api/README.md`](api/README.md)。初始化 DDL 和未来按序迁移
由数据库管理员通过 `database/` 中的脚本应用；API 运行账号不持有 DDL 权限。

生产恢复使用已保存的 Go API 镜像和 MariaDB 备份。数据库恢复会覆盖备份时间点之后的数据库
写入；R2 对象属于独立存储，须按其自身备份策略处理。Cloudflare 的 API DNS、TLS/WAF 与
仍由 Go API 使用的 R2 桶继续保留。
