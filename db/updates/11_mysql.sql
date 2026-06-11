SET FOREIGN_KEY_CHECKS = 0;
DROP INDEX `tx_out` ON `txo`;
CREATE INDEX `tx_out` ON `txo` (tx_out, scripthash);
SET FOREIGN_KEY_CHECKS = 1;
