ALTER TABLE item_changes
  ADD COLUMN IF NOT EXISTS resolution_type TINYINT UNSIGNED NOT NULL DEFAULT 0 AFTER winner_op;

UPDATE item_changes
SET resolution_type=1 WHERE op=4 AND resolution_type=0;
