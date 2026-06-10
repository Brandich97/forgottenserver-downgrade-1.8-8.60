function onUpdateDatabase()
	logMigration("Updating database to version 48 (WAL table for crash-safe async saves)")

	return db.query([[
		CREATE TABLE IF NOT EXISTS `player_save_async_pending` (
			`guid` INT NOT NULL,
			`query_index` INT UNSIGNED NOT NULL,
			`query_text` LONGBLOB NOT NULL,
			`created_at` BIGINT NOT NULL,
			PRIMARY KEY (`guid`, `query_index`),
			FOREIGN KEY (`guid`) REFERENCES `players`(`id`) ON DELETE CASCADE
		) ENGINE=InnoDB
	]])
end