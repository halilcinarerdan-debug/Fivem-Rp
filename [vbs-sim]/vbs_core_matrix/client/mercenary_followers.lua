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
--
-- ★ [MODUL 1] ANTI-DUPE FIX: bu client artik KENDI ped'ini uretmiyor.
-- Sunucu, oyuncunun zaten sahip oldugu (handler_citizenid) ve 'idle' olan
-- KALICI bot kaydini Matrix.SpawnBot ile networked bir entity olarak
-- doguruyor; client sadece o netId'yi NetworkGetEntityFromNetworkId ile
-- COZUP uzerine takip/muharebe davranisi bindiriyor. Dismiss'te entity
-- SILINMEZ -- sunucu Matrix.DespawnBot ile geri cekip ajani 'idle'ye
-- dondurur, boylece ayni kimlik bir sonraki cagrida tekrar kullanilabilir.
--
-- ★ [MODUL 3] Config.BlackMarket.CombatByWeaponClass (shared/config.lua)
-- rifle tasiyan botlarin siper alip mesafeden angaje olmasini, shotgun
-- tasiyanlarin yakin mesafeye itilmesini tanimlar.
--
-- ★ [MODUL 10] F10 -> bilinen hitsquad ambush araci/surucusu sizdiginda
-- server/hitsquad.lua 'matrix:client:hitsquad:squadSpotted' ile bildirir;
-- takipciler generic combat-state'in tetiklenmesini BEKLEMEDEN ona angaje
-- olabilir. Followers roster'i degistiginde guncel network id listesi
-- sunucuya bildirilir (server/hitsquad.lua'nin kolektif hedef havuzu bunu
-- okur).
--
-- ★ [MODUL 11] F10 -> "Muhafiz Taktik Modu" (hold / guard / observe /
-- follow) -- bkz. 'muhafiztaktik' komutu asagida. Bir takipci hold/guard/
-- observe moduna atandiginda, entry.state.last_assigned_coords'a (emrin
-- verildigi andaki konumu) + entry.state.last_assigned_heading'e (emrin
-- verildigi andaki OYUNCUNUN baktigi yon) KİLİTLENİR. Ankraja ulasilinca
-- (Config.Mercenary.HoldAnchorRadius icinde) refresh dongusu ARTIK
-- TaskGoToCoordAnyMeans/TaskGoToEntity'yi HER TICK YENIDEN YAYINLAMAZ --
-- entry.state.anchored bayragi IDEMPOTENT bir kilit gorevi gorur; yalniz
-- durum degisince (yeni emir veya DefendPlayerIfThreatened'in tespit
-- ettigi bir tehdit) gorev yeniden yayinlanir/normal takip-catisma
-- mantigina donulur.
-- =====================================================================


if not Config.Mercenary or not Config.Mercenary.EnablePhysicalFollowers then return end


local Followers = {} -- [i] = { ped = handle, botId = number, entering = bool, state = {...} }

-- ★ [MODUL 10] su an bilinen dusman hitsquad ped'leri (server/hitsquad.lua
-- 'matrix:client:hitsquad:squadSpotted' ile bildirir) -- [driverNetId] = true.
-- Bu, generic IsPedInCombat taramasindan BAGIMSIZ, DETERMINISTIK bir
-- "bilinen tehdit" listesidir: takipciler native combat-state'in
-- tetiklenmesini BEKLEMEDEN, ambush araci menzile girer girmez ona
-- angaje olabilir.
local KnownHostileSquads = {}


