-- =====================================================================
-- ★★★ KATMAN 7 [T4] FAZ 1: TOPLU SATIŞ HUB'LARI (District Distribution) ★★★
-- YENİ dosya. Mevcut hiçbir tabloya/formüle dokunmaz -- yalnızca zaten var
-- olan sistemlere (matrix_trap_stash_<id> ox_inventory stash'i, server/
-- market.lua Matrix.CashDecay.Deposit kirli-nakit hattı, server/bureau.lua
-- [T4] Matrix.Bureau.IsLockedDown) bağlanır.
--
-- F10 -> "Toplu Satış Hub Ata" (client menüsü bu resource'ta değil; burada
-- sunucu tarafı yetki/kalıcılık uç noktası hazırdır -- bkz. RegisterNetEvent
-- 'matrix:server:districtHubs:assign' ve test komutu /hubata) kritik bir
-- kavşağa bir hub atar. Atanan hub, HubDemandCycleSeconds periyodunda trap
-- house'un ortak deposundan (matrix_trap_stash_<id>) sabit/RNG'siz bir
-- miktar çeker ve MEVCUT Config.Market.StreetBasePricePerGram birim
-- fiyatıyla kirli nakite çevirir -- yeni bir ekonomi formülü İCAT EDİLMEZ.
--
-- BÜRO KİLİDİ: server/bureau.lua [T4]'ün 'matrix:internal:bureauLockdown'
-- yayınını dinler (raidIssued/raidResolved İLE AYNI pasif desen). Kilit
-- aktifken o trap house'a bağlı TÜM hub'lar dondurulur (active=0, locked=1)
-- -- demand-cycle ticker'ı onları otomatik atlar.
--
-- SIFIR RNG: bu dosyada math.random YOK.
-- =====================================================================

Matrix.DistrictHubs = Matrix.DistrictHubs or {}

local pairs, ipairs, tonumber, type = pairs, ipairs, tonumber, type

local Hubs      = {}   -- [id] = { id, trap_house_id, label, coords, active, locked }
local dirtyHubs = {}

local function Reply(src, msg)
    if type(src) == 'number' and src > 0 then
        TriggerClientEvent('chat:addMessage', src, { args = { '[HUB]', msg } })
    else
        print(('[MATRIX:DISTRICT_HUBS:CONSOLE] %s'):format(msg))
    end
end

local function IsValidCoords(c)
    if type(c) ~= 'table' and type(c) ~= 'userdata' and type(c) ~= 'vector3' and type(c) ~= 'vector4' then return false end
    if c.x == nil or c.y == nil or c.z == nil then return false end
    if type(c.x) ~= 'number' or type(c.y) ~= 'number' or type(c.z) ~= 'number' then return false end
    if c.x ~= c.x or c.y ~= c.y or c.z ~= c.z then return false end
    return true
end

