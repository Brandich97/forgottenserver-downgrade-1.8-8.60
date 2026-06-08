--[[
================================================================================
  dupetest.lua  -  RevScript  (TFS 1.8 / 8.60 downgrade fork)
  Teste de Vulnerabilidades de Duplicação de Itens
  Repositório: Mateuzkl/forgottenserver-downgrade-1.8-8.60
================================================================================

  Propósito
  ─────────
  Detecta falhas de integridade de itens exploráveis como "dupes":
  situações onde o sistema de save threadado (PR #69) deixa itens no banco
  após remoção da memória, ou não reflete o estado correto no DB.

  USO (apenas GMs com getAccess() == true):
    !dupetest start   - roda todas as 8 fases em sequência
    !dupetest 1-8     - roda uma fase individualmente
    !dupetest info    - descreve cada fase
    !dupetest clean   - remove itens de teste do inventário

  FASES:
  ┌────┬─────────────────────────────────────────┬──────────────────────────────────┐
  │ Ph │ Vetor de Dupe                           │ O que detecta                    │
  ├────┼─────────────────────────────────────────┼──────────────────────────────────┤
  │  1 │ Ghost item após save flood              │ Save antigo sobrescreve novo     │
  │  2 │ SNAPSHOT RACE: add→save→remove→save ★  │ S1 executa após S2 no worker     │
  │  3 │ Stackable count integrity               │ Coins extras/faltando no DB      │
  │  4 │ N rounds add/remove com save em cada    │ Ghost acumulativo por round       │
  │  5 │ Concurrent saves burst (addEvent 0)     │ Worker pool race                 │
  │  6 │ Snapshot reversal: [A]→save→swap B→save │ Item A persiste após swap        │
  │  7 │ Multi-item remoção parcial              │ Item extra no DB                 │
  │  8 │ Simulação completa: flood c/ e s/ item  │ Cenário real de dupe por DC      │
  └────┴─────────────────────────────────────────┴──────────────────────────────────┘
  ★ = fase mais crítica para o PR #69

  PRÉ-REQUISITO:
    Inventário não deve conter itens dos tipos CFG.item_ns e CFG.item_st
    antes de rodar. Use !dupetest clean para garantir.

  SEGURANÇA:
    • Não acessa tabelas de produção diretamente (apenas leitura para verificação).
    • Todos os itens criados são removidos ao final de cada fase.
    • Requer player:getGroup():getAccess() == true.
================================================================================
--]]

-- ============================================================================
-- CONFIGURAÇÃO  –  ajuste para o seu servidor
-- ============================================================================
local CFG = {
    -- Item NÃO-stackável de teste (qualquer item simples serve)
    -- 3280 = Fire Sword;
    item_ns       = 3280,

    -- Item STACKÁVEL de teste
    -- 3031 = Gold Coin
    item_st       = 3031,

    -- Número de saves rápidos por fase de flood
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

local activeRun = false

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
    -- Se hasFailed for true, mostra em vermelho; senão, em azul
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

local function safePlayer(pid)
    local p = Player(pid)
    if not p then
        print("[DupeTest] Player id=" .. tostring(pid) .. " desconectou durante o teste.")
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

-- Soma count total de stackável em player_items (Gold Coin, etc.)
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

-- Remove todos os itens de um tipo do inventário (safety cleanup)
local function safeRemoveAll(player, itemTypeId)
    player:removeItem(itemTypeId, 100000)
end

-- ============================================================================
-- PHASE 1  –  Ghost item após save flood
-- ============================================================================
--[[
  Adiciona 1 item não-stackável, dispara N saves em rafada, depois remove
  o item e salva uma última vez. Verifica que o DB não retém ghost item.

  FALHA INDICA: um dos saves do flood (com item) executou no worker APÓS
  o save de remoção (sem item), sobrescrevendo o estado correto.
  → Fila do worker não é FIFO para itens de player.
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

    -- Flood de saves COM o item na memória
    for i = 1, CFG.save_burst do
        addEvent(function(pid2)
            local p = safePlayer(pid2)
            if p then p:save() end
        end, i * CFG.stagger_ms, pid)
    end

    -- Remove o item e faz save final
    local removeAt = CFG.save_burst * CFG.stagger_ms + 100
    addEvent(function(pid2, tId)
        local p = safePlayer(pid2)
        if not p then return end
        p:removeItem(tId, 1)
        p:save()
    end, removeAt, pid, typeId)

    -- Verifica DB
    addEvent(function(pid2, guid2, tId)
        local p = safePlayer(pid2)
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
            logFail(p, "Phase 1: Falha na query DB (retornou -1). Verifique player_items e conexão.")
        end
    end, removeAt + CFG.verify_delay, pid, guid, typeId)

    return true
end

-- ============================================================================
-- PHASE 2  –  SNAPSHOT RACE  ★  FASE MAIS CRÍTICA
-- ============================================================================
--[[
  Replica o cenário exato de dupe por desconexão/trade:

    1. addItem         → item na MEMÓRIA
    2. player:save()   → snapshot S1 enfileirado: { item presente }
    3. removeItem      → item removido da MEMÓRIA (sem save ainda)
    4. player:save()   → snapshot S2 enfileirado: { item ausente  }

  Worker FIFO correto:  S1 escreve item → S2 apaga item   → DB=0 ✓
  Worker fora de ordem: S2 apaga (nada) → S1 escreve item → DB=1 = DUPE!

  Cenário real explorado por jogadores:
    pick up item → drop item/trade/DC imediato → relog
    → item reaparece no inventário a partir do DB corrompido.

  FALHA AQUI = DUPE BUG CONFIRMADO no flushPlayerSave / pendingFlushes.
--]]
local function runPhase2(player)
    local guid   = player:getGuid()
    local pid    = player:getId()
    local typeId = CFG.item_ns

    log(player, "Phase 2: SNAPSHOT RACE - add->save(S1)->remove->save(S2) | S2 deve ser o estado final.")
    log(player, "Phase 2: FAIL aqui = dupe bug real no ordering do worker thread (PR #69).")

    safeRemoveAll(player, typeId)

    -- 1. Adiciona item (apenas em memória)
    if not player:addItem(typeId, 1, false) then
        logFail(player, "Phase 2: Falha ao criar item. Ajuste CFG.item_ns.")
        return false
    end

    -- 2. Save S1: snapshot COM item → enfileirado no worker
    local s1 = player:save()

    -- 3. Remove da MEMÓRIA sem salvar
    player:removeItem(typeId, 1)

    -- 4. Save S2: snapshot SEM item (deve ser o estado final)
    local s2 = player:save()

    logInfo(player, string.format(
        "Phase 2: S1=%s S2=%s | Dois saves enfileirados. Verificando DB em %dms...",
        tostring(s1), tostring(s2), CFG.verify_delay
    ))

    addEvent(function(pid2, guid2, tId)
        local p = safePlayer(pid2)
        if not p then return end

        local cnt = countItemsInDB(guid2, tId)

        if cnt == 0 then
            logPass(p, "Phase 2: DB=0 - S2 (sem item) foi o estado final. FIFO ordering OK. Sem dupe risk.")
        elseif cnt > 0 then
            logFail(p, string.format(
                "Phase 2: DB=%d (esperado 0) - ## DUPE BUG CONFIRMADO ##", cnt
            ))
            logFail(p, "  -> S1 {item presente} executou APOS S2 {item removido} no worker thread.")
            logFail(p, "  -> Player relogando teria o item de volta no inventario = ITEM DUPLICADO!")
            logFail(p, "  -> Fix: garantir FIFO em SaveManager::onPlayerFlushed + pendingFlushes drain.")
            safeRemoveAll(p, tId)
            p:save()
        else
            logFail(p, "Phase 2: Falha na query DB. Verifique conexão e tabela player_items.")
        end
    end, CFG.verify_delay, pid, guid, typeId)

    return true
end

-- ============================================================================
-- PHASE 3  –  Stackable count integrity
-- ============================================================================
--[[
  Testa que o count de stackáveis se mantém correto após:
    add 200 coins → save → verifica SUM=200
    remove 100    → save → verifica SUM=100

  Um dupe de stackável surge se um snapshot antigo (count maior)
  sobrescreve um snapshot mais novo (count menor), resultado em
  coins extras no banco na próxima sessão.
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
        local p = safePlayer(pid2)
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
            local p3 = safePlayer(pid3)
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
        addEvent(function(pid2, tId)
            local p = safePlayer(pid2)
            if not p then return end
            p:addItem(tId, 1, false)
            p:save()
        end, base, pid, typeId)

        -- removeItem + save
        addEvent(function(pid2, tId)
            local p = safePlayer(pid2)
            if not p then return end
            p:removeItem(tId, 1)
            p:save()
        end, base + 120, pid, typeId)
    end

    local verifyAt = rounds * roundMs + CFG.verify_delay
    addEvent(function(pid2, guid2, tId, n)
        local p = safePlayer(pid2)
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
  Dispara N addEvent(0) simultâneos (todos chamam player:save()).
  Com o PR#69, cada save pode ser enfileirado para workers distintos.
  Verifica que o estado final (item removido) prevalece sobre os N saves
  intermediários (com item na fila).

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

    -- N saves simultâneos COM item na memória
    for i = 1, bursts do
        addEvent(function(pid2)
            local p = safePlayer(pid2)
            if p then p:save() end
        end, 0, pid)
    end

    -- Remove e save final após todos os bursts entrarem na fila
    addEvent(function(pid2, tId)
        local p = safePlayer(pid2)
        if not p then return end
        p:removeItem(tId, 1)
        p:save()
    end, 80, pid, typeId)

    addEvent(function(pid2, guid2, tId, n)
        local p = safePlayer(pid2)
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
    S1 = snapshot com item A (não-stackável), sem item B
    S2 = snapshot sem item A, com item B (stackável)

  Cenário real: player dropa item A, pega item B, desconecta logo depois.
  Worker correto (FIFO):    S1 → S2:  DB tem B, sem A          ✓
  Worker fora de ordem:     S2 → S1:  DB tem A (ghost!) sem B  = DUPE de A

  FALHA INDICA: item A (que foi dropado/removido) reaparece no banco.
--]]
local function runPhase6(player)
    local guid  = player:getGuid()
    local pid   = player:getId()
    local typeA = CFG.item_ns   -- não-stackável
    local typeB = CFG.item_st   -- stackável (tipo diferente)

    log(player, "Phase 6: Snapshot reversal - [A]->save(S1)->remove A, add B->save(S2) | DB deve ter so B...")

    safeRemoveAll(player, typeA)
    safeRemoveAll(player, typeB)

    -- Adiciona A
    if not player:addItem(typeA, 1, false) then
        logFail(player, "Phase 6: Falha ao criar item A. Ajuste CFG.item_ns.")
        return false
    end

    -- S1: { A=1, B=0 }
    player:save()

    -- Troca: remove A, adiciona B (sem save intermediário)
    player:removeItem(typeA, 1)

    if not player:addItem(typeB, 1, false) then
        logFail(player, "Phase 6: Falha ao criar item B. Ajuste CFG.item_st.")
        safeRemoveAll(player, typeA)
        player:save()
        return false
    end

    -- S2: { A=0, B=1 }
    player:save()

    logInfo(player, string.format(
        "Phase 6: S1={A} e S2={B} enfileirados. S2 deve ganhar. Verificando em %dms...",
        CFG.verify_delay
    ))

    addEvent(function(pid2, guid2, tA, tB)
        local p = safePlayer(pid2)
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
-- PHASE 7  –  Multi-item: remoção parcial
-- ============================================================================
--[[
  Adiciona 3 itens não-stackáveis (slots diferentes), salva, remove 2,
  salva novamente. O DB deve ter exatamente 1 item restante.

  Detecta se saves anteriores (com 3 itens) persistem no banco após saves
  mais novos (com apenas 1 item), simulando remoção parcial de inventário.
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

    -- Save com 3 itens
    player:save()

    -- Remove total-1 itens
    for i = 1, total - 1 do
        player:removeItem(typeId, 1)
    end

    -- Save com 1 item
    player:save()

    addEvent(function(pid2, guid2, tId, expected)
        local p = safePlayer(pid2)
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
-- PHASE 8  –  Simulação completa de dupe por desconexão (worst case)
-- ============================================================================
--[[
  Combina todos os vetores anteriores num único teste worst-case:

    1. addItem
    2. Flood A: N saves COM item  (simula auto-saves enquanto item estava no inv)
    3. removeItem  (sem save)
    4. Flood B: M saves SEM item  (simula saves pós-drop/disconnect)
    5. Save final de cleanup
    6. Verifica: DB deve ser 0

  Este é o cenário exato de:
    • Player pega item, carrega por vários saves automáticos, dropa, desconecta
    • Player está num trade, saves ocorrem, trade é cancelado, DC imediato
    • Forge: item consumido, saves pendentes, servidor reinicia antes de draining

  FALHA = cenário real que seria explorado por jogadores.
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

    -- Flood A: saves COM item
    for i = 1, burstA do
        addEvent(function(pid2)
            local p = safePlayer(pid2)
            if p then p:save() end
        end, i * CFG.stagger_ms, pid)
    end

    -- Remove item (sem save ainda)
    local removeAt = burstA * CFG.stagger_ms + 80
    addEvent(function(pid2, tId)
        local p = safePlayer(pid2)
        if not p then return end
        p:removeItem(tId, 1)
    end, removeAt, pid, typeId)

    -- Flood B: saves SEM item
    for i = 1, burstB do
        addEvent(function(pid2)
            local p = safePlayer(pid2)
            if p then p:save() end
        end, removeAt + 20 + i * CFG.stagger_ms, pid)
    end

    -- Save final
    local finalAt = removeAt + 20 + burstB * CFG.stagger_ms + 80
    addEvent(function(pid2)
        local p = safePlayer(pid2)
        if p then p:save() end
    end, finalAt, pid)

    -- Verifica
    addEvent(function(pid2, guid2, tId, nA, nB)
        local p = safePlayer(pid2)
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
-- TALKACTION
-- ============================================================================
local dupeAction = TalkAction("!dupetest")
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
            "=== DupeTest | 8 fases | item duplication vulnerability scanner ===",
            "Ph1  Ghost item: flood saves -> remove -> verifica DB=0",
            "Ph2  * SNAPSHOT RACE: add->save(S1)->remove->save(S2) | S2 deve ganhar",
            "Ph3  Stackable count: add 200->save->remove 100->save->verifica SUM=100",
            "Ph4  5 rounds: add->save->remove->save | final DB=0",
            "Ph5  20x addEvent(0) saves simultaneos + remove | DB=0",
            "Ph6  Reversal: [A]->save->swap por B->save | somente B no DB",
            "Ph7  Multi-item: add 3->remove 2->save | DB deve ter 1",
            "Ph8  Simulacao completa: flood c/item + remocao + flood s/item",
            "Uso: !dupetest [start|1-8|info|clean]",
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
        if activeRun then
            log(player, "Teste em andamento – aguarde conclusão antes de limpar.")
            return false
        end
        safeRemoveAll(player, CFG.item_ns)
        safeRemoveAll(player, CFG.item_st)
        player:save()
        log(player, "Itens de teste removidos do inventário e save feito.")
        return false
    end

    local phaseMap = {
        [1] = runPhase1, [2] = runPhase2, [3] = runPhase3, [4] = runPhase4,
        [5] = runPhase5, [6] = runPhase6, [7] = runPhase7, [8] = runPhase8,
    }

    -- ── FASE INDIVIDUAL ───────────────────────────────────────────────────────
    local phaseNum = tonumber(cmd)
    if phaseNum then
        if activeRun then
            log(player, "Teste em andamento – aguarde conclusão antes de iniciar nova fase.")
            return false
        end
        local fn = phaseMap[phaseNum]
        if fn then
            fn(player)
        else
            player:sendTextMessage(MSG_BLUE, "Fase inválida. Use 1-8, start, info ou clean.")
        end
        return false
    end

    -- ── START – todas as fases em sequência ───────────────────────────────────
    if cmd == "" or cmd == "start" or cmd == "all" then
        if activeRun then
            log(player, "DupeTest já em andamento – aguarde conclusão.")
            return false
        end
        activeRun = true

        -- Cada fase precisa de:
        --   Phase 3 tem 2x verify_delay aninhado → mais lenta
        --   Phase 4 tem rounds * roundMs + verify_delay
        -- Usamos uma janela conservadora que cobre o pior caso (Ph3/Ph4).
        local phaseDuration = math.max(
            5 * 300 + CFG.verify_delay + 500,        -- Ph4: rounds*roundMs + verify + buf
            2 * CFG.verify_delay + 800               -- Ph3: 2x addEvent aninhado
        ) + 500  -- buffer extra entre fases

        logHeader(player, string.format(
            "=== DupeTest | 8 fases | item_ns=%d item_st=%d | ~%.0fs total ===",
            CFG.item_ns, CFG.item_st, (8 * phaseDuration) / 1000
        ))

        local pid = player:getId()

        for i = 1, 8 do
            addEvent(function(pid2, idx)
                local p = safePlayer(pid2)
                if not p then return end
                logInfo(p, string.format("-- Iniciando Phase %d/8 --", idx))
                local fn = phaseMap[idx]
                if fn then fn(p) end
            end, (i - 1) * phaseDuration, pid, i)
        end

        -- Resumo final
        addEvent(function(pid2)
            local p = safePlayer(pid2)
            if p then
                logHeader(p, "=== DupeTest COMPLETO. Revise os [PASS]/[FAIL] acima. ===")
                logInfo(p, "Phase 2 e a mais critica: FAIL la = dupe real confirmado no PR#69.")
            end
            activeRun = false
        end, 8 * phaseDuration + 1500, pid)

        logHeader(player, string.format(
            "Fases espacadas ~%.0fs cada | resultados aparecem gradualmente.",
            phaseDuration / 1000
        ))
        return false
    end

    player:sendTextMessage(MSG_BLUE, "Uso: !dupetest [start|1-8|info|clean]")
    return false
end

dupeAction:accountType(6)
dupeAction:access(true)
dupeAction:register()
