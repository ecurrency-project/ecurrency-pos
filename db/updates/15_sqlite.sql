CREATE TABLE `my_address_new` (
  address     varchar(255) NOT NULL PRIMARY KEY,
  private_key blob(4096)   DEFAULT NULL, -- WIF, or encrypted with the wallet master key (see QBitcoin::Wallet)
  pubkey      blob(2048)   DEFAULT NULL,
  algo        int unsigned NOT NULL DEFAULT 1,
  staked      int unsigned NOT NULL DEFAULT 0,
  tag_id      integer DEFAULT NULL,
  deleg_pubkeyhash varbinary(32) DEFAULT NULL, -- hash of the delegate staking pubkey for delegated-staking addresses (20 bytes hash160 pre-quantum, 32 bytes hash256 post-quantum)
  FOREIGN KEY (tag_id) REFERENCES `tag` (id) ON DELETE SET NULL
);
INSERT INTO `my_address_new` SELECT address, private_key, pubkey, algo, staked, tag_id, deleg_pubkeyhash FROM `my_address`;
DROP TABLE `my_address`;
ALTER TABLE `my_address_new` RENAME TO `my_address`;

CREATE TABLE `delegation_new` (
  address          varchar(255) NOT NULL PRIMARY KEY,
  staking_key_id   integer      NOT NULL,
  owner_pubkeyhash varbinary(32) NOT NULL, -- 20 bytes hash160 pre-quantum, 32 bytes hash256 post-quantum
  FOREIGN KEY (staking_key_id) REFERENCES `staking_key` (id) ON DELETE CASCADE
);
INSERT INTO `delegation_new` SELECT address, staking_key_id, owner_pubkeyhash FROM `delegation`;
DROP TABLE `delegation`;
ALTER TABLE `delegation_new` RENAME TO `delegation`;
