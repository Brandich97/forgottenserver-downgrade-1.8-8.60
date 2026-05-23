// Copyright 2023 The Forgotten Server Authors. All rights reserved.
// Use of this source code is governed by the GPL-2.0 License that can be found in the LICENSE file.

#include "otpch.h"

#include "raids.h"

#include "configmanager.h"
#include "game.h"
#include "monster.h"
#include "pugicast.h"
#include "scheduler.h"
#include "logger.h"
#include <fmt/format.h>

#include <filesystem>

extern Game g_game;

namespace {

std::string getRaidSpawnFilePath(std::string_view spawnFile)
{
	if (spawnFile.empty()) {
		return {};
	}

	std::filesystem::path relativePath{std::string{spawnFile}};
	if (relativePath.empty() || relativePath.is_absolute()) {
		return {};
	}

	for (const auto& part : relativePath) {
		if (part == "..") {
			return {};
		}
	}

	if (!relativePath.has_extension()) {
		relativePath += ".xml";
	}

	return (std::filesystem::path{"data/raids"} / relativePath).generic_string();
}

int32_t getRaidSpawnFileSpawntime()
{
	return std::max<int64_t>(10, getInteger(ConfigManager::RAID_SPAWN_FILE_SPAWNTIME));
}

} // namespace

Raids::Raids() { }

Raids::~Raids() = default;

bool Raids::loadFromXml()
{
	if (isLoaded()) {
		return true;
	}

	pugi::xml_document doc;
	pugi::xml_parse_result result = doc.load_file("data/raids/raids.xml");
	if (!result) {
		printXMLError("Error - Raids::loadFromXml", "data/raids/raids.xml", result);
		return false;
	}

	for (auto raidNode : doc.child("raids").children()) {
		std::string name, file, spawnFile;
		uint32_t interval, margin;

		pugi::xml_attribute attr;
		if ((attr = raidNode.attribute("name"))) {
			name = attr.as_string();
		} else {
			LOG_ERROR("[Error - Raids::loadFromXml] Name tag missing for raid");
			continue;
		}

		if ((attr = raidNode.attribute("file"))) {
			file = attr.as_string();
		} else {
			file = fmt::format("raids/{:s}.xml", name);
			LOG_WARN(fmt::format("[Warning - Raids::loadFromXml] File tag missing for raid {}. Using default: {}", name, file));
		}

		interval = pugi::cast<uint32_t>(raidNode.attribute("interval2").value()) * 60;
		if (interval == 0) {
			LOG_ERROR(fmt::format("[Error - Raids::loadFromXml] interval2 tag missing or zero (would divide by 0) for raid: {}", name));
			continue;
		}

		if ((attr = raidNode.attribute("margin"))) {
			margin = pugi::cast<uint32_t>(attr.value()) * 60 * 1000;
		} else {
			LOG_WARN(fmt::format("[Warning - Raids::loadFromXml] margin tag missing for raid: {}", name));
			margin = 0;
		}

		bool repeat;
		if ((attr = raidNode.attribute("repeat"))) {
			repeat = booleanString(attr.as_string());
		} else {
			repeat = false;
		}

		if ((attr = raidNode.attribute("spawnFile")) && getBoolean(ConfigManager::RAID_SPAWN_FILE_ENABLED)) {
			spawnFile = getRaidSpawnFilePath(attr.as_string());
			if (spawnFile.empty()) {
				LOG_ERROR(fmt::format("[Error - Raids::loadFromXml] Invalid spawnFile path for raid: {}", name));
				continue;
			}
		}

		auto newRaid = std::make_unique<Raid>(name, interval, margin, repeat, std::move(spawnFile));
		if (newRaid->loadFromXml("data/raids/" + file)) {
			raidList.push_back(std::move(newRaid));
		} else {
			LOG_ERROR(fmt::format("[Error - Raids::loadFromXml] Failed to load raid: {}", name));
		}
	}

	loaded = true;
	return true;
}

inline constexpr int32_t MAX_RAND_RANGE = 10000000;

bool Raids::startup()
{
	if (!isLoaded() || isStarted()) {
		return false;
	}

	setLastRaidEnd(OTSYS_TIME());

	// Make sure not to duplicate the event.
    if (checkRaidsEvent != 0) {
        g_scheduler.stopEvent(checkRaidsEvent);
        checkRaidsEvent = 0;
    }

	checkRaidsEvent =
	    g_scheduler.addEvent(createSchedulerTask(CHECK_RAIDS_INTERVAL * 1000, [this]() { checkRaids(); }));

	started = true;
	return started;
}

