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


local Followers = {} -- [i] = { ped, entering, botId, displayName, mode, modeCoords }

-- ★ hud.lua (nametag/F10 menü) AYNI Lua VM'inde çalışan bir client script
-- olduğundan, bu tabloyu Matrix.Client altında paylaşıyoruz -- Followers
-- SIFIRLANIRKEN yeniden ATANMAZ (table.remove/table.insert ile mutasyona
-- uğrar), böylece dış referans hep GEÇERLİ kalır.
Matrix.Client = Matrix.Client or {}
Matrix.Client.Followers = Followers


local function DeleteFollower(entry)
    if entry and entry.ped and DoesEntityExist(entry.ped) then
        SetEntityAsNoLongerNeeded(entry.ped)
        if DoesEntityExist(entry.ped) then
            DeletePed(entry.ped)
        end
    end
end


local function SpawnFollowerPed(coords, pedModelName)
    local model = GetHashKey(pedModelName or Config.Mercenary.PedModel or 'g_m_y_mexgoon_02')
    RequestModel(model)
    local waited = 0
    while not HasModelLoaded(model) and waited < 3000 do
        Wait(50)
        waited = waited + 50
    end
    if not HasModelLoaded(model) then return nil end

    local ped = CreatePed(4, model, coords.x, coords.y, coords.z, 0.0, true, true)
    if not DoesEntityExist(ped) then
        SetModelAsNoLongerNeeded(model)
        return nil
    end

    -- [DÜZELTME] 'SetEntityOrphanMode' CLIENT tarafında tanımsızdır (server-only
    -- native) -- doğrudan çağrısı nil upvalue/global çağrısı olarak çöker. Her
    -- FXServer sürümünde çalışan client-safe eşdeğeri: ped'i mission entity
    -- olarak işaretlemek (garbage-collect edilmesin) + temizlikte
    -- SetEntityAsNoLongerNeeded/DeletePed ile bırakmak.
    SetEntityAsMissionEntity(ped, true, true)
    SetPedFleeAttributes(ped, 0, false)
    SetPedCombatAttributes(ped, 46, true) -- BF_CanFightArmedPedsWhenNotArmed benzeri saldirganlik izni
    SetPedCombatAbility(ped, 2)
    SetPedCombatRange(ped, 2)
    SetPedAccuracy(ped, 65)
    GiveWeaponToPed(ped, GetHashKey('WEAPON_COMBATPISTOL'), 250, false, true)
    SetPedAsGroupMember(ped, GetPlayerGroup(PlayerId()))
    SetPedRelationshipGroupHash(ped, GetHashKey('PLAYER'))
    SetModelAsNoLongerNeeded(model)

    return ped
end


