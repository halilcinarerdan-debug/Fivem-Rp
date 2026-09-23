-- =====================================================================
-- MATRIX YARALANMA MOTORU / server/wound_system.lua
-- (KATMAN 2: Yasal Hastane/EMS Sizinti Döngüsü, KATMAN 3: Arma-Tarzı
--  Bölgesel Bot Yaralanması, KATMAN 4: Kalıcı Sakatlık + Hayalet Cerrah)
--
-- ★★★ TEMİZ SÜRÜM (BU DOSYA) ★★★
--   [FK-1] Tek yetkili EnsureBallisticParentSync (doğru şema kolonları).
--   [FK-2] Tek yetkili ApplyBotRegionalDamage — safeBallisticId bağlı.
--   [FK-3] Helper sıralaması doğru (GetOrInit/Persist/Pick → Apply'dan ÖNCE).
--   [FK-4] weapon_item_name (şemada yok) referansı TAMAMEN kaldırıldı.
--   [FK-5] STATEBAG INVALID-ENTITY FIX: 4-katmanlı savunma (dispatch
--          guard + NetworkGetEntityIsNetworked + reverse net_id check +
--          nested pcall). InvokeNative/qbx_smallresources crash'i
--          YAPISAL olarak imkansız.
--   0-RNG anayasası korundu (math.random YOK).
-- =====================================================================

Matrix.Wounds = Matrix.Wounds or {}

local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local math_min, math_max, math_floor          = math.min, math.max, math.floor
local math_huge                               = math.huge

-- =====================================================================
-- YARDIMCI FONKSİYONLAR
-- =====================================================================
local function Reply(src, msg)
    if type(src) == 'number' and src > 0 then
        TriggerClientEvent('chat:addMessage', src, { args = { '[YARALANMA]', msg } })
    else
        print(('[MATRIX:WOUNDS:CONSOLE] %s'):format(msg))
    end
end

local function VectorDistance(a, b)
    if not a or not b then return math_huge end
    local dx, dy, dz = a.x - b.x, a.y - b.y, (a.z or 0.0) - (b.z or 0.0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function FindNearestTrapHouse(coords)
    local nearestId, nearestDist = nil, math_huge
    for id, house in pairs(Matrix.TrapHouses or {}) do
        local d = VectorDistance(coords, house.coords)
        if d < nearestDist then nearestId, nearestDist = id, d end
    end
    return nearestId, nearestDist
end

-- ★ RNG YOK: server/blackmarket.lua ile aynı sağlama toplamı deseni.
local function ChecksumOf(raw, salt)
    local sum = 0
    for i = 1, #raw do
        sum = (sum + (raw:byte(i) * (i + salt))) % 0xFFFFFFF
    end
    return sum
end

-- =====================================================================
-- ★ [FK-1] TEK YETKİLİ PARENT-ROW SYNCHRONOUS UPSERT
--
-- matrix_ballistic_weapons ŞEMASI (matrix.sql):
--   ballistic_id (PK), weapon_serial (UNIQUE), wear_level,
--   sealed_as_crime_weapon, seal_certainty, first_registered
--
-- 'weapon_item_name' bu şemada YOK → ölü kolon referansı kaldırıldı.
-- Child FK (fk_matrix_forensic_evidence_ballistic) her zaman
-- garanti altına alınır.
-- =====================================================================
local function EnsureBallisticParentSync(ballisticId, weaponSerial)
    if type(ballisticId) ~= 'string' or ballisticId == '' then
        ballisticId = 'BAL-ORPHAN-UNKNOWN'
    end
    if type(weaponSerial) ~= 'string' or weaponSerial == '' then
        weaponSerial = ballisticId
    end

    -- 1) Hedeflenen parent anahtarı için SENKRON upsert (FK race penceresi kapalı).
    local targetOk = pcall(function()
        return MySQL.query.await([[
            INSERT INTO matrix_ballistic_weapons
                (ballistic_id, weapon_serial, wear_level, sealed_as_crime_weapon, first_registered)
            VALUES (?, ?, 0.0, 0, NOW())
            ON DUPLICATE KEY UPDATE weapon_serial = VALUES(weapon_serial)
        ]], { ballisticId, weaponSerial })
    end)
    if targetOk then return ballisticId end

    -- 2) Belt-and-suspenders: orphan anahtarını da senkron materyalize et.
    if ballisticId ~= 'BAL-ORPHAN-UNKNOWN' then
        local orphanOk = pcall(function()
            return MySQL.query.await([[
                INSERT INTO matrix_ballistic_weapons
                    (ballistic_id, weapon_serial, wear_level, sealed_as_crime_weapon, first_registered)
                VALUES ('BAL-ORPHAN-UNKNOWN', 'ORPHAN-SERIAL', 0.0, 0, NOW())
                ON DUPLICATE KEY UPDATE weapon_serial = VALUES(weapon_serial)
            ]], {})
        end)
        if orphanOk then return 'BAL-ORPHAN-UNKNOWN' end
    end

    -- 3) Her iki yol da başarısız → çağıran trauma row'unu atlayacak.
    return nil
end

-- =====================================================================
-- [KATMAN 3] BÖLGESEL BOT YARA STATE (RAM)
-- Helper'lar ApplyBotRegionalDamage'den ÖNCE tanımlanır.
-- =====================================================================
Matrix.Wounds.Bots = Matrix.Wounds.Bots or {}
local DamageTickCounter = {}

local function GetOrInitBotWound(botId)
    local w = Matrix.Wounds.Bots[botId]
    if w then return w end
    w = {
        wound_zone            = nil,
        leg_injury            = 0.0,
        head_injury           = 0.0,
        arm_injury            = 0.0,
        permanently_crippled  = 0,
        installed_prosthetic  = 0
    }
    Matrix.Wounds.Bots[botId] = w
    return w
end

local function PersistBotWound(botId, w)
    MySQL.prepare([[
        UPDATE matrix_bots
        SET wound_zone = ?, leg_injury = ?, head_injury = ?, arm_injury = ?,
            permanently_crippled = ?, installed_prosthetic = ?
        WHERE id = ?
    ]], {
        w.wound_zone, w.leg_injury, w.head_injury, w.arm_injury,
        w.permanently_crippled, w.installed_prosthetic, botId
    })
end

