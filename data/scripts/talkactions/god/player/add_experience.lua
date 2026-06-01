local talkaction = TalkAction("/addexperience")

function talkaction.onSay(player, words, param)
	local split = param:splitTrimmed(",")
	if not split[1] or not split[2] then
		player:sendTextMessage(MESSAGE_STATUS_CONSOLE_BLUE, "Usage: /addexperience player name, amount")
		return false
	end

	local target = Player(split[1])
	if not target then
		player:sendCancelMessage("A player with that name is not online.")
		return false
	end

	local amount = math.floor(tonumber(split[2]) or 0)
	if amount == 0 then
		player:sendCancelMessage("Amount must be different from zero.")
		return false
	end

	local oldLevel = target:getLevel()
	if amount > 0 then
		target:addExperience(amount, true)
		player:sendTextMessage(MESSAGE_STATUS_CONSOLE_BLUE, "Added " .. amount .. " experience to " .. target:getName() .. ". Level: " .. oldLevel .. " -> " .. target:getLevel() .. ".")
		target:sendTextMessage(MESSAGE_STATUS_CONSOLE_BLUE, "You received " .. amount .. " experience.")
	else
		local removedExperience = math.min(math.abs(amount), target:getExperience())
		if removedExperience <= 0 then
			player:sendCancelMessage(target:getName() .. " has no experience to remove.")
			return false
		end

		target:removeExperience(removedExperience)
		player:sendTextMessage(MESSAGE_STATUS_CONSOLE_BLUE, "Removed " .. removedExperience .. " experience from " .. target:getName() .. ". Level: " .. oldLevel .. " -> " .. target:getLevel() .. ".")
		target:sendTextMessage(MESSAGE_STATUS_CONSOLE_BLUE, "You lost " .. removedExperience .. " experience.")
	end

	return false
end

talkaction:separator(" ")
talkaction:accountType(6)
talkaction:access(true)
talkaction:register()
