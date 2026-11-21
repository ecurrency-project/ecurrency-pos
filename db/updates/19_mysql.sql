-- Value and scripthash length of the outputs spent by the stakes of the slashing evidence.
-- The transactions stored before have no such data, their rows get an empty value.
ALTER TABLE `slashing`
  ADD COLUMN prevouts1 longblob NOT NULL AFTER raw1,
  ADD COLUMN prevouts2 longblob NOT NULL AFTER raw2;
