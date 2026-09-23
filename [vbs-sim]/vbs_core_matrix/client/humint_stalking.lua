-- ★ [MODUL 16.1] EMNIYET ILKLENDIRMESI: bu dosyalarin hicbiri global Matrix
-- tablosunu calisma zamaninda okumaz (bkz. server-side yorumlar), ama
-- ileride bir referans eklenirse client-side VM'in erken/farkli sirada
-- yuklenmesi durumunda nil-index hatasi ASLA olusmasin diye zararsiz bir
-- guvenlik agi olarak eklenir.
Matrix = Matrix or {}
Matrix.Client = Matrix.Client or {}


-- =====================================================================
-- ★★★ client/humint_stalking.lua — HUMINT ADAPTIF TAKİP MOTORU ★★★
--
-- ★ v1.0 RED TEAM HARDENING
-- [HS-1] ADAPTİF ÖNBELLEK, [HS-2] DİKİZ AYNASI VEKTÖREL FOV SİNYALİ,
-- [HS-3] ONESYNC DESPAWN SAFE-GUARD.
--
-- ★★★ YAMA 4 (BU SÜRÜM) — CLIENT-SIDE COOLDOWN TAMAMEN KALDIRILDI ★★★
-- Cooldown SERVER'a (server/logistics.lua) taşındı. Bu dosyada artık
-- _L8_DRIVEBY_COOLDOWN_MS ve _l8LastDrivebyAtByBotNetId YOKTUR — NetOwner
-- handoff veya NetID rotasyonu ile bypass edilmesi İMKANSIZ. Client
-- yalnızca server'ın gönderdiği sanitize edilmiş payload'ı uygular.
-- =====================================================================

local STALKING_BASE_INTERVAL_MS = 1500
local STALKING_FAST_INTERVAL_MS = 300
local STALKING_SPEED_THRESHOLD_KMH = 100.0
local STALKING_FOV_DEGREES = 90.0

local stalkedTargets = {}
local stalkingRunning = false


local function ReplyLocal(msg)
    if lib and lib.notify then
        lib.notify({ title = '[HUMINT]', description = msg, type = 'inform', duration = 4000 })
    else
        print(('[MATRIX:HUMINT] %s'):format(msg))
    end
end


local function ComputeAdaptiveInterval(speedMs)
    speedMs = tonumber(speedMs) or 0.0
    if speedMs ~= speedMs or speedMs < 0 then speedMs = 0.0 end

    local speedKmh = speedMs * 3.6

    if speedKmh <= 0.0 then
        return STALKING_BASE_INTERVAL_MS
    end
    if speedKmh >= STALKING_SPEED_THRESHOLD_KMH then
        return STALKING_FAST_INTERVAL_MS
    end

    local ratio = speedKmh / STALKING_SPEED_THRESHOLD_KMH
    return math.floor(STALKING_BASE_INTERVAL_MS - ((STALKING_BASE_INTERVAL_MS - STALKING_FAST_INTERVAL_MS) * ratio))
end


local function VectorDot(a, b)
    return (a.x * b.x) + (a.y * b.y) + (a.z * b.z)
end

local function VectorLength(v)
    return math.sqrt((v.x * v.x) + (v.y * v.y) + (v.z * v.z))
end


local function ForwardVectorFromHeading(headingDegrees)
    local rad = math.rad(headingDegrees)
    return {
        x = -math.sin(rad),
        y =  math.cos(rad),
        z =  0.0
    }
end


local function IsTargetInFOV(observerCoords, observerHeading, targetCoords, fovDegrees)
    fovDegrees = tonumber(fovDegrees) or STALKING_FOV_DEGREES
    if fovDegrees <= 0.0 or fovDegrees >= 360.0 then return true, 1.0 end

    if not observerCoords or not targetCoords then return false, -1.0 end
    if type(observerCoords.x) ~= 'number' or type(targetCoords.x) ~= 'number' then
        return false, -1.0
    end

    local u = ForwardVectorFromHeading(observerHeading)

    local dx = targetCoords.x - observerCoords.x
    local dy = targetCoords.y - observerCoords.y
    local dz = targetCoords.z - observerCoords.z

    local dlen = math.sqrt((dx * dx) + (dy * dy) + (dz * dz))
    if dlen < 0.001 then return true, 1.0 end

    local v = { x = dx / dlen, y = dy / dlen, z = dz / dlen }

    local dot = VectorDot(u, v)
    dot = math.max(-1.0, math.min(1.0, dot))

    local halfFovRad = math.rad(fovDegrees * 0.5)
    local threshold = math.cos(halfFovRad)

    return dot >= threshold, dot
