--[[
================================================================================
  stress_network.lua - RevScript (TFS 1.8 / 8.60 downgrade fork)
  Safe NetworkMessage stress tests for allocator / Lua GC / send path.

  This version intentionally avoids huge synchronous dispatcher loops.
  Heavy workloads are split into small addEvent chunks so online players do not
  suffer server-wide pauses while a GM runs /net benchmarks.
================================================================================
--]]

local talk = TalkAction("/net")

-- ============================================================================
-- CONFIGURACAO
-- ============================================================================
local SUITE_CREATE_AMOUNT      = 10000
local SUITE_GC_AMOUNT          = 10000
local SUITE_POOL_AMOUNT        = 1000
local SUITE_LEAK_ROUNDS        = 100
local SUITE_CONCURRENT_WORKERS = 50
local SUITE_CONCURRENT_MSGS    = 1000
local SUITE_BIGDATA_AMOUNT     = 5000
local SUITE_BIGDATA_SIZE       = 8192
local SUITE_RESET_ROUNDS       = 1000
local SUITE_EXHAUST_POOL       = 2048
local SUITE_EXHAUST_OVER       = 5000
local SUITE_FRAGMENT_ROUNDS    = 500
local SUITE_REFCOUNT_AMOUNT    = 50000

-- Chunking / safety limits.
local NET_CHUNK_SIZE       = 500
local NET_SEND_CHUNK_SIZE  = 50
local NET_CHUNK_DELAY_MS   = 1
local SAFE_SEND_LIMIT      = 1000
local LEAK_MSGS_PER_ROUND  = 10000
local LEAK_MEM_THRESHOLD_KB = 1024

local MSG_BLUE = MESSAGE_STATUS_CONSOLE_BLUE or MESSAGE_EVENT_ADVANCE or 19
local MSG_RED  = MESSAGE_STATUS_CONSOLE_RED or MESSAGE_STATUS_WARNING or MSG_BLUE

local COLOR_RESET  = "\27[0m"
local COLOR_BLUE   = "\27[94m"
local COLOR_GREEN  = "\27[32m"
local COLOR_YELLOW = "\27[33m"
local COLOR_RED    = "\27[31m"
local COLOR_ORANGE = "\27[38;5;208m"

-- ============================================================================
-- UTILIDADES
-- ============================================================================
local function colorize(msg)
    local out = tostring(msg or "")
    out = out:gsub("(CREATE:)", COLOR_ORANGE .. "%1" .. COLOR_RESET)
    out = out:gsub("(GC:)", COLOR_ORANGE .. "%1" .. COLOR_RESET)
    out = out:gsub("(POOL [A-Z]+:)", COLOR_ORANGE .. "%1" .. COLOR_RESET)
    out = out:gsub("(LEAK:)", COLOR_ORANGE .. "%1" .. COLOR_RESET)
    out = out:gsub("(SEND:)", COLOR_ORANGE .. "%1" .. COLOR_RESET)
    out = out:gsub("(CONCURRENT:)", COLOR_ORANGE .. "%1" .. COLOR_RESET)
    out = out:gsub("(BIGDATA:)", COLOR_ORANGE .. "%1" .. COLOR_RESET)
    out = out:gsub("(RESET:)", COLOR_ORANGE .. "%1" .. COLOR_RESET)
    out = out:gsub("(EXHAUST:)", COLOR_ORANGE .. "%1" .. COLOR_RESET)
    out = out:gsub("(FRAGMENT:)", COLOR_ORANGE .. "%1" .. COLOR_RESET)
    out = out:gsub("(REFCOUNT:)", COLOR_ORANGE .. "%1" .. COLOR_RESET)
    return out
end

local function log(player, msg)
    print(COLOR_BLUE .. "[NET TEST]" .. COLOR_RESET .. " " .. colorize(msg))
    if player and player:isPlayer() then
        player:sendTextMessage(MSG_BLUE, "[NET TEST] " .. tostring(msg))
    end
end

local function logFail(player, msg)
    print(COLOR_BLUE .. "[NET TEST]" .. COLOR_RED .. "[FAIL]" .. COLOR_RESET .. " " .. colorize(msg))
    if player and player:isPlayer() then
        player:sendTextMessage(MSG_RED, "[NET TEST][FAIL] " .. tostring(msg))
    end
