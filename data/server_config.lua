-- Server-only configuration.
-- MyAAC reads config.lua, so keep advanced Lua values and server-only toggles here.

-- Dual Wielding
-- NOTE: dualWieldingSpeedRate = 200 means dual-wielding attacks twice as fast
-- dualWieldingDamageRate = 60 means each hit deals 60% of normal damage
-- dualWieldingMode = "allweapons" allows any melee weapon to dual-wield
-- dualWieldingMode = "itemxml" requires <attribute key="dualwielding" value="true"/> on weapons
allowDualWielding = false
dualWieldingSpeedRate = 200
dualWieldingDamageRate = 60
dualWieldingMode = "allweapons"

-- Reset System
-- Enable or disable the full reset system.
resetssystem = true

-- Visual display customization
modifyDamageInK = false
modifyExpInK = false
defaultExpColor = "white"
defaultHealthDisplay = "real"

-- Raid spawn file generation
-- When a raid in data/raids/raids.xml has spawnFile="file.xml", successful
-- singlespawn/areaspawn monsters are exported to data/raids/file.xml.
raidSpawnFileEnabled = true
raidSpawnFileSpawntime = 30
raidSpawnFileIncludeDirection = false
