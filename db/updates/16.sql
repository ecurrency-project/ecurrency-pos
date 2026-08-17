ALTER TABLE `peer` ADD COLUMN hostname varchar(64);
ALTER TABLE `peer` ADD COLUMN hostname_verified smallint unsigned NOT NULL DEFAULT 0;
ALTER TABLE `peer` ADD COLUMN hostname_check_time int unsigned;
