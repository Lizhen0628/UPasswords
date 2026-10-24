-- Additive migration; apply before starting profile-capable API clients.

-- Personal information has a dedicated encrypted table; names/contact values never become SQL columns.
CREATE TABLE IF NOT EXISTS vault_user_profiles (
  vault_id    VARCHAR(32)  NOT NULL,
  item_uuid   CHAR(36)     NOT NULL,                    -- UUIDv4 客户端生成
  kind        TINYINT      NOT NULL DEFAULT 3 CHECK (kind = 3),                    -- 3=user profile; body is client-side AES-GCM ciphertext
  revision    BIGINT UNSIGNED NOT NULL DEFAULT 1,       -- 每次接受写入 +1(CAS)
  body        MEDIUMBLOB   NOT NULL,                    -- VEK AEAD 密文(AAD=vault+uuid)
  body_sha256 CHAR(64)     NOT NULL,
  body_bytes  INT UNSIGNED NOT NULL,
  modified_ms BIGINT       NOT NULL,                    -- 条目自身 mtime(决胜展示)
  created_ms  BIGINT       NOT NULL,
  updated_ms  BIGINT       NOT NULL,                    -- 服务端写入时间
  PRIMARY KEY (vault_id, item_uuid),
  KEY idx_profiles_fullscan (vault_id, updated_ms, item_uuid),
  CONSTRAINT fk_profiles_vault FOREIGN KEY (vault_id) REFERENCES vaults (vault_id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE OR REPLACE VIEW vault_sync_items AS
SELECT * FROM vault_items
UNION ALL
SELECT * FROM vault_user_profiles;
