ALTER TABLE block ADD COLUMN size int unsigned NOT NULL DEFAULT 0;
ALTER TABLE block ADD COLUMN min_fee bigint unsigned NOT NULL DEFAULT 0;
UPDATE block SET size = ( SELECT COALESCE(SUM(t.size), 0) FROM `transaction` t WHERE t.block_height = block.height );
