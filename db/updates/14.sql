ALTER TABLE my_address ADD COLUMN deleg_pubkeyhash binary(32) DEFAULT NULL;

CREATE TABLE `staking_key` (
  id          integer NOT NULL AUTO_INCREMENT PRIMARY KEY,
  private_key blob(4096)   NOT NULL, -- WIF, or encrypted with the wallet master key (see QBitcoin::Wallet)
  pubkey      blob(2048)   NOT NULL,
  algo        int unsigned NOT NULL DEFAULT 1
);

CREATE TABLE `delegation` (
  address          varchar(255) NOT NULL PRIMARY KEY,
  staking_key_id   integer      NOT NULL,
  owner_pubkeyhash binary(32)   NOT NULL,
  FOREIGN KEY (staking_key_id) REFERENCES `staking_key` (id) ON DELETE CASCADE
);