--- ★ [MODUL 10] Followers roster'i her degistiginde (cagirma/olum/salma)
--- guncel network id listesini sunucuya bildirir -- server/hitsquad.lua'nin
--- kolektif hedef havuzu (server/mercenary_followers.lua FollowerNetIds)
--- BUNU okur. Ikinci bir "takipci konumu" sistemi ICAT EDILMEZ.
local function ReportFollowerNetIds()
    local netIds = {}
    for _, entry in ipairs(Followers) do
        if entry.ped and DoesEntityExist(entry.ped) then
            local netId = NetworkGetNetworkIdFromEntity(entry.ped)
            if netId and netId > 0 then netIds[#netIds + 1] = netId end
        end
    end
    TriggerServerEvent('matrix:server:mercenary:reportFollowerNetIds', netIds)
end


-- ★ [MODUL 1] ANTI-DUPE: entity BURADA yaratilmaz -- sunucu Matrix.SpawnBot
-- ile zaten networked olarak doguruyor; client sadece netId cozulene kadar
-- bekler.
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
-- Item adi -> class eslesmesi Config.BlackMarket.Weapons katalogundan
-- (server tarafinda zaten var olan FindWeaponClassByItem ile AYNI veri)
-- client tarafinda kendi kopyasi ile cozulur (Config paylasilir,
-- shared/config.lua).
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

    -- ★ [MODUL 11] entry.state: hold/guard/observe taktik modu takibi --
    -- current_task_mode ('follow' varsayilan), last_assigned_coords/
    -- last_assigned_heading (emrin verildigi andaki ankraj + oyuncunun
    -- baktigi yon) ve anchored (IDEMPOTENT kilit bayragi -- true olunca
    -- refresh dongusu ayni ankraj icin gorevi TEKRAR YAYINLAMAZ).
    Followers[#Followers + 1] = {
        ped = ped,
        botId = botId,
        entering = false,
        state = {
            current_task_mode    = 'follow',
            last_assigned_coords  = nil,
            last_assigned_heading = nil,
            anchored              = false
        }
    }
    ReportFollowerNetIds()

    if lib and lib.notify then
        lib.notify({ title = '[MUHAFIZ CAGRILDI]', description = ('Aktif takipci: %d/%d'):format(newCount, Config.Mercenary.MaxFollowers or 2), type = 'success' })
    end
end)


local function DismissAllFollowers()
    -- ★ Entity'ler BURADA SILINMEZ -- sunucu Matrix.DespawnBot ile bu
    -- kalici kimlikleri kendisi geri cekip 'idle'ye dondurur.
    Followers = {}
    TriggerServerEvent('matrix:server:mercenary:reportDismiss', 0)
    ReportFollowerNetIds()
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
-- ★ [MODUL 11] TAKTİK MOD ATAMASI (F10 -> "Muhafiz Taktik Modu"):
-- hold / guard / observe -- takipciyi ATANDIGI ANDAKI konumuna (ankraj)
-- ve oyuncunun O ANDAKI baktigi yone KİLİTLER; follow -- normal takip
-- davranisina DÖNER (ankraj temizlenir). Gecerli modlar disinda bir
-- girdi SESSİZCE REDDEDİLİR (invalid mode injection guard).
-- =====================================================================
local VALID_TASK_MODES = { hold = true, guard = true, observe = true, follow = true }

local TASK_MODE_LABELS = {
    hold    = 'Nöbet Tut (Hold)',
    guard   = 'Koru (Guard)',
    observe = 'Gözlemle (Observe)',
    follow  = 'Takip Et (Follow)'
}

local function AssignTaskModeToFollowers(mode)
    if not VALID_TASK_MODES[mode] then return end
    if #Followers == 0 then
        if lib and lib.notify then
            lib.notify({ title = '[MUHAFIZ TAKTIK]', description = 'Aktif takipci yok.', type = 'error' })
        end
        return
    end

    local playerPed     = PlayerPedId()
    local playerHeading = GetEntityHeading(playerPed)
    local isAnchorMode  = (mode == 'hold' or mode == 'guard' or mode == 'observe')

    for _, entry in ipairs(Followers) do
        if entry.ped and DoesEntityExist(entry.ped) then
            entry.state = entry.state or {}
            entry.state.current_task_mode = mode
            entry.state.anchored          = false

            if isAnchorMode then
                -- ★ Ankraj = emrin verildigi ANDAKI ped konumu; heading =
                -- emrin verildigi ANDAKI oyuncunun baktigi yon.
                entry.state.last_assigned_coords  = GetEntityCoords(entry.ped)
                entry.state.last_assigned_heading = playerHeading
            else
                entry.state.last_assigned_coords  = nil
                entry.state.last_assigned_heading = nil
            end
        end
    end

    if lib and lib.notify then
        lib.notify({ title = '[MUHAFIZ TAKTIK]', description = ('Mod: %s'):format(TASK_MODE_LABELS[mode] or mode), type = 'inform' })
    end
end