-- =====================================================================
-- LOAD / PERSIST (LoadTrapHouses İLE AYNI kalıp)
-- =====================================================================
function Matrix.DistrictHubs.LoadHubs()
    local rows = MySQL.query.await('SELECT * FROM matrix_district_hubs', {}) or {}
    for _, row in ipairs(rows) do
        Hubs[row.id] = {
            id            = row.id,
            trap_house_id = row.trap_house_id,
            label         = row.label or ('Hub #' .. row.id),
            coords        = vector3(row.coord_x or 0.0, row.coord_y or 0.0, row.coord_z or 0.0),
            active        = row.active == 1,
            locked        = row.locked == 1
        }
    end
    Matrix.Log('DISTRICT_HUB', '%d Toplu Satis Hub RAM onbellege yuklendi.', #rows)
end

CreateThread(function()
    Matrix.DistrictHubs.LoadHubs()
end)

local function FlushDirtyHubs()
    for id in pairs(dirtyHubs) do
        local hub = Hubs[id]
        if hub then
            MySQL.prepare('UPDATE matrix_district_hubs SET active = ?, locked = ? WHERE id = ?',
                { hub.active and 1 or 0, hub.locked and 1 or 0, id })
        end
        dirtyHubs[id] = nil
    end
end

CreateThread(function()
    local interval = Config.Persistence.TrapHouseFlushIntervalMs or 20000
    while true do
        Wait(interval)
        FlushDirtyHubs()
    end
end)

-- =====================================================================
-- ATAMA (F10 -> "Toplu Satış Hub Ata" arka ucu)
-- =====================================================================
function Matrix.DistrictHubs.Assign(trapHouseId, label, coords, dispatcherSrc)
    trapHouseId = tonumber(trapHouseId)
    if not trapHouseId or not Matrix.TrapHouses or not Matrix.TrapHouses[trapHouseId] then
        return false, 'no_trap_house'
    end
    if not IsValidCoords(coords) then return false, 'bad_coords' end

    if Matrix.Bureau and Matrix.Bureau.IsLockedDown and Matrix.Bureau.IsLockedDown(trapHouseId) then
        return false, 'bureau_lockdown'
    end

    local existingForTrap = 0
    for _, hub in pairs(Hubs) do
        if hub.trap_house_id == trapHouseId then existingForTrap = existingForTrap + 1 end
    end
    if existingForTrap >= (Config.DistrictHubs.MaxPerTrapHouse or 3) then
        return false, 'hub_limit_reached'
    end

    label = (type(label) == 'string' and label ~= '') and label or ('Hub #' .. trapHouseId)

    MySQL.insert([[
        INSERT INTO matrix_district_hubs (trap_house_id, label, coord_x, coord_y, coord_z, active, locked, created_at)
        VALUES (?, ?, ?, ?, ?, 1, 0, NOW())
    ]], { trapHouseId, label, coords.x, coords.y, coords.z },
    function(insertId)
        if not insertId then return end
        Hubs[insertId] = {
            id = insertId, trap_house_id = trapHouseId, label = label,
            coords = vector3(coords.x, coords.y, coords.z), active = true, locked = false
        }
        Matrix.Log('DISTRICT_HUB', 'Yeni Toplu Satis Hub #%d (trap #%d, %s) kuruldu.', insertId, trapHouseId, label)
    end)

    return true
end

RegisterNetEvent('matrix:server:districtHubs:assign', function(trapHouseId, label, coords)
    local src = source
    local ok, reason = Matrix.DistrictHubs.Assign(trapHouseId, label, coords, src)
    if not ok then
        Reply(src, reason == 'bureau_lockdown'
            and '[ADLI ANOMALI: BURO KILIDI DEVREDE] - Hub atamasi reddedildi.'
            or ('Hub atamasi basarisiz: %s'):format(tostring(reason)))
    else
        Reply(src, 'Toplu Satis Hub atama istegi gonderildi (async). /hublistele ile dogrulayin.')
    end
end)

-- /hubata [trapHouseId] [label] [x] [y] [z] -- F10 client menüsü henüz bu
-- resource'ta değilken de sunucu tarafını test etmek için (bkz. /traphouseekle
-- İLE AYNI disiplin: boşlukla ayrılmış argümanlar, virgül YOK).
RegisterCommand('hubata', function(src, args)
    local trapHouseId = tonumber(args[1])
    local label        = args[2]
    local x, y, z       = tonumber(args[3]), tonumber(args[4]), tonumber(args[5])
    if not trapHouseId or not x or not y or not z then
        Reply(src, 'Kullanim: /hubata [trapHouseId] [label] [x] [y] [z]'); return
    end

    local ok, reason = Matrix.DistrictHubs.Assign(trapHouseId, label, vector3(x, y, z), src)
    if not ok then
        Reply(src, ('Hub atamasi basarisiz: %s'):format(tostring(reason)))
    else
        Reply(src, 'Hub atama istegi gonderildi (async). /hublistele ile dogrulayin.')
    end
end, false)

RegisterCommand('hublistele', function(src)
    local count = 0
    for id, hub in pairs(Hubs) do
        count = count + 1
        Reply(src, ('#%d trap#%d "%s" | Aktif:%s Kilit:%s'):format(
            id, hub.trap_house_id, hub.label, tostring(hub.active), tostring(hub.locked)))
    end
    Reply(src, ('--- Toplam %d hub ---'):format(count))
end, false)


