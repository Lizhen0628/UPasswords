ALTER TABLE item_changes
  ADD COLUMN IF NOT EXISTS resolved_item_uuid CHAR(36) NULL AFTER item_uuid,
  ADD COLUMN IF NOT EXISTS conflict_id VARCHAR(32) NULL AFTER resolved_item_uuid,
  ADD COLUMN IF NOT EXISTS base_revision BIGINT UNSIGNED NULL AFTER conflict_id,
  ADD COLUMN IF NOT EXISTS winner_candidate_id VARCHAR(32) NULL AFTER base_revision,
  ADD COLUMN IF NOT EXISTS winner_kind TINYINT NULL AFTER winner_candidate_id,
  ADD COLUMN IF NOT EXISTS winner_op TINYINT NULL AFTER winner_kind;