void Raids::shutdown()
{
    // Cancel the recursive verification event.
    if (checkRaidsEvent != 0) {
        g_scheduler.stopEvent(checkRaidsEvent);
        checkRaidsEvent = 0;
    }
    
    // For any running RAID
    if (running) {
        running->stopEvents();
        running = nullptr;
    }

	runningNonRepeatRaid.reset();
    
    // Clear the raid list.
    raidList.clear();
    
    LOG_INFO("[Raids] Shutdown completed");
}

void Raids::checkRaids()
{
	clearCompletedRunningRaid();

	if (!getRunning()) {
		uint64_t now = OTSYS_TIME();

		auto it = std::find_if(raidList.begin(), raidList.end(), [this, now](const auto& raidPtr) {
			Raid* raid = raidPtr.get();
			if (now >= (getLastRaidEnd() + raid->getMargin())) {
				if (((MAX_RAND_RANGE * CHECK_RAIDS_INTERVAL) / raid->getInterval()) >=
				    static_cast<uint32_t>(uniform_random(0, MAX_RAND_RANGE))) {
					return true;
				}
			}
			return false;
		});

		if (it != raidList.end()) {
			Raid* raid = it->get();
			if (!raid->canBeRepeated()) {
				runningNonRepeatRaid = std::move(*it);
				raidList.erase(it);
				raid = runningNonRepeatRaid.get();
			}

			setRunning(raid);
			raid->startRaid();
		}
	}

	// FIX: Cancel previous event before scheduling a new one
    if (checkRaidsEvent != 0) {
        g_scheduler.stopEvent(checkRaidsEvent);
        checkRaidsEvent = 0;
    }

	checkRaidsEvent =
	    g_scheduler.addEvent(createSchedulerTask(CHECK_RAIDS_INTERVAL * 1000, [this]() { checkRaids(); }));
}

void Raids::clear()
{
	g_scheduler.stopEvent(checkRaidsEvent);
	checkRaidsEvent = 0;

	if (runningNonRepeatRaid) {
		runningNonRepeatRaid->stopEvents();
		runningNonRepeatRaid.reset();
	}

	for (const auto& raid : raidList) {
		raid->stopEvents();
	}
	raidList.clear();

	loaded = false;
	started = false;
	running = nullptr;
	lastRaidEnd = 0;

	scriptInterface.reInitState();
}

void Raids::clearCompletedRunningRaid()
{
	if (!running && runningNonRepeatRaid) {
		runningNonRepeatRaid.reset();
	}
}

bool Raids::reload()
{
	clear();
	return loadFromXml();
}

Raid* Raids::getRaidByName(std::string_view name)
{
	for (const auto& raid : raidList) {
		if (caseInsensitiveEqual(raid->getName(), name)) {
			return raid.get();
		}
	}
	return nullptr;
}

Raid::~Raid() = default;

bool Raid::loadFromXml(const std::string& filename)
{
	if (isLoaded()) {
		return true;
	}

	pugi::xml_document doc;
	pugi::xml_parse_result result = doc.load_file(filename.c_str());
	if (!result) {
		printXMLError("Error - Raid::loadFromXml", filename, result);
		return false;
	}

	for (const auto& eventNode : doc.child("raid").children()) {
		std::unique_ptr<RaidEvent> event;
		if (caseInsensitiveEqual(eventNode.name(), "announce")) {
			event = std::make_unique<AnnounceEvent>();
		} else if (caseInsensitiveEqual(eventNode.name(), "singlespawn")) {
			event = std::make_unique<SingleSpawnEvent>();
		} else if (caseInsensitiveEqual(eventNode.name(), "areaspawn")) {
			event = std::make_unique<AreaSpawnEvent>();
		} else if (caseInsensitiveEqual(eventNode.name(), "script")) {
			event = std::make_unique<ScriptEvent>(&g_game.raids.getScriptInterface());
		} else {
			continue;
		}

		if (event->configureRaidEvent(eventNode)) {
			raidEvents.push_back(std::move(event));
		} else {
			LOG_ERROR(fmt::format("[Error - Raid::loadFromXml] In file ({}), eventNode: {}", filename, eventNode.name()));
		}
	}

	// sort by delay time
	std::ranges::sort(raidEvents,
	          [](const auto& lhs, const auto& rhs) { return lhs->getDelay() < rhs->getDelay(); });

	loaded = true;
	return true;
}

