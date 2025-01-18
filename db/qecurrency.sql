
CREATE TABLE `block` (
  height int unsigned NOT NULL PRIMARY KEY,
  time int unsigned NOT NULL,
  hash binary(32) NOT NULL,
  size int unsigned NOT NULL,
  weight bigint unsigned NOT NULL,
  upgraded bigint unsigned NOT NULL DEFAULT 0,
  reward_fund bigint unsigned NOT NULL DEFAULT 0,
  min_fee bigint unsigned NOT NULL DEFAULT 0,
  prev_hash binary(32) DEFAULT NULL,
  merkle_root binary(32) NOT NULL
);
CREATE UNIQUE INDEX `block_hash` ON `block` (hash);
CREATE INDEX `block_time` ON `block` (time);

CREATE TABLE `transaction` (
  id integer NOT NULL AUTO_INCREMENT PRIMARY KEY, -- "integer" (signed) required for sqlite autoincrement
  hash binary(32) NOT NULL,
  block_height int unsigned NOT NULL,
  block_pos smallint unsigned NOT NULL,
  tx_type smallint unsigned NOT NULL DEFAULT 1,
  size int unsigned NOT NULL,
  fee bigint signed NOT NULL,
  FOREIGN KEY (block_height) REFERENCES `block` (height) ON DELETE CASCADE
);
CREATE UNIQUE INDEX `tx_hash` ON `transaction` (hash);
CREATE UNIQUE INDEX `tx_block_height_pos` ON `transaction` (block_height, block_pos);

-- Actually these are qbt addresses
CREATE TABLE `redeem_script` (
  id integer NOT NULL AUTO_INCREMENT PRIMARY KEY,
  hash varbinary(32) NOT NULL,
  script blob NULL
);
CREATE UNIQUE INDEX `redeem_script_hash` ON `redeem_script` (hash);

CREATE TABLE `txo` (
  value      bigint unsigned NOT NULL,
  num        int unsigned NOT NULL,
  tx_in      integer NOT NULL,
  tx_out     integer DEFAULT NULL,
  scripthash integer NOT NULL,
  siglist    blob DEFAULT NULL,
  data       blob NOT NULL DEFAULT '',
  PRIMARY KEY (tx_in, num),
  FOREIGN KEY (tx_in)      REFERENCES `transaction`   (id) ON DELETE CASCADE,
  FOREIGN KEY (tx_out)     REFERENCES `transaction`   (id) ON DELETE SET NULL,
  FOREIGN KEY (scripthash) REFERENCES `redeem_script` (id) ON DELETE RESTRICT
);
CREATE INDEX `tx_out` ON `txo` (tx_out);

CREATE TABLE `my_address` (
  address     varchar(255) NOT NULL PRIMARY KEY,
  private_key blob(4096)   NOT NULL -- TODO: encrypted
);

CREATE TABLE `btc_block` (
  height int unsigned DEFAULT NULL,
  time int unsigned NOT NULL,
  bits int unsigned NOT NULL,
  nonce int unsigned NOT NULL,
  version int unsigned NOT NULL,
  chainwork double unsigned NOT NULL,
  scanned int unsigned NOT NULL,
  hash binary(32) NOT NULL,
  prev_hash binary(32) DEFAULT NULL,
  merkle_root binary(32) NOT NULL
);
CREATE UNIQUE INDEX `btc_height` ON `btc_block` (height);
CREATE UNIQUE INDEX `btc_hash`   ON `btc_block` (hash);
CREATE        INDEX `scanned`    ON `btc_block` (scanned, height);

CREATE TABLE `coinbase` (
  btc_block_height int unsigned DEFAULT NULL,
  btc_tx_num smallint unsigned DEFAULT NULL,
  btc_out_num smallint unsigned NOT NULL,
  btc_tx_hash binary(32) NOT NULL,
  merkle_path blob(512) NOT NULL, -- 16-level btree with 32-byte (256-bit) hashes
  btc_tx_data longblob NOT NULL, -- or 'blob' for sqlite
  value bigint unsigned NOT NULL,
  scripthash integer NOT NULL,
  tx_out integer DEFAULT NULL,
  upgrade_level integer DEFAULT NULL,
  PRIMARY KEY (btc_tx_hash, btc_out_num),
  FOREIGN KEY (btc_block_height) REFERENCES `btc_block`     (height) ON DELETE CASCADE,
  FOREIGN KEY (tx_out)           REFERENCES `transaction`   (id)     ON DELETE SET NULL,
  FOREIGN KEY (scripthash)       REFERENCES `redeem_script` (id)     ON DELETE RESTRICT
);
CREATE INDEX `coinbase_tx_out` ON `coinbase` (tx_out);

CREATE TABLE `peer` (
  type_id smallint unsigned NOT NULL,
  status smallint unsigned NOT NULL DEFAULT 0,
  ip binary(16) NOT NULL,
  port smallint unsigned,
  create_time int unsigned NOT NULL,
  update_time int unsigned NOT NULL,
  software varchar(256),
  features bigint unsigned NOT NULL DEFAULT 0,
  bytes_sent bigint unsigned NOT NULL DEFAULT 0,
  bytes_recv bigint unsigned NOT NULL DEFAULT 0,
  obj_sent int unsigned NOT NULL DEFAULT 0,
  obj_recv bigint unsigned NOT NULL DEFAULT 0,
  ping_min_ms int unsigned,
  ping_avg_ms int unsigned,
  reputation float NOT NULL DEFAULT 0,
  failed_connects int NOT NULL DEFAULT 0,
  pinned smallint unsigned NOT NULL DEFAULT 0,
  PRIMARY KEY (type_id, ip)
);
CREATE INDEX `peer_reputation` ON `peer` (reputation);

CREATE TABLE `version` (
  time timestamp not null DEFAULT CURRENT_TIMESTAMP,
  version int unsigned NOT NULL,
  PRIMARY KEY (version)
);
