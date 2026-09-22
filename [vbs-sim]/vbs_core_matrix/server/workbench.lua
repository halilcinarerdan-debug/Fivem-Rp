-- =====================================================================
-- MATRIX WORKBENCH / server/workbench.lua  (KATMAN 6 — YENİ)
--
-- Kirli Ev Silah Tamir Tezgahı + Paketleme Odası. server/forensics.lua'ya
-- HİÇ DOKUNULMADI: tamir tamamlandığında forensics.lua'nın MEVCUT
-- Matrix.Forensics.WipeBallisticRecord fonksiyonu (aynen /namludegistir'in
-- yaptığı gibi) çağrılır. Fark: para yerine Config.Workbench.RequiredItems
-- listesindeki bileşenler tüketilir VE oyuncu fiziksel olarak trap house
-- iç mekanının içinde (workbench yakınında) olmalıdır.
--
-- Paketleme Odası, YENİ bir ekonomi formülü İCAT ETMEZ — trap house'daki
-- dealer botlarını mevcut Kitchen motorunun 'distribution' aktivitesine
-- (server/kitchen.lua ProcessMinuteCycle zaten bunu okur, DEĞİŞTİRİLMEDİ)
-- geçirip/geri alır.
-- =====================================================================


Matrix.Workbench = Matrix.Workbench or {}


local pairs, ipairs, type, tostring = pairs, ipairs, type, tostring
local tonumber, math                = tonumber, math
local math_huge                     = math.huge
local GetPlayerPed                  = GetPlayerPed
local GetEntityCoords               = GetEntityCoords
local TriggerClientEvent            = TriggerClientEvent


local function Reply(src, msg)
    if type(src) == 'number' and src > 0 then
        TriggerClientEvent('chat:addMessage', src, { args = { '[WORKBENCH]', msg } })
    else
        print(('[MATRIX:WORKBENCH:CONSOLE] %s'):format(msg))
    end
end


local function VectorDistance(a, b)
    if not a or not b then return math_huge end
    return #(a - b)
end


local function HasCommandAuthority(src)
    if not (Matrix.Hierarchy and Matrix.Hierarchy.HasCommandAuthority) then return true end
    local state = Matrix.GetOrCreatePlayerState(src)
    if not state or not state.citizenid then return false end
    return Matrix.Hierarchy.HasCommandAuthority(state.citizenid)
end


--- Oyuncunun şu an bir trap house iç mekanının İÇİNDE olduğunu ve o
--- mekanın içindeki tezgah/paketleme koordinatına yeterince yakın
--- olduğunu doğrular. trap_house_interior.lua yüklü değilse (savunmacı
--- geri düşüş) yalnızca "içeride mi" kontrolü atlanır — konum bazlı
--- doğrulama olmadan çalışmaya devam eder.
local function VerifyInsideTrapHouse(src, localPos)
    if not (Matrix.TrapHouseInterior and Matrix.TrapHouseInterior.GetPlayerTrapHouse) then
        return true, nil
    end


    local trapHouseId = Matrix.TrapHouseInterior.GetPlayerTrapHouse(src)
    if not trapHouseId then return false, nil end


    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false, trapHouseId end
    local coords = GetEntityCoords(ped)
    if localPos and VectorDistance(coords, localPos) > 3.0 then
        return false, trapHouseId
    end
    return true, trapHouseId
end


