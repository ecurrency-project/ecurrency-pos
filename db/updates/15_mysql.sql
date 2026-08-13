ALTER TABLE `my_address` MODIFY `deleg_pubkeyhash` varbinary(32) DEFAULT NULL;
ALTER TABLE `delegation` MODIFY `owner_pubkeyhash` varbinary(32) NOT NULL;
