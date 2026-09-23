-- =====================================================================
-- MATRIX ANTI-GLITCH PVP + GHOST-PEEK + SUPPRESSION / client/anti_glitch.lua
-- (TASK EKI — MODUL 5 / 6 / 7)
--
-- YENİ BİR DOSYA: client/hud.lua zaten 900 satıra yakın, tamamen ayrı bir
-- ilgi alanı (PvP hareket/kamera bütünlüğü) için ayrı dosya tercih edildi
-- (görev talimatı: "or a new client file if hud.lua's structure doesn't
-- fit"). Sunucuya kortizol/bastırma bildirimi client/hud.lua'nın
-- reportPlayerWounded desenini TAKLİT eder -- yeni bir ikinci desen İCAT
-- EDİLMEZ.
--
-- ★ MODUL 5: Strafe-yön-tersine-çevirme (sprint/havadayken) tespiti ->
--   kısa süreli SetPedMoveRateOverride cezası. Birinci şahısta hızlı
--   ardışık zıplama girdisi -> ~1500ms hareket kilidi. Muharebe sırasında
--   "roll/dalış" girdisi (duck+sprint kombosu) -> kontrol TAMAMEN
--   devre dışı + TaskCrouch zorlanır.
-- ★ MODUL 6: "Hayalet bakış" (ghost-peek) -- IsPedShooting true iken
--   kamera rotasyonu ile ped'in gerçek yönelimi (forward vector) arasındaki
--   açı farkı bir eşiği aşarsa (3.şahıs kamera avantajıyla siperin
--   ARKASINDAN, gövde hizalanmadan ateş etme) DisablePlayerFiring çağrılır.
-- ★ MODUL 7: Yakın-ıskalama (~2.5m gövde) bastırma birikimi -> DrawRect
--   tabanlı vinyet/monokrom kararma + server'a kortizol artışı bildirimi.
--   NOT: İstemci tarafında per-mermi "yakın ıskalama" tespiti için GTA V
--   yerlisi (native) YOKTUR -- bu modül, yakınlıktaki düşman ped'lerin
--   AKTİF ATEŞ ETTİĞİ VE ateş hattının oyuncuya hizalı olduğu anları
--   (MODUL 6 ile AYNI açı-farkı yöntemi) bir "baskı altında" vekili olarak
--   kullanır (deterministik, RNG yok) -- gerçek mermi-geçiş simülasyonu
--   değildir; bu, mevcut FiveM API yüzeyiyle en gerçekçi yaklaşımdır.
-- =====================================================================

local PlayerPedId          = PlayerPedId
local GetEntityCoords      = GetEntityCoords
local GetEntityForwardVector = GetEntityForwardVector
local GetGameplayCamRot    = GetGameplayCamRot
local IsPedShooting        = IsPedShooting
local DisablePlayerFiring  = DisablePlayerFiring
local GetGameTimer         = GetGameTimer

-- =====================================================================
-- MODUL 5: STRAFE-TERSİNE-ÇEVİRME + HIZLI-ZIPLAMA + ROLL/DALIŞ
-- =====================================================================
local MOVE_RATE_PENALTY          = 0.4
local MOVE_RATE_PENALTY_MS       = 600
local STRAFE_REVERSAL_WINDOW_MS  = 220
local JUMP_LOCK_MS               = 1500
local JUMP_SPAM_WINDOW_MS        = 900
local JUMP_SPAM_COUNT_THRESHOLD  = 3

local lastLateralSign   = 0
local lastLateralAt     = 0
local moveRatePenaltyUntil = 0

local jumpTimestamps    = {}
local movementLockUntil = 0

CreateThread(function()
    while true do
        Wait(0)
        local ped = PlayerPedId()
        local now = GetGameTimer()

        -- --- Strafe-yön-tersine-çevirme (sprint/havada) ---
        local sprinting = IsPedSprinting(ped)
        local airborne  = IsPedFalling(ped) or IsPedJumping(ped) or not IsPedOnGround(ped)

        if sprinting or airborne then
            local lateral = GetControlNormal(0, 30) -- INPUT_MOVE_LR
            local sign = (lateral > 0.35 and 1) or (lateral < -0.35 and -1) or 0

            if sign ~= 0 then
                if lastLateralSign ~= 0 and sign ~= lastLateralSign
                    and (now - lastLateralAt) <= STRAFE_REVERSAL_WINDOW_MS then
                    moveRatePenaltyUntil = now + MOVE_RATE_PENALTY_MS
                end
                lastLateralSign = sign
                lastLateralAt   = now
            end
        else
            lastLateralSign = 0
        end

        if now < moveRatePenaltyUntil then
            SetPedMoveRateOverride(ped, MOVE_RATE_PENALTY)
        end

        -- --- Birinci şahısta hızlı ardışık zıplama -> hareket kilidi ---
        local firstPerson = GetFollowPedCamViewMode() == 4
        if firstPerson and IsControlJustPressed(0, 22) then -- INPUT_JUMP
            jumpTimestamps[#jumpTimestamps + 1] = now
            local pruned = {}
            for _, t in ipairs(jumpTimestamps) do
                if (now - t) <= JUMP_SPAM_WINDOW_MS then pruned[#pruned + 1] = t end
            end
            jumpTimestamps = pruned
            if #jumpTimestamps >= JUMP_SPAM_COUNT_THRESHOLD then
                movementLockUntil = now + JUMP_LOCK_MS
                jumpTimestamps = {}
            end
        end

        if now < movementLockUntil then
            DisableControlAction(0, 22, true)  -- INPUT_JUMP
            DisableControlAction(0, 24, true)  -- INPUT_ATTACK (asiri hizli zipla-vur kombosunu da keser)
            SetPedMoveRateOverride(ped, MOVE_RATE_PENALTY)
        end

        -- --- Muharebede roll/dalış (duck+sprint) girdisi -> tamamen kapat + crouch ---
        if IsPedInCombat(ped, 0) then
            local duckPressed = IsControlPressed(0, 36) -- INPUT_DUCK
            if duckPressed and sprinting then
                DisableControlAction(0, 36, true)
                pcall(TaskCrouch, ped, -1)
            end
        end
    end
end)

-- =====================================================================
-- ORTAK: KAMERA/GÖVDE HİZALAMA AÇI FARKI (MODUL 6 + 7'de yeniden kullanılır)
-- =====================================================================
local function AngleDiffDegrees(camRot, forward)
    -- Kamera rotasyonunu (pitch atılmış, sadece yaw) yön vektörüne çevir.
    local yawRad = math.rad(camRot.z)
    local camFwd = vector3(-math.sin(yawRad), math.cos(yawRad), 0.0)

    local a = vector3(camFwd.x, camFwd.y, 0.0)
    local b = vector3(forward.x, forward.y, 0.0)
    local lenA = #a
    local lenB = #b
    if lenA < 0.0001 or lenB < 0.0001 then return 0.0 end

    local dot = (a.x * b.x + a.y * b.y) / (lenA * lenB)
    dot = math.max(-1.0, math.min(1.0, dot))
    return math.deg(math.acos(dot))
end

-- =====================================================================
-- MODUL 6: HAYALET BAKIŞ (GHOST-PEEK) TESPİTİ
-- =====================================================================
local GHOST_PEEK_ANGLE_THRESHOLD_DEG = 35.0

CreateThread(function()
    while true do
        Wait(0)
        local ped = PlayerPedId()
        if IsPedShooting(ped) then
            local camRot  = GetGameplayCamRot(2)
            local forward = GetEntityForwardVector(ped)
            local diff = AngleDiffDegrees(camRot, forward)

            if diff > GHOST_PEEK_ANGLE_THRESHOLD_DEG then
                -- Govde ates hattina hizali degil (siper arkasindan 3.sahis
                -- kamera avantajiyla "gorup vurma") -- atisi engelle.
                DisablePlayerFiring(PlayerId(), true)
            end
        end
    end
end)

-- =====================================================================
-- MODUL 7: BASKI / TAKTİK TÜNEL GÖRÜŞÜ
-- =====================================================================
local SUPPRESSION_RADIUS_METERS   = 2.5
local SUPPRESSION_GAIN_PER_TICK   = 0.18
local SUPPRESSION_DECAY_PER_TICK  = 0.10
local SUPPRESSION_TICK_MS         = 200
local SUPPRESSION_REPORT_MS       = 1000

local suppressionLevel = 0.0 -- 0..1

CreateThread(function()
    local lastReportAt = 0
    while true do
        Wait(SUPPRESSION_TICK_MS)

        local ped = PlayerPedId()
        local playerCoords = GetEntityCoords(ped)
        local underFire = false

        local handle, otherPed = FindFirstPed()
        local found = true
        repeat
            if otherPed ~= ped and DoesEntityExist(otherPed) and not IsPedAPlayer(otherPed) then
                local d = #(GetEntityCoords(otherPed) - playerCoords)
                if d <= (SUPPRESSION_RADIUS_METERS * 6.0) and IsPedShooting(otherPed) then
                    -- Ates eden ped'in gövde yönelimi oyuncuya (MODUL 6'daki
                    -- AYNI açı-farkı yöntemiyle) hizalıysa "baski altinda" say.
                    local toPlayer = playerCoords - GetEntityCoords(otherPed)
                    local diff = AngleDiffDegrees(vector3(0.0, 0.0, math.deg(math.atan(toPlayer.x, toPlayer.y))), GetEntityForwardVector(otherPed))
                    if diff < 40.0 and d <= SUPPRESSION_RADIUS_METERS then
                        underFire = true
                        break
                    end
                end
            end
            found, otherPed = FindNextPed(handle)
        until not found
        EndFindPed(handle)

        if underFire then
            suppressionLevel = math.min(1.0, suppressionLevel + SUPPRESSION_GAIN_PER_TICK)
        else
            suppressionLevel = math.max(0.0, suppressionLevel - SUPPRESSION_DECAY_PER_TICK)
        end

        local now = GetGameTimer()
        if suppressionLevel > 0.0 and (now - lastReportAt) >= SUPPRESSION_REPORT_MS then
            lastReportAt = now
            TriggerServerEvent('matrix:server:reportSuppression', suppressionLevel)
        end
    end
end)

-- Vinyet/monokrom kararma -- suppressionLevel ile olceklenir (0 = etkisiz).
CreateThread(function()
    while true do
        if suppressionLevel > 0.01 then
            local alpha = math.floor(suppressionLevel * 180)
            local w, h = GetActiveScreenResolution()

            -- Kenarlardan icE dogru kararan 4 serit -- basit ama etkili bir
            -- "tunel gorusu" vinyeti (DrawRect merkezlenmis dikdortgen alir).
            local edge = 0.14 + (suppressionLevel * 0.10)
            DrawRect(0.5, edge / 2, 1.0, edge, 5, 5, 5, alpha)
            DrawRect(0.5, 1.0 - (edge / 2), 1.0, edge, 5, 5, 5, alpha)
            DrawRect(edge / 2, 0.5, edge, 1.0, 5, 5, 5, alpha)
            DrawRect(1.0 - (edge / 2), 0.5, edge, 1.0, 5, 5, 5, alpha)

            Wait(0)
        else
            Wait(250)
        end
    end
end)

-- =====================================================================
-- MODUL 7 (devam): KORTİZOL -> NİŞAN SALLANTISI (AIM SWAY)
-- server/wound_system.lua Matrix.Wounds.ApplySuppressionCortisol her
-- bastırma güncellemesinde bu event'i tetikler (mevcut cortisol_level
-- hiçbir yeni ikinci "biyoloji senkronu" İCAT EDİLMEDEN client'a iletilir).
-- Sunucudan gelmeyen aralıklarda değer, doğal toparlanmayla AYNI ruhta
-- yerel olarak yavaşça sıfıra sönümlenir (server tarafı zaten kendi
-- toparlanma formülünü ayrıca uyguluyor -- bu sadece GÖRSEL/HİSSİYAT
-- senkronu, ekonomi/DB durumu değil).
-- =====================================================================
local lastKnownCortisol = 0.0

RegisterNetEvent('matrix:client:cortisolSync', function(cortisolLevel)
    cortisolLevel = tonumber(cortisolLevel)
    if cortisolLevel then
        lastKnownCortisol = math.max(0.0, math.min(1.0, cortisolLevel))
    end
end)

CreateThread(function()
    while true do
        Wait(0)
        if lastKnownCortisol > 0.02 then
            local ped = PlayerPedId()
            if IsPedShooting(ped) or IsPlayerFreeAiming(PlayerId()) then
                ShakeGameplayCam('HAND_SHAKE', lastKnownCortisol)
            end
            -- Yerel görsel sönümleme (sunucu tarafi kendi toparlanma
            -- formülünü ayrıca uyguluyor -- bu SADECE hissiyat senkronu).
            lastKnownCortisol = math.max(0.0, lastKnownCortisol - 0.0003)
            Wait(0)
        else
            Wait(200)
        end
    end
end)

AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    SetPedMoveRateOverride(PlayerPedId(), 1.0)
end)
