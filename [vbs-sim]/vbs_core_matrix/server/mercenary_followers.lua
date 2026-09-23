-- =====================================================================
-- MATRIX MUHAFIZ/KURYE TAKİPÇİLERİ / server/mercenary_followers.lua
-- (KATMAN 1)
--
-- ★ KATMAN 23 DÜZELTMESİ: Matrix.Mercenary.* fonksiyon kancaları artık
-- diagnostics/ModularSimulationQueue tarafından probe edilebilir. Önceki
-- sürüm yalnızca RegisterNetEvent handler'ları taşıyordu; hiçbir isim
-- alanı kancası yoktu — bu yüzden matrix_diagnostics.lua'daki
-- `Matrix.Mercenary.RequestSummon` probe'u nil dönüyordu.
-- =====================================================================

Matrix.Mercenary = Matrix.Mercenary or {}

local SummonCooldown = {} -- [src] = sonraki izinli cagri zamani (Unix saniye)
local FollowerCount  = {} -- [src] = su anki aktif takipci sayisi
local DeployedBots   = {} -- [src] = { [botId] = true } -- bu oyuncuya atanmis, sahada olan KALICI ajanlar

-- ★ [MODUL 10] src -> { [i] = followerNetId } -- client/mercenary_followers.
-- lua'nin ZATEN VAR OLAN Followers listesinden (anti-dupe networked bot
-- entity'leri) turetilen network id'ler; server/hitsquad.lua'nin kolektif
-- hedef havuzu ICIN tek kaynak -- ikinci bir "takipci konumu" tablosu ICAT
-- EDILMEZ, yalnizca client'in zaten sahip oldugu netId'ler rapor edilir.
local FollowerNetIds = {}

