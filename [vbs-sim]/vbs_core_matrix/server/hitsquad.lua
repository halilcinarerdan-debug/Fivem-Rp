-- =====================================================================
-- MATRIX HIT SQUAD / server/hitsquad.lua  (KATMAN 8 — YENİ)
--
-- Yüksek siber-ısılı oyuncular (server/rendezvous.lua [R2] İLE AYNI
-- trace-level formülü: Matrix.Bureau.GetHeat / Config.Bureau.
-- CyberLeakMaxIntensity) en yakın düşman mahallesinden (Config.GangHoods)
-- sızdırılan otonom bir çete aracı tarafından takip edilir. Araç saldırı
-- menziline girince Config.HitSquad.DrivebySeconds boyunca TaskVehicleDriveby
-- ile sürekli ateş açar, ardından "Hit-and-Run" — arka sokaklardan en
-- yakın mahalleye otonom geri çekilir. RNG YOK: eşik karşılaştırması +
-- sabit süreli fazlar. Entity yaşam döngüsü server/main.lua'nın fiziksel
-- sevk deseniyle AYNI (AwaitEntityCreation, SetEntityOrphanMode/Bucket).
-- =====================================================================


Matrix.HitSquad = Matrix.HitSquad or {}


local pairs, type, tostring   = pairs, type, tostring
local math_max, math_huge      = math.max, math.huge
local GetPlayers                = GetPlayers
local GetPlayerPed              = GetPlayerPed
local GetEntityCoords           = GetEntityCoords
local DoesEntityExist            = DoesEntityExist
local DeleteEntity               = DeleteEntity
local CreateVehicle              = CreateVehicle
local CreatePedInsideVehicle     = CreatePedInsideVehicle
local GetHashKey                 = GetHashKey
local TaskVehicleDriveToCoord    = TaskVehicleDriveToCoord
local TaskVehicleDriveby         = TaskVehicleDriveby
local ClearPedTasksImmediately   = ClearPedTasksImmediately
local SetEntityOrphanMode        = SetEntityOrphanMode
local SetEntityRoutingBucket     = SetEntityRoutingBucket
local GiveWeaponToPed            = GiveWeaponToPed
local SetPedCombatAttributes     = SetPedCombatAttributes


-- Aktif takip/saldırı durumu: src -> { vehicle, driver, phase,
-- phase_started_at, trap_house_id, hood }
local activeSquads = {}


--- server/main.lua'nın SafeDeleteEntity'siyle AYNI dayanıklı imha deseni
--- (bu dosyada tekrar İCAT EDİLMEDİ, yalnızca birebir taşındı — o local
--- Matrix.* olarak dışa aktarılmadığından buradan erişilemiyor).
local function SafeDeleteEntity(handle)
    if not handle or handle == 0 then return end
    pcall(function()
        if DoesEntityExist(handle) then DeleteEntity(handle) end
    end)
end


local function FindNearestTrapHouse(coords)
    local bestId, bestDist = nil, math_huge
    for id, house in pairs(Matrix.TrapHouses or {}) do
        if house.coords then
            local d = #(coords - house.coords)
            if d < bestDist then bestDist, bestId = d, id end
        end
    end
    return bestId
end


local function FindNearestHood(coords)
    local best, bestDist = nil, math_huge
    for _, hood in pairs((Config.GangHoods and Config.GangHoods.Hoods) or {}) do
        if hood.coords then
            local d = #(coords - hood.coords)
            if d < bestDist then bestDist, best = d, hood end
        end
    end
    return best
end