end

local function logPass(player, msg)
    print(COLOR_BLUE .. "[NET TEST]" .. COLOR_YELLOW .. "[PASS]" .. COLOR_RESET .. " " .. colorize(msg))
    if player and player:isPlayer() then
        player:sendTextMessage(MSG_BLUE, "[NET TEST][PASS] " .. tostring(msg))
    end
end

local function logInfo(player, msg)
    print(COLOR_BLUE .. "[NET TEST]" .. COLOR_GREEN .. "[INFO]" .. COLOR_RESET .. " " .. colorize(msg))
    if player and player:isPlayer() then
        player:sendTextMessage(MSG_BLUE, "[NET TEST][INFO] " .. tostring(msg))
    end
end

local function logHeader(player, msg)
    print(COLOR_BLUE .. "[NET TEST] " .. tostring(msg) .. COLOR_RESET)
    if player and player:isPlayer() then
        player:sendTextMessage(MSG_BLUE, "[NET TEST] " .. tostring(msg))
    end
end

local function safePlayer(pid, expectedGuid)
    local p = Player(pid)
    if not p then
        print("[NET TEST] Player id=" .. tostring(pid) .. " disconnected during test.")
        return nil
    end

    if expectedGuid and p:getGuid() ~= expectedGuid then
        print("[NET TEST] Player id=" .. tostring(pid) .. " GUID mismatch. PID recycled; ignoring callback.")
        return nil
    end

    return p
end

local function clampInt(value, defaultValue, minValue, maxValue)
    local n = tonumber(value) or defaultValue
    n = math.floor(n)
    if minValue and n < minValue then n = minValue end
    if maxValue and n > maxValue then n = maxValue end
    return n
end

-- Runs work in small scheduler chunks to avoid blocking the dispatcher.
local function runChunked(player, label, total, chunkSize, workFn, onDone, done)
    total = math.max(0, math.floor(total or 0))
    chunkSize = math.max(1, math.floor(chunkSize or NET_CHUNK_SIZE))

    local pid = player:getId()
    local guid = player:getGuid()
    local index = 1
    local startedAt = os.clock()

    logInfo(player, string.format("%s: running %d ops in chunks of %d.", label, total, chunkSize))

    local function step()
        local p = safePlayer(pid, guid)
        if not p then
            return
        end

        if total == 0 then
            if onDone then onDone(p, os.clock() - startedAt, total) end
            if done then done() end
            return
        end

        local last = math.min(index + chunkSize - 1, total)
        for i = index, last do
            workFn(i, p)
        end

        if last < total then
            index = last + 1
            addEvent(step, NET_CHUNK_DELAY_MS)
            return
        end

        collectgarbage("collect")
        local elapsed = os.clock() - startedAt
        if onDone then onDone(p, elapsed, total) end
        if done then done() end
    end

    addEvent(step, 0)
    return true
end

-- ============================================================================
-- TESTES INDIVIDUAIS
-- ============================================================================
local function runCreateTest(player, amount, done)
    amount = clampInt(amount, SUITE_CREATE_AMOUNT, 1, 250000)
    return runChunked(player, "CREATE", amount, NET_CHUNK_SIZE,
        function(i)
            local msg = NetworkMessage()
            msg:addByte(0xAA)
            msg:addU16(i % 65535)
            msg:addString("stress")
            msg = nil
        end,
        function(p, elapsed, total)
            logPass(p, string.format("CREATE: %d messages in %.3f sec CPU (%.0f msgs/sec)", total, elapsed, total / (elapsed + 1e-9)))
        end,
        done
    )
end

local function runGCTest(player, amount, done)
    amount = clampInt(amount, SUITE_GC_AMOUNT, 1, 250000)
    return runChunked(player, "GC", amount, NET_CHUNK_SIZE,
        function(i)
            local msg = NetworkMessage()
            msg:addString("GC TEST")
            msg:addByte(i % 255)
            msg = nil
        end,
        function(p, elapsed, total)
            logPass(p, string.format("GC: %d messages collected in %.3f sec CPU (%.0f msgs/sec)", total, elapsed, total / (elapsed + 1e-9)))
        end,
        done
    )
end

