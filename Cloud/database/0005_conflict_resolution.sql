ALTER TABLE item_conflicts
  ADD COLUMN IF NOT EXISTS current_deleted_seq BIGINT UNSIGNED NOT NULL DEFAULT 0 AFTER current_revision,
  ADD COLUMN IF NOT EXISTS selected_candidate_id VARCHAR(32) NULL AFTER resolved_ms,
  ADD COLUMN IF NOT EXISTS resolved_item_uuid CHAR(36) NULL AFTER selected_candidate_id;

ALTER TABLE item_conflict_candidates
  ADD COLUMN IF NOT EXISTS disposition VARCHAR(16) NOT NULL DEFAULT 'pending' AFTER committed_ms,
  ADD COLUMN IF NOT EXISTS expires_ms BIGINT NULL AFTER disposition;

CREATE TABLE IF NOT EXISTS item_tombstones (
  vault_id    VARCHAR(32) NOT NULL,
  item_uuid   CHAR(36) NOT NULL,
  revision    BIGINT UNSIGNED NOT NULL,
  seq         BIGINT UNSIGNED NOT NULL,
  deleted_ms  BIGINT NOT NULL,
  session_id  VARCHAR(32) NULL,
  device_name VARCHAR(128) NOT NULL DEFAULT '',
  platform    VARCHAR(16) NOT NULL DEFAULT 'other',
  PRIMARY KEY (vault_id, item_uuid),
  KEY idx_item_tombstones_seq (vault_id, seq),
  CONSTRAINT fk_item_tombstones_vault FOREIGN KEY (vault_id)
    REFERENCES vaults (vault_id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

INSERT INTO item_tombstones(
  vault_id,item_uuid,revision,seq,deleted_ms,session_id,device_name,platform
)
SELECT c.vault_id,c.item_uuid,c.revision,c.seq,c.created_ms,c.session_id,
       COALESCE(s.device_name,''),COALESCE(s.platform,'other')
FROM item_changes c
JOIN (
  SELECT vault_id,item_uuid,MAX(seq) AS seq
  FROM item_changes
  WHERE op=2
  GROUP BY vault_id,item_uuid
) latest ON latest.vault_id=c.vault_id AND latest.item_uuid=c.item_uuid AND latest.seq=c.seq
LEFT JOIN vault_sync_items i ON i.vault_id=c.vault_id AND i.item_uuid=c.item_uuid
LEFT JOIN sessions s ON s.id=c.session_id
WHERE i.item_uuid IS NULL
ON DUPLICATE KEY UPDATE
  revision=VALUES(revision),seq=VALUES(seq),deleted_ms=VALUES(deleted_ms),
  session_id=VALUES(session_id),device_name=VALUES(device_name),platform=VALUES(platform);
