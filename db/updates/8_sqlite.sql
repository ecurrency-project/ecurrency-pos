PRAGMA foreign_keys=off;
BEGIN TRANSACTION;
CREATE TABLE `tag` (
  id integer NOT NULL PRIMARY KEY,
  tag varchar(64) NOT NULL UNIQUE
);

CREATE TABLE `new_my_address` (
  address     varchar(255) NOT NULL PRIMARY KEY,
  private_key blob(4096)   NOT NULL, -- TODO: encrypted
  algo        int unsigned NOT NULL DEFAULT 1,
  staked      int unsigned NOT NULL DEFAULT 0,
  tag_id      integer DEFAULT NULL,
  FOREIGN KEY (tag_id) REFERENCES `tag` (id) ON DELETE SET NULL
);
INSERT INTO `new_my_address` (address, private_key, algo, staked) SELECT address, private_key, algo, staked FROM `my_address`;
DROP TABLE `my_address`;
ALTER TABLE `new_my_address` RENAME TO `my_address`;
COMMIT;
PRAGMA foreign_keys=on;
