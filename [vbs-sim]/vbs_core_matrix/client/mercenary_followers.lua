-- =====================================================================
-- MATRIX MUHAFIZ/KURYE TAKİPÇİLERİ / client/mercenary_followers.lua
-- (KATMAN 1: Fiziksel Takipçi Botlar + Araç Komutu)
--
-- F10 -> "Muhafiz Cagir" -- en fazla Config.Mercenary.MaxFollowers (2)
-- ped, oyuncuyu takip eder; oyuncu bir araca binince BOŞ koltuklara
-- TaskEnterVehicle ile OTONOM biner; catisma icinde MEVCUT taktik
-- muharebe gorevleriyle (TaskCombatPed) oyuncuyu savunur.
--
-- PERFORMANS: mesafe/arac kontrolleri HER FRAME DEGIL, Config.Mercenary.
-- CheckIntervalMs (1500ms) araliginda calisan hafif bir onbellek
-- uzerinden yurutulur -- yalnizca dusman farkindaligi/TaskCombatPed
-- yenileme (kisa Wait) daha sik calisir, o da yalnizca aktif catisma
-- aninda.
-- =====================================================================


if not Config.Mercenary or not Config.Mercenary.EnablePhysicalFollowers then return end


local Followers = {} -- [i] = { ped = handle, botId = number, entering = bool }


-- ★ ANTI-DUPE FIX (MODUL 1): bu client artik KENDI ped'ini uretmiyor.
-- Sunucu, oyuncunun zaten sahip oldugu (handler_citizenid) ve 'idle' olan
-- KALICI bot kaydini Matrix.SpawnBot ile networked bir entity olarak
-- doguruyor; client sadece o netId'yi NetworkGetEntityFromNetworkId ile
-- COZUP uzerine takip/muharebe davranisi bindiriyor. Dismiss'te entity
-- SILINMEZ -- sunucu Matrix.DespawnBot ile geri cekip ajani 'idle'ye
-- dondurur, boylece ayni kimlik bir sonraki cagrida tekrar kullanilabilir.
local function AwaitNetworkEntity(netId, timeoutMs)
    local waited = 0
    while not NetworkDoesEntityExistWithNetworkId(netId) and waited < (timeoutMs or 3000) do
        Wait(50)
        waited = waited + 50
    end
    if not NetworkDoesEntityExistWithNetworkId(netId) then return nil end
    local ped = NetworkGetEntityFromNetworkId(netId)
    if not ped or ped == 0 or not DoesEntityExist(ped) then return nil end
    return ped
end


-- =====================================================================
-- ★ MODUL 3: SILAH SINIFINA GORE MUHAREBE DAVRANISI
-- Config.BlackMarket.CombatByWeaponClass (shared/config.lua) rifle tasiyan
-- botlarin siper alip mesafeden angaje olmasini, shotgun tasiyanlarin
-- yakin mesafeye itilmesini tanimlar. Item adi -> class eslesmesi
-- Config.BlackMarket.Weapons katalogundan (server tarafinda zaten var
-- olan FindWeaponClassByItem ile AYNI veri) client tarafinda kendi
-- kopyasi ile cozulur (Config paylasilir, shared/config.lua).
-- =====================================================================
local WeaponHashToClass = {}
for _, w in ipairs(Config.BlackMarket.Weapons or {}) do
    WeaponHashToClass[GetHashKey(w.item)] = w.class
end

local function ApplyWeaponClassCombatBehavior(ped)
    local currentHash = GetSelectedPedWeapon(ped)
    local class = WeaponHashToClass[currentHash]
    local rule = class and Config.BlackMarket.CombatByWeaponClass and Config.BlackMarket.CombatByWeaponClass[class]
    if not rule then return end

    SetPedCombatRange(ped, rule.combat_range)
    SetPedCombatAttributes(ped, 0, rule.use_cover == true) -- BF_CanUseCover
end