RegisterCommand('muhafiztaktik', function(_, args)
    local mode = args and args[1] and tostring(args[1]):lower() or nil
    if not mode or not VALID_TASK_MODES[mode] then
        if lib and lib.notify then
            lib.notify({ title = '[MUHAFIZ TAKTIK]', description = 'Gecerli mod: hold, guard, observe, follow', type = 'error' })
        end
        return
    end
    AssignTaskModeToFollowers(mode)
end, false)
RegisterKeyMapping('muhafiztaktik', 'Muhafiz Taktik Modu Ata: hold/guard/observe/follow (F10 icinden de erisilebilir)', 'keyboard', '')


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

    -- ★ [MODUL 11] cagiran tarafa (refresh dongusu) tehdit bulunup
    -- bulunmadigini bildirir -- hold/guard/observe ankraj kilidini
    -- KIRMAK icin kullanilir ("threat detected" -> normal takip/catisma
    -- mantigina donulur).
    return threat
end


-- =====================================================================
-- ★ [MODUL 10] BILINEN HITSQUAD ANGAJMANI — server/hitsquad.lua bir cete
-- ambush araci/surucusu sizdirdiginda (veya geri cektiginde) netId'sini
-- 'matrix:client:hitsquad:squadSpotted' ile bildirir. Bu, generic
-- DefendPlayerIfThreatened taramasinin (IsPedInCombat SARTINA bagli)
-- AKSINE, native combat-state'in tetiklenmesini BEKLEMEDEN -- ambush
-- surucusu menzile (Config.Mercenary.CombatAggroRadius) girer girmez
-- takipcilerin ona angaje olmasini saglar. RNG YOK: her takipci en
-- yakin bilinen dusman ped'ine, mesafeye gore deterministik olarak
-- angaje olur.
-- =====================================================================
RegisterNetEvent('matrix:client:hitsquad:squadSpotted', function(driverNetId, isActive)
    driverNetId = tonumber(driverNetId)
    if not driverNetId then return end
    if isActive then
        KnownHostileSquads[driverNetId] = true
    else
        KnownHostileSquads[driverNetId] = nil
    end
end)


