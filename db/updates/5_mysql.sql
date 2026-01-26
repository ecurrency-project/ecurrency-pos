ALTER TABLE `transaction`
    ADD COLUMN token_id integer DEFAULT NULL,
    ADD FOREIGN KEY (token_id) REFERENCES `transaction` (id) ON DELETE SET NULL;