-- =====================================================================
-- ★ ANTI-DUPE FIX (MODUL 1): /muhafizcagir ARTIK YENI BIR AJAN KIMLIGI
-- YARATMAZ. Sadece Matrix.Bots icinde ZATEN VAR OLAN, bu oyuncunun
-- citizenid'ine ait (handler_citizenid), status='active' VE
-- state.activity='idle' olan EN KUCUK id'li devsirilmis
-- (bkz. Matrix.Recruitment.Promote / outcome='recruited') ajani bulur, onu
-- 'deployed' olarak isaretler ve O SPESIFIK, KALICI ENTITY'YI (Matrix.
-- SpawnBot ile ayni networked-ped yolu) cagirir. Havuzda uygun ajan yoksa
-- cagri REDDEDILIR -- hicbir yeni kimlik/entity uretilmez.
-- =====================================================================
local function FindDeployableOwnedBot(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' then return nil end

    local bestId, bestBot = nil, nil
    for id, bot in pairs(Matrix.Bots) do
        if bot.handler_citizenid == citizenid
            and bot.status == 'active'
            and bot.state and bot.state.activity == 'idle'
            and (not bestId or id < bestId) then
            bestId, bestBot = id, bot
        end
    end
    return bestId, bestBot
end

--- ★ SAF/SENKRON KANCA: diagnostics tarafindan probe edilebilir.
--- Config.Mercenary.EnablePhysicalFollowers KAPALI iken erken ve GÜVENLİ
--- döner (Safe-Exit) — nil/global runtime hatası ASLA fırlatmaz.
function Matrix.Mercenary.RequestSummon(src)
    if type(src) ~= 'number' or src <= 0 then return false, 'bad_src' end
    if not Config.Mercenary or not Config.Mercenary.EnablePhysicalFollowers then
        return false, 'disabled'
    end

    local now = Matrix.Now()
    if SummonCooldown[src] and now < SummonCooldown[src] then
        return false, 'cooldown'
    end

    local current = FollowerCount[src] or 0
    if current >= (Config.Mercenary.MaxFollowers or 2) then
        return false, 'max_reached'
    end

    local pstate = Matrix.GetOrCreatePlayerState and Matrix.GetOrCreatePlayerState(src)
    local citizenid = pstate and pstate.citizenid
    if type(citizenid) ~= 'string' or citizenid == '' then
        return false, 'citizen_unresolved'
    end

    local botId, bot = FindDeployableOwnedBot(citizenid)
    if not botId then
        return false, 'no_recruited_agents'
    end

    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then
        return false, 'ped_unresolved'
    end

    local heading    = GetEntityHeading(ped)
    local offset     = (current + 1) * (Config.Mercenary.SummonRadius or 3.0)
    local spawnCoords = GetOffsetFromEntityInWorldCoords(ped, (current == 0) and 1.0 or -1.0, -offset, 0.0)
    local spawnVec4  = vector4(spawnCoords.x, spawnCoords.y, spawnCoords.z, heading)

    -- Zaten sahadaysa (baska bir yerde deploy edilmisti) once cekilir;
    -- AYNI kalici kimlik yeniden konumlandirilir -- yeni entity YOK.
    if bot.state.spawned then
        Matrix.DespawnBot(botId)
    end

    local spawnOk, netIdOrReason = Matrix.SpawnBot(botId, spawnVec4)
    if not spawnOk then
        return false, 'spawn_failed'
    end

    bot.state.activity     = 'deployed'
    bot.state.assigned_src = src
    Matrix.MarkBotDirty(botId)

    DeployedBots[src] = DeployedBots[src] or {}
    DeployedBots[src][botId] = true

    SummonCooldown[src] = now + math.floor((Config.Mercenary.SummonCooldownMs or 5000) / 1000)
    FollowerCount[src]   = current + 1
    return true, FollowerCount[src], botId, netIdOrReason, bot.dna_id, bot.name
end

--- ★ SAF/SENKRON KANCA: client 'matrix:server:mercenary:reportDismiss'
--- event'inden geldiginde sayaci senkronlar VE atanmis ajanlari havuza
--- ('idle') geri birakir -- KALICI kimlikler asla silinmez, sadece
--- devreden cikarilir (Matrix.DespawnBot) ve tekrar cagrilabilir hale gelir.
function Matrix.Mercenary.ReportDismiss(src, remainingCount)
    if type(src) ~= 'number' or src <= 0 then return false end
    FollowerCount[src] = math.max(0, tonumber(remainingCount) or 0)

    local assigned = DeployedBots[src]
    if assigned then
        for botId in pairs(assigned) do
            local bot = Matrix.Bots[botId]
            if bot then
                if bot.state.spawned then Matrix.DespawnBot(botId) end
                bot.state.activity     = 'idle'
                bot.state.assigned_src = nil
                Matrix.MarkBotDirty(botId)
            end
        end
        DeployedBots[src] = nil
    end
    return true
end

--- Salt-okunur getter — diagnostics/HUD/rapor icin.
function Matrix.Mercenary.GetFollowerCount(src)
    return FollowerCount[src] or 0
end


--- ★ [MODUL 10] SAF/SENKRON KANCA: client'in en son bildirdigi takipci
--- network id listesinin bir KOPYASINI dondurur (cagiran taraf orijinal
--- tabloyu mutasyona ugratamaz). server/hitsquad.lua kolektif hedef
--- havuzunu bu listeden (NetworkGetEntityFromNetworkId ile) kurar.
function Matrix.Mercenary.GetFollowerNetIds(src)
    local ids = FollowerNetIds[src]
    if not ids then return {} end
    local copy = {}
    for i = 1, #ids do copy[i] = ids[i] end
    return copy
end

--- ★ [MODUL 10] Bu oyuncuya su an atanmis (deployed) tum bot id'lerini
--- dondurur -- server/hitsquad.lua'nin ally-role tespiti (guard-role
--- following bot filtreleme) icin kullanilir.
function Matrix.Mercenary.GetDeployedBotIds(src)
    local assigned = DeployedBots[src]
    if not assigned then return {} end
    local ids = {}
    for botId in pairs(assigned) do ids[#ids + 1] = botId end
    return ids
end


RegisterNetEvent('matrix:server:mercenary:requestSummon', function()
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    if not Config.Mercenary or not Config.Mercenary.EnablePhysicalFollowers then return end

    local ok, newCountOrReason, botId, netId, dnaId, botName = Matrix.Mercenary.RequestSummon(src)
    if not ok then
        local msg = (newCountOrReason == 'cooldown')
            and 'Takipci cagirma kisa bir sure sonra tekrar kullanilabilir.'
            or (newCountOrReason == 'max_reached')
                and 'Zaten maksimum takipci sayisina ulastiniz.'
                or (newCountOrReason == 'no_recruited_agents')
                    and 'Devsirilmis ve bos (idle) bir ajaniniz yok. Once /sorgu ile bir aday devsirin.'
                    or 'Cagri baslatilamadi.'
        TriggerClientEvent('matrix:client:actionNotify', src, false, msg)
        return
    end

    TriggerClientEvent('matrix:client:mercenary:summonApproved', src, newCountOrReason, botId, netId, dnaId, botName)
end)


RegisterNetEvent('matrix:server:mercenary:reportDismiss', function(remainingCount)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    Matrix.Mercenary.ReportDismiss(src, remainingCount)
end)


-- ★ [MODUL 10] client/mercenary_followers.lua roster her degistiginde
-- (cagirma/olum/salma) guncel netId listesini gonderir -- ACE/permission
-- kontrolu GEREKMEZ (yalnizca kendi src'sinin listesini yazabilir, source
-- her zaman event'i tetikleyen client'tir, spoof edilemez).
RegisterNetEvent('matrix:server:mercenary:reportFollowerNetIds', function(netIds)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    if type(netIds) ~= 'table' then netIds = {} end

    local clean = {}
    for _, netId in ipairs(netIds) do
        local n = tonumber(netId)
        if n and n > 0 then clean[#clean + 1] = n end
    end
    FollowerNetIds[src] = clean
end)


AddEventHandler('playerDropped', function()
    local src = source
    SummonCooldown[src] = nil
    FollowerCount[src]   = nil
    FollowerNetIds[src]  = nil
    -- ★ ANTI-DUPE: oyuncu dusse bile atanmis KALICI ajanlar 'idle'ye
    -- donderilir, silinmez -- bir sonraki oturumda tekrar cagrilabilirler.
    local assigned = DeployedBots[src]
    if assigned then
        for botId in pairs(assigned) do
            local bot = Matrix.Bots[botId]
            if bot then
                if bot.state.spawned then Matrix.DespawnBot(botId) end
                bot.state.activity     = 'idle'
                bot.state.assigned_src = nil
                Matrix.MarkBotDirty(botId)
            end
        end
        DeployedBots[src] = nil
    end
end)


exports('RequestSummon',  function(src)               return Matrix.Mercenary.RequestSummon(src) end)
exports('ReportDismiss',  function(src, remaining)    return Matrix.Mercenary.ReportDismiss(src, remaining) end)
exports('GetFollowerCount', function(src)             return Matrix.Mercenary.GetFollowerCount(src) end)
exports('GetFollowerNetIds', function(src)            return Matrix.Mercenary.GetFollowerNetIds(src) end)
exports('GetDeployedBotIds', function(src)            return Matrix.Mercenary.GetDeployedBotIds(src) end)