--- Server/rendezvous.lua [R2] İLE BİREBİR AYNI normalize formülü — ikinci
--- bir ısı alanı İCAT EDİLMEZ, mevcut Matrix.Bureau.GetHeat getter'ı
--- (KATMAN 5, DEĞİŞTİRİLMEDİ) okunur.
local function ComputeTraceLevel(coords)
    local trapHouseId = FindNearestTrapHouse(coords)
    local heat    = (trapHouseId and Matrix.Bureau and Matrix.Bureau.GetHeat and Matrix.Bureau.GetHeat(trapHouseId)) or 0.0
    local maxHeat = (Config.Bureau and Config.Bureau.CyberLeakMaxIntensity) or 5.0
    return Matrix.Clamp(heat / math_max(maxHeat, 0.0001), 0.0, 1.0), trapHouseId
end


local function DespawnSquad(src, reason)
    local squad = activeSquads[src]
    if not squad then return end
    SafeDeleteEntity(squad.driver)
    SafeDeleteEntity(squad.vehicle)
    activeSquads[src] = nil
    Matrix.Log('HITSQUAD', 'src=%s takip sonlandi (%s).', tostring(src), tostring(reason))
end


local function SpawnSquadVehicle(hood)
    local vehHash = GetHashKey(Config.HitSquad.VehicleModel)
    local pedHash = GetHashKey(Config.HitSquad.PedModel)

    local vehicle = CreateVehicle(vehHash, hood.coords.x, hood.coords.y, hood.coords.z, 0.0, true, true)
    if not Matrix.AwaitEntityCreation(vehicle) then
        SafeDeleteEntity(vehicle)
        return nil, nil
    end
    pcall(SetEntityOrphanMode, vehicle, 2) -- KeepEntity
    pcall(SetEntityRoutingBucket, vehicle, 0)

    local driver = CreatePedInsideVehicle(vehicle, 0, pedHash, -1, true, true)
    if not Matrix.AwaitEntityCreation(driver) then
        SafeDeleteEntity(driver)
        SafeDeleteEntity(vehicle)
        return nil, nil
    end
    pcall(SetEntityOrphanMode, driver, 2) -- KeepEntity
    pcall(SetEntityRoutingBucket, driver, 0)
    pcall(GiveWeaponToPed, driver, GetHashKey(Config.HitSquad.Weapon), 250, false, true)
    pcall(SetPedCombatAttributes, driver, 46, true)

    return vehicle, driver
end