local function ApplyFollowerCombatSetup(ped)
    SetPedFleeAttributes(ped, 0, false)
    SetPedCombatAttributes(ped, 46, true) -- BF_CanFightArmedPedsWhenNotArmed benzeri saldirganlik izni
    SetPedCombatAbility(ped, 2)
    SetPedCombatRange(ped, 2)
    SetPedAccuracy(ped, 65)
    SetPedAsGroupMember(ped, GetPlayerGroup(PlayerId()))
    SetPedRelationshipGroupHash(ped, GetHashKey('PLAYER'))
    ApplyWeaponClassCombatBehavior(ped)
end


RegisterNetEvent('matrix:client:mercenary:summonApproved', function(newCount, botId, netId)
    if type(netId) ~= 'number' then
        if lib and lib.notify then
            lib.notify({ title = '[MUHAFIZ]', description = 'Ajan entity referansi alinamadi.', type = 'error' })
        end
        return
    end

    local ped = AwaitNetworkEntity(netId)
    if not ped then
        if lib and lib.notify then
            lib.notify({ title = '[MUHAFIZ]', description = 'Ajan sahaya inemedi (network senkron zaman asimi).', type = 'error' })
        end
        return
    end

    ApplyFollowerCombatSetup(ped)
    Followers[#Followers + 1] = { ped = ped, botId = botId, entering = false }

    if lib and lib.notify then
        lib.notify({ title = '[MUHAFIZ CAGRILDI]', description = ('Aktif takipci: %d/%d'):format(newCount, Config.Mercenary.MaxFollowers or 2), type = 'success' })
    end
end)


local function DismissAllFollowers()
    -- ★ Entity'ler BURADA SILINMEZ -- sunucu Matrix.DespawnBot ile bu
    -- kalici kimlikleri kendisi geri cekip 'idle'ye dondurur.
    Followers = {}
    TriggerServerEvent('matrix:server:mercenary:reportDismiss', 0)
    if lib and lib.notify then
        lib.notify({ title = '[MUHAFIZ]', description = 'Tum takipciler serbest birakildi.', type = 'inform' })
    end
end


RegisterCommand('muhafizcagir', function()
    TriggerServerEvent('matrix:server:mercenary:requestSummon')
end, false)
RegisterKeyMapping('muhafizcagir', 'Fiziksel Muhafiz/Kurye Takipci Cagir (F10 icinden de erisilebilir)', 'keyboard', '')


RegisterCommand('muhafizsalla', function()
    DismissAllFollowers()
end, false)


-- =====================================================================
-- ARAÇ KOMUTU: oyuncu bir araca binince, BOŞ koltuklara TaskEnterVehicle
-- ile OTONOM binerler.
-- =====================================================================
local function TryEnterVehicleSeats(vehicle)
    if not DoesEntityExist(vehicle) then return end
    local maxSeats = GetVehicleMaxNumberOfPassengers(vehicle)

    for _, entry in ipairs(Followers) do
        if entry.ped and DoesEntityExist(entry.ped) and not entry.entering then
            local alreadyInVehicle = IsPedInVehicle(entry.ped, vehicle, false)
            if not alreadyInVehicle then
                local freeSeat = nil
                for seat = -1, maxSeats - 1 do
                    if IsVehicleSeatFree(vehicle, seat) then freeSeat = seat; break end
                end
                if freeSeat then
                    entry.entering = true
                    TaskEnterVehicle(entry.ped, vehicle, 8000, freeSeat, 1.0, 1, 0)
                end
            end
        end
    end
end


-- =====================================================================
-- ÇATIŞMA SAVUNMASI: yakındaki bir tehdit (Config.Mercenary.CombatAggroRadius
-- içinde silahlı düşman ped'i) tespit edilirse TaskCombatPed ile oyuncuyu
-- savunurlar.
-- =====================================================================
local function DefendPlayerIfThreatened(playerPed)
    local playerCoords = GetEntityCoords(playerPed)
    local handle, ped = FindFirstPed()
    local found = true
    local threat = nil

    repeat
        if ped ~= playerPed and DoesEntityExist(ped) and not IsPedAPlayer(ped)
            and GetPedRelationshipGroupHash(ped) ~= GetHashKey('PLAYER')
            and IsPedInCombat(ped, playerPed) then
            local d = #(GetEntityCoords(ped) - playerCoords)
            if d <= (Config.Mercenary.CombatAggroRadius or 35.0) then
                threat = ped
                break
            end
        end
        found, ped = FindNextPed(handle)
    until not found

    EndFindPed(handle)

    if threat then
        for _, entry in ipairs(Followers) do
            if entry.ped and DoesEntityExist(entry.ped) and not IsPedInCombat(entry.ped, threat) then
                TaskCombatPed(entry.ped, threat, 0, 16)
            end
        end
    end
end


-- =====================================================================
-- HAFİF ÖNBELLEK DÖNGÜSÜ (1500ms) — takip mesafesi, araç girişi ve
-- ışınlanma-koruması burada tek bir Wait ile toplu değerlendirilir.
-- =====================================================================
CreateThread(function()
    while true do
        Wait(Config.Mercenary.CheckIntervalMs or 1500)

        if #Followers > 0 then
            local playerPed = PlayerPedId()
            local playerCoords = GetEntityCoords(playerPed)
            local vehicle = IsPedInAnyVehicle(playerPed, false) and GetVehiclePedIsIn(playerPed, false) or nil

            for i = #Followers, 1, -1 do
                local entry = Followers[i]
                if not entry.ped or not DoesEntityExist(entry.ped) then
                    table.remove(Followers, i)
                elseif IsEntityDead(entry.ped) then
                    -- Entity'nin kendisi silinmez (sunucu Matrix.DespawnBot ile
                    -- yonetir) -- sadece client tarafi listeden dusuruluyor.
                    table.remove(Followers, i)
                    TriggerServerEvent('matrix:server:mercenary:reportDismiss', #Followers)
                else
                    -- ★ MODUL 3: silah degisebilir (ornegin /silahmodtak
                    -- sonrasi) -- her onbellek turunda davranis yeniden
                    -- degerlendirilir (pahali degil, 1500ms'de bir).
                    ApplyWeaponClassCombatBehavior(entry.ped)

                    local followerCoords = GetEntityCoords(entry.ped)
                    local dist = #(followerCoords - playerCoords)

                    if dist > (Config.Mercenary.TeleportDistance or 60.0) then
                        SetEntityCoords(entry.ped, playerCoords.x, playerCoords.y, playerCoords.z, false, false, false, false)
                    elseif vehicle then
                        entry.entering = false
                        TryEnterVehicleSeats(vehicle)
                    elseif not IsPedInAnyVehicle(entry.ped, false) and dist > (Config.Mercenary.FollowDistance or 3.0) then
                        -- ★ [DÜZELTME] backtick hash-literal (`SCRIPT_TASK_...`) standart
                        -- Lua sözdizimi DEĞİLDİR (bkz. client/hud.lua'daki AYNI uyarı) --
                        -- burada görev durumu izlenmeden, 1500ms önbellek aralığında
                        -- YENİDEN yayınlamak yeterlidir (TaskGoToEntity zaten devam eden
                        -- bir görevi sorunsuzca üstüne yazar).
                        TaskGoToEntity(entry.ped, playerPed, -1, Config.Mercenary.FollowDistance or 3.0, 2.0, 1073741824, 0)
                    end
                end
            end

            if #Followers > 0 then
                DefendPlayerIfThreatened(playerPed)
            end
        end
    end
end)


AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    -- Entity'ler sunucu tarafinin sorumlulugunda (Matrix.DespawnBot); client
    -- yalnizca kendi listesini temizler.
    Followers = {}
end)
