-- sqlite does not create indexes for foreign keys implicitly
CREATE INDEX `tx_token_id` ON `transaction` (token_id) WHERE token_id IS NOT NULL;
CREATE INDEX `txo_scripthash_in` ON `txo` (scripthash, tx_in);
CREATE INDEX `coinbase_btc_block_height` ON `coinbase` (btc_block_height);