RegisterNetEvent('matrix:client:mercenary:summonApproved', function(newCount, botId, pedModel, displayName)
    local playerPed = PlayerPedId()
    local baseCoords = GetEntityCoords(playerPed)
    local heading    = GetEntityHeading(playerPed)
    local offset     = (#Followers + 1) * (Config.Mercenary.SummonRadius or 3.0)
    local spawnCoords = GetOffsetFromEntityInWorldCoords(playerPed, (Followers[1] and 1.0 or -1.0), -offset, 0.0)

    local ped = SpawnFollowerPed(spawnCoords, pedModel)
    if not ped then
        if lib and lib.notify then
            lib.notify({ title = '[MUHAFIZ]', description = 'Takipci doğurulamadi (model yuklenemedi).', type = 'error' })
        end
        return
    end

    Followers[#Followers + 1] = {
        ped = ped, entering = false,
        botId = botId, displayName = displayName or 'Muhafiz',
        mode = 'follow', modeCoords = nil
    }

    if lib and lib.notify then
        lib.notify({ title = '[MUHAFIZ CAGRILDI]', description = ('%s katildi (%d/%d)'):format(displayName or 'Muhafiz', newCount, Config.Mercenary.MaxFollowers or 2), type = 'success' })
    end
end)


-- ★ F10 komut menüsünden gelen mod değişikliği onayı (server yetki/sahiplik
-- kontrolünü zaten yaptı -- burada sadece local state güncellenir).
RegisterNetEvent('matrix:client:mercenary:modeApplied', function(botId, mode, extraCoords)
    for _, entry in ipairs(Followers) do
        if entry.botId == botId then
            entry.mode = mode
            entry.modeCoords = extraCoords
            entry.entering = false
            break
        end
    end
end)


local function DismissAllFollowers()
    for _, entry in ipairs(Followers) do
        DeleteFollower(entry)
    end
    -- ★ Followers YENİDEN ATANMAZ -- Matrix.Client.Followers referansı
    -- (hud.lua nametag/F10 menü tarafından tutulan) geçersiz kalmasın diye
    -- table.remove ile YERİNDE boşaltılır.
    for i = #Followers, 1, -1 do table.remove(Followers, i) end
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
--- Verilen merkez noktaya (oyuncu ya da bir muhafızın Koru/Gözlem
--- ankraji) en yakın, çatışma halindeki düşman ped'i bulur.
local function FindNearestCombatThreat(centerCoords, radius)
    local handle, ped = FindFirstPed()
    local found = true
    local threat = nil

    repeat
        if DoesEntityExist(ped) and not IsPedAPlayer(ped)
            and GetPedRelationshipGroupHash(ped) ~= GetHashKey('PLAYER')
            and (IsPedInCombat(ped, PlayerPedId()) or IsPedShooting(ped)) then
            local d = #(GetEntityCoords(ped) - centerCoords)
            if d <= radius then
                threat = ped
                break
            end
        end
        found, ped = FindNextPed(handle)
    until not found

    EndFindPed(handle)
    return threat
end

local function DefendPlayerIfThreatened(playerPed)
    local playerCoords = GetEntityCoords(playerPed)
    local threat = FindNearestCombatThreat(playerCoords, Config.Mercenary.CombatAggroRadius or 35.0)

    for _, entry in ipairs(Followers) do
        if entry.ped and DoesEntityExist(entry.ped) and (entry.mode == 'follow' or entry.mode == nil) then
            if threat and not IsPedInCombat(entry.ped, threat) then
                TaskCombatPed(entry.ped, threat, 0, 16)
            end
        end
    end
end

--- "Koru" (guard) modundaki muhafız kendi ankraj noktasını savunur --
--- oyuncudan değil, ATANDIĞI noktaya yakın tehditlerden tepki verir.
--- "Gözlem" (observe) modu KASITLI OLARAK ateş etmez -- yalnızca izler
--- (kullanıcı isteği: "suppressive fire" gibi gerçekçi-olmayan bir
--- mekanik EKLENMEDİ; gözlem tamamen pasiftir).
local function TickGuardModes()
    for _, entry in ipairs(Followers) do
        if entry.ped and DoesEntityExist(entry.ped) and entry.modeCoords then
            if entry.mode == 'guard' then
                local threat = FindNearestCombatThreat(entry.modeCoords, Config.Mercenary.CombatAggroRadius or 35.0)
                if threat and not IsPedInCombat(entry.ped, threat) then
                    TaskCombatPed(entry.ped, threat, 0, 16)
                end
            elseif entry.mode == 'attack' then
                local threat = FindNearestCombatThreat(GetEntityCoords(entry.ped), Config.Mercenary.CombatAggroRadius or 35.0)
                if threat and not IsPedInCombat(entry.ped, threat) then
                    TaskCombatPed(entry.ped, threat, 0, 16)
                end
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
                    DeleteFollower(entry)
                    table.remove(Followers, i)
                    TriggerServerEvent('matrix:server:mercenary:reportDismiss', #Followers)
                elseif entry.mode == 'hold' or entry.mode == 'guard' or entry.mode == 'observe' then
                    -- ★ Arma 3 tarzı: bu üç modda muhafız OYUNCUYU DEĞİL,
                    -- kendisine atanan sabit noktayı takip eder.
                    local anchor = entry.modeCoords or GetEntityCoords(entry.ped)
                    local followerCoords = GetEntityCoords(entry.ped)
                    local anchorDist = #(followerCoords - anchor)
                    if anchorDist > (Config.Mercenary.TeleportDistance or 60.0) then
                        SetEntityCoords(entry.ped, anchor.x, anchor.y, anchor.z, false, false, false, false)
                    elseif not IsPedInAnyVehicle(entry.ped, false) and anchorDist > 3.0 then
                        TaskGoToCoordAnyMeans(entry.ped, anchor.x, anchor.y, anchor.z, 1.0, 0, false, 786603, 0)
                    elseif entry.mode == 'observe' and not IsPedInCombat(entry.ped, PlayerPedId()) then
                        TaskStartScenarioInPlace(entry.ped, 'WORLD_HUMAN_GUARD_STAND', 0, true)
                    end
                elseif entry.mode == 'attack' then
                    -- Hedef arama/çatışma TickGuardModes'ta yönetilir; burada
                    -- yalnızca oyuncudan çok uzak kalmasın diye ışınlama koruması.
                    local followerCoords = GetEntityCoords(entry.ped)
                    if #(followerCoords - playerCoords) > (Config.Mercenary.TeleportDistance or 60.0) then
                        SetEntityCoords(entry.ped, playerCoords.x, playerCoords.y, playerCoords.z, false, false, false, false)
                    end
                else
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
                TickGuardModes()
            end
        end
    end
end)


AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    for _, entry in ipairs(Followers) do
        DeleteFollower(entry)
    end
    Followers = {}
end)