end


local function SafeReadEntityCoords(entity)
    if not entity or entity == 0 then return nil, false end

    local ok, exists = pcall(DoesEntityExist, entity)
    if not ok or not exists then return nil, false end

    local okCoords, coords = pcall(GetEntityCoords, entity)
    if not okCoords or not coords then return nil, false end

    local x, y, z = tonumber(coords.x), tonumber(coords.y), tonumber(coords.z)
    if not x or not y or not z then return nil, false end
    if x ~= x or y ~= y or z ~= z then return nil, false end

    return vector3(x, y, z), true
end


local function SafeReadEntityHeading(entity)
    if not entity or entity == 0 then return nil end

    local ok, exists = pcall(DoesEntityExist, entity)
    if not ok or not exists then return nil end

    local okHeading, heading = pcall(GetEntityHeading, entity)
    if not okHeading then return nil end

    local h = tonumber(heading)
    if not h or h ~= h then return nil end
    return h
end


CreateThread(function()
    while true do
        if not stalkingRunning or next(stalkedTargets) == nil then
            Wait(1000)
        else
            local playerPed = PlayerPedId()
            local playerVehicle = GetVehiclePedIsIn(playerPed, false)

            local myCoords  = SafeReadEntityCoords(playerVehicle ~= 0 and playerVehicle or playerPed)
            local myHeading = SafeReadEntityHeading(playerVehicle ~= 0 and playerVehicle or playerPed)

            local maxSpeedMs = 0.0
            for _, target in pairs(stalkedTargets) do
                if target.vehicleEntity then
                    local okSpeed, speed = pcall(GetEntitySpeed, target.vehicleEntity)
                    if okSpeed and type(speed) == 'number' and speed == speed then
                        if speed > maxSpeedMs then maxSpeedMs = speed end
                    end
                end
            end

            local interval = ComputeAdaptiveInterval(maxSpeedMs)

            if myCoords and myHeading then
                for netId, target in pairs(stalkedTargets) do
                    local targetCoords, alive = SafeReadEntityCoords(target.vehicleEntity)

                    if not alive then
                        stalkedTargets[netId] = nil
                        ReplyLocal('Hedef arac kapsam disina cikti (OneSync despawn). Takip sonlandirildi.')
                    else
                        local inFov, cosTheta = IsTargetInFOV(myCoords, myHeading, targetCoords, STALKING_FOV_DEGREES)

                        if inFov then
                            target.lastKnownCoords = targetCoords
                            if target.onVisualConfirm then
                                pcall(target.onVisualConfirm, netId, targetCoords, cosTheta)
                            end
                        else
                            if target.onVisualLoss then
                                pcall(target.onVisualLoss, netId, cosTheta)
                            end
                        end
                    end
                end
            end

            Wait(interval)
        end
    end
end)


exports('StartStalking', function(targetNetId, vehicleEntity, callbacks)
    targetNetId = tonumber(targetNetId)
    if not targetNetId or not vehicleEntity or vehicleEntity == 0 then return false end

    local exists = DoesEntityExist(vehicleEntity)
    if not exists then return false end

    stalkedTargets[targetNetId] = {
        vehicleEntity    = vehicleEntity,
        startedAt        = GetGameTimer(),
        lastKnownCoords  = nil,
        onVisualConfirm  = callbacks and callbacks.onVisualConfirm or nil,
        onVisualLoss     = callbacks and callbacks.onVisualLoss or nil
    }
    stalkingRunning = true
    return true
end)


