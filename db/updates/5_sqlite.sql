PRAGMA foreign_keys=off;
BEGIN TRANSACTION;
CREATE TABLE `new_transaction` (
  id integer NOT NULL PRIMARY KEY, -- "integer" (signed) required for sqlite autoincrement
  hash binary(32) NOT NULL,
  block_height int unsigned NOT NULL,
  block_pos smallint unsigned NOT NULL,
  tx_type smallint unsigned NOT NULL DEFAULT 1,
  token_id integer DEFAULT NULL,
  size int unsigned NOT NULL,
  fee bigint signed NOT NULL,
  FOREIGN KEY (block_height) REFERENCES `block`       (height) ON DELETE CASCADE,
  FOREIGN KEY (token_id)     REFERENCES `transaction` (id)     ON DELETE SET NULL
);
INSERT INTO `new_transaction` (id, hash, block_height, block_pos, tx_type, size, fee) SELECT id, hash, block_height, block_pos, tx_type, size, fee FROM `transaction`;
DROP TABLE `transaction`;
ALTER TABLE `new_transaction` RENAME TO `transaction`;
CREATE UNIQUE INDEX `tx_hash` ON `transaction` (hash);
CREATE UNIQUE INDEX `tx_block_height_pos` ON `transaction` (block_height, block_pos);
COMMIT;
PRAGMA foreign_keys=on;
