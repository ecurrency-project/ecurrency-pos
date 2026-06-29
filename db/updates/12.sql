CREATE TABLE `slashing` (
  tx_id      integer NOT NULL PRIMARY KEY,
  timeslot   int unsigned NOT NULL,
  prev_hash1 binary(32) NOT NULL,
  digest1    binary(32) NOT NULL,
  raw1       longblob   NOT NULL,
  prev_hash2 binary(32) NOT NULL,
  digest2    binary(32) NOT NULL,
  raw2       longblob   NOT NULL,
  FOREIGN KEY (tx_id) REFERENCES `transaction` (id) ON DELETE CASCADE
);
