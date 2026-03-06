CREATE TABLE `my_address_new` (
  address     varchar(255) NOT NULL PRIMARY KEY,
  private_key blob(4096)   DEFAULT NULL,
  algo        int unsigned NOT NULL DEFAULT 1,
  staked      int unsigned NOT NULL DEFAULT 0
);
INSERT INTO `my_address_new` SELECT address, private_key, 1, staked FROM `my_address`;
DROP TABLE `my_address`;
ALTER TABLE `my_address_new` RENAME TO `my_address`;