local function runPoolTest(player, amount, done)
    amount = clampInt(amount, SUITE_POOL_AMOUNT, 1, 20000)
    local messages = {}
    local start = os.clock()

    for i = 1, amount do
        local msg = NetworkMessage()
        msg:addString("POOL TEST")
        msg:addU32(i)
        messages[i] = msg
    end

    local allocElapsed = os.clock() - start
    logPass(player, string.format("POOL ALLOC: %d messages in %.3f sec (%.0f msgs/sec)", amount, allocElapsed, amount / (allocElapsed + 1e-9)))

    local pid = player:getId()
    local guid = player:getGuid()
    addEvent(function(playerId, playerGuid)
        local p = safePlayer(playerId, playerGuid)
        if not p then return end

        local freeStart = os.clock()
        for i = 1, #messages do
            messages[i] = nil
        end
        collectgarbage("collect")

        local freeElapsed = os.clock() - freeStart
        logPass(p, string.format("POOL FREE: %d messages in %.3f sec (%.0f msgs/sec)", amount, freeElapsed, amount / (freeElapsed + 1e-9)))
        if done then done() end
    end, 5000, pid, guid)

    return true
end

local function runLeakTest(player, rounds, done)
    rounds = clampInt(rounds, SUITE_LEAK_ROUNDS, 1, 500)
    collectgarbage("collect")
    local memBefore = collectgarbage("count")
    local totalMsgs = rounds * LEAK_MSGS_PER_ROUND

    return runChunked(player, "LEAK", totalMsgs, NET_CHUNK_SIZE,
        function(i)
            local msg = NetworkMessage()
            msg:addString("Leak Test")
            msg = nil

            -- One GC per logical round, not one GC per worker/callback.
            if i % LEAK_MSGS_PER_ROUND == 0 then
                collectgarbage("collect")
            end
        end,
        function(p, elapsed, total)
            collectgarbage("collect")
            local memAfter = collectgarbage("count")
            local totalDelta = memAfter - memBefore

            if totalDelta > LEAK_MEM_THRESHOLD_KB then
                logFail(p, string.format("LEAK: %d rounds | %d msgs | %.3f sec CPU | mem growth %.0f KB > %d KB", rounds, total, elapsed, totalDelta, LEAK_MEM_THRESHOLD_KB))
            else
                logPass(p, string.format("LEAK: %d rounds completed | %d msgs | %.3f sec CPU | mem delta %.0f KB", rounds, total, elapsed, totalDelta))
            end
        end,
        done
    )
end

local function runSendTest(player, amount, done)
    amount = clampInt(amount, SUITE_POOL_AMOUNT, 1, 100000)
    if amount > SAFE_SEND_LIMIT then
        logInfo(player, string.format("SEND: requested %d packets, capped to safe limit %d to avoid disconnect.", amount, SAFE_SEND_LIMIT))
        amount = SAFE_SEND_LIMIT
    end

    return runChunked(player, "SEND", amount, NET_SEND_CHUNK_SIZE,
        function(_, p)
            local msg = NetworkMessage()
            msg:addByte(0xB4)
            msg:addString("Benchmark")
            msg:sendToPlayer(p)
        end,
        function(p, elapsed, total)
            logPass(p, string.format("SEND: %d packets queued in %.3f sec CPU (%.0f packets/sec)", total, elapsed, total / (elapsed + 1e-9)))
        end,
        done
    )
end

local function runConcurrentTest(player, workers, msgsPerWorker, done)
    workers = clampInt(workers, SUITE_CONCURRENT_WORKERS, 1, 200)
    msgsPerWorker = clampInt(msgsPerWorker, SUITE_CONCURRENT_MSGS, 1, 20000)

    local pid = player:getId()
    local guid = player:getGuid()
    local startTime = os.clock()
    local completed = 0
    local totalMsgs = workers * msgsPerWorker

    logInfo(player, "CONCURRENT: addEvent(0) is dispatcher-sequential; this is allocator stress, not true C++ thread safety.")
    logInfo(player, string.format("CONCURRENT: dispatching %d workers (%d msgs each = %d total).", workers, msgsPerWorker, totalMsgs))

    for w = 1, workers do
        addEvent(function(workerId, amount, totalWorkers, playerId, playerGuid)
            local p = safePlayer(playerId, playerGuid)
            if not p then return end

            for i = 1, amount do
                local msg = NetworkMessage()
                msg:addByte(workerId % 256)
                msg:addU32(i)
                msg:addString("worker_" .. workerId)
                msg = nil
            end

            completed = completed + 1
            if completed == totalWorkers then
                collectgarbage("collect")
                local elapsed = os.clock() - startTime
                logPass(p, string.format("CONCURRENT: %d workers completed | %d msgs in %.3f sec CPU (%.0f msgs/sec)", totalWorkers, totalMsgs, elapsed, totalMsgs / (elapsed + 1e-9)))
                if done then done() end
            end
        end, 0, w, msgsPerWorker, workers, pid, guid)
    end

    return true
