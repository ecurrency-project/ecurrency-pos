DROP INDEX `tx_out`;
CREATE INDEX `tx_out` ON `txo` (tx_out, scripthash);
