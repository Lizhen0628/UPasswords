-- UPasswords v1 full DDL (MariaDB 11.4, utf8mb4, InnoDB)
-- 约定:时间一律 BIGINT Unix 毫秒(与客户端 Card 时间戳同单位,服务端签发);
-- 外键 users→sessions/vaults、vaults→items/changes/attachments 均 ON DELETE CASCADE;
-- attachments.card_uuid 为逻辑引用(条目体是密文,无法建 FK,孤儿由 cron 清扫)。
-- 本文件幂等(IF NOT EXISTS),可重复执行;建库与账号由部署脚本另行执行。

CREATE TABLE IF NOT EXISTS users (
  id                 VARCHAR(32)  NOT NULL,             -- 随机 128bit hex
  email_hmc          VARCHAR(128) NOT NULL,             -- HMAC(APP_KEK, 规范化邮箱) 查询键
  email_enc          TEXT         NULL,                 -- AES-GCM(APP_KEK, 邮箱)
  state              VARCHAR(16)  NOT NULL DEFAULT 'active',
  plan               VARCHAR(16)  NOT NULL DEFAULT 'normal',
  totp_secret        TEXT         NULL,                 -- 规划:同样 APP_KEK 加密
  created_ms         BIGINT       NOT NULL,
  last_login_ms      BIGINT       NULL,
  deregistered_at_ms BIGINT       NULL,                 -- 注销 30 天物理清除排程
  PRIMARY KEY (id),
  UNIQUE KEY uq_users_email (email_hmc)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS email_codes (
  email_hmc  VARCHAR(128) NOT NULL,                     -- 单活跃码(按 purpose)
  purpose    VARCHAR(16)  NOT NULL DEFAULT 'login',     -- login|sensitive
  code_hash  VARCHAR(128) NOT NULL,                     -- 键控哈希
  ip         VARCHAR(64)  NOT NULL DEFAULT '',
  expires_ms BIGINT       NOT NULL,
  attempts   INT          NOT NULL DEFAULT 0,
  used_ms    BIGINT       NULL,
  created_ms BIGINT       NOT NULL,
  PRIMARY KEY (email_hmc, purpose)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS sessions (
  id           VARCHAR(32)  NOT NULL,
  user_id      VARCHAR(32)  NOT NULL,
  token_hash   CHAR(64)     NOT NULL,                   -- SHA-256 hex(256bit 随机令牌)
  device_name  VARCHAR(128) NOT NULL DEFAULT '',
  platform     VARCHAR(16)  NOT NULL DEFAULT 'other',   -- macos|ios|autofill|ext-*
  created_ms   BIGINT       NOT NULL,
  last_seen_ms BIGINT       NOT NULL,
  expires_ms   BIGINT       NOT NULL,                   -- 90 天滑动
  revoked_ms   BIGINT       NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uq_sessions_token (token_hash),
  KEY idx_sessions_user (user_id, expires_ms),
  CONSTRAINT fk_sessions_user FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS vaults (
  vault_id            VARCHAR(32)  NOT NULL,            -- 随机 hex
  user_id             VARCHAR(32)  NOT NULL,
  name                VARCHAR(64)  NOT NULL,            -- 明文(已决策)
  password_version    BIGINT       NOT NULL DEFAULT 1,  -- 单调,rekey 时 +1
  password_changed_ms BIGINT       NOT NULL,
  envelope_enc        TEXT         NULL,                -- AES-GCM(APP_KEK, .upwkey 信封)
  envelope_changed_ms BIGINT       NULL,
  head_seq            BIGINT UNSIGNED NOT NULL DEFAULT 0, -- 变更日志高水位(便宜轮询)
  changes_floor_seq   BIGINT UNSIGNED NOT NULL DEFAULT 0, -- 日志保留地板(cron 推进)
  item_count          INT  UNSIGNED NOT NULL DEFAULT 0, -- 配额核算(cron 对账自愈)
  attach_bytes        BIGINT UNSIGNED NOT NULL DEFAULT 0,
  created_ms          BIGINT       NOT NULL,
  updated_ms          BIGINT       NOT NULL,
  PRIMARY KEY (vault_id),
  UNIQUE KEY uq_vaults_user_name (user_id, name),
  KEY idx_vaults_user (user_id),
  CONSTRAINT fk_vaults_user FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS vault_items (
  vault_id    VARCHAR(32)  NOT NULL,
  item_uuid   CHAR(36)     NOT NULL,                    -- UUIDv4 客户端生成
  kind        TINYINT      NOT NULL,                    -- 当前 API: 1=card 2=label
  revision    BIGINT UNSIGNED NOT NULL DEFAULT 1,       -- 每次接受写入 +1(CAS)
  body        MEDIUMBLOB   NOT NULL,                    -- VEK AEAD 密文(AAD=vault+uuid)
  body_sha256 CHAR(64)     NOT NULL,
  body_bytes  INT UNSIGNED NOT NULL,
  modified_ms BIGINT       NOT NULL,                    -- 条目自身 mtime(决胜展示)
  created_ms  BIGINT       NOT NULL,
  updated_ms  BIGINT       NOT NULL,                    -- 服务端写入时间
  PRIMARY KEY (vault_id, item_uuid),
  KEY idx_items_fullscan (vault_id, updated_ms, item_uuid),
  CONSTRAINT fk_items_vault FOREIGN KEY (vault_id) REFERENCES vaults (vault_id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS item_changes (
  seq        BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,   -- 全局单调,按 vault 过滤即游标
  vault_id   VARCHAR(32)  NOT NULL,
  item_uuid  CHAR(36)     NOT NULL,                     -- op=rekey 时为空串(库级事件)
  op         TINYINT      NOT NULL,                     -- 1=upsert 2=purge 3=rekey
  revision   BIGINT UNSIGNED NOT NULL,
  session_id VARCHAR(32)  NOT NULL DEFAULT '',
  created_ms BIGINT       NOT NULL,
  PRIMARY KEY (seq),
  KEY idx_changes_vault (vault_id, seq),
  CONSTRAINT fk_changes_vault FOREIGN KEY (vault_id) REFERENCES vaults (vault_id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS attachments (
  vault_id    VARCHAR(32)  NOT NULL,
  attach_uuid CHAR(36)     NOT NULL,                    -- UUIDv4
  card_uuid   CHAR(36)     NOT NULL,                    -- 属主条目(逻辑引用,无 FK)
  object_key  VARCHAR(180) NOT NULL,                    -- R2 路径
  dek_wrapped VARBINARY(256) NOT NULL,                  -- VEK 包裹的附件 DEK
  sha256      CHAR(64)     NOT NULL,                    -- 密文哈希
  bytes       BIGINT UNSIGNED NOT NULL,
  created_ms  BIGINT       NOT NULL,
  PRIMARY KEY (vault_id, attach_uuid),
  KEY idx_attach_card (vault_id, card_uuid),
  CONSTRAINT fk_attach_vault FOREIGN KEY (vault_id) REFERENCES vaults (vault_id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS rekeys (
  rekey_id             VARCHAR(32) NOT NULL,
  vault_id             VARCHAR(32) NOT NULL,            -- 存在未过期行 = 库写锁
  new_envelope_enc     TEXT        NOT NULL,
  new_password_version BIGINT      NOT NULL,
  item_total           INT         NOT NULL,
  dek_total            INT         NOT NULL,
  item_staged          INT         NOT NULL DEFAULT 0,
  dek_staged           INT         NOT NULL DEFAULT 0,
  expires_ms           BIGINT      NOT NULL,            -- TTL 1h,写路径惰性判定+cron 兜底
  created_ms           BIGINT      NOT NULL,
  PRIMARY KEY (rekey_id),
  KEY idx_rekeys_vault (vault_id),
  CONSTRAINT fk_rekeys_vault FOREIGN KEY (vault_id) REFERENCES vaults (vault_id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS rekey_staging (
  rekey_id  VARCHAR(32) NOT NULL,
  item_uuid CHAR(36)    NOT NULL,                       -- 条目 uuid 或附件 uuid
  kind      TINYINT     NOT NULL,                       -- 1=条目体 2=附件 DEK
  payload   MEDIUMBLOB  NOT NULL,                       -- 新 VEK 密文 / 新包裹的 DEK
  sha256    CHAR(64)    NOT NULL,
  PRIMARY KEY (rekey_id, item_uuid),
  CONSTRAINT fk_staging_rekey FOREIGN KEY (rekey_id) REFERENCES rekeys (rekey_id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS audit_log (
  id       BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  user_id  VARCHAR(32) NULL,
  vault_id VARCHAR(32) NULL,
  action   VARCHAR(64) NOT NULL,
  detail   VARCHAR(1024) NOT NULL DEFAULT '',           -- 无 PII
  ts_ms    BIGINT      NOT NULL,
  PRIMARY KEY (id),
  KEY idx_audit_user (user_id, ts_ms)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------- 网站目录(全局非用户数据) ----------

CREATE TABLE IF NOT EXISTS websites (
  site_id        BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  name_zh        VARCHAR(255) NULL,                     -- 可空:无中文名回退英文
  name_en        VARCHAR(255) NOT NULL,
  home_url       VARCHAR(512) NULL,
  icon_sha256    CHAR(64)     NULL,                     -- 内容寻址,R2 去重
  icon_mime      VARCHAR(16)  NULL,
  icon_bytes     INT UNSIGNED NULL,
  icon_updated_ms BIGINT      NULL,
  status         TINYINT      NOT NULL DEFAULT 1,       -- 1=启用 0=下架
  created_ms     BIGINT       NOT NULL,
  updated_ms     BIGINT       NOT NULL,
  PRIMARY KEY (site_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS website_domains (
  domain     VARCHAR(255) NOT NULL,                     -- 规范化小写 host,唯一查询键
  site_id    BIGINT UNSIGNED NOT NULL,
  is_primary TINYINT(1)     NOT NULL DEFAULT 0,
  PRIMARY KEY (domain),
  KEY idx_sitedom_site (site_id),
  CONSTRAINT fk_sitedom_site FOREIGN KEY (site_id) REFERENCES websites (site_id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