end

local function runBigDataTest(player, amount, payloadSize, done)
    amount = clampInt(amount, SUITE_BIGDATA_AMOUNT, 1, 50000)
    payloadSize = clampInt(payloadSize, SUITE_BIGDATA_SIZE, 1, 65535)
    local payload = string.rep("X", payloadSize)

    return runChunked(player, "BIGDATA", amount, NET_CHUNK_SIZE,
        function()
            local msg = NetworkMessage()
            msg:addString(payload)
            msg = nil
        end,
        function(p, elapsed, total)
            logPass(p, string.format("BIGDATA: %d messages x %d bytes in %.3f sec CPU (%.0f msgs/sec)", total, payloadSize, elapsed, total / (elapsed + 1e-9)))
        end,
        done
    )
end

local function runResetTest(player, rounds, done)
    rounds = clampInt(rounds, SUITE_RESET_ROUNDS, 1, 100000)

    return runChunked(player, "RESET", rounds, NET_CHUNK_SIZE,
        function(round)
            local msg1 = NetworkMessage()
            msg1:addByte(0xFF)
            msg1:addString("SECRET_DATA_" .. round)
            msg1:addU32(0xDEADBEEF)
            msg1 = nil

            if round % 100 == 0 then
                collectgarbage("collect")
            end

            local msg2 = NetworkMessage()
            msg2:addByte(0x00)
            msg2:addString("CLEAN_" .. round)
            msg2 = nil
        end,
        function(p, elapsed, total)
            logPass(p, string.format("RESET: %d reuse cycles in %.3f sec CPU - no-crash smoke test completed", total, elapsed))
            logInfo(p, "RESET: Lua cannot verify buffer zeroing; real validation requires a C++ unit test or a Lua buffer-inspection binding.")
        end,
        done
    )
end

local function runExhaustTest(player, poolSize, overshoot, done)
    poolSize = clampInt(poolSize, SUITE_EXHAUST_POOL, 1, 5000)
    overshoot = clampInt(overshoot, SUITE_EXHAUST_OVER, 1, 10000)

    local messages = {}
    logInfo(player, string.format("EXHAUST: allocating %d pool msgs + %d overshoot msgs. WARNING: large values may cause lag.", poolSize, overshoot))

    local t1 = os.clock()
    for i = 1, poolSize do
        messages[i] = NetworkMessage()
        messages[i]:addString("pool_" .. i)
    end
    local poolTime = os.clock() - t1
    local poolThroughput = poolSize / (poolTime + 1e-9)

    local t2 = os.clock()
    for i = poolSize + 1, poolSize + overshoot do
        messages[i] = NetworkMessage()
        messages[i]:addString("fallback_" .. i)
    end
    local fallbackTime = os.clock() - t2
    local fallbackThroughput = overshoot / (fallbackTime + 1e-9)

    logPass(player, string.format("EXHAUST: Pool=%.0f msgs/sec | Fallback=%.0f msgs/sec | Fallback is %.1f%% of pool speed", poolThroughput, fallbackThroughput, (fallbackThroughput / (poolThroughput + 1e-9)) * 100))

    for i = 1, #messages do
        messages[i] = nil
    end
    collectgarbage("collect")

    local t3 = os.clock()
    for i = 1, poolSize do
        local msg = NetworkMessage()
        msg:addString("recovery_" .. i)
        msg = nil
    end
    collectgarbage("collect")

    local recoveryTime = os.clock() - t3
    local recoveryThroughput = poolSize / (recoveryTime + 1e-9)
    logPass(player, string.format("EXHAUST: Recovery=%.0f msgs/sec (%.1f%% of original pool speed)", recoveryThroughput, (recoveryThroughput / (poolThroughput + 1e-9)) * 100))

    if done then addEvent(done, 0) end
    return true