void Raid::startRaid()
{
	spawnFileEntries.clear();
	spawnFileRecording = !spawnFile.empty() && getBoolean(ConfigManager::RAID_SPAWN_FILE_ENABLED);

	RaidEvent* raidEvent = getNextRaidEvent();
	if (raidEvent) {
		state = RAIDSTATE_EXECUTING;
		nextEventEvent = g_scheduler.addEvent(
		    createSchedulerTask(raidEvent->getDelay(), ([this, raidEvent]() { executeRaidEvent(raidEvent); })));
	} else {
		resetRaid();
	}
}

void Raid::executeRaidEvent(RaidEvent* raidEvent)
{
	nextEventEvent = 0;

	if (raidEvent->executeEvent()) {
		nextEvent++;
		RaidEvent* newRaidEvent = getNextRaidEvent();

		if (newRaidEvent) {
			uint32_t ticks = static_cast<uint32_t>(
			    std::max<int32_t>(RAID_MINTICKS, newRaidEvent->getDelay() - raidEvent->getDelay()));
			nextEventEvent =
			    g_scheduler.addEvent(createSchedulerTask(ticks, ([this, newRaidEvent]() { executeRaidEvent(newRaidEvent); })));
		} else {
			resetRaid();
		}
	} else {
		resetRaid();
	}
}

void Raid::resetRaid()
{
	flushSpawnFile();
	nextEvent = 0;
	state = RAIDSTATE_IDLE;
	nextEventEvent = 0;
	g_game.raids.setRunning(nullptr);
	g_game.raids.setLastRaidEnd(OTSYS_TIME());
}

void Raid::stopEvents()
{
	if (nextEventEvent != 0) {
		g_scheduler.stopEvent(nextEventEvent);
		nextEventEvent = 0;
	}
	flushSpawnFile();
}

RaidEvent* Raid::getNextRaidEvent()
{
	if (nextEvent < raidEvents.size()) {
		return raidEvents[nextEvent].get();
	}
	return nullptr;
}

void Raid::recordSpawnFileMonster(std::string_view monsterName, const Position& position, Direction direction)
{
	if (!spawnFileRecording || spawnFile.empty() || !getBoolean(ConfigManager::RAID_SPAWN_FILE_ENABLED)) {
		return;
	}

	spawnFileEntries.emplace_back(monsterName, position, direction);
}

void Raid::flushSpawnFile()
{
	if (!spawnFileRecording) {
		return;
	}

	spawnFileRecording = false;
	if (spawnFile.empty() || !getBoolean(ConfigManager::RAID_SPAWN_FILE_ENABLED)) {
		spawnFileEntries.clear();
		return;
	}

	pugi::xml_document doc;
	auto declaration = doc.prepend_child(pugi::node_declaration);
	declaration.append_attribute("version") = "1.0";

	auto spawnsNode = doc.append_child("spawns");
	struct SpawnGroup
	{
		Position center;
		std::vector<const RaidSpawnFileEntry*> entries;
	};

	std::vector<SpawnGroup> groups;
	for (const RaidSpawnFileEntry& entry : spawnFileEntries) {
		auto groupIt = std::find_if(groups.begin(), groups.end(), [&entry](const SpawnGroup& group) {
			return group.center.z == entry.position.z &&
			       std::abs(static_cast<int32_t>(group.center.x) - static_cast<int32_t>(entry.position.x)) <= 1 &&
			       std::abs(static_cast<int32_t>(group.center.y) - static_cast<int32_t>(entry.position.y)) <= 1;
		});

		if (groupIt == groups.end()) {
			SpawnGroup group;
			group.center = entry.position;
			group.entries.push_back(&entry);
			groups.push_back(std::move(group));
		} else {
			groupIt->entries.push_back(&entry);
		}
	}

	const int32_t spawntime = getRaidSpawnFileSpawntime();
	const bool includeDirection = getBoolean(ConfigManager::RAID_SPAWN_FILE_INCLUDE_DIRECTION);
	for (const SpawnGroup& group : groups) {
		auto spawnNode = spawnsNode.append_child("spawn");
		spawnNode.append_attribute("centerx") = group.center.x;
		spawnNode.append_attribute("centery") = group.center.y;
		spawnNode.append_attribute("centerz") = group.center.z;
		spawnNode.append_attribute("radius") = 1;

		for (const RaidSpawnFileEntry* entry : group.entries) {
			auto monsterNode = spawnNode.append_child("monster");
			monsterNode.append_attribute("name") = entry->monsterName.c_str();
			monsterNode.append_attribute("x") =
			    static_cast<int32_t>(entry->position.x) - static_cast<int32_t>(group.center.x);
			monsterNode.append_attribute("y") =
			    static_cast<int32_t>(entry->position.y) - static_cast<int32_t>(group.center.y);
			monsterNode.append_attribute("z") = entry->position.z;
			monsterNode.append_attribute("spawntime") = spawntime;
			if (includeDirection) {
				monsterNode.append_attribute("direction") = static_cast<uint16_t>(entry->direction);
			}
		}
	}

	std::filesystem::path targetPath{spawnFile};
	std::error_code error;
	if (targetPath.has_parent_path()) {
		std::filesystem::create_directories(targetPath.parent_path(), error);
		if (error) {
			LOG_ERROR(fmt::format("[Error - Raid::flushSpawnFile] Failed to create directory for {}: {}", spawnFile, error.message()));
			spawnFileEntries.clear();
			return;
		}
	}

	std::filesystem::path tempPath = targetPath;
	tempPath += ".tmp";
	if (!doc.save_file(tempPath.string().c_str(), "\t", pugi::format_default, pugi::encoding_utf8)) {
		LOG_ERROR(fmt::format("[Error - Raid::flushSpawnFile] Failed to save raid spawn file: {}", tempPath.generic_string()));
		spawnFileEntries.clear();
		return;
	}

	std::filesystem::remove(targetPath, error);
	error.clear();
	std::filesystem::rename(tempPath, targetPath, error);
	if (error) {
		LOG_ERROR(fmt::format("[Error - Raid::flushSpawnFile] Failed to replace raid spawn file {}: {}", spawnFile, error.message()));
		error.clear();
		std::filesystem::remove(tempPath, error);
		spawnFileEntries.clear();
		return;
	}

	LOG_INFO(fmt::format("[Raid] Wrote {} successful spawn(s) to {}", spawnFileEntries.size(), spawnFile));
	spawnFileEntries.clear();
}

