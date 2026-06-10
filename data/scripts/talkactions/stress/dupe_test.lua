--[[
================================================================================
  dupetest.lua  -  RevScript  (TFS 1.8 / 8.60 downgrade fork)
  Teste de Vulnerabilidades de Duplicacao de Itens
  Repositorio: Mateuzkl/forgottenserver-downgrade-1.8-8.60
================================================================================

  Proposito
  ─────────
  Detecta falhas de integridade de itens exploraveis como "dupes":
  situacoes onde o sistema de save threadado (PR #69) deixa itens no banco
  apos remocao da memoria, ou nao reflete o estado correto no DB.

  USO (apenas GMs com getAccess() == true):
    /dupe start   - roda todas as 8 fases em sequencia
    /dupe 1-8     - roda uma fase individualmente
    /dupe info    - descreve cada fase
    /dupe clean   - remove itens de teste do inventario

  FASES:
  ┌────┬─────────────────────────────────────────┬──────────────────────────────────┐
  │ Ph │ Vetor de Dupe                           │ O que detecta                    │
  ├────┼─────────────────────────────────────────┼──────────────────────────────────┤
  │  1 │ Ghost item apos save flood              │ Save antigo sobrescreve novo     │
  │  2 │ SNAPSHOT RACE: add→save→remove→save ★  │ S1 executa apos S2 no worker     │
  │  3 │ Stackable count integrity               │ Coins extras/faltando no DB      │
  │  4 │ N rounds add/remove com save em cada    │ Ghost acumulativo por round       │
  │  5 │ Concurrent saves burst (addEvent 0)     │ Worker pool race                 │
  │  6 │ Snapshot reversal: [A]→save→swap B→save │ Item A persiste apos swap        │
  │  7 │ Multi-item remocao parcial              │ Item extra no DB                 │
  │  8 │ Simulacao completa: flood c/ e s/ item  │ Cenario real de dupe por DC      │
  └────┴─────────────────────────────────────────┴──────────────────────────────────┘
  ★ = fase mais critica para o PR #69

  PRE-REQUISITO:
    Inventario nao deve conter itens dos tipos CFG.item_ns e CFG.item_st
    antes de rodar. Use /dupe clean para garantir.

  SEGURANCA:
    • Nao acessa tabelas de producao diretamente (apenas leitura para verificacao).
    • Todos os itens criados sao removidos ao final de cada fase.
    • Requer player:getGroup():getAccess() == true.
================================================================================
--]]

-- ============================================================================
-- CONFIGURACAO  –  ajuste para o seu servidor
-- ============================================================================
-- Itens de teste - use IDs que nao interfiram com inventario real.
-- Se o servidor tiver itens QA/debug, defina QA_ITEM_NS e QA_ITEM_ST abaixo.
local QA_ITEM_NS = 3264   -- Sword (cheap non-stackable, safe for QA cleanup)
local QA_ITEM_ST = 3035   -- Platinum Coin (low-value stackable, safe for QA cleanup)

-- Seguranca: rejeita IDs de producao de alto valor (Fire Sword=3280, Gold Coin=3031)
if QA_ITEM_NS == 3280 or QA_ITEM_NS == 3031 or QA_ITEM_ST == 3280 or QA_ITEM_ST == 3031 then
    error("BLOCKED: QA item IDs must not be high-value production IDs (3280/3031). Use safe QA-only IDs.")
end

-- Seguranca: verifica no registro que os itens existem (evita IDs invalidos)
do
    local itemType = ItemType(QA_ITEM_NS)
    assert(itemType and itemType:getId() ~= 0,
        "QA_ITEM_NS=" .. QA_ITEM_NS .. " item invalido ou inexistente. Verifique items.otb e items.xml.")
end
do
    local itemType = ItemType(QA_ITEM_ST)
    assert(itemType and itemType:getId() ~= 0,
        "QA_ITEM_ST=" .. QA_ITEM_ST .. " item invalido ou inexistente. Verifique items.otb e items.xml.")
end

local CFG = {
    -- Item NAO-stackavel de teste
    item_ns       = QA_ITEM_NS,

    -- Item STACKAVEL de teste
    item_st       = QA_ITEM_ST,

    -- Numero de saves rapidos por fase de flood
    save_burst    = 8,

    -- Intervalo entre saves no flood (ms)
    stagger_ms    = 15,

    -- Delay antes de consultar o DB (ms)
    -- Deve ser maior que o tempo de settle do worker thread do PR #69.
    -- Aumente para 2500-3000 se rodar em banco lento.
    verify_delay  = 2000,
}

-- ============================================================================
-- UTILIDADES
-- ============================================================================
local COLOR_RESET  = "\27[0m"
local COLOR_BLUE   = "\27[94m"
local COLOR_GREEN  = "\27[32m"
local COLOR_YELLOW = "\27[33m"
local COLOR_RED    = "\27[31m"
local COLOR_ORANGE = "\27[38;5;208m"

local MSG_BLUE = MESSAGE_STATUS_CONSOLE_BLUE or MESSAGE_EVENT_ADVANCE or 19
local MSG_RED  = MESSAGE_STATUS_CONSOLE_RED  or MESSAGE_STATUS_WARNING or MSG_BLUE

local activeRuns = {}  -- keyed by player GUID to allow multiple GMs
local phaseFailed = {}  -- keyed by player GUID; logFail sets, /dupe start resets per-GUID

local function colorPhase(msg)
    local out = msg:gsub("(Phase %d+[abc]?:)", COLOR_ORANGE .. "%1" .. COLOR_RESET)
    return out
end

local function log(player, msg)
    print(COLOR_BLUE .. "[DupeTest]" .. COLOR_RESET .. " " .. colorPhase(msg))
    if player and player:isPlayer() then
        player:sendTextMessage(MSG_BLUE, "[DupeTest] " .. msg)
    end
end

local function logFail(player, msg)
    if player and player:isPlayer() then
        phaseFailed[player:getGuid()] = true
    end
    print(COLOR_BLUE .. "[DupeTest]" .. COLOR_RED .. "[FAIL]" .. COLOR_RESET .. " " .. colorPhase(msg))
    if player and player:isPlayer() then
        player:sendTextMessage(MSG_RED, "[DupeTest][FAIL] " .. msg)
    end
end

local function logPass(player, msg)
    print(COLOR_BLUE .. "[DupeTest]" .. COLOR_YELLOW .. "[PASS]" .. COLOR_RESET .. " " .. colorPhase(msg))
    if player and player:isPlayer() then
        player:sendTextMessage(MSG_BLUE, "[DupeTest][PASS] " .. msg)
    end
end

local function logInfo(player, msg)
    print(COLOR_BLUE .. "[DupeTest]" .. COLOR_GREEN .. "[INFO]" .. COLOR_RESET .. " " .. colorPhase(msg))
    if player and player:isPlayer() then
        player:sendTextMessage(MSG_BLUE, "[DupeTest][INFO] " .. msg)
    end
end

local function logHeader(player, msg)
    -- Pinta a mensagem inteira em azul
    print(COLOR_BLUE .. "[DupeTest] " .. msg .. COLOR_RESET)
    if player and player:isPlayer() then
        player:sendTextMessage(MSG_BLUE, "[DupeTest] " .. msg)
    end
end

local function logSummary(player, msg, hasFailed)
    -- Se hasFailed for true, mostra em vermelho; senao, em azul
    if hasFailed then
        print(COLOR_BLUE .. "[DupeTest]" .. COLOR_RED .. "[FAIL] " .. msg .. COLOR_RESET)
        if player and player:isPlayer() then
            player:sendTextMessage(MSG_RED, "[DupeTest][FAIL] " .. msg)
        end
    else
        print(COLOR_BLUE .. "[DupeTest] " .. msg .. COLOR_RESET)
        if player and player:isPlayer() then
            player:sendTextMessage(MSG_BLUE, "[DupeTest] " .. msg)
        end
    end
end

local function safePlayer(pid, expectedGuid)
    local p = Player(pid)
    if not p then
        print("[DupeTest] Player id=" .. tostring(pid) .. " desconectou durante o teste.")
        return nil
    end
    if expectedGuid and p:getGuid() ~= expectedGuid then
        print("[DupeTest] Player id=" .. tostring(pid) .. " GUID mismatch (PID reciclado?). ignorando.")
        return nil
    end
    return p
end

-- Conta linhas em player_items para este player_guid + itemtype
local function countItemsInDB(playerGuid, itemTypeId)
    local res = db.storeQuery(string.format(
        "SELECT COUNT(*) AS cnt FROM `player_items` WHERE `player_id`=%d AND `itemtype`=%d",
        playerGuid, itemTypeId
    ))
    if not res or res == false then return -1 end
    local cnt = result.getNumber(res, "cnt")
    result.free(res)
    return cnt
end

-- Soma count total de stackavel em player_items (Gold Coin, etc.)
local function sumStackInDB(playerGuid, itemTypeId)
    local res = db.storeQuery(string.format(
        "SELECT COALESCE(SUM(`count`), 0) AS total FROM `player_items` WHERE `player_id`=%d AND `itemtype`=%d",
        playerGuid, itemTypeId
    ))
    if not res or res == false then return -1 end
    local total = result.getNumber(res, "total")
    result.free(res)
    return total
end

-- Remove todos os itens de um tipo do inventario (safety cleanup)
-- Count items first, then remove only what exists (avoid excessive iteration)
local function safeRemoveAll(player, itemTypeId)
    local count = player:getItemCount(itemTypeId)
    if count > 0 then
        player:removeItem(itemTypeId, count)
    end
end

-- Tenta verificar condicao com retry em vez de delay fixo.
--   checkFn: retorna true se a verificacao passou, false se falhou
--   onPass(attempt): chamado quando checkFn retorna true
--   onFail(finalAttempt): chamado apos exaurir maxRetries
--   initialDelay: primeiro delay antes de tentar (ms)
--   retryInterval: intervalo entre retries (ms)
--   maxRetries: numero maximo de tentativas (default 3)
local function verifyWithRetry(checkFn, onPass, onFail, initialDelay, retryInterval, maxRetries)
    maxRetries = maxRetries or 3
    retryInterval = retryInterval or 800
    local attempt = 0

    local function tryVerify()
        attempt = attempt + 1
        if checkFn(attempt) then
            onPass(attempt)
        elseif attempt < maxRetries then
            addEvent(tryVerify, retryInterval)
        else
            onFail(attempt)
        end
    end

    addEvent(tryVerify, initialDelay)
end

-- Verifica se o player ja possui itens dos tipos de teste no inventario
-- Retorna true se houver itens pre-existentes (risco de mistura) ou erro de DB
local function hasPreExistingTestItems(player, guid)
    local cntNS = countItemsInDB(guid, QA_ITEM_NS)
    local cntST = sumStackInDB(guid, QA_ITEM_ST)
    if cntNS == -1 or cntST == -1 then
        logFail(player, "hasPreExistingTestItems: Erro na query DB - nao foi possivel verificar inventario.")
        return true  -- bloqueia por seguranca (fails closed)
    end
    if cntNS > 0 or cntST > 0 then
        return true
    end
    return false
end

-- ============================================================================
-- PHASE 1  –  Ghost item apos save flood
-- ============================================================================
--[[
  Adiciona 1 item nao-stackavel, dispara N saves em rafada, depois remove
  o item e salva uma ultima vez. Verifica que o DB nao retem ghost item.

  FALHA INDICA: um dos saves do flood (com item) executou no worker APOS
  o save de remocao (sem item), sobrescrevendo o estado correto.
  → Fila do worker nao e FIFO para itens de player.
--]]
local function runPhase1(player)
    local guid   = player:getGuid()
    local pid    = player:getId()
    local typeId = CFG.item_ns

    log(player, string.format(
        "Phase 1: Ghost item - add 1 item, %dx save flood (stagger=%dms), remove, verifica DB=0...",
        CFG.save_burst, CFG.stagger_ms
    ))

    safeRemoveAll(player, typeId)

    if not player:addItem(typeId, 1, false) then
        logFail(player, "Phase 1: Falha ao criar item (item_ns=" .. typeId .. "). Ajuste CFG.item_ns.")
        return false
    end

    -- Flood de saves COM o item na memoria (async para testar PR#69)
    for i = 1, CFG.save_burst do
        addEvent(function(pid2, guid2)
            local p = safePlayer(pid2, guid2)
            if p and not p:saveAsync() then
                logInfo(p, "Phase 1: saveAsync() retornou false (flush em andamento) - normal em flood.")
            end
        end, i * CFG.stagger_ms, pid, guid)
    end

    -- Remove o item e faz save final
    local removeAt = CFG.save_burst * CFG.stagger_ms + 100
    addEvent(function(pid2, guid2, tId)
        local p = safePlayer(pid2, guid2)
        if not p then return end
        p:removeItem(tId, 1)
        p:save()
    end, removeAt, pid, guid, typeId)

    -- Verifica DB
    addEvent(function(pid2, guid2, tId)
        local p = safePlayer(pid2, guid2)
        if not p then return end

        local cnt = countItemsInDB(guid2, tId)
        if cnt == 0 then
            logPass(p, "Phase 1: DB=0 - sem ghost item. Ordering do save flood preservado.")
        elseif cnt > 0 then
            logFail(p, string.format(
                "Phase 1: DB=%d (esperado 0) - GHOST ITEM! Save do flood (c/item) sobrescreveu save de remocao.",
                cnt
            ))
            logFail(p, "  -> Worker nao respeita FIFO: save antigo chegou apos save mais novo.")
            safeRemoveAll(p, tId)
            p:save()
        else
            logFail(p, "Phase 1: Falha na query DB (retornou -1). Verifique player_items e conexao.")
        end
    end, removeAt + CFG.verify_delay, pid, guid, typeId)

    return true
end

-- ============================================================================
-- PHASE 2  –  SNAPSHOT RACE  ★  FASE MAIS CRITICA
-- ============================================================================
--[[
  Replica o cenario exato de dupe por desconexao/trade:

    1. addItem         → item na MEMORIA
    2. player:save()   → snapshot S1 enfileirado: { item presente }
    3. removeItem      → item removido da MEMORIA (sem save ainda)
    4. player:save()   → snapshot S2 enfileirado: { item ausente  }

  Worker FIFO correto:  S1 escreve item → S2 apaga item   → DB=0 ✓
  Worker fora de ordem: S2 apaga (nada) → S1 escreve item → DB=1 = DUPE!

  Cenario real explorado por jogadores:
    pick up item → drop item/trade/DC imediato → relog
    → item reaparece no inventario a partir do DB corrompido.

  FALHA AQUI = DUPE BUG CONFIRMADO no flushPlayerSave / pendingFlushes.
--]]
local function runPhase2(player)
    local guid   = player:getGuid()
    local pid    = player:getId()
    local typeId = CFG.item_ns

    log(player, "Phase 2: SNAPSHOT RACE - add->save(S1)->remove->save(S2) | S2 deve ser o estado final.")
    log(player, "Phase 2: se falhar aqui = dupe bug real no ordering do worker thread (PR #69).")

    safeRemoveAll(player, typeId)

    -- 1. Adiciona item (apenas em memoria)
    if not player:addItem(typeId, 1, false) then
        logFail(player, "Phase 2: Falha ao criar item. Ajuste CFG.item_ns.")
        return false
    end

    -- 2. Save S1: snapshot COM item → enfileirado no worker (async para race real)
    local s1 = player:saveAsync()
    if not s1 then
        logFail(player, "Phase 2: saveAsync() S1 retornou false - flush nao enfileirado. Teste pode ser inconclusivo.")
        safeRemoveAll(player, typeId)
        return false
    end

    -- 3. Remove da MEMORIA sem salvar
    player:removeItem(typeId, 1)

    -- 4. Save S2: snapshot SEM item (deve ser o estado final) (async, vai p/ pendingFlushes)
    local s2 = player:saveAsync()
    if not s2 then
        logFail(player, "Phase 2: saveAsync() S2 retornou false - flush nao enfileirado. Teste pode ser inconclusivo.")
        safeRemoveAll(player, typeId)
        return false
    end

    logInfo(player, string.format(
        "Phase 2: S1=%s S2=%s | Dois saves enfileirados. Verificando DB com retry...",
        tostring(s1), tostring(s2)
    ))

    verifyWithRetry(
        function()
            local p = safePlayer(pid, guid)
            if not p then return false end
            return countItemsInDB(guid, typeId) == 0
        end,
        function(attempt)
            local p = safePlayer(pid, guid)
            if not p then return end
            logPass(p, string.format(
                "Phase 2: DB=0 (attempt %d) - S2 (sem item) foi o estado final. FIFO ordering OK.",
                attempt
            ))
        end,
        function(attempt)
            local p = safePlayer(pid, guid)
            if not p then return end
            local cnt = countItemsInDB(guid, typeId)
            if cnt > 0 then
                logFail(p, string.format(
                    "Phase 2: DB=%d (esperado 0) apos %d tentativas - ## DUPE BUG CONFIRMADO ##", cnt, attempt
                ))
                logFail(p, "  -> S1 {item presente} executou APOS S2 {item removido} no worker thread.")
                logFail(p, "  -> Player relogando teria o item de volta no inventario = ITEM DUPLICADO!")
                logFail(p, "  -> Fix: garantir FIFO em SaveManager::onPlayerFlushed + pendingFlushes drain.")
                safeRemoveAll(p, typeId)
                p:save()
            else
                logFail(p, "Phase 2: Falha na query DB. Verifique conexao e tabela player_items.")
            end
        end,
        CFG.verify_delay, 800, 3
    )

    return true
end

-- ============================================================================
-- PHASE 3  –  Stackable count integrity
-- ============================================================================
--[[
  Testa que o count de stackaveis se mantem correto apos:
    add 200 coins → save → verifica SUM=200
    remove 100    → save → verifica SUM=100

  Um dupe de stackavel surge se um snapshot antigo (count maior)
  sobrescreve um snapshot mais novo (count menor), resultado em
  coins extras no banco na proxima sessao.
--]]
local function runPhase3(player)
    local guid   = player:getGuid()
    local pid    = player:getId()
    local typeId = CFG.item_st
    local addQty = 200

    log(player, string.format(
        "Phase 3: Stackable count - add %d, save, check=200, remove 100, save, check=100...",
        addQty
    ))

    safeRemoveAll(player, typeId)

    if not player:addItem(typeId, addQty, false) then
        logFail(player, "Phase 3: Falha ao criar item stackavel. Ajuste CFG.item_st.")
        return false
    end

    player:save()

    addEvent(function(pid2, guid2, tId, qty)
        local p = safePlayer(pid2, guid2)
        if not p then return end

        -- 3a: verifica SUM apos add+save
        local sumA = sumStackInDB(guid2, tId)
        if sumA ~= qty then
            logFail(p, string.format(
                "Phase 3a: DB sum=%d (esperado %d) apos add+save. Problema basico de save.",
                sumA, qty
            ))
        else
            logPass(p, string.format("Phase 3a: DB sum=%d OK apos add+save.", sumA))
        end

        -- Remove metade
        local half = math.floor(qty / 2)
        p:removeItem(tId, half)
        p:save()

        addEvent(function(pid3, guid3, tId3, expected, removed)
            local p3 = safePlayer(pid3, guid3)
            if not p3 then return end

            local sumB = sumStackInDB(guid3, tId3)
            if sumB == expected then
                logPass(p3, string.format(
                    "Phase 3b: DB sum=%d OK apos remover %d. Count integrity verificada.",
                    sumB, removed
                ))
            elseif sumB > expected then
                logFail(p3, string.format(
                    "Phase 3b: DB sum=%d (esperado %d) - EXTRA %d coins! Snapshot antigo (maior) sobrescreveu.",
                    sumB, expected, sumB - expected
                ))
            else
                logFail(p3, string.format(
                    "Phase 3b: DB sum=%d (esperado %d) - coins a menos. Save nao persistiu remocao.",
                    sumB, expected
                ))
            end

            safeRemoveAll(p3, tId3)
            p3:save()
        end, CFG.verify_delay, pid2, guid2, tId, qty - half, half)

    end, CFG.verify_delay, pid, guid, typeId, addQty)

    return true
end

-- ============================================================================
-- PHASE 4  –  N rounds de add/remove com save em cada round
-- ============================================================================
--[[
  Repete N vezes: addItem → save → removeItem → save.
  Cada round insere dois snapshots na fila do worker (com e sem item).
  Um ghost acumulativo indicaria que saves "com item" de rounds anteriores
  chegam depois dos saves "sem item" de rounds posteriores.
--]]
local function runPhase4(player)
    local guid   = player:getGuid()
    local pid    = player:getId()
    local typeId = CFG.item_ns
    local rounds = 5
    local roundMs = 300

    log(player, string.format(
        "Phase 4: %d rounds add->save->remove->save (cada ~%dms) | final DB deve ser 0...",
        rounds, roundMs
    ))

    safeRemoveAll(player, typeId)

    for i = 1, rounds do
        local base = (i - 1) * roundMs

        -- addItem + save
        addEvent(function(pid2, guid2, tId)
            local p = safePlayer(pid2, guid2)
            if not p then return end
            p:addItem(tId, 1, false)
            p:save()
        end, base, pid, guid, typeId)

        -- removeItem + save
        addEvent(function(pid2, guid2, tId)
            local p = safePlayer(pid2, guid2)
            if not p then return end
            p:removeItem(tId, 1)
            p:save()
        end, base + 120, pid, guid, typeId)
    end

    local verifyAt = rounds * roundMs + CFG.verify_delay
    addEvent(function(pid2, guid2, tId, n)
        local p = safePlayer(pid2, guid2)
        if not p then return end

        local cnt = countItemsInDB(guid2, tId)
        if cnt == 0 then
            logPass(p, string.format(
                "Phase 4: DB=0 apos %d rounds add/remove. Sem ghost acumulativo.", n
            ))
        elseif cnt > 0 then
            logFail(p, string.format(
                "Phase 4: DB=%d (esperado 0) apos %d rounds. Ghost item(s) persistiram!",
                cnt, n
            ))
            logFail(p, "  -> Save {com item} de um round chegou ao worker apos save {sem item} de round posterior.")
            safeRemoveAll(p, tId)
            p:save()
        else
            logFail(p, "Phase 4: Falha na query DB.")
        end
    end, verifyAt, pid, guid, typeId, rounds)

    return true
end

-- ============================================================================
-- PHASE 5  –  Burst de saves concorrentes via addEvent(0)
-- ============================================================================
--[[
  Dispara N addEvent(0) simultaneos (todos chamam player:save()).
  Com o PR#69, cada save pode ser enfileirado para workers distintos.
  Verifica que o estado final (item removido) prevalece sobre os N saves
  intermediarios (com item na fila).

  Similar ao Ph5 do stress_db.lua, mas testando itens em vez de storage.
--]]
local function runPhase5(player)
    local guid   = player:getGuid()
    local pid    = player:getId()
    local typeId = CFG.item_ns
    local bursts = 20

    log(player, string.format(
        "Phase 5: %d addEvent(0) saves concorrentes (worker pool saturation) | final DB=0...",
        bursts
    ))

    safeRemoveAll(player, typeId)

    if not player:addItem(typeId, 1, false) then
        logFail(player, "Phase 5: Falha ao criar item. Ajuste CFG.item_ns.")
        return false
    end

    -- N saves simultaneos COM item na memoria (async, satura worker pool)
    for i = 1, bursts do
        addEvent(function(pid2, guid2)
            local p = safePlayer(pid2, guid2)
            if p and not p:saveAsync() then
                logInfo(p, "Phase 5: saveAsync() retornou false (fila cheia) - esperado em saturacao.")
            end
        end, 0, pid, guid)
    end

    -- Remove e save final apos todos os bursts entrarem na fila
    addEvent(function(pid2, guid2, tId)
        local p = safePlayer(pid2, guid2)
        if not p then return end
        p:removeItem(tId, 1)
        p:save()
    end, 80, pid, guid, typeId)

    addEvent(function(pid2, guid2, tId, n)
        local p = safePlayer(pid2, guid2)
        if not p then return end

        local cnt = countItemsInDB(guid2, tId)
        if cnt == 0 then
            logPass(p, string.format(
                "Phase 5: DB=0 apos %d saves concorrentes + remove. Worker pool sem race detectada.", n
            ))
        elseif cnt > 0 then
            logFail(p, string.format(
                "Phase 5: DB=%d (esperado 0) - ghost apos %d saves concorrentes!",
                cnt, n
            ))
            logFail(p, "  -> Um dos saves do burst (com item) chegou ao worker apos o save de remocao.")
            safeRemoveAll(p, tId)
            p:save()
        else
            logFail(p, "Phase 5: Falha na query DB.")
        end
    end, 80 + CFG.verify_delay, pid, guid, typeId, bursts)

    return true
end

-- ============================================================================
-- PHASE 6  –  Snapshot reversal: [A] → save → swap por B → save
-- ============================================================================
--[[
  Troca de itens com dois snapshots em voo:
    S1 = snapshot com item A (nao-stackavel), sem item B
    S2 = snapshot sem item A, com item B (stackavel)

  Cenario real: player dropa item A, pega item B, desconecta logo depois.
  Worker correto (FIFO):    S1 → S2:  DB tem B, sem A          ✓
  Worker fora de ordem:     S2 → S1:  DB tem A (ghost!) sem B  = DUPE de A

  FALHA INDICA: item A (que foi dropado/removido) reaparece no banco.
--]]
local function runPhase6(player)
    local guid  = player:getGuid()
    local pid   = player:getId()
    local typeA = CFG.item_ns   -- nao-stackavel
    local typeB = CFG.item_st   -- stackavel (tipo diferente)

    log(player, "Phase 6: Snapshot reversal - [A]->save(S1)->remove A, add B->save(S2) | DB deve ter so B...")

    safeRemoveAll(player, typeA)
    safeRemoveAll(player, typeB)

    -- Adiciona A
    if not player:addItem(typeA, 1, false) then
        logFail(player, "Phase 6: Falha ao criar item A. Ajuste CFG.item_ns.")
        return false
    end

    -- S1: { A=1, B=0 } (async — enfileirado no worker)
    local ok1 = player:saveAsync()
    if not ok1 then
        logFail(player, "Phase 6: saveAsync() S1 retornou false - teste abortado.")
        safeRemoveAll(player, typeA)
        return false
    end

    -- Troca: remove A, adiciona B (sem save intermediario)
    player:removeItem(typeA, 1)

    if not player:addItem(typeB, 1, false) then
        logFail(player, "Phase 6: Falha ao criar item B. Ajuste CFG.item_st.")
        safeRemoveAll(player, typeA)
        player:save()
        return false
    end

    -- S2: { A=0, B=1 } (async — pendingFlushes atras de S1)
    local ok2 = player:saveAsync()
    if not ok2 then
        logFail(player, "Phase 6: saveAsync() S2 retornou false - teste pode ser inconclusivo.")
    end

    logInfo(player, string.format(
        "Phase 6: S1={A} e S2={B} enfileirados. S2 deve ganhar. Verificando em %dms...",
        CFG.verify_delay
    ))

    addEvent(function(pid2, guid2, tA, tB)
        local p = safePlayer(pid2, guid2)
        if not p then return end

        local cntA = countItemsInDB(guid2, tA)
        local cntB = countItemsInDB(guid2, tB)

        if cntA == 0 and cntB > 0 then
            logPass(p, string.format(
                "Phase 6: DB A=%d (ghost=0 OK) B=%d (presente OK). Swap correto, sem reversal.",
                cntA, cntB
            ))
        else
            if cntA > 0 then
                logFail(p, string.format(
                    "Phase 6: DB A=%d (esperado 0) - GHOST de A! S1 sobrescreveu S2.",
                    cntA
                ))
                logFail(p, "  -> Cenario real: player dropou A, pegou B, relog -> tem A de volta = DUPE!")
            end
            if cntB == 0 then
                logFail(p, "Phase 6: DB B=0 - item B sumiu. S2 nao persistiu corretamente.")
            end
        end

        safeRemoveAll(p, tA)
        safeRemoveAll(p, tB)
        p:save()
    end, CFG.verify_delay, pid, guid, typeA, typeB)

    return true
end

-- ============================================================================
-- PHASE 7  –  Multi-item: remocao parcial
-- ============================================================================
--[[
  Adiciona 3 itens nao-stackaveis (slots diferentes), salva, remove 2,
  salva novamente. O DB deve ter exatamente 1 item restante.

  Detecta se saves anteriores (com 3 itens) persistem no banco apos saves
  mais novos (com apenas 1 item), simulando remocao parcial de inventario.
--]]
local function runPhase7(player)
    local guid   = player:getGuid()
    local pid    = player:getId()
    local typeId = CFG.item_ns
    local total  = 3

    log(player, string.format(
        "Phase 7: Multi-item - add %d, save, remove %d, save, verifica DB=1...",
        total, total - 1
    ))

    safeRemoveAll(player, typeId)

    local added = 0
    for i = 1, total do
        if player:addItem(typeId, 1, false) then
            added = added + 1
        end
    end

    if added < total then
        logFail(player, string.format(
            "Phase 7: Apenas %d/%d itens adicionados (inventario cheio?).", added, total
        ))
        safeRemoveAll(player, typeId)
        return false
    end

    -- Save com 3 itens (async)
    local ok1 = player:saveAsync()
    if not ok1 then
        logFail(player, "Phase 7: saveAsync() S1 retornou false - flush nao enfileirado.")
        safeRemoveAll(player, typeId)
        return false
    end

    -- Remove total-1 itens
    for i = 1, total - 1 do
        player:removeItem(typeId, 1)
    end

    -- Save com 1 item (async, pendingFlushes)
    local ok2 = player:saveAsync()
    if not ok2 then
        logFail(player, "Phase 7: saveAsync() S2 retornou false - teste pode ser inconclusivo.")
    end

    addEvent(function(pid2, guid2, tId, expected)
        local p = safePlayer(pid2, guid2)
        if not p then return end

        local cnt = countItemsInDB(guid2, tId)
        if cnt == expected then
            logPass(p, string.format(
                "Phase 7: DB=%d (esperado %d). Remocao parcial salva corretamente.", cnt, expected
            ))
        elseif cnt > expected then
            logFail(p, string.format(
                "Phase 7: DB=%d (esperado %d) - %d item(s) EXTRA no banco! Ghost de save anterior.",
                cnt, expected, cnt - expected
            ))
            logFail(p, "  -> Save {3 itens} chegou ao worker apos save {1 item}. Player ganha items gratis ao relogar.")
        else
            logFail(p, string.format(
                "Phase 7: DB=%d (esperado %d) - item removido demais no banco. Save nao persistiu.",
                cnt, expected
            ))
        end

        safeRemoveAll(p, tId)
        p:save()
    end, CFG.verify_delay, pid, guid, typeId, 1)

    return true
end

-- ============================================================================
-- PHASE 8  –  Simulacao completa de dupe por desconexao (worst case)
-- ============================================================================
--[[
  Combina todos os vetores anteriores num unico teste worst-case:

    1. addItem
    2. Flood A: N saves COM item  (simula auto-saves enquanto item estava no inv)
    3. removeItem  (sem save)
    4. Flood B: M saves SEM item  (simula saves pos-drop/disconnect)
    5. Save final de cleanup
    6. Verifica: DB deve ser 0

  Este e o cenario exato de:
    • Player pega item, carrega por varios saves automaticos, dropa, desconecta
    • Player esta num trade, saves ocorrem, trade e cancelado, DC imediato
    • Forge: item consumido, saves pendentes, servidor reinicia antes de draining

  FALHA = cenario real que seria explorado por jogadores.
--]]
local function runPhase8(player)
    local guid   = player:getGuid()
    local pid    = player:getId()
    local typeId = CFG.item_ns
    local burstA = math.max(1, math.ceil(CFG.save_burst / 2))  -- saves COM item
    local burstB = math.max(1, CFG.save_burst - burstA)         -- saves SEM item

    log(player, string.format(
        "Phase 8: Simulacao completa - %d saves c/item + remove + %d saves s/item -> DB=0...",
        burstA, burstB
    ))
    log(player, "Phase 8: Cenario: pick up -> auto-saves -> drop/trade/DC -> verifica.")

    safeRemoveAll(player, typeId)

    if not player:addItem(typeId, 1, false) then
        logFail(player, "Phase 8: Falha ao criar item.")
        return false
    end

    -- Flood A: saves COM item (async)
    for i = 1, burstA do
        addEvent(function(pid2, guid2)
            local p = safePlayer(pid2, guid2)
            if p and not p:saveAsync() then
                logInfo(p, "Phase 8: saveAsync() flood A retornou false - esperado em saturacao.")
            end
        end, i * CFG.stagger_ms, pid, guid)
    end

    -- Remove item (sem save ainda)
    local removeAt = burstA * CFG.stagger_ms + 80
    addEvent(function(pid2, guid2, tId)
        local p = safePlayer(pid2, guid2)
        if not p then return end
        p:removeItem(tId, 1)
    end, removeAt, pid, guid, typeId)

    -- Flood B: saves SEM item (async)
    for i = 1, burstB do
        addEvent(function(pid2, guid2)
            local p = safePlayer(pid2, guid2)
            if p and not p:saveAsync() then
                logInfo(p, "Phase 8: saveAsync() flood B retornou false - esperado em saturacao.")
            end
        end, removeAt + 20 + i * CFG.stagger_ms, pid, guid)
    end

    -- Save final (async)
    local finalAt = removeAt + 20 + burstB * CFG.stagger_ms + 80
    addEvent(function(pid2, guid2)
        local p = safePlayer(pid2, guid2)
        if p and not p:saveAsync() then
            logInfo(p, "Phase 8: saveAsync() final retornou false.")
        end
    end, finalAt, pid, guid)

    -- Verifica
    addEvent(function(pid2, guid2, tId, nA, nB)
        local p = safePlayer(pid2, guid2)
        if not p then return end

        local cnt = countItemsInDB(guid2, tId)

        if cnt == 0 then
            logPass(p, string.format(
                "Phase 8: DB=0 - simulacao completa OK. %d saves c/item + remove + %d saves s/item correto.",
                nA, nB
            ))
        elseif cnt > 0 then
            logFail(p, string.format(
                "Phase 8: DB=%d (esperado 0) - ## DUPE CONFIRMADO NA SIMULACAO COMPLETA ##",
                cnt
            ))
            logFail(p, string.format(
                "Phase 8: Um dos %d saves {com item} chegou ao worker APOS um dos %d saves {sem item}.",
                nA, nB
            ))
            logFail(p, "  -> ESTE E O CENARIO EXATO explorado via trade/drop/DC rapido.")
            logFail(p, "  -> Fix urgente: FIFO estrito no drain de pendingFlushes.")
            safeRemoveAll(p, tId)
            p:save()
        else
            logFail(p, "Phase 8: Falha na query DB.")
        end
    end, finalAt + CFG.verify_delay, pid, guid, typeId, burstA, burstB)

    return true
end

-- ============================================================================
-- PHASE 9  –  Login Barrier Test (drainPlayerFlushAsync)
-- ============================================================================
--[[
  Testa a barreira de login (PR#78 commits 06-09) diretamente via
  player:drainAsyncSave(callback).

  Cenario simulado:
    1. addItem → saveAsync(S0)  → snapshot COM item, enfileirado no worker
    2. removeItem → saveAsync(S1) → snapshot SEM item (pendingFlushes se S0 em voo)
    3. drainAsyncSave() → espera flush chain completar (S0 → S1)
    4. callback verifica DB=0

  Diferenca da Phase 2:
    Phase 2 usa verifyWithRetry (polling) para verificar o DB.
    Phase 9 usa a barreira de login REAL (drainPlayerFlushAsync) que e o
    mecanismo usado no login do protocolgame.cpp. Se o callback nunca disparar,
    a fase falha por timeout (10s).

  FALHA AQUI = a barreira de login nao esta funcionando corretamente.
--]]
local function runPhase9(player)
    local guid   = player:getGuid()
    local pid    = player:getId()
    local typeId = CFG.item_ns

    logHeader(player, "Phase 9: Login Barrier Test - drainAsyncSave + callback verification")

    safeRemoveAll(player, typeId)

    if not player:addItem(typeId, 1, false) then
        logFail(player, "Phase 9: Falha ao criar item. Ajuste CFG.item_ns.")
        return false
    end

    -- S0: snapshot COM item (async)
    local ok0 = player:saveAsync()
    if not ok0 then
        logFail(player, "Phase 9: saveAsync() S0 retornou false.")
        safeRemoveAll(player, typeId)
        return false
    end

    -- Remove item (simula player dropando item entre autosave e logout)
    player:removeItem(typeId, 1)

    -- S1: snapshot SEM item (async — pendingFlushes se S0 ainda em voo)
    local ok1 = player:saveAsync()
    if not ok1 then
        logInfo(player, "Phase 9: saveAsync() S1 retornou false (flush em andamento) - normal.")
    end

    log(player, "Phase 9: S0 e S1 enfileirados. Chamando drainAsyncSave()...")

    -- Timeout de seguranca: se callback nunca disparar, falha apos 12s
    local timedOut = false
    local timeoutEvent = addEvent(function(pid2, guid2)
        local p = safePlayer(pid2, guid2)
        if p then
            logFail(p, "Phase 9: TIMEOUT - drainAsyncSave callback nao disparou em 12s.")
            logFail(p, "  -> A barreira de login pode estar com problema no flushChainCallbacks.")
            safeRemoveAll(p, typeId)
            p:save()
        end
        timedOut = true
    end, 12000, pid, guid)

    -- Usa a barreira de login real
    player:drainAsyncSave(function(drained)
        if timedOut then
            -- Timeout ja tratou, ignorar callback tardio
            return
        end
        stopEvent(timeoutEvent)

        local p = safePlayer(pid, guid)
        if not p then
            logFail(nil, "Phase 9: Player desconectou durante drainAsyncSave.")
            return
        end

        if not drained then
            logFail(p, "Phase 9: drainAsyncSave retornou false - flush chain falhou ou timeout interno.")
            safeRemoveAll(p, typeId)
            p:save()
            return
        end

        -- Barreira completou: verifica DB
        local cnt = countItemsInDB(guid, typeId)
        if cnt == 0 then
            logPass(p, string.format(
                "Phase 9: DB=0 apos drainAsyncSave. Barreira de login funcional! " ..
                "(S0 c/item -> S1 s/item -> drain -> DB=0)"
            ))
        elseif cnt > 0 then
            logFail(p, string.format(
                "Phase 9: DB=%d (esperado 0) - ## BARREIRA DE LOGIN FALHOU ##", cnt
            ))
            logFail(p, "  -> drainAsyncSave retornou true mas DB ainda contem o item.")
            logFail(p, "  -> Possivel: S1 nao foi executado, ou flush chain ignorou pendingFlushes.")
            safeRemoveAll(p, typeId)
            p:save()
        else
            logFail(p, "Phase 9: Falha na query DB.")
        end
    end)

    return true
end

-- ============================================================================
-- TALKACTION
-- ============================================================================
local dupeAction = TalkAction("/dupe")
dupeAction:separator(" ")
dupeAction:access(true)

function dupeAction.onSay(player, words, param)
    if not player:getGroup():getAccess() then
        return false
    end

    local cmd = (param or ""):lower():match("^%s*(.-)%s*$")

    -- ── INFO ──────────────────────────────────────────────────────────────────
    if cmd == "info" then
        local lines = {
            "=== DupeTest | 9 fases | item duplication vulnerability scanner ===",
            "Ph1  Ghost item: flood saves -> remove -> verifica DB=0",
            "Ph2  * SNAPSHOT RACE: add->save(S1)->remove->save(S2) | S2 deve ganhar",
            "Ph3  Stackable count: add 200->save->remove 100->save->verifica SUM=100",
            "Ph4  5 rounds: add->save->remove->save | final DB=0",
            "Ph5  20x addEvent(0) saves simultaneos + remove | DB=0",
            "Ph6  Reversal: [A]->save->swap por B->save | somente B no DB",
            "Ph7  Multi-item: add 3->remove 2->save | DB deve ter 1",
            "Ph8  Simulacao completa: flood c/item + remocao + flood s/item",
            "Ph9  * BARREIRA DE LOGIN: drainAsyncSave + callback | testa PR#78",
            "Uso: /dupe [start|1-9|info|clean]",
            string.format("CFG: item_ns=%d item_st=%d verify_delay=%dms",
                CFG.item_ns, CFG.item_st, CFG.verify_delay),
        }
        for _, l in ipairs(lines) do
            player:sendTextMessage(MSG_BLUE, l)
        end
        return false
    end

    -- ── CLEAN ─────────────────────────────────────────────────────────────────
    if cmd == "clean" then
        if activeRuns[player:getGuid()] then
            log(player, "Teste em andamento – aguarde conclusao antes de limpar.")
            return false
        end
        safeRemoveAll(player, CFG.item_ns)
        safeRemoveAll(player, CFG.item_st)
        player:save()
        log(player, "Itens de teste removidos do inventario e save feito.")
        return false
    end

    local phaseMap = {
        [1] = runPhase1, [2] = runPhase2, [3] = runPhase3, [4] = runPhase4,
        [5] = runPhase5, [6] = runPhase6, [7] = runPhase7, [8] = runPhase8,
        [9] = runPhase9,
    }

    -- ── FASE INDIVIDUAL ───────────────────────────────────────────────────────
    local phaseNum = tonumber(cmd)
    if phaseNum then
        if activeRuns[player:getGuid()] then
            log(player, "Teste em andamento – aguarde conclusao antes de iniciar nova fase.")
            return false
        end
        if hasPreExistingTestItems(player, player:getGuid()) then
            logFail(player, string.format(
                "Inventario ja contem itens dos tipos %d e/ou %d. Use /dupe clean primeiro.",
                QA_ITEM_NS, QA_ITEM_ST
            ))
            return false
        end
        local fn = phaseMap[phaseNum]
        if fn then
            activeRuns[player:getGuid()] = true
            local ok, err = xpcall(fn, debug.traceback, player)
            if not ok then
                logFail(player, "Fase " .. phaseNum .. " encontrou erro: " .. tostring(err))
                activeRuns[player:getGuid()] = false
            else
                local maxDuration = math.max(
                    CFG.save_burst * CFG.stagger_ms + 100 + CFG.verify_delay + 500,
                    CFG.verify_delay + 800 * 3 + 500,
                    2 * CFG.verify_delay + 800,
                    5 * 300 + CFG.verify_delay + 500,
                    14000                              -- Ph9: timeout 12s + buffer
                ) + 500
                local guid = player:getGuid()
                addEvent(function(g) activeRuns[g] = false end, maxDuration, guid)
            end
        else
            player:sendTextMessage(MSG_BLUE, "Fase invalida. Use 1-9, start, info ou clean.")
        end
        return false
    end

    -- ── START – todas as fases em sequencia ───────────────────────────────────
    if cmd == "" or cmd == "start" or cmd == "all" then
        if activeRuns[player:getGuid()] then
            log(player, "DupeTest ja em andamento – aguarde conclusao.")
            return false
        end
        if hasPreExistingTestItems(player, player:getGuid()) then
            logFail(player, string.format(
                "Inventario ja contem itens dos tipos %d e/ou %d. Use /dupe clean primeiro.",
                QA_ITEM_NS, QA_ITEM_ST
            ))
            return false
        end
        activeRuns[player:getGuid()] = true

        -- Cada fase precisa de:
        --   Phase 3 tem 2x verify_delay aninhado → mais lenta
        --   Phase 4 tem rounds * roundMs + verify_delay
        -- Usamos uma janela conservadora que cobre o pior caso (Ph3/Ph4).
        local phaseDuration = math.max(
            5 * 300 + CFG.verify_delay + 500,        -- Ph4: rounds*roundMs + verify + buf
            2 * CFG.verify_delay + 800,              -- Ph3: 2x addEvent aninhado
            12000 + 2000                             -- Ph9: timeout 12s + buffer
        ) + 500  -- buffer extra entre fases

        logHeader(player, string.format(
            "=== DupeTest | 9 fases | item_ns=%d item_st=%d | ~%.0fs total ===",
            CFG.item_ns, CFG.item_st, (9 * phaseDuration) / 1000
        ))

        local pid = player:getId()
        local guid = player:getGuid()

        for i = 1, 9 do
            addEvent(function(pid2, g2, idx)
                local p = safePlayer(pid2, g2)
                if not p then return end
                logHeader(p, string.format("-- Iniciando Phase %d/9 --", idx))
                local fn = phaseMap[idx]
                if fn then fn(p) end
            end, (i - 1) * phaseDuration, pid, guid, i)
        end
        -- Resumo final
        phaseFailed[guid] = nil
        addEvent(function(pid2, g)
            local p = safePlayer(pid2, g)
            if p then
                if phaseFailed[g] then
                    logHeader(p, "=== DupeTest COMPLETO - UMA OU MAIS FASES FALHARAM ===")
                else
                    logHeader(p, "=== DupeTest COMPLETO - TODAS AS 9 FASES PASSARAM ===")
                end
            end
            activeRuns[g] = false
            phaseFailed[g] = nil
        end, 9 * phaseDuration + 1500, pid, guid)

        logHeader(player, string.format(
            "Fases espacadas ~%.0fs cada | Ph9 usa drainAsyncSave (barreira real) | resultados aparecem gradualmente.",
            phaseDuration / 1000
        ))
        return false
    end

    player:sendTextMessage(MSG_BLUE, "Uso: /dupe [start|1-9|info|clean]")
    return false
end

dupeAction:accountType(6)
dupeAction:register()