end

local function runFragmentTest(player, rounds, done)
    rounds = clampInt(rounds, SUITE_FRAGMENT_ROUNDS, 1, 5000)
    local opsPerRound = 1500

    return runChunked(player, "FRAGMENT", rounds, 10,
        function(round)
            local msgs = {}
            for i = 1, 1000 do
                msgs[i] = NetworkMessage()
                msgs[i]:addString("fragment_" .. i)
            end
            for i = 1, 1000, 2 do
                msgs[i] = nil
            end
            collectgarbage("collect")
            for i = 1, 500 do
                local msg = NetworkMessage()
                msg:addString("reuse_" .. i)
                msg = nil
            end
            for i = 1, 1000 do
                msgs[i] = nil
            end
            if round % 100 == 0 then
                collectgarbage("collect")
            end
        end,
        function(p, elapsed, totalRounds)
            local totalOps = totalRounds * opsPerRound
            logPass(p, string.format("FRAGMENT: %d rounds (%d total ops) in %.3f sec CPU (%.0f ops/sec)", totalRounds, totalOps, elapsed, totalOps / (elapsed + 1e-9)))
        end,
        done
    )
end

local function runRefCountTest(player, amount, done)
    amount = clampInt(amount, SUITE_REFCOUNT_AMOUNT, 1, 250000)

    return runChunked(player, "REFCOUNT", amount, NET_CHUNK_SIZE,
        function()
            local msg = NetworkMessage()
            msg:addByte(0xAA)
            local refs = {msg, msg, msg, msg, msg}
            refs = nil
            msg = nil
        end,
        function(p, elapsed, total)
            logPass(p, string.format("REFCOUNT: %d objects (5 refs each) in %.3f sec CPU (%.0f objs/sec)", total, elapsed, total / (elapsed + 1e-9)))
        end,
        done
    )
end

