ALTER TABLE `peer` ADD COLUMN `last_success_time` int unsigned;
ALTER TABLE `peer` ADD COLUMN `last_fail_time` int unsigned;
ALTER TABLE `peer` ADD COLUMN `hidden` smallint unsigned NOT NULL DEFAULT 0;
