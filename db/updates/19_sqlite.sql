-- Value and scripthash length of the outputs spent by the stakes of the slashing evidence.
-- sqlite can not add a not last column, so the table is recreated.
-- The transactions stored before have no such data, their rows get an empty value.
CREATE TABLE `slashing_new` (
  tx_id      integer NOT NULL PRIMARY KEY,
  timeslot   int unsigned NOT NULL,
  prev_hash1 binary(32) NOT NULL,
  digest1    binary(32) NOT NULL,
  raw1       longblob   NOT NULL,
  prevouts1  longblob   NOT NULL,
  prev_hash2 binary(32) NOT NULL,
  digest2    binary(32) NOT NULL,
  raw2       longblob   NOT NULL,
  prevouts2  longblob   NOT NULL,
  FOREIGN KEY (tx_id) REFERENCES `transaction` (id) ON DELETE CASCADE
);
INSERT INTO `slashing_new` SELECT tx_id, timeslot, prev_hash1, digest1, raw1, x'', prev_hash2, digest2, raw2, x'' FROM `slashing`;
DROP TABLE `slashing`;
ALTER TABLE `slashing_new` RENAME TO `slashing`;