-- ============================================================================
-- /net all - sequencial, assíncrono e sem pular POOL FREE
-- ============================================================================
local function runAllTests(player)
    local pid = player:getId()
    local guid = player:getGuid()
    local suiteStart = os.clock()

    local steps = {
        { name = "CREATE", run = function(p, nextStep) runCreateTest(p, SUITE_CREATE_AMOUNT, nextStep) end },
        { name = "GC", run = function(p, nextStep) runGCTest(p, SUITE_GC_AMOUNT, nextStep) end },
        { name = "POOL", run = function(p, nextStep) runPoolTest(p, SUITE_POOL_AMOUNT, nextStep) end },
        { name = "LEAK", run = function(p, nextStep) runLeakTest(p, SUITE_LEAK_ROUNDS, nextStep) end },
        { name = "SEND", run = function(p, nextStep) runSendTest(p, SUITE_POOL_AMOUNT, nextStep) end },
        { name = "CONCURRENT", run = function(p, nextStep) runConcurrentTest(p, SUITE_CONCURRENT_WORKERS, SUITE_CONCURRENT_MSGS, nextStep) end },
        { name = "BIGDATA", run = function(p, nextStep) runBigDataTest(p, SUITE_BIGDATA_AMOUNT, SUITE_BIGDATA_SIZE, nextStep) end },
        { name = "RESET", run = function(p, nextStep) runResetTest(p, SUITE_RESET_ROUNDS, nextStep) end },
        { name = "EXHAUST", run = function(p, nextStep) runExhaustTest(p, SUITE_EXHAUST_POOL, SUITE_EXHAUST_OVER, nextStep) end },
        { name = "FRAGMENT", run = function(p, nextStep) runFragmentTest(p, SUITE_FRAGMENT_ROUNDS, nextStep) end },
        { name = "REFCOUNT", run = function(p, nextStep) runRefCountTest(p, SUITE_REFCOUNT_AMOUNT, nextStep) end },
    }

    local index = 1
    logHeader(player, "=== Starting COMPLETE NetworkMessage Benchmark ===")

    local function runNext()
        local p = safePlayer(pid, guid)
        if not p then return end

        local step = steps[index]
        if not step then
            local elapsed = os.clock() - suiteStart
            logHeader(p, string.format("=== NETWORK COMPLETO: ALL DONE | CPU %.3fs ===", elapsed))
            return
        end

        logHeader(p, string.format("-- NET ALL %d/%d: %s --", index, #steps, step.name))
        index = index + 1
        step.run(p, function()
            addEvent(runNext, 250)
        end)
    end

    addEvent(runNext, 0)
end

-- ============================================================================
-- HELP / TALKACTION
-- ============================================================================
local function showHelp(player)
    log(player, "==================== HELP ====================")
    logInfo(player, string.format("/net create[,%d]", SUITE_CREATE_AMOUNT))
    logInfo(player, string.format("/net gc[,%d]", SUITE_GC_AMOUNT))
    logInfo(player, string.format("/net pool[,%d]", SUITE_POOL_AMOUNT))
    logInfo(player, string.format("/net leak[,%d]", SUITE_LEAK_ROUNDS))
    logInfo(player, string.format("/net send[,%d] (safe cap=%d)", SUITE_POOL_AMOUNT, SAFE_SEND_LIMIT))
    log(player, "----------------------------------------------")
    logInfo(player, string.format("/net concurrent[,%d,%d]", SUITE_CONCURRENT_WORKERS, SUITE_CONCURRENT_MSGS))
    logInfo(player, string.format("/net bigdata[,%d,%d]", SUITE_BIGDATA_AMOUNT, SUITE_BIGDATA_SIZE))
    logInfo(player, string.format("/net reset[,%d] (Lua no-crash smoke test only)", SUITE_RESET_ROUNDS))
    logInfo(player, string.format("/net exhaust[,%d,%d]", SUITE_EXHAUST_POOL, SUITE_EXHAUST_OVER))
    logInfo(player, string.format("/net fragment[,%d]", SUITE_FRAGMENT_ROUNDS))
    logInfo(player, string.format("/net refcount[,%d]", SUITE_REFCOUNT_AMOUNT))
    log(player, "----------------------------------------------")
    logInfo(player, "/net all - run all tests sequentially without blocking dispatcher")
    log(player, "==============================================")
end

function talk.onSay(player, words, param)
    if not player:getGroup():getAccess() then
        return false
    end

    param = tostring(param or "")
    if param == "" then
        showHelp(player)
        return false
    end

    local parts = {}
    for part in param:gmatch("([^,]+)") do
        parts[#parts + 1] = part:match("^%s*(.-)%s*$")
    end

    local cmd = (parts[1] or ""):lower()
    local value1 = tonumber(parts[2])
    local value2 = tonumber(parts[3])

    if cmd == "create" then
        runCreateTest(player, value1 or SUITE_CREATE_AMOUNT)
    elseif cmd == "gc" then
        runGCTest(player, value1 or SUITE_GC_AMOUNT)
    elseif cmd == "pool" then
        runPoolTest(player, value1 or SUITE_POOL_AMOUNT)
    elseif cmd == "leak" then
        runLeakTest(player, value1 or SUITE_LEAK_ROUNDS)
    elseif cmd == "send" then
        runSendTest(player, value1 or SUITE_POOL_AMOUNT)
    elseif cmd == "concurrent" then
        runConcurrentTest(player, value1 or SUITE_CONCURRENT_WORKERS, value2 or SUITE_CONCURRENT_MSGS)
    elseif cmd == "bigdata" then
        runBigDataTest(player, value1 or SUITE_BIGDATA_AMOUNT, value2 or SUITE_BIGDATA_SIZE)
    elseif cmd == "reset" then
        runResetTest(player, value1 or SUITE_RESET_ROUNDS)
    elseif cmd == "exhaust" then
        runExhaustTest(player, value1 or SUITE_EXHAUST_POOL, value2 or SUITE_EXHAUST_OVER)
    elseif cmd == "fragment" then
        runFragmentTest(player, value1 or SUITE_FRAGMENT_ROUNDS)
    elseif cmd == "refcount" then
        runRefCountTest(player, value1 or SUITE_REFCOUNT_AMOUNT)
    elseif cmd == "all" or cmd == "start" then
        runAllTests(player)
    else
        showHelp(player)
    end

    return false
end

talk:separator(" ")
talk:accountType(6)
talk:register()
