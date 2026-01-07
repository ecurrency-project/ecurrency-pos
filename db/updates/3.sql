ALTER TABLE my_address ADD COLUMN staked int unsigned NOT NULL DEFAULT 0;
UPDATE my_address SET staked = 1;