--- Deterministik bölge seçimi (RNG YOK): botId + monoton vuruş sayacı.
local function PickWoundZone(botId)
    DamageTickCounter[botId] = (DamageTickCounter[botId] or 0) + 1
    local raw = ('%d#%d'):format(botId, DamageTickCounter[botId])
    local idx = (ChecksumOf(raw, 17) % #Config.BotWounds.ZoneOrder) + 1
    return Config.BotWounds.ZoneOrder[idx]
end

-- =====================================================================
-- ★ TEK YETKİLİ ApplyBotRegionalDamage
--
-- [A] Dispatch guard      : bot aktif sevk DEĞİLSE statebag yazımı YOK
-- [B] Networked guard     : NetworkGetEntityIsNetworked
-- [C] Reverse net_id check: NetworkGetNetworkIdFromEntity == state.net_id
-- [D] Nested pcall        : güvenlik ağı
-- =====================================================================
function Matrix.Wounds.ApplyBotRegionalDamage(botId, rawDamage, forcedZone)
    local bot = Matrix.Bots[botId]
    if not bot then return end
    if bot.status ~= 'active' then return end

    local w = GetOrInitBotWound(botId)
    if w.permanently_crippled == 1 then return end

    local zone = forcedZone or PickWoundZone(botId)
    w.wound_zone = zone
    local delta = Matrix.Clamp(tonumber(rawDamage) or 0.05, 0.0, 1.0) * 0.25

    if zone == 'leg' then
        w.leg_injury = Matrix.Clamp(w.leg_injury + delta, 0.0, 1.0)
        if w.leg_injury >= (Config.BotWounds.CripplingThreshold or 1.0) then
            w.permanently_crippled = 1
            Matrix.Log('WOUNDS', '[KALICI SAKATLIK] Bot #%d bacaktan KALICI olarak sakat kaldi.', botId)
        end
    elseif zone == 'head' then
        w.head_injury = Matrix.Clamp(w.head_injury + delta, 0.0, 1.0)
    elseif zone == 'arm' then
        w.arm_injury = Matrix.Clamp(w.arm_injury + delta, 0.0, 1.0)
        if w.arm_injury >= (Config.BotWounds.CripplingThreshold or 1.0) then
            w.permanently_crippled = 1
            Matrix.Log('WOUNDS', '[KALICI SAKATLIK] Bot #%d koldan KALICI olarak sakat kaldi.', botId)
        end
    elseif zone == 'torso' then
        if bot.biology then
            bot.biology.cortisol_level = Config.BotWounds.TorsoCortisolLock or 0.90
        end

        local trapId = bot.state and bot.state.trap_house_id
        local zoneId = trapId and Matrix.Inspector and Matrix.Inspector.GetZoneForTrapHouse
            and Matrix.Inspector.GetZoneForTrapHouse(trapId) or nil
        if zoneId then
            MySQL.prepare([[
                INSERT INTO matrix_zone_ledger (zone_id, audit_anomaly_rate, updated_at)
                VALUES (?, ?, NOW())
                ON DUPLICATE KEY UPDATE audit_anomaly_rate = audit_anomaly_rate * ?, updated_at = NOW()
            ]], {
                zoneId,
                Config.BotWounds.TorsoAuditAnomalyMultiplier or 3.0,
                Config.BotWounds.TorsoAuditAnomalyMultiplier or 3.0
            })
        end

        if trapId then
            local stashId = ('matrix_trap_stash_%d'):format(trapId)
            local invOk, inv = pcall(exports['ox_inventory'].GetInventory, exports['ox_inventory'], stashId)
            if invOk and inv and inv.items then
                for _, item in pairs(inv.items) do
                    if item and item.name then
                        pcall(function()
                            exports['ox_inventory']:RemoveItem(stashId, item.name,
                                math_min(item.count or 0, math_floor(Config.BotWounds.TorsoStashTheftGrams or 10)))
                        end)
                        break
                    end
                end
            end
        end

        Matrix.Log('WOUNDS',
            '[GOVDE YARASI] Bot #%d -- kortizol kilitli, denetim anomali +%%%d, stash hirsizligi tetiklendi.',
            botId, math_floor(((Config.BotWounds.TorsoAuditAnomalyMultiplier or 3.0) - 1.0) * 100))

        -- =================================================================
        -- ★ [MODUL 15.2] KAYIP VE KANIT KARARTMA PROTOKOLU (Casualty
        -- Protocol) -- gövde yarasi (bu bot "yere yigildi") ANINDA, AKTIF
        -- bir sevkte (Matrix.Dispatches[botId]) OpenAI'in /timeemir ile
        -- atadigi dispatch.ai_fsm_matrix.casualty_protocol MEVCUTSA
        -- deterministik olarak dallanir -- alan YOKSA (AI emri hic
        -- verilmemis) HICBIR SEY DEGISMEZ (TAMAMEN ADDITIVE).
        -- =================================================================
        local dispatch = Matrix.Dispatches and Matrix.Dispatches[botId]
        if dispatch and dispatch.ai_fsm_matrix then
            local protocol = dispatch.ai_fsm_matrix.casualty_protocol
            local netId = bot.state and bot.state.net_id
            local casualtyPed = (type(netId) == 'number' and netId > 0) and NetworkGetEntityFromNetworkId(netId) or nil

            if protocol == 'carry' and casualtyPed and casualtyPed ~= 0 and DoesEntityExist(casualtyPed) then
                local vehNetId = dispatch.vehicle_net_id
                local vehicle = (type(vehNetId) == 'number' and vehNetId > 0) and NetworkGetEntityFromNetworkId(vehNetId) or nil
                if vehicle and vehicle ~= 0 and DoesEntityExist(vehicle) then
                    local ok = pcall(TaskPutPedDirectlyIntoVehicle, casualtyPed, vehicle, -1)
                    Matrix.Log('WOUNDS', '[KAYIP PROTOKOLU] Bot #%d "carry" emriyle araca yuklendi (basarili:%s).', botId, tostring(ok))

                    -- ★ [FIX] CASEVAC sirasinda yarali botun kanamasi
                    -- aracin ic mekanina/bagajina bulasir -- Matrix.
                    -- Forensics.RecordBloodEvidence (MODUL 2 ile AYNI
                    -- fonksiyon) aracin KENDI koordinatinda EK bir
                    -- biological_blood satiri isler -- ikinci bir "kan
                    -- delili" yolu ICAT EDILMEZ.
                    if ok and Matrix.Forensics and type(Matrix.Forensics.RecordBloodEvidence) == 'function' then
                        local vehCoords = GetEntityCoords(vehicle)
                        local cortisol = bot.biology and bot.biology.cortisol_level or 0.0
                        pcall(Matrix.Forensics.RecordBloodEvidence, bot.dna_id or 'UNKNOWN', 'CASEVAC', vehCoords, cortisol, 0.0)
                    end
                end
            elseif protocol == 'purge_evidence' and casualtyPed and casualtyPed ~= 0 and DoesEntityExist(casualtyPed) then
                local coords = GetEntityCoords(casualtyPed)
                local collectOk = pcall(Matrix.Forensics.CollectShells, botId, coords)
                Matrix.Log('WOUNDS', '[KAYIP PROTOKOLU] Bot #%d "purge_evidence" emriyle olay yeri kazindi (basarili:%s), otonom kacis.', botId, tostring(collectOk))
                if Matrix.CompleteDispatch then
                    pcall(Matrix.CompleteDispatch, botId, 'panic_recall')
                end
            end
        end
    end

    Matrix.Wounds.Bots[botId] = w
    PersistBotWound(botId, w)

    -- =================================================================
    -- ★ [A-D] STATEBAG WRITE — 4-KATMANLI SAVUNMA
    -- =================================================================
    local _botForStateBag = Matrix.Bots[botId]
    local _hasActiveDispatch = Matrix.Dispatches
        and type(Matrix.Dispatches) == 'table'
        and Matrix.Dispatches[botId] ~= nil

    if _botForStateBag
        and _hasActiveDispatch
        and _botForStateBag.state
        and type(_botForStateBag.state.net_id) == 'number'
        and _botForStateBag.state.net_id ~= 0 then
        pcall(function()
            local _pedEntity = NetworkGetEntityFromNetworkId(_botForStateBag.state.net_id)
            if not _pedEntity or _pedEntity == 0 then return end
            if not DoesEntityExist(_pedEntity) then return end
            if not NetworkGetEntityIsNetworked(_pedEntity) then return end

            local _freshNetId = NetworkGetNetworkIdFromEntity(_pedEntity)
            if type(_freshNetId) ~= 'number'
                or _freshNetId == 0
                or _freshNetId ~= _botForStateBag.state.net_id then
                return
            end

            Entity(_pedEntity).state.limb_damage = {
                leg_injury           = w.leg_injury,
                head_injury          = w.head_injury,
                arm_injury           = w.arm_injury,
                wound_zone           = w.wound_zone,
                permanently_crippled = w.permanently_crippled,
                installed_prosthetic = w.installed_prosthetic,
                updated_at           = Matrix.Now()
            }
        end)
    end

    -- =================================================================
    -- ★ [FK-2] ADLİ KANIT CHILD-ROW INSERT — safeBallisticId
    -- =================================================================
    if _botForStateBag then
        local _trapHouseId = _botForStateBag.state and _botForStateBag.state.trap_house_id
        if _trapHouseId then
            local traumaSerial = ('TRAUMA-%s'):format(tostring(_botForStateBag.dna_id or 'UNKNOWN'))

            local parentBallisticId
            if Matrix.Forensics and type(Matrix.Forensics.RegisterOrGetBallisticId) == 'function' then
                local ok, bId = pcall(Matrix.Forensics.RegisterOrGetBallisticId, traumaSerial, 0.0)
                if ok and type(bId) == 'string' and bId ~= '' then
                    parentBallisticId = bId
                end
            end
            if not parentBallisticId then
                parentBallisticId = 'BAL-ORPHAN-UNKNOWN'
            end

            local safeBallisticId = EnsureBallisticParentSync(parentBallisticId, traumaSerial)

            if safeBallisticId then
                pcall(function()
                    MySQL.prepare([[
                        INSERT INTO matrix_forensic_evidence
                            (ballistic_id, evidence_type, striation_quality, fingerprint_id,
                             fingerprint_quality, match_certainty, sealed_as_crime_weapon,
                             coords_x, coords_y, coords_z, biological_trauma,
                             inflicted_force_striation, created_at)
                        VALUES (?, 'biological_trauma', 1.0, ?, 1.0, 0.0, 0, 0.0, 0.0, 0.0, 1, ?, NOW())
                    ]], {
                        safeBallisticId,
                        _botForStateBag.dna_id or 'UNKNOWN',
                        w.leg_injury + w.head_injury + w.arm_injury
                    })
                end)
            else
                Matrix.Log('WOUNDS',
                    '[HATA] Ballistic parent satiri olusturulamadi -- trauma kaniti ATLANDI (bot=%s, RAM kalici).',
                    tostring(_botForStateBag.dna_id))
            end
        end
    end
end

-- =====================================================================
-- [KATMAN 3] EVENT BRIDGE
-- =====================================================================
AddEventHandler('matrix:server:reportDealerCombatDamage', function(botId, rawDamage)
    botId = tonumber(botId)
    if not botId then return end
    local ok, err = pcall(Matrix.Wounds.ApplyBotRegionalDamage, botId, rawDamage)
    if not ok then
        Matrix.Log('WOUNDS', '[HATA] ApplyBotRegionalDamage basarisiz (yutuldu): %s', tostring(err))
    end
end)

-- =====================================================================
-- [KATMAN 3] EFEKTIF CEZA ÇARPANLARI
-- =====================================================================
function Matrix.Wounds.GetMovementMultiplier(botId)
    local w = Matrix.Wounds.Bots[botId]
    if not w then return 1.0 end
    if w.permanently_crippled == 1 and w.leg_injury >= (Config.BotWounds.CripplingThreshold or 1.0) then
        return 1.0 - (Config.PermanentCrippling.LegMovementPenalty or 0.90)
    end
    if w.leg_injury > 0.0 then
        return 1.0 - (Config.BotWounds.LegSpeedPenalty or 0.60)
    end
    return 1.0
end

function Matrix.Wounds.GetDetectionRangeCap(botId)
    local w = Matrix.Wounds.Bots[botId]
    if not w or w.head_injury <= 0.0 then return nil end
    return Config.BotWounds.HeadDetectionRangeCap or 15.0
end

function Matrix.Wounds.GetAccuracyMultiplier(botId)
    local w = Matrix.Wounds.Bots[botId]
    if not w then return 1.0 end
    if w.permanently_crippled == 1 and w.arm_injury >= (Config.BotWounds.CripplingThreshold or 1.0) then
        return 1.0 - (Config.PermanentCrippling.ArmCraftingShootingPenalty or 0.90)
    end
    if w.arm_injury > 0.0 then
        return 1.0 - (Config.BotWounds.ArmAccuracyPenalty or 0.50)
    end
    return 1.0
end

function Matrix.Wounds.GetShellCasingQualityOverride(botId)
    local w = Matrix.Wounds.Bots[botId]
    if not w or w.arm_injury <= 0.0 then return nil end
    return Config.BotWounds.ArmPerfectCasingQuality or 1.0
end

-- =====================================================================
-- [KATMAN 3] KARABORSA AMELİYATI — Trap House tedavisi
-- =====================================================================
function Matrix.Wounds.BeginTrapHouseTreatment(botId)
    local bot = Matrix.Bots[botId]
    if not bot then return false, 'bot_missing' end
    local w = GetOrInitBotWound(botId)
    if w.permanently_crippled == 1 then return false, 'permanently_crippled' end
    if (w.leg_injury or 0.0) <= 0.0 and (w.head_injury or 0.0) <= 0.0 and (w.arm_injury or 0.0) <= 0.0 then
        return false, 'no_injury'
    end

    local until_ = Matrix.Now() + (Config.BotWounds.TrapHouseTreatmentHours or 12) * 3600
    bot.state.medical_lock_until = until_
    if Matrix.Dispatches and Matrix.Dispatches[botId] then
        Matrix.CompleteDispatch(botId, 'panic_recall')
    end

    MySQL.prepare('UPDATE matrix_bots SET medical_lock_until = FROM_UNIXTIME(?) WHERE id = ?', { until_, botId })
    Matrix.Log('WOUNDS', '[KARABORSA AMELIYATI] Bot #%d tedaviye alindi -- %d saat dispatch KABUL EDEMEZ.',
        botId, Config.BotWounds.TrapHouseTreatmentHours or 12)
    return true
end

function Matrix.Wounds.IsUnderMedicalLock(botId)
    local bot = Matrix.Bots[botId]
    if not bot or not bot.state or not bot.state.medical_lock_until then return false end
    return Matrix.Now() < bot.state.medical_lock_until
end

local function ProcessMedicalLockCycle()
    for botId, bot in pairs(Matrix.Bots) do
        local until_ = bot.state and bot.state.medical_lock_until
        if until_ and Matrix.Now() >= until_ then
            bot.state.medical_lock_until = nil
            local w = GetOrInitBotWound(botId)
            if w.permanently_crippled ~= 1 then
                w.leg_injury, w.head_injury, w.arm_injury, w.wound_zone = 0.0, 0.0, 0.0, nil
                PersistBotWound(botId, w)
                Matrix.Log('WOUNDS', '[TEDAVI TAMAMLANDI] Bot #%d uzuv hasarlari sifirlandi, dispatch tekrar aktif.', botId)
            end
            MySQL.prepare('UPDATE matrix_bots SET medical_lock_until = NULL WHERE id = ?', { botId })
        end
    end
end

CreateThread(function()
    while true do
        Wait(Config.Tick.SecondsPerMinute * Config.Tick.IntervalMs)
        local ok, err = pcall(ProcessMedicalLockCycle)
        if not ok then
            Matrix.Log('WOUNDS', '[HATA] ProcessMedicalLockCycle basarisiz (yutuldu): %s', tostring(err))
        end
    end
end)

RegisterCommand('kadroameliyat', function(src, args)
    local botId = tonumber(args[1])
    if not botId then Reply(src, 'Kullanim: /kadroameliyat [botId] (F10 panelinden kullanin)'); return end
    local ok, reason = Matrix.Wounds.BeginTrapHouseTreatment(botId)
    TriggerClientEvent('matrix:client:actionNotify', src, ok,
        ok and 'Bot tedaviye alindi.' or ('Ameliyat basarisiz: ' .. tostring(reason)))
end, false)

-- =====================================================================
-- [KATMAN 2] SON ATEŞ EDİLEN SİLAH ÖNBELLEĞİ (src bazlı)
-- =====================================================================
local LastFiredWeaponSerial = {}

AddEventHandler('matrix:server:reportWeaponShotFired', function(weaponItemName, weaponSlot)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    if type(weaponSlot) ~= 'number' then return end

    local ok, meta = pcall(Matrix.Inventory.GetSlotMetadata, tostring(src), weaponSlot)
    if not ok or type(meta) ~= 'table' then return end
    if type(meta.weapon_serial) == 'string' and meta.weapon_serial ~= '' then
        LastFiredWeaponSerial[src] = meta.weapon_serial
    end
end)

AddEventHandler('playerDropped', function()
    local src = source
    LastFiredWeaponSerial[src] = nil
end)

-- =====================================================================
-- MODUL 2: MELEE/BIÇAK SILAH HASH SETI (RNG YOK -- sabit ad listesinden
-- GetHashKey ile bir kez turetilir, sonra tostring(hash) karsilastirilir --
-- client'in TriggerServerEvent'e AYNEN gönderdiği format budur, bkz.
-- client/hud.lua: weaponHashStr = tostring(weaponHash)).
-- =====================================================================
local MeleeWeaponHashSet = {}
for _, weaponName in ipairs(Config.Forensics.MeleeWeaponNames or {}) do
    MeleeWeaponHashSet[tostring(GetHashKey(weaponName))] = true
end

-- =====================================================================
-- [KATMAN 2] OYUNCU-HASAR KANCA
--
-- ★ [MODUL 14.2] TEK YETKILI ProcessWoundReport: hem canli event'ten
-- (isDelayed=false) hem de client/hud.lua LocalAdliBuffer'inin agir
-- baglanti kesintisi sonrasi gonderdigi 'Delayed Batch Sync' paketinden
-- (isDelayed=true, originalTs = client'in o anki os.time() damgasi)
-- CAGRILIR -- ikinci bir "hasar isleme" yolu ICAT EDILMEZ. Zaman damgasi
-- gecmise donuk olsa dahi ayni ACID INSERT/UPDATE disiplini uygulanir.
-- =====================================================================
local function ProcessWoundReport(src, attackerServerId, attackerWeaponHash, isDelayed, originalTs)
    if type(src) ~= 'number' or src <= 0 then return end

    local state = Matrix.GetOrCreatePlayerState(src)
    if not state or not state.citizenid then return end

    -- ★ MODUL 2: melee/bicak hasari -> biological_blood adli kanit satiri.
    if type(attackerWeaponHash) == 'string' and MeleeWeaponHashSet[attackerWeaponHash] then
        attackerServerId = tonumber(attackerServerId)
        local attackerState = (attackerServerId and attackerServerId > 0)
            and Matrix.GetOrCreatePlayerState(attackerServerId) or nil
        local attackerDnaId = (attackerState and attackerState.dna_id) or 'UNKNOWN'

        local victimPed = GetPlayerPed(src)
        local coords = (victimPed and victimPed ~= 0) and GetEntityCoords(victimPed) or nil

        local cortisol = state.biology and state.biology.cortisol_level or 0.0
        local fatigue   = state.biology and state.biology.fatigue_level  or 0.0

        local ok, err = pcall(Matrix.Forensics.RecordBloodEvidence,
            state.dna_id, attackerDnaId, coords, cortisol, fatigue)
        if not ok then
            Matrix.Log('WOUNDS', '[HATA] RecordBloodEvidence basarisiz (yutuldu): %s', tostring(err))
        end
    end

    local ballisticId = nil

    attackerServerId = tonumber(attackerServerId)
    if attackerServerId and attackerServerId > 0 and LastFiredWeaponSerial[attackerServerId] then
        local serial = LastFiredWeaponSerial[attackerServerId]
        local ok, bId = pcall(Matrix.Forensics.RegisterOrGetBallisticId, serial, 1.0)
        if ok then ballisticId = bId end
    elseif type(attackerWeaponHash) == 'string' and attackerWeaponHash ~= '' then
        local syntheticSerial = ('NPC-%08X'):format(ChecksumOf(attackerWeaponHash, 41))
        local ok, bId = pcall(Matrix.Forensics.RegisterOrGetBallisticId, syntheticSerial, 1.0)
        if ok then ballisticId = bId end
    end

    if not ballisticId then return end

    MySQL.prepare([[
        INSERT INTO matrix_player_state (citizenid, has_wound, wound_ballistic_id, updated_at)
        VALUES (?, 1, ?, NOW())
        ON DUPLICATE KEY UPDATE has_wound = 1, wound_ballistic_id = VALUES(wound_ballistic_id), updated_at = NOW()
    ]], { state.citizenid, ballisticId })

    state.has_wound          = true
    state.wound_ballistic_id = ballisticId

    if isDelayed then
        Matrix.Log('WOUNDS',
            '[GECIKMELI ADLI IZ] %s balistik-imza #%s ile yaralandi (istemci zaman damgasi: %s, agir baglanti kesintisi sonrasi toplu senkron).',
            state.citizenid, tostring(ballisticId), tostring(originalTs))
    else
        Matrix.Log('WOUNDS', '[YARALANMA] %s balistik-imza #%s ile yaralandi.', state.citizenid, tostring(ballisticId))
    end
end

RegisterNetEvent('matrix:server:reportPlayerWounded', function(attackerServerId, attackerWeaponHash)
    local src = source
    ProcessWoundReport(src, attackerServerId, attackerWeaponHash, false, nil)
end)

-- =====================================================================
-- ★ [MODUL 14.2] GECIKMELI TOPLU SENKRON (Delayed Batch Sync) --
-- client/hud.lua LocalAdliBuffer'inin (agir baglanti kesintisi/timeout
-- riski sirasinda kordugu, FIFO + 32 paket tavanli) tampon icerigini
-- ag hatti normale doner donmez TEK bir event ile gonderir. Her kayit
-- BAGIMSIZ olarak, AYNI ProcessWoundReport disipliniyle (ACID insert/
-- update) islenir -- kismi yazim YOK. RAM-bomb korumasi: 32 kayittan
-- fazlasi (client tarafi zaten sinirlar, ama sunucu tarafi da GUVENMEZ)
-- SESSIZCE KIRPILIR.
-- =====================================================================
local MAX_DELAYED_BATCH_RECORDS = 32

RegisterNetEvent('matrix:server:reportPlayerWoundedBatch', function(records)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    if type(records) ~= 'table' then return end

    local processed = 0
    for i, rec in ipairs(records) do
        if i > MAX_DELAYED_BATCH_RECORDS then break end
        if type(rec) == 'table' then
            local ok, err = pcall(ProcessWoundReport, src, rec.attacker_server_id, rec.weapon_hash, true, rec.ts)
            if ok then
                processed = processed + 1
            else
                Matrix.Log('WOUNDS', '[HATA] Gecikmeli paket #%d islenemedi (yutuldu): %s', i, tostring(err))
            end
        end
    end

    if processed > 0 then
        Matrix.Log('WOUNDS', '[GECIKMELI ADLI IZ] src=%d -- %d/%d tamponlanmis paket ACID butunlugu ile islendi.',
            src, processed, math.min(#records, MAX_DELAYED_BATCH_RECORDS))
    end
end)

-- =====================================================================
-- MODUL 7: BASKI (SUPPRESSION) -> KORTİZOL ARTIŞI
-- client/anti_glitch.lua yakın-ıskalama/ateş-hattı vekilini saniyede bir
-- (SUPPRESSION_REPORT_MS) bu event ile bildirir. RNG YOK: sabit oran
-- (~%10/sn tam bastırmada) intensity (0..1) ile DOĞRUSAL ölçeklenir.
-- =====================================================================
function Matrix.Wounds.ApplySuppressionCortisol(src, intensity)
    if type(src) ~= 'number' or src <= 0 then return end
    local state = Matrix.GetOrCreatePlayerState(src)
    if not state or not state.biology then return end

    intensity = Matrix.Clamp(tonumber(intensity) or 0.0, 0.0, 1.0)
    local delta = 0.10 * intensity -- ~%10/sn tam bastirmada (event ~1sn'de bir gelir)

    state.biology.cortisol_level = Matrix.Clamp(state.biology.cortisol_level + delta, 0.0, 1.0)
    TriggerClientEvent('matrix:client:cortisolSync', src, state.biology.cortisol_level)
end

RegisterNetEvent('matrix:server:reportSuppression', function(intensity)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    local ok, err = pcall(Matrix.Wounds.ApplySuppressionCortisol, src, intensity)
    if not ok then
        Matrix.Log('WOUNDS', '[HATA] ApplySuppressionCortisol basarisiz (yutuldu): %s', tostring(err))
    end
end)

-- =====================================================================
-- ★ [MODUL 13.1] MUHAREBE STRESI (PANIK) VE EMIR REDDI
-- Histerezis: bot.state.panicking=true iken cortisol_level Config.
-- CombatPanic.CalmCortisolThreshold ALTINA dusmeden panicking=false
-- OLMAZ -- RefusalCortisolThreshold'un ANLIK altina/ustune salinimi
-- "yeniden itaat" SAYILMAZ (gorev talimati acikca boyle istiyor).
-- server/mercenary_followers.lua taktik emir atamasindan ONCE bunu
-- probe eder.
-- =====================================================================
function Matrix.Wounds.IsBotPanicking(botId)
    local bot = Matrix.Bots[botId]
    if not bot or not bot.biology then return false end

    local cortisol = bot.biology.cortisol_level or 0.0
    bot.state = bot.state or {}

    if bot.state.panicking then
        if cortisol < (Config.CombatPanic.CalmCortisolThreshold or 0.60) then
            bot.state.panicking = false
        end
    else
        if cortisol >= (Config.CombatPanic.RefusalCortisolThreshold or 0.85) then
            bot.state.panicking = true
        end
    end

    return bot.state.panicking == true
end

-- =====================================================================
-- ★ [MODUL 13.3] TAKTIK TURNIKE PROTOKOLU
-- Kompleks tibbi kit/igne YOK -- tek mudahale araci Config.
-- TacticalTourniquet.Item. Agir uzuv hasari alan (leg_injury>0 veya
-- arm_injury>0) bir bota, ApplyRadiusMeters icinden basarili mudahalede:
--   * leg/arm_injury InjuryReductionPct ORANIYLA sonumlenir (kalici
--     sakatlik esigine girme ihtimali dusurulur, TAMAMEN sifirlanmaz).
--   * bot.state.panicking=false (emirlere yeniden itaat).
--   * KOMA MODUNDAYSA (server/bureau.lua KOR NOKTA) Matrix.Bureau.
--     ExtendComaClock ile deceased-arsivleme sayaci ERTELENIR -- koma
--     IYILESTIRILMEZ (biz bir sagli ekibi degiliz).
--   * ADLI IZ: tuketilen turnike kumasina bulasan kan icin EK, yuksek
--     saflikli (cortisol=0,fatigue=0 -> purity=1.0, RNG YOK) bir
--     biological_blood satiri (MODUL 2 ile AYNI RecordBloodEvidence).
-- =====================================================================
function Matrix.Wounds.ApplyTourniquet(src, botId)
    if type(src) ~= 'number' or src <= 0 then return false, 'bad_src' end
    botId = tonumber(botId)
    local bot = botId and Matrix.Bots[botId]
    if not bot then return false, 'bot_missing' end

    local w = GetOrInitBotWound(botId)
    local wasComatose = (bot.status == 'comatose')

    if not wasComatose and w.leg_injury <= 0.0 and w.arm_injury <= 0.0 then
        return false, 'no_wound'
    end

    local ped = GetPlayerPed(src)
    local netId = bot.state and bot.state.net_id
    local botPed = (type(netId) == 'number' and netId > 0) and NetworkGetEntityFromNetworkId(netId) or nil
    if not ped or ped == 0 or not botPed or botPed == 0 or not DoesEntityExist(botPed) then
        return false, 'not_nearby'
    end

    local dist = VectorDistance(GetEntityCoords(ped), GetEntityCoords(botPed))
    if dist > (Config.TacticalTourniquet.ApplyRadiusMeters or 2.0) then
        return false, 'not_nearby'
    end

    local removeOk, removeResult = pcall(function()
        return exports['ox_inventory']:RemoveItem(src, Config.TacticalTourniquet.Item, 1)
    end)
    if not removeOk or removeResult ~= true then return false, 'item_missing' end

    local pct = Matrix.Clamp(Config.TacticalTourniquet.InjuryReductionPct or 0.50, 0.0, 1.0)
    w.leg_injury = Matrix.Clamp(w.leg_injury * (1.0 - pct), 0.0, 1.0)
    w.arm_injury = Matrix.Clamp(w.arm_injury * (1.0 - pct), 0.0, 1.0)
    PersistBotWound(botId, w)

    bot.state = bot.state or {}
    bot.state.panicking = false

    local comaExtended = false
    if wasComatose and Matrix.Bureau and type(Matrix.Bureau.ExtendComaClock) == 'function' then
        local ok = Matrix.Bureau.ExtendComaClock(botId, Config.TacticalTourniquet.ComaExtensionSeconds or 7200)
        comaExtended = (ok == true)
    end

    if Matrix.Forensics and type(Matrix.Forensics.RecordBloodEvidence) == 'function' then
        local coords = GetEntityCoords(botPed)
        pcall(Matrix.Forensics.RecordBloodEvidence, bot.dna_id or 'UNKNOWN', 'TOURNIQUET', coords, 0.0, 0.0)
    end

    Matrix.Log('WOUNDS', '[TURNIKE] src=%d bot #%d icin turnike uyguladi (koma-erteleme:%s).',
        src, botId, tostring(comaExtended))
    return true, comaExtended
end

RegisterNetEvent('matrix:server:wounds:applyTourniquet', function(botId)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end

    local ok, resultOrReason = Matrix.Wounds.ApplyTourniquet(src, botId)
    if ok then
        TriggerClientEvent('matrix:client:actionNotify', src, true, resultOrReason
            and '[TURNIKE] Kanama durduruldu, koma sayaci ertelendi.'
            or '[TURNIKE] Kanama durduruldu.')
    else
        local msg = (resultOrReason == 'no_wound') and 'Bu botun turnike gerektiren bir yarasi yok.'
            or (resultOrReason == 'not_nearby') and 'Turnike icin bota daha yakin olmalisiniz.'
            or (resultOrReason == 'item_missing') and 'Envanterinizde Taktik Turnike yok.'
            or 'Turnike uygulanamadi.'
        TriggerClientEvent('matrix:client:actionNotify', src, false, msg)
    end
end)

exports('ApplyTourniquet', function(src, botId) return Matrix.Wounds.ApplyTourniquet(src, botId) end)
exports('IsBotPanicking', function(botId) return Matrix.Wounds.IsBotPanicking(botId) end)

-- =====================================================================
-- [KATMAN 2] /tedaviol — Yasal Hastane Check-In + Adli Sorgu
-- =====================================================================
local BedsideSessions = {}

local function EnsureWoundColumnsLoaded(state)
    if state.has_wound ~= nil then return end
    local row = MySQL.single.await(
        'SELECT has_wound, wound_ballistic_id FROM matrix_player_state WHERE citizenid = ?',
        { state.citizenid })
    state.has_wound          = row and row.has_wound == 1 or false
    state.wound_ballistic_id = row and row.wound_ballistic_id or nil
end

function Matrix.Wounds.ComputeBureauLeakMultiplier(currentIntensity)
    if type(currentIntensity) ~= 'number' or currentIntensity ~= currentIntensity or currentIntensity <= 0.0 then
        currentIntensity = 1.0
    end
    local mult = Config.Hospital.LeakIntensityMultiplier or 2.0
    return currentIntensity * mult, mult, currentIntensity
end

local function LeakToBureauOnTreatment(citizenid, ballisticId)
    local current = GetConvarFloat('matrix_bureau_intensity', 1.0)
    local spiked, mult, correctedCurrent = Matrix.Wounds.ComputeBureauLeakMultiplier(current)
    current = correctedCurrent
    SetConvar('matrix_bureau_intensity', tostring(spiked))

    local nearestId = nil
    local row = ballisticId and MySQL.single.await(
        'SELECT coords_x, coords_y, coords_z FROM matrix_forensic_evidence WHERE ballistic_id = ? ORDER BY id DESC LIMIT 1',
        { ballisticId })
    if row then
        nearestId = FindNearestTrapHouse(vector3(row.coords_x, row.coords_y, row.coords_z))
    end
    if nearestId and Matrix.Bureau.LogPatternEvent then
        pcall(Matrix.Bureau.LogPatternEvent, nearestId)
    end

    Matrix.Log('WOUNDS', '[TIBBI SIZINTI] %s tedavi oldu -- matrix_bureau_intensity %.3f -> %.3f (x%.1f).',
        citizenid, current, spiked, mult)
end

RegisterCommand(Config.Hospital.TreatmentCommand, function(src)
    if type(src) ~= 'number' or src <= 0 then return end
    if not Config.Hospital.Enabled then return end

    local ped = GetPlayerPed(src)
    local coords = ped and ped ~= 0 and GetEntityCoords(ped) or nil
    local nearCheckIn = false
    if coords then
        for _, point in ipairs(Config.Hospital.CheckInPoints) do
            if VectorDistance(coords, point.coords) <= point.radius then nearCheckIn = true; break end
        end
    end
    if not nearCheckIn then
        Reply(src, 'Yasal bir hastane check-in noktasinda degilsiniz.')
        return
    end

    local state = Matrix.GetOrCreatePlayerState(src)
    if not state or not state.citizenid then return end
    EnsureWoundColumnsLoaded(state)

    if not state.has_wound then
        Reply(src, 'Uzerinizde kayitli bir yara izi yok -- tedaviye gerek duyulmadi.')
        return
    end

    local ballisticId = state.wound_ballistic_id

    state.has_wound = false
    MySQL.prepare('UPDATE matrix_player_state SET has_wound = 0 WHERE citizenid = ?', { state.citizenid })
    LeakToBureauOnTreatment(state.citizenid, ballisticId)

    BedsideSessions[state.citizenid] = {
        defendant_src     = src,
        ballistic_id      = ballisticId,
        conviction_weight = 0.0,
        lie_count         = 0
    }

    Reply(src, 'Tedavi tamamlandi. Yara ANINDA Buro raporuna dustu.')
    Reply(src, '[YATAK BASI SORGU] Yaranizin kaynagini soruluyor. /yarasorgucevap itiraf VEYA /yarasorgucevap inkar ile yanit verin.')
end, false)

RegisterCommand('yarasorgucevap', function(src, args)
    if type(src) ~= 'number' or src <= 0 then return end
    local state = Matrix.GetOrCreatePlayerState(src)
    if not state or not state.citizenid then return end

    local session = BedsideSessions[state.citizenid]
    if not session then
        Reply(src, 'Acik bir yatak-basi sorgu oturumunuz yok.')
        return
    end

    local answer = tostring(args[1] or ''):lower()
    local isLie       = (answer == 'inkar' or answer == 'yalan')
    local isConfession = (answer == 'itiraf' or answer == 'dogru')
    if not isLie and not isConfession then
        Reply(src, 'Kullanim: /yarasorgucevap [itiraf|inkar]')
        return
    end

    if isConfession then
        session.conviction_weight = 1.0
    elseif isLie and session.ballistic_id then
        local hasEvidence = MySQL.scalar.await(
            'SELECT COUNT(*) FROM matrix_forensic_evidence WHERE ballistic_id = ?', { session.ballistic_id }) or 0
        if tonumber(hasEvidence) and tonumber(hasEvidence) > 0 then
            session.lie_count = session.lie_count + 1
            session.conviction_weight = math_min(
                session.conviction_weight + (Config.Hospital.ConvictionWeightLiePenalty or 0.40), 1.0)
        end
    end

    Reply(src, ('[YATAK BASI SORGU] Yalan-Sayaci:%d | Mahkumiyet-Skoru:%%%.1f'):format(
        session.lie_count, session.conviction_weight * 100.0))

    if session.conviction_weight >= (Config.Hospital.ConvictionWipeThreshold or 1.0) then
        BedsideSessions[state.citizenid] = nil
        pcall(Matrix.Bureau.ExecuteVerdict, 0, {
            defendant_citizenid = state.citizenid,
            defendant_src       = src,
            lie_count           = session.lie_count
        })
    end
end, false)

-- =====================================================================
-- [KATMAN 4] HAYALET CERRAH (PHANTOM SURGEON)
-- =====================================================================
local function ComputePhantomIndexForBucket(epochBucket, coordsList)
    local raw = ('PHANTOM#%d'):format(epochBucket)
    return (ChecksumOf(raw, 71) % #coordsList) + 1
end

function Matrix.Wounds.GetPhantomDoctorLocation()
    local coordsList = Config.PhantomDoctor.Coords
    local intervalSeconds = (Config.PhantomDoctor.RotationIntervalHours or 6) * 3600
    local epochBucket = math_floor(Matrix.Now() / intervalSeconds)
    local idx = ComputePhantomIndexForBucket(epochBucket, coordsList)
    return coordsList[idx], idx
end

function Matrix.Wounds.__ComputePhantomIndexForEpochBucket(epochBucket)
    return ComputePhantomIndexForBucket(epochBucket, Config.PhantomDoctor.Coords)
end

function Matrix.Wounds.BeginPhantomSurgery(src, botId)
    local bot = Matrix.Bots[botId]
    if not bot then return false, 'bot_missing' end
    local w = GetOrInitBotWound(botId)
    if w.permanently_crippled ~= 1 then return false, 'not_crippled' end

    local doctorCoords = Matrix.Wounds.GetPhantomDoctorLocation()
    local ped = GetPlayerPed(src)
    local playerCoords = ped and ped ~= 0 and GetEntityCoords(ped) or nil
    if not playerCoords or VectorDistance(playerCoords, doctorCoords) > 25.0 then
        return false, 'not_at_doctor'
    end

    local player = Matrix.QBX:GetPlayer(src)
    if not player then return false, 'player_not_found' end

    local price = Config.PhantomDoctor.SurgeryPrice or 60000.0
    local bank = (player.PlayerData.money and player.PlayerData.money.bank) or 0
    local cash = (player.PlayerData.money and player.PlayerData.money.cash) or 0
    local account = nil
    if bank >= price then account = 'bank' elseif cash >= price then account = 'cash' end
    if not account then return false, 'insufficient_funds' end

    local removeOk, removeResult = pcall(function()
        return player.Functions.RemoveMoney(account, price, 'phantom-surgery')
    end)
    if not removeOk or removeResult ~= true then return false, 'charge_failed' end

    bot.status = 'comatose'
    Matrix.MarkBotDirty(botId)
    if Matrix.Dispatches and Matrix.Dispatches[botId] then
        Matrix.CompleteDispatch(botId, 'panic_recall')
    end

    local surgeryUntil = Matrix.Now() + (Config.PhantomDoctor.SurgeryHours or 24) * 3600
    bot.state.medical_lock_until = surgeryUntil

    local nearestTrapId = FindNearestTrapHouse(doctorCoords)
    if nearestTrapId then
        pcall(Matrix.Bureau.TriggerPropaganda, nearestTrapId)

        local velocity = Matrix.Bureau.GetBureaucraticVelocity and Matrix.Bureau.GetBureaucraticVelocity() or 1.0
        if velocity >= (Config.PhantomDoctor.FederalStingIntensityThreshold or 1.5) then
            pcall(Matrix.Bureau.IssueRaid, nearestTrapId)
            Reply(src, '[FEDERAL BASKIN] Buro yogunlugu ameliyat sirasinda kliniginizi buldu!')
        end
    end

    MySQL.prepare('UPDATE matrix_bots SET medical_lock_until = FROM_UNIXTIME(?) WHERE id = ?', { surgeryUntil, botId })
    Reply(src, ('[HAYALET CERRAH] $%.0f odendi. Bot #%d %d saatlik ameliyata alindi.'):format(
        price, botId, Config.PhantomDoctor.SurgeryHours or 24))
    return true
end

local function ProcessPhantomSurgeryCycle()
    for botId, bot in pairs(Matrix.Bots) do
        if bot.status == 'comatose' and bot.state and bot.state.medical_lock_until
            and Matrix.Now() >= bot.state.medical_lock_until then
            local w = GetOrInitBotWound(botId)
            if w.permanently_crippled == 1 then
                w.permanently_crippled = 0
                w.installed_prosthetic = 1
                w.leg_injury, w.head_injury, w.arm_injury, w.wound_zone = 0.0, 0.0, 0.0, nil
                PersistBotWound(botId, w)
                bot.status = 'active'
                bot.state.medical_lock_until = nil
                Matrix.MarkBotDirty(botId)
                MySQL.prepare('UPDATE matrix_bots SET medical_lock_until = NULL WHERE id = ?', { botId })
                Matrix.Log('WOUNDS', '[AMELIYAT BASARILI] Bot #%d protez takildi, kalici sakatlik giderildi.', botId)
            end
        end
    end
end

CreateThread(function()
    while true do
        Wait(Config.Tick.SecondsPerMinute * Config.Tick.IntervalMs)
        local ok, err = pcall(ProcessPhantomSurgeryCycle)
        if not ok then
            Matrix.Log('WOUNDS', '[HATA] ProcessPhantomSurgeryCycle basarisiz (yutuldu): %s', tostring(err))
        end
    end
end)

RegisterCommand('hayaletcerrah', function(src, args)
    local botId = tonumber(args[1])
    if not botId then Reply(src, 'Kullanim: /hayaletcerrah [botId] (doktorun konumundayken)'); return end
    local ok, reason = Matrix.Wounds.BeginPhantomSurgery(src, botId)
    TriggerClientEvent('matrix:client:actionNotify', src, ok,
        ok and 'Ameliyat basladi.' or ('Ameliyat basarisiz: ' .. tostring(reason)))
end, false)

lib.callback.register('matrix:callback:getPhantomDoctorLocation', function(src)
    return Matrix.Wounds.GetPhantomDoctorLocation()
end)

-- =====================================================================
-- BOOT: matrix_bots'un YENİ kolonlarını RAM önbelleğine yükle
-- =====================================================================
CreateThread(function()
    Wait(2000)
    local ok, rows = pcall(function()
        return MySQL.query.await(
            'SELECT id, wound_zone, leg_injury, head_injury, arm_injury, permanently_crippled, installed_prosthetic FROM matrix_bots')
    end)
    if not ok or type(rows) ~= 'table' then return end
    for _, row in ipairs(rows) do
        Matrix.Wounds.Bots[row.id] = {
            wound_zone            = row.wound_zone,
            leg_injury            = tonumber(row.leg_injury) or 0.0,
            head_injury           = tonumber(row.head_injury) or 0.0,
            arm_injury            = tonumber(row.arm_injury) or 0.0,
            permanently_crippled  = tonumber(row.permanently_crippled) or 0,
            installed_prosthetic  = tonumber(row.installed_prosthetic) or 0
        }
    end
    Matrix.Log('WOUNDS', 'Bot yara profilleri yuklendi (%d satir).', #rows)
end)