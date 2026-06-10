function onUpdateDatabase()
	logMigration("Updating database to version 47 (Expanded blessings 1-8)")

	-- Add columns individually to avoid failing when columns already exist
	local blessingColumns = {
		"blessings1", "blessings2", "blessings3", "blessings4",
		"blessings5", "blessings6", "blessings7", "blessings8"
	}
	for _, col in ipairs(blessingColumns) do
		db.query("ALTER TABLE `players` ADD COLUMN `" .. col .. "` tinyint unsigned NOT NULL DEFAULT 0")
	end
	return true
end