-- ★ KATMAN 7 FAZ 2: F10 "Otonom Depo Lojistigi" paneli. getRegionalFinancialReport
-- (server/market.lua) ILE AYNI desen: duz metin satirlari, yeni bir formul
-- ICAT EDILMEZ -- yalnizca yukaridaki Hubs tablosu okunur.
lib.callback.register('matrix:callback:getDistrictHubsReport', function(src)
    local lines = { '=== OTONOM DEPO LOJISTIGI (TOPLU SATIS HUBLARI) ===' }

    local count = 0
    for id, hub in pairs(Hubs) do
        count = count + 1
        local house = Matrix.TrapHouses and Matrix.TrapHouses[hub.trap_house_id]
        lines[#lines + 1] = ('Hub #%d -> Trap #%d (%s) | "%s" | Aktif:%s | Kilit:%s'):format(
            id, hub.trap_house_id, (house and house.label) or '?', hub.label,
            tostring(hub.active), tostring(hub.locked))
    end
    if count == 0 then
        lines[#lines + 1] = 'Henuz atanmis bir Toplu Satis Hub yok.'
    end

    return lines
end)

-- =====================================================================
-- ★ [OTONOM ALT HUCRE BOLUNMESI] FragmentTerritory (SLIME MODEL)
-- Bir otonom cete lideri (bot.role=='Leader') 'deceased' olarak dustugunde
-- (bkz. server/main.lua Matrix.RemoveBot -> TriggerEvent
-- 'matrix:internal:gangLeaderDeceased') o trap house'a bagli TUM Toplu
-- Satis Hub'lari parcalanir. 0-RNG formul: trapHouseId CIFT ise 2, TEK ise
-- 3 Alt Hucre (Splinter Cell) uretilir. Her Alt Hucre, MEVCUT
-- ProcessHubDemandCycle toplu-satis motoruna (asagida) EK olarak periyodik
-- agresif pusu (server/rendezvous.lua'nin AYNI 'matrix:client:rendezvous:
-- triggerAmbush' event'i + Config.Rendezvous parametreleri) ve siber
-- mesaj sizintisi (server/bureau.lua'nin AYNI Matrix.Bureau.
-- TriggerPropaganda formulu) uretir -- yeni bir paralel ekonomi/formul
-- ICAT EDILMEZ, mevcut motorlar yeniden kullanilir.
-- =====================================================================
local SplinterCells = {} -- [id] = { id, parent_hub_id, trap_house_id, splinter_index, coords, active }
local nextSplinterId = 1

--- ★ [FIX] Tekil satir MySQL.insert artik dongu ICINDE cagrilmiyor -- bir
--- parcalanma olayindaki TUM Alt Hucre satirlari (Config.DistrictHubs'a
--- gore en fazla 2-3) tek bir MySQL.transaction.await ile ATOMIK olarak
--- yazilir (Rule #2: explicit transaction, kismi yazim YOK). Eskiden
--- PersistSplinterCell'in insertId callback'i cell.db_id'ye yaziyordu --
--- bu alan hicbir yerde OKUNMUYORDU, bu yuzden batch'e gecerken guvenle
--- dusuruldu.
local function PersistSplinterCellsBatch(cells)
    if #cells == 0 then return true end

    local queries = {}
    for _, cell in ipairs(cells) do
        queries[#queries + 1] = {
            query = [[
                INSERT INTO matrix_splinter_cells
                    (parent_hub_id, trap_house_id, splinter_index, coord_x, coord_y, coord_z, active, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, NOW())
            ]],
            values = {
                cell.parent_hub_id, cell.trap_house_id, cell.splinter_index,
                cell.coords.x, cell.coords.y, cell.coords.z, cell.active and 1 or 0
            }
        }
    end

    local ok, result = pcall(function() return MySQL.transaction.await(queries) end)
    if not ok or result == false then
        Matrix.Log('DISTRICT_HUB', '[HATA] PersistSplinterCellsBatch transaction basarisiz: %s', tostring(result))
        return false
    end
    return true
end

function Matrix.DistrictHubs.FragmentTerritory(trapHouseId, deadLeaderBotId)
    trapHouseId = tonumber(trapHouseId)
    if not trapHouseId then return false, 'bad_trap_house' end

    -- 0-RNG formul: cift trapHouseId -> 2 Alt Hucre, tek -> 3 Alt Hucre.
    local splinterCount = (trapHouseId % 2 == 0) and 2 or 3

    local fragmentedHubs = 0
    local newCells = {}
    for hubId, hub in pairs(Hubs) do
        if hub.trap_house_id == trapHouseId and hub.active then
            hub.active = false
            dirtyHubs[hubId] = true
            fragmentedHubs = fragmentedHubs + 1

            for i = 1, splinterCount do
                local cell = {
                    id             = nextSplinterId,
                    parent_hub_id  = hubId,
                    trap_house_id  = trapHouseId,
                    splinter_index = i,
                    coords         = hub.coords,
                    active         = true
                }
                nextSplinterId = nextSplinterId + 1
                SplinterCells[cell.id] = cell
                newCells[#newCells + 1] = cell
            end
        end
    end

    PersistSplinterCellsBatch(newCells)

    Matrix.Log('DISTRICT_HUB',
        '[FRAGMENTATION] Cete lideri Bot #%s dustu (Trap #%d) -- %d hub parcalandi, %dx Alt Hucre (Splinter Cell) uretildi (0-RNG: %s).',
        tostring(deadLeaderBotId), trapHouseId, fragmentedHubs, fragmentedHubs * splinterCount,
        (trapHouseId % 2 == 0) and 'cift->2' or 'tek->3')

    -- ★ [KATMAN 7 REGRESYON] Her bolunme matrix_gang_learning_core'a bir
    -- ogrenme kaydi isler -- FragmentTerritory'nin ne kadar sik/agresif
    -- tetiklendiginin kalici izi (aggression_level = uretilen toplam Alt
    -- Hucre sayisi, RNG YOK -- salt bir sayac).
    pcall(function()
        MySQL.insert([[
            INSERT INTO matrix_gang_learning_core (trap_house_id, splinter_count, aggression_level, updated_at)
            VALUES (?, ?, ?, NOW())
        ]], { trapHouseId, splinterCount, fragmentedHubs * splinterCount })
    end)

    return true, fragmentedHubs, splinterCount
end

AddEventHandler('matrix:internal:gangLeaderDeceased', function(trapHouseId, deadLeaderBotId)
    local ok, err = pcall(Matrix.DistrictHubs.FragmentTerritory, trapHouseId, deadLeaderBotId)
    if not ok then
        Matrix.Log('DISTRICT_HUB', '[HATA] FragmentTerritory basarisiz (yutuldu): %s', tostring(err))
    end
end)

-- =====================================================================
-- BÜRO KİLİDİ DİNLEYİCİSİ (raidIssued/raidResolved İLE AYNI pasif desen)
-- =====================================================================
AddEventHandler('matrix:internal:bureauLockdown', function(trapHouseId, active)
    for id, hub in pairs(Hubs) do
        if hub.trap_house_id == trapHouseId then
            hub.locked = active and true or false
            if active then hub.active = false end
            dirtyHubs[id] = true
        end
    end
    if active then
        Matrix.Log('DISTRICT_HUB', 'Trap #%d icin tum hublar Buro Kilidi nedeniyle donduruldu.', trapHouseId)
    end
end)

-- =====================================================================
-- TALEP DÖNGÜSÜ: sabit-miktar (RNG'siz) toplu satış
-- Depo: matrix_trap_stash_<trapHouseId> (MEVCUT ox_inventory stash --
-- server/logistics.lua Matrix.Logistics.DispatchAmmoRun İLE AYNI API).
-- Ciro: Matrix.CashDecay.Deposit (server/market.lua, MEVCUT kirli-nakit
-- hattı) + Config.Market.StreetBasePricePerGram (MEVCUT birim fiyat).
-- =====================================================================
local function ProcessHubDemandCycle(hubId, hub)
    if not hub.active or hub.locked then return end
    if Matrix.Bureau and Matrix.Bureau.IsLockedDown and Matrix.Bureau.IsLockedDown(hub.trap_house_id) then return end

    local stashId = ('matrix_trap_stash_%d'):format(hub.trap_house_id)
    local invOk, inv = pcall(exports['ox_inventory'].GetInventory, exports['ox_inventory'], stashId)
    if not invOk or type(inv) ~= 'table' or type(inv.items) ~= 'table' then return end

    local batchGrams = Config.DistrictHubs.SaleBatchGrams or 10

    for _, item in pairs(inv.items) do
        if type(item) == 'table' and type(item.name) == 'string' and (tonumber(item.count) or 0) >= batchGrams then
            -- ★ CRITICAL FIX: RemoveItem'in GERCEK basari boolean'i (2. donus
            -- degeri) kontrol edilmeden kirli nakit yatirilirsa, depodan
            -- urun hic eksilmeden sinirsiz nakit uretilebilirdi.
            local removeOk, removed = pcall(function()
                return exports['ox_inventory']:RemoveItem(stashId, item.name, batchGrams, item.metadata)
            end)
            if removeOk and removed == true then
                local proceeds = batchGrams * (Config.Market.StreetBasePricePerGram or 20.0)
                Matrix.CashDecay.Deposit(hub.trap_house_id, proceeds)
                Matrix.Log('DISTRICT_HUB', 'Hub #%d (trap #%d, %s) toplu satis: %s x%d, ciro=%.1f (kirli nakite eklendi).',
                    hubId, hub.trap_house_id, hub.label, item.name, batchGrams, proceeds)
            end
            break
        end
    end
end

CreateThread(function()
    while true do
        Wait((Config.DistrictHubs.DemandCycleSeconds or 45) * 1000)
        for hubId, hub in pairs(Hubs) do
            local ok, err = pcall(ProcessHubDemandCycle, hubId, hub)
            if not ok then
                Matrix.Log('DISTRICT_HUB', '[HATA] ProcessHubDemandCycle #%d hata verdi (yutuldu): %s', hubId, tostring(err))
            end
        end
    end
end)

-- ★ Alt Hucre (Splinter Cell) dongusu: MEVCUT ProcessHubDemandCycle ILE
-- AYNI periyotta (Config.DistrictHubs.DemandCycleSeconds) calisir, ama
-- normal hub'lardan farkli olarak HER turda ek olarak (a) trap house'un
-- en yakinindaki oyunculara agresif pusu sizdirir VE (b) Buro'nun siber
-- sizinti/propaganda formulunu ilerletir.
local function ProcessSplinterCellCycle(cellId, cell)
    if not cell.active then return end

    -- (a) AGRESIF PUSU: server/rendezvous.lua'nin AYNI client event'i +
    -- AYNI Config.Rendezvous ambush parametreleri, tum online oyunculardan
    -- Alt Hucre'nin AmbushAggroRadius'u icindekilere sizdirilir.
    local players = GetPlayers and GetPlayers() or {}
    for _, playerIdStr in ipairs(players) do
        local targetSrc = tonumber(playerIdStr)
        if targetSrc then
            local ped = GetPlayerPed(targetSrc)
            if ped and ped ~= 0 then
                local okCoords, coords = pcall(GetEntityCoords, ped)
                if okCoords and coords and #(coords - cell.coords) <= (Config.Rendezvous.AmbushAggroRadius or 60.0) then
                    TriggerClientEvent('matrix:client:rendezvous:triggerAmbush', targetSrc, {
                        coords       = cell.coords,
                        ped_model    = Config.Rendezvous.AmbushPedModel,
                        weapon       = Config.Rendezvous.AmbushWeapon,
                        squad_size   = Config.Rendezvous.AmbushSquadSize,
                        spawn_radius = Config.Rendezvous.AmbushSpawnRadius,
                        aggro_radius = Config.Rendezvous.AmbushAggroRadius
                    })
                    Matrix.Log('DISTRICT_HUB',
                        '[ALT HUCRE PUSUSU] Splinter Cell #%d (trap #%d) -> oyuncu src=%d icin pusu sizdirildi.',
                        cellId, cell.trap_house_id, targetSrc)
                end
            end
        end
    end

    -- (b) SIBER MESAJ SIZINTISI: MEVCUT Matrix.Bureau.TriggerPropaganda
    -- formulu (propagandaMomentum + cyberLeakHeatmap) yeniden kullanilir.
    if Matrix.Bureau and Matrix.Bureau.TriggerPropaganda then
        pcall(Matrix.Bureau.TriggerPropaganda, cell.trap_house_id)
    end

    -- Toplu satis motoru: Alt Hucre de ayni depo-tuketim mantigini
    -- (ProcessHubDemandCycle'in AYNISI) kullanir -- yeni bir hub kaydi gibi davranir.
    ProcessHubDemandCycle(cellId, { active = true, locked = false, trap_house_id = cell.trap_house_id, label = ('Alt Hucre #%d'):format(cellId) })
end

CreateThread(function()
    while true do
        Wait((Config.DistrictHubs.DemandCycleSeconds or 45) * 1000)
        for cellId, cell in pairs(SplinterCells) do
            local ok, err = pcall(ProcessSplinterCellCycle, cellId, cell)
            if not ok then
                Matrix.Log('DISTRICT_HUB', '[HATA] ProcessSplinterCellCycle #%d hata verdi (yutuldu): %s', cellId, tostring(err))
            end
        end
    end
end)