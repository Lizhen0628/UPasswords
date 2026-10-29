-- Additive migration; encrypted conflict candidates are retained outside live item rows.

ALTER TABLE vault_items
  ADD COLUMN IF NOT EXISTS origin_session_id VARCHAR(32) NULL AFTER updated_ms,
  ADD COLUMN IF NOT EXISTS origin_device_name VARCHAR(128) NOT NULL DEFAULT '' AFTER origin_session_id,
  ADD COLUMN IF NOT EXISTS origin_platform VARCHAR(16) NOT NULL DEFAULT 'other' AFTER origin_device_name;

ALTER TABLE vault_user_profiles
  ADD COLUMN IF NOT EXISTS origin_session_id VARCHAR(32) NULL AFTER updated_ms,
  ADD COLUMN IF NOT EXISTS origin_device_name VARCHAR(128) NOT NULL DEFAULT '' AFTER origin_session_id,
  ADD COLUMN IF NOT EXISTS origin_platform VARCHAR(16) NOT NULL DEFAULT 'other' AFTER origin_device_name;

CREATE OR REPLACE VIEW vault_sync_items AS
SELECT vault_id,item_uuid,kind,revision,body,body_sha256,body_bytes,modified_ms,created_ms,updated_ms,
       origin_session_id,origin_device_name,origin_platform
FROM vault_items
UNION ALL
SELECT vault_id,item_uuid,kind,revision,body,body_sha256,body_bytes,modified_ms,created_ms,updated_ms,
       origin_session_id,origin_device_name,origin_platform
FROM vault_user_profiles;

CREATE TABLE IF NOT EXISTS item_conflicts (
  conflict_id     VARCHAR(32) NOT NULL,
  vault_id        VARCHAR(32) NOT NULL,
  item_uuid       CHAR(36) NOT NULL,
  base_revision   BIGINT UNSIGNED NOT NULL,
  current_revision BIGINT UNSIGNED NOT NULL,
  generation      BIGINT UNSIGNED NOT NULL DEFAULT 0,
  status          VARCHAR(16) NOT NULL DEFAULT 'open',
  created_ms      BIGINT NOT NULL,
  updated_ms      BIGINT NOT NULL,
  resolved_ms     BIGINT NULL,
  expires_ms      BIGINT NULL,
  PRIMARY KEY (conflict_id),
  KEY idx_conflicts_pending (vault_id, status, updated_ms),
  KEY idx_conflicts_item (vault_id, item_uuid, status),
  CONSTRAINT fk_item_conflicts_vault FOREIGN KEY (vault_id) REFERENCES vaults (vault_id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS item_conflict_candidates (
  candidate_id       VARCHAR(32) NOT NULL,
  conflict_id        VARCHAR(32) NOT NULL,
  kind               TINYINT NOT NULL,
  op                 TINYINT NOT NULL,
  revision           BIGINT UNSIGNED NOT NULL,
  body               MEDIUMBLOB NULL,
  body_sha256        CHAR(64) NULL,
  modified_ms        BIGINT NOT NULL,
  source_session_id  VARCHAR(32) NULL,
  source_device_name VARCHAR(128) NOT NULL DEFAULT '',
  source_platform    VARCHAR(16) NOT NULL DEFAULT 'other',
  committed_ms       BIGINT NOT NULL,
  PRIMARY KEY (conflict_id, candidate_id),
  KEY idx_conflict_candidates (conflict_id, committed_ms),
  CONSTRAINT fk_conflict_candidate_set FOREIGN KEY (conflict_id) REFERENCES item_conflicts (conflict_id) ON DELETE CASCADE,
  CONSTRAINT chk_conflict_candidate_kind CHECK (kind IN (1, 2, 3)),
  CONSTRAINT chk_conflict_candidate_op CHECK (op IN (1, 2))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