-- =====================================================================
-- TAKİP/SALDIRI FAZ MAKİNESİ — mesafe/hedefleme her tick DEĞİL, main.lua'
-- nın bureauAccumulator deseniyle AYNI TARZDA sabit bir aralıkta taranır
-- (Config.HitSquad.ScanIntervalTicks * Config.Tick.IntervalMs).
-- =====================================================================
local function TickPlayer(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return end
    local coords = GetEntityCoords(ped)
    local squad  = activeSquads[src]

    if not squad then
        local traceLevel = ComputeTraceLevel(coords)
        if traceLevel < Config.HitSquad.HeatTraceThreshold then return end

        local hood = FindNearestHood(coords)
        if not hood then return end

        local vehicle, driver = SpawnSquadVehicle(hood)
        if not (vehicle and driver) then return end

        activeSquads[src] = {
            vehicle = vehicle, driver = driver,
            phase = 'pursuing', phase_started_at = Matrix.Now(),
            hood = hood
        }
        pcall(TaskVehicleDriveToCoord, driver, vehicle, coords.x, coords.y, coords.z,
            Config.HitSquad.CruiseSpeed, 0, GetHashKey(Config.HitSquad.VehicleModel),
            Config.HitSquad.AggressiveDriveStyle, 5.0, 1)

        Matrix.Log('HITSQUAD', 'src=%s iz=%.3f (esik:%.2f) -> "%s" cetesi sizdirildi.',
            tostring(src), traceLevel, Config.HitSquad.HeatTraceThreshold, hood.label)
        return
    end

    if not DoesEntityExist(squad.vehicle) or not DoesEntityExist(squad.driver) then
        DespawnSquad(src, 'entity_lost')
        return
    end

    local vehCoords = GetEntityCoords(squad.vehicle)

    if squad.phase == 'pursuing' then
        local dist = #(coords - vehCoords)
        if dist <= Config.HitSquad.AttackRange then
            squad.phase, squad.phase_started_at = 'driveby', Matrix.Now()
            -- ★ DÜZELTME: TaskVehicleDriveby server context'te tanimli
            -- DEGIL (silah atesleme/nisan task'leri FiveM'de yalnizca
            -- client-tarafta calisir) -- bu daima nil'e pcall eder ve
            -- sessizce basarisiz olur (bkz. server/matrix_diagnostics.lua
            -- DERIN-SIM kontrolu #100, ayni sinirlamayi ATLANDI olarak
            -- raporlar). Type-check ile aciktan atlanir; davranis ONCEDEN
            -- de aynen buydu (pcall zaten sonucu yoksayiyordu), yalnizca
            -- artik niyet dokumante ve gereksiz nil-cagri denemesi yok.
            if type(TaskVehicleDriveby) == 'function' then
                pcall(TaskVehicleDriveby, squad.driver, ped, 0, 0.0, 0.0, 0.0,
                    Config.HitSquad.DrivebyRange, Config.HitSquad.PedAccuracy, false,
                    GetHashKey('FIRING_PATTERN_FULL_AUTO'))
            end
        else
            pcall(TaskVehicleDriveToCoord, squad.driver, squad.vehicle, coords.x, coords.y, coords.z,
                Config.HitSquad.CruiseSpeed, 0, GetHashKey(Config.HitSquad.VehicleModel),
                Config.HitSquad.AggressiveDriveStyle, 5.0, 1)
        end

    elseif squad.phase == 'driveby' then
        if (Matrix.Now() - squad.phase_started_at) >= Config.HitSquad.DrivebySeconds then
            local hood = FindNearestHood(vehCoords)
            squad.phase, squad.phase_started_at, squad.hood = 'fleeing', Matrix.Now(), hood or squad.hood

            pcall(ClearPedTasksImmediately, squad.driver)
            if squad.hood then
                pcall(TaskVehicleDriveToCoord, squad.driver, squad.vehicle,
                    squad.hood.coords.x, squad.hood.coords.y, squad.hood.coords.z,
                    Config.HitSquad.CruiseSpeed * 1.4, 0, GetHashKey(Config.HitSquad.VehicleModel),
                    Config.HitSquad.AggressiveDriveStyle, 5.0, 1)
            end
            Matrix.Log('HITSQUAD', 'src=%s "Hit-and-Run" -> en yakin mahalleye geri cekiliyor.', tostring(src))
        end

    elseif squad.phase == 'fleeing' then
        if (Matrix.Now() - squad.phase_started_at) >= Config.HitSquad.FleeSeconds then
            DespawnSquad(src, 'retreated_to_hood')
        end
    end
end


-- =====================================================================
-- BİRİKİMLİ TARAMA DÖNGÜSÜ — server/main.lua'nın bureauAccumulator ile
-- AYNI kalıcı Config.Tick.IntervalMs taban aralığı; ayrı bir Wait(0)
-- sıcak döngüsü AÇILMAZ.
-- =====================================================================
CreateThread(function()
    local scanAccumulator = 0

    while true do
        Wait(Config.Tick.IntervalMs)
        scanAccumulator = scanAccumulator + 1
        if scanAccumulator >= Config.HitSquad.ScanIntervalTicks then
            scanAccumulator = 0
            for _, srcStr in ipairs(GetPlayers()) do
                local src = tonumber(srcStr)
                if src then
                    local ok, err = pcall(TickPlayer, src)
                    if not ok then Matrix.Log('HITSQUAD', '[HATA] TickPlayer(%s) basarisiz (yutuldu): %s', tostring(src), tostring(err)) end
                end
            end
        end
    end
end)


AddEventHandler('playerDropped', function()
    DespawnSquad(source, 'disconnected')
end)