-- =====================================================================
-- [W1] SİLAH TAMİR TEZGAHI — nakit YOK, yalnızca bileşen tüketimi.
-- =====================================================================
function Matrix.Workbench.RepairWeapon(src, weaponSlot)
    if type(src) ~= 'number' or src <= 0 then return false, 'bad_src' end
    weaponSlot = tonumber(weaponSlot)
    if not weaponSlot then return false, 'bad_slot' end


    local shell = Config.TrapHouseInterior and Config.TrapHouseInterior.Shell
    local ok = VerifyInsideTrapHouse(src, shell and shell.WorkbenchPos)
    if not ok then
        Reply(src, 'Tezgahın yanında değilsiniz (bir trap house içine girip tezgaha yaklaşın).')
        return false, 'not_at_workbench'
    end


    local okSlot, weaponItem = pcall(function() return exports['ox_inventory']:GetSlot(src, weaponSlot) end)
    if not okSlot or type(weaponItem) ~= 'table' or type(weaponItem.name) ~= 'string' then
        Reply(src, 'Belirtilen slotta silah bulunamadı.')
        return false, 'no_weapon'
    end


    if not (Config.BlackMarket and Config.BlackMarket.ReplaceableWeaponItems and Config.BlackMarket.ReplaceableWeaponItems[weaponItem.name]) then
        Reply(src, 'Bu silah türü için tezgah tamiri desteklenmiyor.')
        return false, 'not_replaceable'
    end


    -- Bileşen kontrolü: HEPSİ mevcut olmalı, tümü ya da hiçbiri tüketilir.
    for _, req in ipairs(Config.Workbench.RequiredItems) do
        local countOk, have = pcall(function() return exports['ox_inventory']:Search(src, 'count', req.item) end)
        have = (countOk and tonumber(have)) or 0
        if have < req.count then
            Reply(src, ('Eksik bileşen: %s (x%d gerekli).'):format(req.label, req.count))
            return false, 'missing_component'
        end
    end


    for _, req in ipairs(Config.Workbench.RequiredItems) do
        local removeOk = pcall(function() return exports['ox_inventory']:RemoveItem(src, req.item, req.count) end)
        if not removeOk then
            Reply(src, 'Bileşenler tüketilirken bir hata oluştu.')
            return false, 'consume_failed'
        end
    end


    local oldMeta   = weaponItem.metadata or {}
    local oldSerial = oldMeta.weapon_serial


    local state = Matrix.GetOrCreatePlayerState(src)
    local citizenid = (state and state.citizenid) or ('SRC-%d'):format(src)


    local newSerial
    if Matrix.BlackMarket and Matrix.BlackMarket.GenerateWeaponSerial then
        newSerial = Matrix.BlackMarket.GenerateWeaponSerial(citizenid, weaponItem.name)
    else
        newSerial = ('WB-%s-%07X'):format(weaponItem.name:sub(-6):upper(), (GetGameTimer() + weaponSlot) % 0xFFFFFFF)
    end


    -- ★ server/forensics.lua'ya DOKUNULMADI — /namludegistir'in KENDİSİNİN
    -- kullandığı, hiç değiştirilmemiş fonksiyon çağrılıyor.
    if type(oldSerial) == 'string' and oldSerial ~= '' and Matrix.Forensics and Matrix.Forensics.WipeBallisticRecord then
        pcall(Matrix.Forensics.WipeBallisticRecord, oldSerial)
    end


    Matrix.Inventory.MergeMetadata(tostring(src), weaponSlot, {
        weapon_serial   = newSerial,
        shots_fired     = 0,
        durability      = 100.0,
        jam_accumulator = 0.0,
        jammed          = false,
        description     = '[TEZGAH TAMİRİ]\nYiv-set yeniden raybalandı, Büro balistik arşivi tamamen silindi.'
    })


    TriggerClientEvent('matrix:client:weaponJamStateChanged', src, weaponSlot, false)
    Reply(src, ('%s tezgahta tamir edildi. Büro balistik arşivi tamamen kör edildi.'):format(weaponItem.label or weaponItem.name))
    Matrix.Log('WORKBENCH', '[TEZGAH TAMİRİ] src=%d silah=%s eski-seri=%s yeni-seri=%s',
        src, weaponItem.name, tostring(oldSerial), newSerial)
    return true
end


RegisterNetEvent('matrix:server:workbench:repairWeapon', function(weaponSlot)
    Matrix.Workbench.RepairWeapon(source, weaponSlot)
end)


-- =====================================================================
-- [W2] PAKETLEME ODASI — mevcut Kitchen 'distribution' aktivitesini
-- trap house başına toplu olarak aç/kapat.
-- =====================================================================
local PackagingActive         = {} -- trapHouseId -> true
local PackagingActivatedBots  = {} -- trapHouseId -> { [botId] = true } (yalnızca BU modülün değiştirdiği botlar geri alınır)
local dirtyPackaging          = {}