bool RaidEvent::configureRaidEvent(const pugi::xml_node& eventNode)
{
	pugi::xml_attribute delayAttribute = eventNode.attribute("delay");
	if (!delayAttribute) {
		LOG_ERROR("[Error] Raid: delay tag missing.");
		return false;
	}

	delay = std::max<uint32_t>(RAID_MINTICKS, pugi::cast<uint32_t>(delayAttribute.value()));
	return true;
}

bool AnnounceEvent::configureRaidEvent(const pugi::xml_node& eventNode)
{
	if (!RaidEvent::configureRaidEvent(eventNode)) {
		return false;
	}

	pugi::xml_attribute messageAttribute = eventNode.attribute("message");
	if (!messageAttribute) {
		LOG_ERROR("[Error] Raid: message tag missing for announce event.");
		return false;
	}
	message = messageAttribute.as_string();

	pugi::xml_attribute typeAttribute = eventNode.attribute("type");
	if (typeAttribute) {
		std::string tmpStrValue = boost::algorithm::to_lower_copy<std::string>(typeAttribute.as_string());
		if (tmpStrValue == "warning") {
			messageType = MESSAGE_STATUS_WARNING;
		} else if (tmpStrValue == "event") {
			messageType = MESSAGE_EVENT_ADVANCE;
		} else if (tmpStrValue == "default") {
			messageType = MESSAGE_EVENT_DEFAULT;
		} else if (tmpStrValue == "description") {
			messageType = MESSAGE_INFO_DESCR;
		} else if (tmpStrValue == "smallstatus") {
			messageType = MESSAGE_STATUS_SMALL;
		} else if (tmpStrValue == "blueconsole") {
			messageType = MESSAGE_STATUS_CONSOLE_BLUE;
		} else if (tmpStrValue == "redconsole") {
			messageType = MESSAGE_STATUS_CONSOLE_RED;
		} else {
			LOG_WARN(fmt::format("[Notice] Raid: Unknown type tag missing for announce event. Using default: {}", static_cast<uint32_t>(messageType)));
		}
	} else {
		messageType = MESSAGE_EVENT_ADVANCE;
		LOG_WARN(fmt::format("[Notice] Raid: type tag missing for announce event. Using default: {}", static_cast<uint32_t>(messageType)));
	}
	return true;
}

bool AnnounceEvent::executeEvent()
{
	g_game.broadcastMessage(message, messageType);
	return true;
}