exports('StopStalking', function(targetNetId)
    targetNetId = tonumber(targetNetId)
    if not targetNetId then return false end
    if stalkedTargets[targetNetId] then
        stalkedTargets[targetNetId] = nil
        if next(stalkedTargets) == nil then stalkingRunning = false end
        return true
    end
    return false
end)


exports('IsTargetInFov', function(observerCoords, observerHeading, targetCoords, fovDegrees)
    return IsTargetInFOV(observerCoords, observerHeading, targetCoords, fovDegrees)
end)


exports('ComputeAdaptiveInterval', function(speedMs)
    return ComputeAdaptiveInterval(speedMs)
end)


AddEventHandler('onClientResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    stalkedTargets = {}
    stalkingRunning = false
    -- ★ [YAMA 4] Client-side cooldown tablosu ARTIK YOK — temizlenecek
    -- bir yerel state kalmadı.
end)


-- =====================================================================
-- ★★★ KATMAN 8 — CEPHE A: CLIENT-RELAY BALİSTİK MOTORU (YAMA 4) ★★★
--
-- ★★★ ÖNEMLİ DEĞİŞİKLİK ★★★
--   Eski sürümde bu bloğun içinde CLIENT-SIDE bir cooldown tablosu
--   (_l8LastDrivebyAtByBotNetId) vardı. Hileciler NetOwner handoff veya
--   NetID rotasyonu ile bu bariyeri BYPASS edebiliyordu. Cooldown artık
--   %100 SUNUCU OTORİTESİNDE (bkz. server/logistics.lua
--   _RelayHitsquadDrivebyServerAuthoritative). Client yalnızca server'ın
--   push ettiği sanitize edilmiş payload'ı uygular.
-- =====================================================================

RegisterNetEvent('matrix:client:hitsquadDriveby', function(payload)
    if type(payload) ~= 'table' then return end
    if type(payload.ped_net_id) ~= 'number' or payload.ped_net_id == 0 then return end

    local pedEntity = NetworkGetEntityFromNetworkId(payload.ped_net_id)
    if not pedEntity or pedEntity == 0 or not DoesEntityExist(pedEntity) then return end

    -- NetOwner doğrulaması ZORUNLU — server zaten yalnızca NetOwner'a push
    -- eder, ancak savunma katmanı olarak client tarafında da doğrulanır.
    local ownerOk, ownerPlayer = pcall(NetworkGetEntityOwner, pedEntity)
    if not ownerOk or ownerPlayer ~= PlayerId() then return end

    local weaponHash    = tonumber(payload.weapon_hash) or GetHashKey('WEAPON_MICROSMG')
    local firingPattern = GetHashKey(payload.firing_pattern or 'FIRING_PATTERN_FULL_AUTO')
    -- ★ Server değerleri CLAMP eder; client yalnızca uygular (savunma).
    local accuracy      = math.min(math.max(tonumber(payload.accuracy) or 75, 0), 100)
    local range         = math.min(math.max(tonumber(payload.range) or 60.0, 1.0), 200.0)

    local taskOk = pcall(TaskVehicleDriveby,
        pedEntity,
        pedEntity,
        0,
        0.0, 0.0, 0.0,
        range,
        accuracy,
        false,
        firingPattern
    )

    if not taskOk and type(payload.vehicle_net_id) == 'number' and payload.vehicle_net_id ~= 0 then
        local vehEntity = NetworkGetEntityFromNetworkId(payload.vehicle_net_id)
        if vehEntity and vehEntity ~= 0 and DoesEntityExist(vehEntity) then
            pcall(TaskVehicleDriveby,
                pedEntity,
                pedEntity,
                vehEntity,
                0.0, 0.0, 0.0,
                range,
                accuracy,
                false,
                firingPattern
            )
        end
    end

    -- ★ CLIENT-SIDE COOLDOWN YOK — server otoritesindedir.
    -- Aynı bot için 3sn'lik ve aynı client için 1sn'lik rate-limit
    -- server/logistics.lua içinde _RelayHitsquadDrivebyServerAuthoritative
    -- fonksiyonu tarafından uygulanır.
end)