local function LoadPackagingRoomState()
    local callOk = pcall(function()
        MySQL.query('SELECT trap_house_id, active FROM matrix_packaging_room_state', {}, function(rows)
            pcall(function()
                if type(rows) == 'table' then
                    for _, row in ipairs(rows) do
                        if row and row.trap_house_id and row.active == 1 then
                            PackagingActive[row.trap_house_id] = true
                        end
                    end
                    Matrix.Log('WORKBENCH', '%d paketleme odasi durumu yuklendi.', #rows)
                end
            end)
        end)
    end)
    if not callOk then
        Matrix.Log('WORKBENCH', '[HATA] matrix_packaging_room_state sorgu cagrisi reddedildi; RAM bos baslatildi.')
    end
end


CreateThread(function()
    LoadPackagingRoomState()
end)


-- ★ CRITICAL FIX: toplu MySQL.transaction.await; RAM bayraklari SADECE
-- basari sonrasi temizlenir (bkz. server/logistics.lua FlushDirtyFleet ile
-- AYNI desen).
local function FlushDirtyPackaging()
    local pendingHouses = {}
    for trapHouseId in pairs(dirtyPackaging) do
        pendingHouses[#pendingHouses + 1] = trapHouseId
    end
    if #pendingHouses == 0 then return end


    local queries = {}
    for _, trapHouseId in ipairs(pendingHouses) do
        local citizenid = dirtyPackaging[trapHouseId]
        queries[#queries + 1] = {
            query = [[
                INSERT INTO matrix_packaging_room_state (trap_house_id, active, started_by_citizenid, updated_at)
                VALUES (?, ?, ?, NOW())
                ON DUPLICATE KEY UPDATE active = VALUES(active), started_by_citizenid = VALUES(started_by_citizenid), updated_at = NOW()
            ]],
            values = { trapHouseId, PackagingActive[trapHouseId] and 1 or 0, citizenid }
        }
    end


    local ok, result = pcall(function() return MySQL.transaction.await(queries) end)
    if ok and result ~= false then
        for _, trapHouseId in ipairs(pendingHouses) do dirtyPackaging[trapHouseId] = nil end
    else
        Matrix.Log('WORKBENCH',
            '[HATA][KRITIK] FlushDirtyPackaging transaction basarisiz -- dirty bayraklar KORUNDU, tekrar denenecek: %s',
            tostring(result))
    end
end


function Matrix.Workbench.TogglePackagingRoom(src, trapHouseId, forceState)
    trapHouseId = tonumber(trapHouseId)
    if not trapHouseId or not Matrix.TrapHouses[trapHouseId] then return false, 'bad_trap_house' end
    if not HasCommandAuthority(src) then return false, 'no_authority' end


    local newState = (forceState ~= nil) and forceState or not PackagingActive[trapHouseId]
    if newState == (PackagingActive[trapHouseId] or false) then return true, newState end


    PackagingActive[trapHouseId] = newState
    PackagingActivatedBots[trapHouseId] = PackagingActivatedBots[trapHouseId] or {}


    local affected = 0
    for botId, bot in pairs(Matrix.Bots) do
        if bot.role == 'dealer' and bot.state.trap_house_id == trapHouseId then
            if newState and bot.state.activity ~= 'distribution' then
                bot.state.activity = 'distribution'
                PackagingActivatedBots[trapHouseId][botId] = true
                affected = affected + 1
            elseif not newState and PackagingActivatedBots[trapHouseId][botId] then
                bot.state.activity = 'idle'
                PackagingActivatedBots[trapHouseId][botId] = nil
                affected = affected + 1
            end
        end
    end


    local state = Matrix.GetOrCreatePlayerState(src)
    dirtyPackaging[trapHouseId] = (state and state.citizenid) or 'UNKNOWN'


    Matrix.Log('WORKBENCH', '[PAKETLEME ODASI] Trap #%d -> %s (%d bot etkilendi, tetikleyen:%s)',
        trapHouseId, newState and 'BASLATILDI' or 'DURDURULDU', affected, tostring(state and state.citizenid))


    return true, newState
end


RegisterNetEvent('matrix:server:workbench:togglePackagingRoom', function(trapHouseId)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    local ok, newStateOrReason = Matrix.Workbench.TogglePackagingRoom(src, trapHouseId)
    if not ok then
        Reply(src, newStateOrReason == 'no_authority'
            and 'Bu islemi yapmak icin yeterli rutbeniz yok (Logistics_Officer veya Leader gerekir).'
            or 'Gecersiz trap house.')
        return
    end
    Reply(src, newStateOrReason and 'Paketleme odasi calismaya basladi.' or 'Paketleme odasi durduruldu.')
end)


CreateThread(function()
    local interval = (Config.Persistence and Config.Persistence.TrapHouseFlushIntervalMs) or 20000
    while true do
        Wait(interval)
        FlushDirtyPackaging()
    end
end)


-- Atmosferik log: "20 adam sigara icip paketliyor" hissi icin periyodik,
-- oynanisi ETKILEMEYEN bir konsol/ log satiri (yeni ekonomi formulu yok).
CreateThread(function()
    local interval = ((Config.PackagingRoom and Config.PackagingRoom.FlavorLogIntervalSeconds) or 300) * 1000
    while true do
        Wait(interval)
        for trapHouseId, active in pairs(PackagingActive) do
            if active then
                local house = Matrix.TrapHouses[trapHouseId]
                Matrix.Log('WORKBENCH', '[PAKETLEME ODASI] Trap #%d (%s) kuryeler icin mal paketlemeye devam ediyor.',
                    trapHouseId, house and house.label or '?')
            end
        end
    end
end)


-- =====================================================================
-- TAKTİK DEBUG PANELİ
-- =====================================================================
RegisterCommand('paketlemedurum', function(src)
    local count = 0
    for trapHouseId, active in pairs(PackagingActive) do
        if active then
            count = count + 1
            Reply(src, ('Trap #%d paketleme odasi AKTIF.'):format(trapHouseId))
        end
    end
    Reply(src, ('--- %d aktif paketleme odasi ---'):format(count))
end, false)


exports('RepairWeaponAtWorkbench', function(src, weaponSlot) return Matrix.Workbench.RepairWeapon(src, weaponSlot) end)
exports('TogglePackagingRoom', function(src, trapHouseId, forceState) return Matrix.Workbench.TogglePackagingRoom(src, trapHouseId, forceState) end)