bool SingleSpawnEvent::configureRaidEvent(const pugi::xml_node& eventNode)
{
	if (!RaidEvent::configureRaidEvent(eventNode)) {
		return false;
	}

	pugi::xml_attribute attr;
	if ((attr = eventNode.attribute("name"))) {
		monsterName = attr.as_string();
	} else {
		LOG_ERROR("[Error] Raid: name tag missing for singlespawn event.");
		return false;
	}

	if ((attr = eventNode.attribute("x"))) {
		position.x = pugi::cast<uint16_t>(attr.value());
	} else {
		LOG_ERROR("[Error] Raid: x tag missing for singlespawn event.");
		return false;
	}

	if ((attr = eventNode.attribute("y"))) {
		position.y = pugi::cast<uint16_t>(attr.value());
	} else {
		LOG_ERROR("[Error] Raid: y tag missing for singlespawn event.");
		return false;
	}

	if ((attr = eventNode.attribute("z"))) {
		position.z = pugi::cast<uint16_t>(attr.value());
	} else {
		LOG_ERROR("[Error] Raid: z tag missing for singlespawn event.");
		return false;
	}
	return true;
}

bool SingleSpawnEvent::executeEvent()
{
	auto monsterUnique = Monster::createMonster(monsterName);
	if (!monsterUnique) {
		LOG_ERROR(fmt::format("[Error] Raids: Cant create monster {}", monsterName));
		return false;
	}

	std::shared_ptr<Monster> monster(std::move(monsterUnique));
	if (!g_game.placeCreature(monster.get(), position, false, true)) {
		LOG_ERROR(fmt::format("[Error] Raids: Cant place monster {}", monsterName));
		return false;
	}

	if (Raid* raid = g_game.raids.getRunning()) {
		raid->recordSpawnFileMonster(monsterName, monster->getPosition(), monster->getDirection());
	}
	return true;
}

bool AreaSpawnEvent::configureRaidEvent(const pugi::xml_node& eventNode)
{
	if (!RaidEvent::configureRaidEvent(eventNode)) {
		return false;
	}

	pugi::xml_attribute attr;
	if ((attr = eventNode.attribute("radius"))) {
		int32_t radius = pugi::cast<int32_t>(attr.value());
		Position centerPos;

		if ((attr = eventNode.attribute("centerx"))) {
			centerPos.x = pugi::cast<uint16_t>(attr.value());
		} else {
			LOG_ERROR("[Error] Raid: centerx tag missing for areaspawn event.");
			return false;
		}

		if ((attr = eventNode.attribute("centery"))) {
			centerPos.y = pugi::cast<uint16_t>(attr.value());
		} else {
			LOG_ERROR("[Error] Raid: centery tag missing for areaspawn event.");
			return false;
		}

		if ((attr = eventNode.attribute("centerz"))) {
			centerPos.z = pugi::cast<uint16_t>(attr.value());
		} else {
			LOG_ERROR("[Error] Raid: centerz tag missing for areaspawn event.");
			return false;
		}

		fromPos.x = static_cast<uint16_t>(std::max<int32_t>(0, centerPos.getX() - radius));
		fromPos.y = static_cast<uint16_t>(std::max<int32_t>(0, centerPos.getY() - radius));
		fromPos.z = centerPos.z;

		toPos.x = static_cast<uint16_t>(std::min<int32_t>(0xFFFF, centerPos.getX() + radius));
		toPos.y = static_cast<uint16_t>(std::min<int32_t>(0xFFFF, centerPos.getY() + radius));
		toPos.z = centerPos.z;
	} else {
		if ((attr = eventNode.attribute("fromx"))) {
			fromPos.x = pugi::cast<uint16_t>(attr.value());
		} else {
			LOG_ERROR("[Error] Raid: fromx tag missing for areaspawn event.");
			return false;
		}

		if ((attr = eventNode.attribute("fromy"))) {
			fromPos.y = pugi::cast<uint16_t>(attr.value());
		} else {
			LOG_ERROR("[Error] Raid: fromy tag missing for areaspawn event.");
			return false;
		}

		if ((attr = eventNode.attribute("fromz"))) {
			fromPos.z = static_cast<uint8_t>(pugi::cast<int32_t>(attr.value()));
		} else {
			LOG_ERROR("[Error] Raid: fromz tag missing for areaspawn event.");
			return false;
		}

		if ((attr = eventNode.attribute("tox"))) {
			toPos.x = pugi::cast<uint16_t>(attr.value());
		} else {
			LOG_ERROR("[Error] Raid: tox tag missing for areaspawn event.");
			return false;
		}

		if ((attr = eventNode.attribute("toy"))) {
			toPos.y = pugi::cast<uint16_t>(attr.value());
		} else {
			LOG_ERROR("[Error] Raid: toy tag missing for areaspawn event.");
			return false;
		}

		if ((attr = eventNode.attribute("toz"))) {
			toPos.z = static_cast<uint8_t>(pugi::cast<int32_t>(attr.value()));
		} else {
			LOG_ERROR("[Error] Raid: toz tag missing for areaspawn event.");
			return false;
		}
	}

	for (auto& monsterNode : eventNode.children()) {
		const char* name;

		if ((attr = monsterNode.attribute("name"))) {
			name = attr.value();
		} else {
			LOG_ERROR("[Error] Raid: name tag missing for monster node.");
			return false;
		}

		uint32_t minAmount;
		if ((attr = monsterNode.attribute("minamount"))) {
			minAmount = pugi::cast<uint32_t>(attr.value());
		} else {
			minAmount = 0;
		}

		uint32_t maxAmount;
		if ((attr = monsterNode.attribute("maxamount"))) {
			maxAmount = pugi::cast<uint32_t>(attr.value());
		} else {
			maxAmount = 0;
		}

		if (maxAmount == 0 && minAmount == 0) {
			if ((attr = monsterNode.attribute("amount"))) {
				minAmount = pugi::cast<uint32_t>(attr.value());
				maxAmount = minAmount;
			} else {
				LOG_ERROR("[Error] Raid: amount tag missing for monster node.");
				return false;
			}
		}

		spawnList.emplace_back(name, minAmount, maxAmount);
	}
	return true;
}

