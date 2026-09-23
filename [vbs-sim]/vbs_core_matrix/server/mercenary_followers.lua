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


-- =====================================================================
-- ★ [MODUL 13.2] TAKTIK MUHABERE (COMMS LINK) GUARD
-- =====================================================================
local VALID_TASK_MODES_SERVER = { hold = true, guard = true, observe = true, follow = true, attack = true }

local function IsCoordsInDeadZone(coords)
    if not coords then return false end
    for _, zone in ipairs(Config.Logistics.DeadZones or {}) do
        local dx, dy = coords.x - zone.coords.x, coords.y - zone.coords.y
        if math.sqrt(dx * dx + dy * dy) <= zone.radius then return true end
    end
    return false
end

local function HasActiveBurnerPhone(src)
    local ok, count = pcall(function()
        return exports['ox_inventory']:Search(src, 'count', Config.CommsLink.BurnerPhoneItem or 'burner_phone')
    end)
    return ok and type(count) == 'number' and count > 0
end

--- ★ SAF/SENKRON KANCA: bir komutanin (commanderSrc) bir bota (botId)
--- emir ULASTIRABILIP ULASTIRAMAYACAGINI belirler.
---   * Config.CommsLink.PhysicalCommandRadius ICINDE ise HER ZAMAN
---     gecerli -- telsiz/Acik Hat ARANMAZ.
---   * Radius DISINDA ise commanderSrc'nin AKTIF bir Acik Hat
---     (burner_phone) sahibi OLMASI VE botun bulundugu koordinatin bir
---     Dead Zone (Config.Logistics.DeadZones ile AYNI harita, ikinci bir
---     "kor bolge" listesi ICAT EDILMEZ) ICINDE OLMAMASI GEREKIR.
function Matrix.Mercenary.CanReachBot(commanderSrc, botId)
    local bot = Matrix.Bots[botId]
    if not bot then return false, 'bot_missing' end

    local netId = bot.state and bot.state.net_id
    local botPed = (type(netId) == 'number' and netId > 0) and NetworkGetEntityFromNetworkId(netId) or nil
    if not botPed or botPed == 0 or not DoesEntityExist(botPed) then return false, 'bot_unreachable' end

    local commanderPed = GetPlayerPed(commanderSrc)
    if not commanderPed or commanderPed == 0 then return false, 'commander_unresolved' end

    local botCoords = GetEntityCoords(botPed)
    local dist = #(GetEntityCoords(commanderPed) - botCoords)

    if dist <= (Config.CommsLink.PhysicalCommandRadius or 8.0) then
        return true
    end

    if not HasActiveBurnerPhone(commanderSrc) then
        return false, 'no_burner_phone'
    end

    if IsCoordsInDeadZone(botCoords) then
        return false, 'static_blocked'
    end

    return true
end