local function EngageKnownHostileSquads()
    for netId in pairs(KnownHostileSquads) do
        local hostilePed = NetworkGetEntityFromNetworkId(netId)
        if not hostilePed or hostilePed == 0 or not DoesEntityExist(hostilePed) or IsEntityDead(hostilePed) then
            KnownHostileSquads[netId] = nil
        else
            local hostileCoords = GetEntityCoords(hostilePed)
            for _, entry in ipairs(Followers) do
                if entry.ped and DoesEntityExist(entry.ped) and not IsEntityDead(entry.ped) then
                    local d = #(GetEntityCoords(entry.ped) - hostileCoords)
                    if d <= (Config.Mercenary.CombatAggroRadius or 35.0) and not IsPedInCombat(entry.ped, hostilePed) then
                        TaskCombatPed(entry.ped, hostilePed, 0, 16)
                    end
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

            -- ★ [MODUL 11] threat, DefendPlayerIfThreatened + KnownHostileSquads'in
            -- BIRLESIMIDIR -- ikisi de "tehdit tespit edildi" sayilir ve
            -- hold/guard/observe ankraj kilidini KIRAR (normal takip/catisma
            -- mantigina donulur). DefendPlayerIfThreatened bu tick icin
            -- takipcilere TaskCombatPed'i ZATEN atadi -- burada yalnizca
            -- SONUCU okunur, ikinci bir tarama YAPILMAZ.
            local threat = DefendPlayerIfThreatened(playerPed)
            local threatActive = (threat ~= nil) or next(KnownHostileSquads) ~= nil

            for i = #Followers, 1, -1 do
                local entry = Followers[i]
                if not entry.ped or not DoesEntityExist(entry.ped) then
                    table.remove(Followers, i)
                elseif IsEntityDead(entry.ped) then
                    -- ★ [MODUL 1] Entity'nin kendisi silinmez (sunucu
                    -- Matrix.DespawnBot ile yonetir) -- sadece client
                    -- tarafi listeden dusuruluyor.
                    table.remove(Followers, i)
                    TriggerServerEvent('matrix:server:mercenary:reportDismiss', #Followers)
                    ReportFollowerNetIds()
                else
                    -- ★ MODUL 3: silah degisebilir (ornegin /silahmodtak
                    -- sonrasi) -- her onbellek turunda davranis yeniden
                    -- degerlendirilir (pahali degil, 1500ms'de bir).
                    ApplyWeaponClassCombatBehavior(entry.ped)

                    entry.state = entry.state or { current_task_mode = 'follow', anchored = false }
                    local followerCoords = GetEntityCoords(entry.ped)
                    local dist = #(followerCoords - playerCoords)
                    local mode = entry.state.current_task_mode or 'follow'
                    local isAnchorMode = (mode == 'hold' or mode == 'guard' or mode == 'observe')

                    if dist > (Config.Mercenary.TeleportDistance or 60.0) then
                        SetEntityCoords(entry.ped, playerCoords.x, playerCoords.y, playerCoords.z, false, false, false, false)
                        entry.state.anchored = false
                    elseif vehicle then
                        entry.entering = false
                        entry.state.anchored = false
                        TryEnterVehicleSeats(vehicle)
                    elseif isAnchorMode and not threatActive then
                        -- ★ [MODUL 11] IDEMPOTENT NAVMESH KİLİDİ: ankraj noktasi
                        -- HENUZ atanmamissa (guvenlik agi) su anki konum ankraj
                        -- yapilir; ankraj Config.Mercenary.HoldAnchorRadius (~1.5m)
                        -- ICINDEYSE gorev BIR KEZ yayinlanir (TaskAchieveHeading +
                        -- nobet duruşu) ve entry.state.anchored=true olunca HER
                        -- TICK yeniden TaskGoToCoordAnyMeans/TaskGoToEntity
                        -- YAYINLANMAZ -- bot artik jitter/cirpinma YAPMAZ.
                        local anchor = entry.state.last_assigned_coords
                        if not anchor then
                            anchor = followerCoords
                            entry.state.last_assigned_coords = anchor
                        end

                        local anchorDist = #(followerCoords - anchor)
                        if anchorDist <= (Config.Mercenary.HoldAnchorRadius or 1.5) then
                            if not entry.state.anchored then
                                TaskAchieveHeading(entry.ped, entry.state.last_assigned_heading or GetEntityHeading(entry.ped), Config.Mercenary.HoldHeadingLockMs or 3000)
                                TaskStartScenarioInPlace(entry.ped, Config.Mercenary.GuardScenario or 'WORLD_HUMAN_GUARD_STAND', 0, true)
                                entry.state.anchored = true
                            end
                            -- ★ NO-OP: bot zaten ankrajda -- gorev TEKRAR YAYINLANMAZ.
                        else
                            entry.state.anchored = false
                            if not IsPedInAnyVehicle(entry.ped, false) then
                                TaskGoToCoordAnyMeans(entry.ped, anchor.x, anchor.y, anchor.z, 2.0, 0, false, 786603, 0xbf800000)
                            end
                        end
                    elseif not IsPedInAnyVehicle(entry.ped, false) and dist > (Config.Mercenary.FollowDistance or 3.0) then
                        -- ★ [DÜZELTME] backtick hash-literal (`SCRIPT_TASK_...`) standart
                        -- Lua sözdizimi DEĞİLDİR (bkz. client/hud.lua'daki AYNI uyarı) --
                        -- burada görev durumu izlenmeden, 1500ms önbellek aralığında
                        -- YENİDEN yayınlamak yeterlidir (TaskGoToEntity zaten devam eden
                        -- bir görevi sorunsuzca üstüne yazar).
                        -- ★ [MODUL 11] tehdit tespit edildiyse (threatActive) VEYA mod
                        -- 'follow' ise buraya duser -- ankraj kilidi ARTIK GECERSIZDIR,
                        -- bir sonraki hold/guard/observe emrinde yeniden kurulur
                        -- (entry.state.anchored zaten yukarida false'a cekildi).
                        entry.state.anchored = false
                        TaskGoToEntity(entry.ped, playerPed, -1, Config.Mercenary.FollowDistance or 3.0, 2.0, 1073741824, 0)
                    end
                end
            end
        end

        -- ★ [MODUL 10] bilinen hitsquad angajmani, #Followers == 0 olsa
        -- BILE calisir (KnownHostileSquads temizligi icin), ama pratikte
        -- ic dongu zaten Followers'i tarar.
        if next(KnownHostileSquads) then
            EngageKnownHostileSquads()
        end
    end
end)


AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    -- ★ [MODUL 1] Entity'ler sunucu tarafinin sorumlulugunda
    -- (Matrix.DespawnBot); client yalnizca kendi listesini temizler.
    Followers = {}
end)