bool AreaSpawnEvent::executeEvent()
{
	for (const MonsterSpawn& spawn : spawnList) {
		uint32_t amount = uniform_random(spawn.minAmount, spawn.maxAmount);
		uint32_t placed = 0;
		for (uint32_t i = 0; i < amount; ++i) {
			auto monsterUnique = Monster::createMonster(spawn.name);
			if (!monsterUnique) {
				LOG_ERROR(fmt::format("[Error - AreaSpawnEvent::executeEvent] Can't create monster {}", spawn.name));
				return false;
			}

			std::shared_ptr<Monster> monster(std::move(monsterUnique));
			for (int32_t tries = 0; tries < MAXIMUM_TRIES_PER_MONSTER; tries++) {
				Tile* tile = g_game.map.getTile(static_cast<uint16_t>(uniform_random(fromPos.x, toPos.x)),
				                                static_cast<uint16_t>(uniform_random(fromPos.y, toPos.y)),
				                                static_cast<uint16_t>(uniform_random(fromPos.z, toPos.z)));
				if (tile && !tile->isMoveableBlocking() && !tile->hasFlag(TILESTATE_PROTECTIONZONE) &&
				    tile->getTopCreature() == nullptr &&
				    g_game.placeCreature(monster.get(), tile->getPosition(), false, true)) {
					++placed;
					if (Raid* raid = g_game.raids.getRunning()) {
						raid->recordSpawnFileMonster(spawn.name, monster->getPosition(), monster->getDirection());
					}
					break;
				}
			}
		}

		if (placed < amount) {
			LOG_WARN(fmt::format("[Warning - AreaSpawnEvent::executeEvent] Placed {}/{} monster(s) for {}.", placed, amount, spawn.name));
		}
	}
	return true;
}

bool ScriptEvent::configureRaidEvent(const pugi::xml_node& eventNode)
{
	if (!RaidEvent::configureRaidEvent(eventNode)) {
		return false;
	}

	pugi::xml_attribute scriptAttribute = eventNode.attribute("script");
	if (!scriptAttribute) {
		LOG_ERROR("Error: [ScriptEvent::configureRaidEvent] No script file found for raid");
		return false;
	}

	if (!loadScript("data/raids/scripts/" + std::string(scriptAttribute.as_string()))) {
		LOG_ERROR("Error: [ScriptEvent::configureRaidEvent] Can not load raid script.");
		return false;
	}
	return true;
}

bool ScriptEvent::executeEvent()
{
	// onRaid()
	if (!scriptInterface->reserveScriptEnv()) {
		LOG_ERROR("[Error - ScriptEvent::onRaid] Call stack overflow");
		return false;
	}

	ScriptEnvironment* env = scriptInterface->getScriptEnv();
	env->setScriptId(scriptId, scriptInterface);

	scriptInterface->pushFunction(scriptId);

	return scriptInterface->callFunction(0);
}