-- =====================================================================
-- ★ [MODUL 13/11] TAKTIK MOD ATAMASI -- SERVER TARAFI ONAYI
-- client/mercenary_followers.lua ARTIK modu DOGRUDAN UYGULAMAZ; ilgili
-- botlar icin panik (Matrix.Wounds.IsBotPanicking) VE muhabere hatti
-- (Matrix.Mercenary.CanReachBot) BURADA dogrulanir, yalnizca ONAYLANAN
-- botlarin netId'leri client'a geri bildirilir. Panik REDDI bir telsiz
-- bulteni olarak da geri bildirilir.
-- =====================================================================
RegisterNetEvent('matrix:server:mercenary:assignTaskMode', function(mode)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    if not VALID_TASK_MODES_SERVER[mode] then return end

    local botIds = Matrix.Mercenary.GetDeployedBotIds(src)
    local approvedNetIds, rejections = {}, {}

    for _, botId in ipairs(botIds) do
        local bot = Matrix.Bots[botId]
        if bot then
            local reachOk, reachReason = Matrix.Mercenary.CanReachBot(src, botId)
            if not reachOk then
                rejections[#rejections + 1] = { botId = botId, reason = reachReason }
            elseif Matrix.Wounds and Matrix.Wounds.IsBotPanicking and Matrix.Wounds.IsBotPanicking(botId) then
                rejections[#rejections + 1] = { botId = botId, reason = 'panicking' }
            else
                local netId = bot.state and bot.state.net_id
                if type(netId) == 'number' and netId > 0 then
                    approvedNetIds[#approvedNetIds + 1] = netId
                end
            end
        end
    end

    TriggerClientEvent('matrix:client:mercenary:taskModeApproved', src, mode, approvedNetIds, rejections)
end)


-- =====================================================================
-- ★ [MODUL 13.4] HQ BARON UZAKTAN YONETIM
-- Rutbeli subay (Config.Hierarchy.MinRankLevelForCommand -- MEVCUT
-- Matrix.Hierarchy.HasCommandAuthority ile AYNI yetki, ikinci bir
-- "komuta yetkisi" ICAT EDILMEZ), fiziksel olarak yaninda durmadan,
-- herhangi bir oyuncuya atanmis (deployed) bota F10/G/H panelinden
-- UZAKTAN emir (hold/guard/attack/follow) gonderebilir -- AYNI muhabere
-- hatti kurallari (Matrix.Mercenary.CanReachBot) ve panik kontrolu
-- gecerlidir. Onay, botun SAHIBI OLAN oyuncunun client'ina iletilir --
-- yalnizca o client Followers[] uzerinde native gorev atayabilir.
-- =====================================================================
RegisterNetEvent('matrix:server:mercenary:remoteCommand', function(targetBotId, mode)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    if not VALID_TASK_MODES_SERVER[mode] then return end

    local pstate = Matrix.GetOrCreatePlayerState and Matrix.GetOrCreatePlayerState(src)
    local citizenid = pstate and pstate.citizenid
    if not citizenid or not (Matrix.Hierarchy and Matrix.Hierarchy.HasCommandAuthority
        and Matrix.Hierarchy.HasCommandAuthority(citizenid)) then
        TriggerClientEvent('matrix:client:actionNotify', src, false, 'Bu komutu vermek icin yeterli rutbeniz yok.')
        return
    end

    targetBotId = tonumber(targetBotId)
    local bot = targetBotId and Matrix.Bots[targetBotId]
    if not bot then
        TriggerClientEvent('matrix:client:actionNotify', src, false, 'Bot bulunamadi.')
        return
    end

    local reachOk, reachReason = Matrix.Mercenary.CanReachBot(src, targetBotId)
    if not reachOk then
        local msg = (reachReason == 'no_burner_phone') and '[BZZZT] -- bag-lan-ti kes-ildi... Acik Hat yok.'
            or (reachReason == 'static_blocked') and '[BZZZT] -- bag-lan-ti kes-ildi... siber parazit/kor bolge.'
            or 'Komut hedefe ulasamadi.'
        TriggerClientEvent('matrix:client:actionNotify', src, false, msg)
        return
    end

    if Matrix.Wounds and Matrix.Wounds.IsBotPanicking and Matrix.Wounds.IsBotPanicking(targetBotId) then
        TriggerClientEvent('matrix:client:actionNotify', src, false,
            '[BZZZT] -- Komutanim ates hatti cok yogun, kafami kaldiramiyorum, pozisyonu terk edemem!')
        return
    end

    local ownerSrc = bot.state and bot.state.assigned_src
    local netId    = bot.state and bot.state.net_id
    if ownerSrc and type(netId) == 'number' and netId > 0 then
        -- ★ [FIX] hold/guard/observe UZAKTAN atandiginda, komutu veren
        -- rutbelinin O ANKI canli koordinati/baktigi yon ankraj olarak
        -- mühürlenir ve botun SAHIBI OLAN client'a iletilir -- aksi halde
        -- o client kendi PlayerPedId()'sini (Baron degil, botun sahibi)
        -- ankraj sanip yanlis noktaya kilitlerdi.
        local remoteAnchor = nil
        if mode == 'hold' or mode == 'guard' or mode == 'observe' then
            local commanderPed = GetPlayerPed(src)
            if commanderPed and commanderPed ~= 0 then
                remoteAnchor = {
                    coords  = GetEntityCoords(commanderPed),
                    heading = GetEntityHeading(commanderPed)
                }
            end
        end
        TriggerClientEvent('matrix:client:mercenary:taskModeApproved', ownerSrc, mode, { netId }, {}, remoteAnchor)
    end
end)


exports('RequestSummon',  function(src)               return Matrix.Mercenary.RequestSummon(src) end)
exports('ReportDismiss',  function(src, remaining)    return Matrix.Mercenary.ReportDismiss(src, remaining) end)
exports('GetFollowerCount', function(src)             return Matrix.Mercenary.GetFollowerCount(src) end)
exports('GetFollowerNetIds', function(src)            return Matrix.Mercenary.GetFollowerNetIds(src) end)
exports('GetDeployedBotIds', function(src)            return Matrix.Mercenary.GetDeployedBotIds(src) end)
exports('CanReachBot',    function(src, botId)        return Matrix.Mercenary.CanReachBot(src, botId) end)
