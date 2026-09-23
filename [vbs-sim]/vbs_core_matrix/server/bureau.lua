-- =====================================================================
-- MATRIX BUREAU / bureau.lua
-- Dirty-set persistence, ticker'da sıfır await, pattern cache,
-- ★ REVİZYON #2: BÜRO ↔ TOPTANCI İSTİHBARAT KÖPRÜSÜ
--
-- ★★★ YAMA 2 (BU SÜRÜM) — SEC-6 CRYPTO CAS + ASİMETRİK SABOTAJ KORUMASI ★★★
--   • [SEC-6] ProcessBribeCryptoTransaction artık Lua-seviyesi satır kilidi
--     + SELECT ... FOR UPDATE + DB CAS ile zırhlıdır. Kaybeden eşzamanlı
--     istek RAM önbelleğini KİRLETMEZ; yalnızca kazanan CAS RAM'e yazar.
--   • _BurnAndRaid KALDIRILDI; yerine _BurnAndRaidByHolder(holderIdentifier)
--     geldi. Ceza ve RAID tetikleyicisi, çağıranın gönderdiği
--     targetIdentifier'a DEĞİL, DB satır kilidinden okunan GERÇEK
--     wallet.holder_identifier değerine yönelir.
--   • [YAMA 5 KOD SAVUNMASI] _BurnAndRaidByHolder multi-match görürse
--     ikinci eşleşmeyi silmez, UYARI basar ve break eder. dna_id UNIQUE
--     KEY migration'ı uygulanınca bu dal hiç tetiklenmez.
--
-- ★★★ KATMAN 8 SIZDIRMAZ KANCA YAMASI (BU SÜRÜM — EN ÜST ÖNCELİK) ★★★
--   • RadioSpectrum alt tabloları (PushToTalkAccum/JamStrength/BreachAccum)
--     AYRI AYRI ilklendirilir; harici bir kod yolu tarafından kısmen
--     doldurulmuş olsa bile O(1) boş tablo ile tamamlanır.
--   • Livestream tick'indeki `cyberSkill` artık `ResolveLivestreamCyberSkill`
--     pcall+tip-guard katmanından geçer; Matrix.Kitchen yüklü DEĞİLSE veya
--     nil/NaN dönerse KESİN 1.0 taban değerine düşer (RNG YOK, determinizm
--     %100 korunur — eski kodun ORİJİNAL ilk değeri de 1.0'dı).
-- =====================================================================

Matrix.Bureau     = Matrix.Bureau     or {}
Matrix.TrapHouses = Matrix.TrapHouses or {}
Matrix.Supplier   = Matrix.Supplier   or {}
Matrix.Bureau.DropForensics = Matrix.Bureau.DropForensics or {}

local pairs, ipairs, next        = pairs, ipairs, next
local type, tostring, tonumber   = type, tostring, tonumber
local math, table                = math, table
local math_max, math_min         = math.max, math.min
local math_huge                  = math.huge
local math_floor                 = math.floor
local os_date                    = os.date
local os_time                    = os.time
local GetPlayerPed               = GetPlayerPed
local GetEntityCoords            = GetEntityCoords
local GetPeds                    = GetPeds
local DoesEntityExist             = DoesEntityExist
local GetPedPropIndex            = GetPedPropIndex

local propagandaMomentum = 0.0
local cyberLeakHeatmap   = {}
local patternLog         = {}

local dirtyDecryption = {}
local dirtyIntel      = {}
local dirtyPatternLog  = {}
local patternLogFlushed = {}

local RaidLogIdByTrapHouse = {}
local LivestreamSessions   = {}

local DropForensicsByDropId = Matrix.Bureau.DropForensics
local WARNED_MISSING_SUPPLIER_HOOK = false

-- =====================================================================
-- UTILITIES
-- =====================================================================
local function VectorDistance(a, b)
    if not a or not b then return math_huge end
    if type(a) ~= 'userdata' and type(a) ~= 'table' and type(a) ~= 'vector3' and type(a) ~= 'vector4' then return math_huge end
    if type(b) ~= 'userdata' and type(b) ~= 'table' and type(b) ~= 'vector3' and type(b) ~= 'vector4' then return math_huge end
    local ax, ay, az = a.x, a.y, a.z
    local bx, by, bz = b.x, b.y, b.z
    if type(ax) ~= 'number' or type(ay) ~= 'number' or type(az) ~= 'number' then return math_huge end
    if type(bx) ~= 'number' or type(by) ~= 'number' or type(bz) ~= 'number' then return math_huge end
    if ax ~= ax or ay ~= ay or az ~= az then return math_huge end
    if bx ~= bx or by ~= by or bz ~= bz then return math_huge end
    return #(a - b)
end

local function IsValidCoords(c)
    if type(c) ~= 'table' and type(c) ~= 'userdata' and type(c) ~= 'vector3' and type(c) ~= 'vector4' then return false end
    if c.x == nil or c.y == nil or c.z == nil then return false end
    if type(c.x) ~= 'number' or type(c.y) ~= 'number' or type(c.z) ~= 'number' then return false end
    if c.x ~= c.x or c.y ~= c.y or c.z ~= c.z then return false end
    return true
end

-- =====================================================================
-- LOAD
-- =====================================================================
function Matrix.Bureau.LoadTrapHouses()
    local rows = MySQL.query.await('SELECT * FROM matrix_trap_houses', {}) or {}
    for _, row in ipairs(rows) do
        Matrix.TrapHouses[row.id] = {
            id                   = row.id,
            label                = row.label or ('Trap #' .. row.id),
            coords               = vector3(row.coord_x or 0.0, row.coord_y or 0.0, row.coord_z or 0.0),
            decryption_confidence= Matrix.Clamp(tonumber(row.decryption_confidence) or 0.0, 0.0, 1.0),
            raid_ordered         = row.raid_ordered == 1
        }
        cyberLeakHeatmap[row.id] = Matrix.Clamp(tonumber(row.cyber_leak_intensity) or 0.0, 0.0, 999.0)
        patternLog[row.id]       = {}
    end
    Matrix.Log('BUREAU', '%d trap house yüklendi.', #rows)
end

CreateThread(function()
    Matrix.Bureau.LoadTrapHouses()
end)

function Matrix.Bureau.CreateTrapHouse(label, coords)
    if not IsValidCoords(coords) then return false, 'bad_coords' end
    label = (type(label) == 'string' and label ~= '') and label or 'Yeni Trap'

    MySQL.insert([[
        INSERT INTO matrix_trap_houses (label, coord_x, coord_y, coord_z, decryption_confidence, cyber_leak_intensity, raid_ordered, created_at)
        VALUES (?, ?, ?, ?, 0.0, 0.0, 0, NOW())
    ]], { label, coords.x, coords.y, coords.z },
    function(insertId)
        if not insertId then return end
        Matrix.TrapHouses[insertId] = {
            id = insertId, label = label, coords = vector3(coords.x, coords.y, coords.z),
            decryption_confidence = 0.0, raid_ordered = false
        }
        cyberLeakHeatmap[insertId] = 0.0
        patternLog[insertId] = {}
        Matrix.Log('BUREAU', 'Yeni trap house #%d (%s) oluşturuldu.', insertId, label)
    end)

    return true
end

-- =====================================================================
-- FIND NEAREST
-- =====================================================================
local function FindNearestTrapHouse(coords)
    local nearestId, nearestDist = nil, math_huge
    for id, house in pairs(Matrix.TrapHouses) do
        local d = VectorDistance(coords, house.coords)
        if d < nearestDist then nearestId, nearestDist = id, d end
    end
    return nearestId, nearestDist
end

-- =====================================================================
-- PATTERN LOG (cache + async upsert)
-- =====================================================================
function Matrix.Bureau.LogPatternEvent(trapHouseId)
    if type(trapHouseId) ~= 'number' or not Matrix.TrapHouses[trapHouseId] then return false end
    if not patternLog[trapHouseId] then patternLog[trapHouseId] = {} end

    local dt = os_date('*t')
    local key = ('%d_%d'):format(dt.wday, dt.hour)
    patternLog[trapHouseId][key] = (patternLog[trapHouseId][key] or 0) + 1

    dirtyPatternLog[trapHouseId] = true
    return true
end

local function FlushDirtyPatternLog()
    local queries = {}
    for trapHouseId in pairs(dirtyPatternLog) do
        local buckets = patternLog[trapHouseId]
        if buckets then
            local flushedSnap = patternLogFlushed[trapHouseId]
            if not flushedSnap then
                flushedSnap = {}
                patternLogFlushed[trapHouseId] = flushedSnap
            end
            for key, count in pairs(buckets) do
                local already = flushedSnap[key] or 0
                local delta = count - already
                if delta > 0 then
                    local wday, hour = key:match('^(%d+)_(%d+)$')
                    if wday and hour then
                        queries[#queries + 1] = {
                            query = [[
                                INSERT INTO matrix_pattern_log (trap_house_id, day_of_week, hour_of_day, occurrence_count)
                                VALUES (?, ?, ?, ?)
                                ON DUPLICATE KEY UPDATE occurrence_count = occurrence_count + VALUES(occurrence_count)
                            ]],
                            values = { trapHouseId, tonumber(wday), tonumber(hour), delta }
                        }
                        flushedSnap[key] = count
                    end
                end
            end
        end
        dirtyPatternLog[trapHouseId] = nil
    end

    if #queries == 0 then return end

    local ok, err = pcall(function() return MySQL.transaction.await(queries) end)
    if not ok or err == false then
        Matrix.Log('BUREAU', '[HATA][SEC-5] FlushDirtyPatternLog transaction basarisiz (yutulmadi, log icin): %s', tostring(err))
    end
end

local function ComputePatternRegularity(trapHouseId)
    local buckets = patternLog[trapHouseId]
    if not buckets then return 0.0 end

    local total, maxBucket = 0, 0
    for _, count in pairs(buckets) do
        total = total + count
        if count > maxBucket then maxBucket = count end
    end
    if total == 0 then return 0.0 end
    return maxBucket / total
end

-- =====================================================================
-- DECRYPTION (dirty-set)
-- =====================================================================
function Matrix.Bureau.AdvanceDecryption(trapHouseId, amount)
    local house = Matrix.TrapHouses[trapHouseId]
    if not house then return end

    amount = tonumber(amount) or 0.0
    if amount ~= amount then amount = 0.0 end

    amount = amount * Matrix.Bureau.GetBureaucraticVelocity()

    house.decryption_confidence = Matrix.Clamp(house.decryption_confidence + amount, 0.0, 1.0)
    dirtyDecryption[trapHouseId] = true

    if house.decryption_confidence >= Config.Bureau.RaidDecryptionThreshold and not house.raid_ordered then
        Matrix.Bureau.IssueRaid(trapHouseId)
    end
end

local function FlushDirtyDecryption()
    local queries = {}
    for id in pairs(dirtyDecryption) do
        local h = Matrix.TrapHouses[id]
        if h then
            queries[#queries + 1] = {
                query  = 'UPDATE matrix_trap_houses SET decryption_confidence = ? WHERE id = ?',
                values = { h.decryption_confidence, id }
            }
        end
        dirtyDecryption[id] = nil
    end
    if #queries == 0 then return end
    local ok, err = pcall(function() return MySQL.transaction.await(queries) end)
    if not ok or err == false then
        Matrix.Log('BUREAU', '[HATA][SEC-3] FlushDirtyDecryption transaction basarisiz (yutulmadi, log icin): %s', tostring(err))
    end
end

-- =====================================================================
-- COMMS TRIANGULATION (IDW)
-- =====================================================================
function Matrix.Bureau.OnUnencryptedComms(actorRef, coords)
    if not IsValidCoords(coords) then return nil end

    local actor = Matrix.ResolveActor(actorRef)

    local hitTowers = {}
    for _, tower in ipairs(Config.Bureau.CellTowers) do
        if VectorDistance(coords, tower.coords) <= Config.Bureau.TowerRange then
            hitTowers[#hitTowers + 1] = tower
        end
    end
    if #hitTowers == 0 then return nil end

    local sumX, sumY, sumZ, sumWeight = 0.0, 0.0, 0.0, 0.0
    for _, tower in ipairs(hitTowers) do
        local d = math_max(VectorDistance(coords, tower.coords), 1.0)
        local w = 1.0 / d
        sumX = sumX + (tower.coords.x * w)
        sumY = sumY + (tower.coords.y * w)
        sumZ = sumZ + (tower.coords.z * w)
        sumWeight = sumWeight + w
    end
    if sumWeight <= 0.0 then return nil end

    local estimate = vector3(sumX / sumWeight, sumY / sumWeight, sumZ / sumWeight)
    local narrowedRadius = Config.Bureau.BaseSearchRadius / #hitTowers

    local trapHouseId, distToTrap = FindNearestTrapHouse(estimate)
    if not trapHouseId or distToTrap > narrowedRadius then
        return { estimate = estimate, radius = narrowedRadius }
    end

    Matrix.Bureau.LogPatternEvent(trapHouseId)

    if Matrix.Bureau.RecordRadioBreach then
        Matrix.Bureau.RecordRadioBreach(trapHouseId)
    end

    local heat = cyberLeakHeatmap[trapHouseId] or 0.0
    local normRadius = math_max(narrowedRadius / Config.Bureau.BaseSearchRadius, 0.01)
    local gain = (Config.Bureau.TriangulationDecryptionGain / normRadius)
                 * (1.0 + heat)
                 / #hitTowers
    gain = Matrix.Clamp(gain, 0.0, 0.5)

    Matrix.Bureau.AdvanceDecryption(trapHouseId, gain)

    Matrix.Log('BUREAU', 'Üçgenleme (%s): %d istasyon, r=%.1fm, trap #%d kazanç=%.4f',
        (actor and actor.dna_id) or 'UNKNOWN', #hitTowers, narrowedRadius, trapHouseId, gain)

    return { estimate = estimate, radius = narrowedRadius, trap_house_id = trapHouseId, gain = gain }
end

-- =====================================================================
-- PROPAGANDA
-- =====================================================================
function Matrix.Bureau.TriggerPropaganda(trapHouseId)
    if type(trapHouseId) ~= 'number' or not Matrix.TrapHouses[trapHouseId] then return 0.0, 0.0 end

    propagandaMomentum = math_min(
        (propagandaMomentum * Config.Bureau.PropagandaGeometricFactor)
            + Config.Bureau.PropagandaMomentumIncrement,
        Config.Bureau.PropagandaMaxMomentum
    )

    local currentHeat = cyberLeakHeatmap[trapHouseId] or 0.0
    currentHeat = math_min(
        (currentHeat * Config.Bureau.CyberLeakGeometricFactor)
            + Config.Bureau.CyberLeakIncrement,
        Config.Bureau.CyberLeakMaxIntensity
    )
    cyberLeakHeatmap[trapHouseId] = currentHeat
    dirtyIntel[trapHouseId]       = true

    Matrix.Log('BUREAU', 'Propaganda: momentum=%.2f, trap #%d heat=%.2f',
        propagandaMomentum, trapHouseId, currentHeat)

    return propagandaMomentum, currentHeat
end

function Matrix.Bureau.GetPropagandaMomentum()
    return propagandaMomentum
end

function Matrix.Bureau.GetHeat(trapHouseId)
    return cyberLeakHeatmap[trapHouseId] or 0.0
end

local function FlushDirtyIntel()
    local queries = {}
    for id in pairs(dirtyIntel) do
        local heat = cyberLeakHeatmap[id] or 0.0
        queries[#queries + 1] = {
            query  = [[
                INSERT INTO matrix_bureau_intel (trap_house_id, category, intensity, updated_at)
                VALUES (?, 'cyber_leak', ?, NOW())
                ON DUPLICATE KEY UPDATE intensity = VALUES(intensity), updated_at = NOW()
            ]],
            values = { id, heat }
        }
        dirtyIntel[id] = nil
    end
    if #queries == 0 then return end
    local ok, err = pcall(function() return MySQL.transaction.await(queries) end)
    if not ok or err == false then
        Matrix.Log('BUREAU', '[HATA][SEC-3] FlushDirtyIntel transaction basarisiz (yutulmadi, log icin): %s', tostring(err))
    end
end

-- =====================================================================
-- TICK
-- =====================================================================
function Matrix.Bureau.Tick()
    for trapHouseId, house in pairs(Matrix.TrapHouses) do
        if not house.raid_ordered then
            local regularity = ComputePatternRegularity(trapHouseId)
            local heat       = cyberLeakHeatmap[trapHouseId] or 0.0
            local gain       = Config.Bureau.PatternAnalysisGain * regularity * (1.0 + heat)

            if gain > 0.0 then
                Matrix.Bureau.AdvanceDecryption(trapHouseId, gain)
            end
        end
    end
end

-- =====================================================================
-- RAID
-- =====================================================================
local function ComputeRaidSquad(trapHouseId, house)
    local heat = cyberLeakHeatmap[trapHouseId] or 0.0
    local squadSize = math_floor(Config.Bureau.RaidBaseSquadSize + (heat * Config.Bureau.RaidHeatSquadFactor) + 0.5)
    squadSize = math_max(Config.Bureau.RaidBaseSquadSize, math_min(squadSize, Config.Bureau.RaidMaxSquadSize))

    local breachMethod = (house.decryption_confidence >= Config.Bureau.RaidExplosiveBreachThreshold)
        and 'explosive' or 'ram'

    local escapeWindow = Config.Bureau.RaidBaseEscapeWindowSeconds
    for _, zone in ipairs(Config.Logistics.DeadZones) do
        if VectorDistance(house.coords, zone.coords) <= zone.radius then
            escapeWindow = escapeWindow + Config.Bureau.RaidDeadZoneEscapeBonusSeconds
            break
        end
    end

    if Matrix.DoorReinforcement and Matrix.DoorReinforcement.GetBreachDelaySeconds then
        local ok, bonus = pcall(Matrix.DoorReinforcement.GetBreachDelaySeconds, trapHouseId)
        if ok and type(bonus) == 'number' and bonus == bonus and bonus > 0.0 then
            escapeWindow = escapeWindow + bonus
        end
    end

    return squadSize, breachMethod, escapeWindow
end

-- =====================================================================
-- ★★★ SİVİL MUHBİR / MASKE ENTEGRASYONU ★★★
-- server/logistics.lua Matrix.Logistics.ApplyCombatDamage, bir bot
-- ELENDİĞİNDE (ve saldıran bir gerçek oyuncuysa) bu hook'u çağırır.
--
-- GetPedDensityMultiplier gibi bir GETTER native'i YOKTUR (bkz. server/
-- logistics.lua Config.Traffic yorumu) -- gerçek sivil (ped) sayısını
-- GetPeds() ile örneklem yarıçapında sayarız. Maske kontrolü GTA V'in
-- gerçek prop sistemi üzerinden yapılır: GetPedPropIndex(ped, 1) == -1
-- ise "Mask" prop slotu BOŞTUR (maskesiz).
--
--   • Sivil yoksa (yaricapta 0 ped) -> kimse GORMEDI, sessizce cikilir.
--   • Maskesiz -> GERCEK citizenid/dna_id polise ihbar edilir,
--     matrix_bureau_intensity ConVar'i (bureau.lua/logistics.lua/
--     wound_system.lua ILE AYNI ConVar) katlanir.
--   • Maskeli -> fail kimligi UNKNOWN-MASKED-SUBJECT olarak KALIR (sistem
--     COZEMEZ), bunun yerine bolgeye asenkron bir hitsquad sevk edilir
--     (Matrix.HitSquad.DispatchToNearestPlayer, pcall'li -- hitsquad.lua
--     yuklenmemis olsa bile bu fonksiyon COKMEZ).
-- =====================================================================
local function ComputeNearbyPedCount(coords, radius)
    if not (coords and radius and radius > 0.0) then return 0 end
    local ok, peds = pcall(GetPeds)
    if not ok or type(peds) ~= 'table' then return 0 end

    local radiusSq = radius * radius
    local count = 0
    for i = 1, #peds do
        local ped = peds[i]
        if ped and ped ~= 0 and DoesEntityExist(ped) then
            local okCoords, pedCoords = pcall(GetEntityCoords, ped)
            if okCoords and pedCoords then
                local dx, dy, dz = pedCoords.x - coords.x, pedCoords.y - coords.y, pedCoords.z - coords.z
                if (dx * dx + dy * dy + dz * dz) <= radiusSq then count = count + 1 end
            end
        end
    end
    return count
end

local function IsWearingMask(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false end
    local ok, propIndex = pcall(GetPedPropIndex, ped, (Config.Witness and Config.Witness.MaskPropSlot) or 1)
    if not ok then return false end
    return (tonumber(propIndex) or -1) ~= -1
end

--- @return string|nil failIdentifier -- gercek citizenid VEYA
---   'UNKNOWN-MASKED-SUBJECT' VEYA nil (kimse tanik olmadi).
function Matrix.Bureau.WitnessBotElimination(attackerSrc, botId, coords)
    if type(attackerSrc) ~= 'number' or attackerSrc <= 0 then return nil end
    if not (Config.Witness and coords) then return nil end

    local density = ComputeNearbyPedCount(coords, Config.Witness.SampleRadius or 30.0)
    if density <= 0 then return nil end -- kimse gormedi -- sessiz cikis

    local masked   = IsWearingMask(attackerSrc)
    local before   = GetConvarFloat('matrix_bureau_intensity', 1.0)
    local after    = before * (Config.Witness.BureauIntensitySpikeMultiplier or 2.0)
    SetConvar('matrix_bureau_intensity', tostring(after))

    if masked then
        Matrix.Log('BUREAU',
            '[MUHBIR][MASKELI] Bot #%d olumu %d sivil tarafindan goruldu -- fail=UNKNOWN-MASKED-SUBJECT. matrix_bureau_intensity %.2f -> %.2f.',
            botId, density, before, after)

        if Config.Witness.HitSquadDispatchOnMasked and Matrix.HitSquad and Matrix.HitSquad.DispatchToNearestPlayer then
            pcall(Matrix.HitSquad.DispatchToNearestPlayer, coords, 'muhbir_maskeli')
        end
        return 'UNKNOWN-MASKED-SUBJECT'
    end

    local state      = Matrix.GetOrCreatePlayerState(attackerSrc)
    local citizenid  = state and state.citizenid
    local dnaId      = state and state.dna_id

    Matrix.Log('BUREAU',
        '[MUHBIR] Bot #%d olumu %d sivil tarafindan goruldu -- fail kimligi=%s (dna=%s) polise ihbar edildi. matrix_bureau_intensity %.2f -> %.2f.',
        botId, density, tostring(citizenid), tostring(dnaId), before, after)

    return citizenid
end

exports('WitnessBotElimination', function(attackerSrc, botId, coords)
    return Matrix.Bureau.WitnessBotElimination(attackerSrc, botId, coords)
end)

function Matrix.Bureau.IssueRaid(trapHouseId)
    local house = Matrix.TrapHouses[trapHouseId]
    if not house then return end
    if house.raid_ordered then return end

    local decryptionAtRaid = house.decryption_confidence
    local squadSize, breachMethod, escapeWindow = ComputeRaidSquad(trapHouseId, house)

    house.raid_ordered          = true
    house.decryption_confidence = Config.Bureau.PostRaidDecryptionReset
    cyberLeakHeatmap[trapHouseId] = (cyberLeakHeatmap[trapHouseId] or 0.0) * Config.Bureau.PostRaidHeatmapDecay
    patternLog[trapHouseId]     = {}
    patternLogFlushed[trapHouseId] = nil

    MySQL.prepare([[
        UPDATE matrix_trap_houses
        SET raid_ordered = 1, last_raid_at = NOW(),
            decryption_confidence = ?, cyber_leak_intensity = ?
        WHERE id = ?
    ]], {
        Config.Bureau.PostRaidDecryptionReset,
        cyberLeakHeatmap[trapHouseId],
        trapHouseId
    })

    MySQL.insert([[
        INSERT INTO matrix_raid_log (
            trap_house_id, squad_size, breach_method, decryption_confidence_at_raid,
            escape_window_seconds, outcome, created_at
        ) VALUES (?, ?, ?, ?, ?, 'pending', NOW())
    ]], { trapHouseId, squadSize, breachMethod, decryptionAtRaid, escapeWindow },
    function(insertId)
        if insertId then RaidLogIdByTrapHouse[trapHouseId] = insertId end
    end)

    TriggerClientEvent('matrix:client:executeRaid', -1, trapHouseId, house.coords, {
        squad_size    = squadSize,
        breach_method = breachMethod,
        escape_window = escapeWindow
    })

    TriggerEvent('matrix:internal:raidIssued', trapHouseId, escapeWindow, breachMethod, squadSize)

    if Matrix.Bureau.RecordPurityIntercepted then
        Matrix.Bureau.RecordPurityIntercepted(trapHouseId)
    end

    Matrix.Log('BUREAU', '[ŞAFAK BASKINI] Trap house #%d (%s): %d birim, breach=%s, kaçış=%ds.',
        trapHouseId, house.label, squadSize, breachMethod, escapeWindow)
end

local VALID_RAID_OUTCOMES = { captured = true, escaped = true, eliminated = true }

function Matrix.Bureau.ResolveRaidOutcome(trapHouseId, outcome)
    if not VALID_RAID_OUTCOMES[outcome] then return false end
    local logId = RaidLogIdByTrapHouse[trapHouseId]
    if not logId then return false end

    MySQL.prepare('UPDATE matrix_raid_log SET outcome = ?, resolved_at = NOW() WHERE id = ?', { outcome, logId })

    TriggerEvent('matrix:internal:raidResolved', trapHouseId, outcome)

    Matrix.Log('BUREAU', 'Baskın (kayıt #%d, trap #%d) sonuçlandı: %s', logId, trapHouseId, outcome)
    return true
end

function Matrix.Bureau.ReceiveSnitchLeak(trapHouseId)
    local house = Matrix.TrapHouses[trapHouseId]
    if not house then return end

    local target = Config.Bureau.RaidDecryptionThreshold + 0.05
    if house.decryption_confidence < target then
        house.decryption_confidence = target
    end
    dirtyDecryption[trapHouseId] = true

    if Matrix.Bureau.RecordRadioBreach then
        Matrix.Bureau.RecordRadioBreach(trapHouseId)
    end
end

-- =====================================================================
-- FLUSH LOOP
-- =====================================================================
CreateThread(function()
    local interval = Config.Persistence.TrapHouseFlushIntervalMs or 20000
    while true do
        Wait(interval)
        FlushDirtyDecryption()
        FlushDirtyIntel()
        FlushDirtyPatternLog()
    end
end)

-- =====================================================================
-- LİVESTREAM
-- =====================================================================
function Matrix.Bureau.StartLivestream(src)
    if type(src) ~= 'number' or src <= 0 then return false end
    if LivestreamSessions[src] then return false end

    local searchOk, phoneCount = pcall(function()
        return exports['ox_inventory']:Search(src, 'count', 'burner_phone')
    end)
    if not searchOk or (tonumber(phoneCount) or 0) <= 0 then
        Matrix.Log('BUREAU', '[YAYIN REDDEDILDI] src=%s ustunde aktif burner_phone yok.', tostring(src))
        return false
    end

    local state = Matrix.GetOrCreatePlayerState(src)
    LivestreamSessions[src] = {
        started    = Matrix.Now(),
        citizenid  = state and state.citizenid,
        hype       = 1.0,
        heat_added = 0.0,
        trap_house_id = nil
    }
    Matrix.Log('BUREAU', '[CANLI YAYIN BAŞLADI] src=%d, IP çıkışı Büro siber taramasına açıldı.', src)
    return true
end

function Matrix.Bureau.StopLivestream(src)
    if type(src) ~= 'number' or src <= 0 then return false end
    local session = LivestreamSessions[src]
    if not session then return false end
    LivestreamSessions[src] = nil

    local duration = Matrix.Now() - session.started
    MySQL.prepare([[
        INSERT INTO matrix_livestream_events (citizenid, duration_seconds, hype_multiplier, heat_added, trap_house_id, created_at)
        VALUES (?, ?, ?, ?, ?, NOW())
    ]], { session.citizenid, duration, session.hype, session.heat_added, session.trap_house_id })

    Matrix.Log('BUREAU', '[CANLI YAYIN BİTTİ] src=%d, süre=%ds, son hype=%.2f, eklenen heat=%.2f',
        src, duration, session.hype, session.heat_added)
    return true
end

RegisterNetEvent('matrix:server:reportLivestreamStart', function()
    Matrix.Bureau.StartLivestream(source)
end)

RegisterNetEvent('matrix:server:reportLivestreamStop', function()
    Matrix.Bureau.StopLivestream(source)
end)

-- =====================================================================
-- ★ [SELF-HEALING FIX] cyberSkill RESOLUTION
--
-- ESKİ HATA: `cyberSkill = Matrix.Kitchen.GetEffectiveSkill(bot, 'skill_cyber')`
-- doğrudan çağrılıyordu. server/kitchen.lua henüz yüklenmemişse VEYA
-- fonksiyon nil/NaN döndürürse `math_max(nil, 0.1)` runtime hatası
-- fırlatıyor ve TÜM livestream tick döngüsü sessizce ölüyordu.
--
-- YENİ DİSİPLİN (RIGID STRUCTURAL FALLBACK):
--   1) Matrix.Kitchen VE GetEffectiveSkill tip kontrolü.
--   2) Çağrı pcall ile sarılır.
--   3) Dönüş değeri katı sayısal doğrulamadan geçer (nil/NaN/±inf reddedilir).
--   4) Herhangi bir aşama başarısız olursa → cyberSkill = 1.0 (eski kodun
--      ORİJİNAL ilk değeriyle BİREBİR AYNI, RNG YOK, determinizm %100).
--   5) En sonda math_max(cyberSkill, 0.1) alt sınırı yine uygulanır.
-- =====================================================================
local function ResolveLivestreamCyberSkill(trapHouseId)
    if not Matrix.Kitchen or type(Matrix.Kitchen.GetEffectiveSkill) ~= 'function' then
        return 1.0
    end

    local resolved = 1.0
    local botIter = Matrix.Bots
    if type(botIter) ~= 'table' then return resolved end

    for _, bot in pairs(botIter) do
        if bot and bot.state and bot.state.trap_house_id == trapHouseId then
            local okSkill, skillValue = pcall(Matrix.Kitchen.GetEffectiveSkill, bot, 'skill_cyber')
            if okSkill
                and type(skillValue) == 'number'
                and skillValue == skillValue
                and skillValue ~= math.huge
                and skillValue ~= -math.huge then
                resolved = skillValue
            end
            break
        end
    end

    if type(resolved) ~= 'number' or resolved ~= resolved
        or resolved == math.huge or resolved == -math.huge then
        resolved = 1.0
    end
    return resolved
end

CreateThread(function()
    while true do
        Wait(1000)
        for src, session in pairs(LivestreamSessions) do
            local ped = GetPlayerPed(src)
            local searchOk, phoneCount = pcall(function()
                return exports['ox_inventory']:Search(src, 'count', 'burner_phone')
            end)
            local hasBurnerPhone = searchOk and (tonumber(phoneCount) or 0) > 0

            if not ped or ped == 0 then
                LivestreamSessions[src] = nil
            elseif not hasBurnerPhone then
                Matrix.Log('BUREAU',
                    '[YAYIN ZORLA KESILDI] src=%d ustunde aktif burner_phone bulunamadi -- StopLivestream tetiklendi.', src)
                Matrix.Bureau.StopLivestream(src)
            else
                session.hype = math_min(
                    (session.hype * Config.Bureau.LivestreamHypeGeometricFactor) + Config.Bureau.LivestreamHypeIncrementPerTick,
                    Config.Bureau.PropagandaMaxMomentum
                )

                propagandaMomentum = math_min(
                    (propagandaMomentum * Config.Bureau.PropagandaGeometricFactor) + Config.Bureau.PropagandaMomentumIncrement,
                    Config.Bureau.PropagandaMaxMomentum
                )

                local coords = GetEntityCoords(ped)
                local trapHouseId, dist = FindNearestTrapHouse(coords)
                if trapHouseId and dist <= Config.Bureau.BaseSearchRadius then
                    session.trap_house_id = trapHouseId

                    local silent = Matrix.RadioSilence and Matrix.RadioSilence.IsActive
                        and Matrix.RadioSilence.IsActive(session.citizenid)

                    if not silent then
                        -- ★ SELF-HEALING FIX: cyberSkill artık nil/NaN OLAMAZ.
                        local cyberSkill = ResolveLivestreamCyberSkill(trapHouseId)
                        cyberSkill = math_max(cyberSkill, 0.1)

                        local heatGain = Config.Bureau.LivestreamHeatIncrementPerTick * cyberSkill
                        cyberLeakHeatmap[trapHouseId] = math_min(
                            ((cyberLeakHeatmap[trapHouseId] or 0.0) * Config.Bureau.CyberLeakGeometricFactor) + heatGain,
                            Config.Bureau.CyberLeakMaxIntensity
                        )
                        dirtyIntel[trapHouseId] = true
                        session.heat_added = session.heat_added + heatGain

                        Matrix.Bureau.AdvanceDecryption(trapHouseId, Config.Bureau.LivestreamDecryptionGainPerTick * cyberSkill)

                        Matrix.Bureau.RecordLivestreamRadioLeak(trapHouseId, Config.Bureau.LivestreamRadioBreachMultiplier)
                    end
                end
            end
        end
    end
end)

-- =====================================================================
-- REVİZYON #2: DEAD DROP ADLİ ÖRNEK TOPLAYICI
-- =====================================================================
local function CfgBureau(key, default)
    local v = Config.Bureau[key]
    if v == nil then return default end
    return v
end

local function NowEpoch()
    return os_time()
end

function Matrix.Bureau.OnDeadDropForensicPickup(dropId, quality, supplierId, citizenid)
    dropId     = tonumber(dropId)
    supplierId = tonumber(supplierId)
    quality    = tonumber(quality) or 0.0
    if not dropId or not supplierId then return false end
    if quality ~= quality then quality = 0.0 end
    quality = Matrix.Clamp(quality, 0.0, 1.0)

    local rec = DropForensicsByDropId[dropId]
    if not rec then
        rec = {
            samples          = {},
            supplier_id      = supplierId,
            citizenid        = citizenid or 'UNKNOWN',
            leaked           = false,
            last_activity_at = NowEpoch()
        }
        DropForensicsByDropId[dropId] = rec
    end

    local maxSamples = CfgBureau('MaxDropSamplesForLeak', 8)
    rec.samples[#rec.samples + 1] = { quality = quality, at = NowEpoch() }
    while #rec.samples > maxSamples do
        table.remove(rec.samples, 1)
    end
    rec.last_activity_at = NowEpoch()

    Matrix.Log('BUREAU',
        '[ADLİ ÖRNEK] Drop #%d, kalite=%.3f (toplam örnek: %d, toptancı #%d)',
        dropId, quality, #rec.samples, rec.supplier_id)
    return true
end

local function ComputeDropForensicCertainty(dropId, rec)
    rec = rec or DropForensicsByDropId[dropId]
    if not rec or #rec.samples == 0 then return 0.0, 0.0, 0 end

    local decayRate  = CfgBureau('SampleDecayRate', 0.002)
    local now        = NowEpoch()
    local wSum, qSum = 0.0, 0.0
    for _, s in ipairs(rec.samples) do
        local ageMin = math_max((now - s.at) / 60.0, 0.0)
        local w      = math.exp(-ageMin * decayRate)
        qSum = qSum + (s.quality * w)
        wSum = wSum + w
    end
    if wSum <= 0.0 then return 0.0, 0.0, #rec.samples end

    local avgQ        = qSum / wSum
    local required    = CfgBureau('RequiredSamplesForLeak', 3)
    local volumeF     = math_min(1.0, #rec.samples / math_max(required, 1))
    local heat        = 0.0
    local dropCfg
    if Config.Supplier and Config.Supplier.DeadDrops then
        for _, d in ipairs(Config.Supplier.DeadDrops) do
            if d.id == dropId then dropCfg = d break end
        end
    end
    if dropCfg then
        local trapId, trapDist = FindNearestTrapHouse(dropCfg.coords)
        if trapId and trapDist <= Config.Bureau.BaseSearchRadius then
            heat = cyberLeakHeatmap[trapId] or 0.0
        end
    end
    local heatF       = 1.0 + math_min(heat, Config.Bureau.CyberLeakMaxIntensity) * 0.15
    local certainty   = Matrix.Clamp(avgQ * volumeF * heatF, 0.0, 1.0)
    return certainty, avgQ, #rec.samples
end

local function EmitSupplierIntelLeak(citizenid, supplierId, certainty, dropId)
    local threshold  = CfgBureau('BureauLeakCertaintyThreshold', 0.65)
    local basePen    = CfgBureau('BureauLeakTrustPenaltyBase', 0.15)
    local maxPen     = CfgBureau('BureauLeakTrustPenaltyMax',  0.45)
    local span       = math_max(1.0 - threshold, 0.001)
    local norm       = Matrix.Clamp((certainty - threshold) / span, 0.0, 1.0)
    local penalty    = basePen + (maxPen - basePen) * norm

    if Matrix.Supplier and Matrix.Supplier.ApplyBureauIntelLeak then
        pcall(Matrix.Supplier.ApplyBureauIntelLeak, citizenid, supplierId, penalty, dropId)
    else
        MySQL.prepare([[
            INSERT INTO matrix_supplier_trust
                (citizenid, supplier_id, trust, late_payments, forensic_leaks, created_at, updated_at)
            VALUES (?, ?, 0.5, 0, 1, NOW(), NOW())
            ON DUPLICATE KEY UPDATE
                trust          = GREATEST(0.0, trust - ?),
                forensic_leaks = forensic_leaks + 1,
                updated_at     = NOW()
        ]], { citizenid, supplierId, penalty })

        if not WARNED_MISSING_SUPPLIER_HOOK then
            WARNED_MISSING_SUPPLIER_HOOK = true
            Matrix.Log('BUREAU',
                '[UYARI] Matrix.Supplier.ApplyBureauIntelLeak hooku tanimli degil; dogrudan DB yazimi kullanildi (logistics.lua guncellemesi onerilir).')
        end
    end

    Matrix.Log('BUREAU',
        '[İSTİHBARAT SIZINTISI] Drop #%d → Toptancı #%d | Kesinlik=%.3f | Penalty=%.3f | Mağdur=%s',
        dropId, supplierId, certainty, penalty, tostring(citizenid))
end

function Matrix.Bureau.TickDropForensics()
    local threshold  = CfgBureau('BureauLeakCertaintyThreshold', 0.65)
    local staleAfter = CfgBureau('DropForensicsStaleSeconds', 3600)

    local now = NowEpoch()
    local toRemove = {}

    for dropId, rec in pairs(DropForensicsByDropId) do
        if (now - (rec.last_activity_at or now)) > staleAfter then
            toRemove[#toRemove + 1] = dropId
        else
            local certainty, avgQ, N = ComputeDropForensicCertainty(dropId, rec)

            if not rec.leaked and certainty >= threshold then
                rec.leaked = true
                EmitSupplierIntelLeak(rec.citizenid, rec.supplier_id, certainty, dropId)
            end

            if N > 0 and N % 3 == 0 then
                Matrix.Log('BUREAU',
                    '[ADLİ TAKİP] Drop #%d | Örnek:%d | avgQ:%.3f | Kesinlik:%.3f (eşik:%.2f) | Sızdı:%s',
                    dropId, N, avgQ, certainty, threshold, tostring(rec.leaked))
            end
        end
    end

    for _, id in ipairs(toRemove) do
        DropForensicsByDropId[id] = nil
    end
end

CreateThread(function()
    local interval = CfgBureau('DropForensicsTickIntervalSeconds', 30) * 1000
    while true do
        Wait(interval)
        local ok, err = pcall(Matrix.Bureau.TickDropForensics)
        if not ok then
            Matrix.Log('BUREAU', '[HATA] TickDropForensics hata verdi (yutuldu): %s', tostring(err))
        end
    end
end)

-- =====================================================================
-- EVENT BRIDGE
-- =====================================================================
RegisterNetEvent('matrix:server:reportUnencryptedComms', function(coords)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    if not IsValidCoords(coords) then return end
    Matrix.Bureau.OnUnencryptedComms({ kind = 'player', source = src }, coords)
end)

RegisterNetEvent('matrix:server:triggerPropaganda', function(trapHouseId)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    trapHouseId = tonumber(trapHouseId)
    if not trapHouseId then return end
    Matrix.Bureau.TriggerPropaganda(trapHouseId)
end)

RegisterNetEvent('matrix:server:reportLogisticsRun', function(trapHouseId)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    trapHouseId = tonumber(trapHouseId)
    if not trapHouseId then return end
    Matrix.Bureau.LogPatternEvent(trapHouseId)
end)

RegisterNetEvent('matrix:server:reportRaidOutcome', function(trapHouseId, outcome)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    trapHouseId = tonumber(trapHouseId)
    if not trapHouseId then return end
    Matrix.Bureau.ResolveRaidOutcome(trapHouseId, outcome)
end)

RegisterNetEvent('matrix:server:reportDeadDropForensic', function(dropId, quality, supplierId, citizenid)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    Matrix.Bureau.OnDeadDropForensicPickup(dropId, quality, supplierId, citizenid)
end)

-- =====================================================================
-- EXPORTLAR
-- =====================================================================
exports('TriggerPropaganda',      function(t) return Matrix.Bureau.TriggerPropaganda(t) end)
exports('ReportUnencryptedComms', function(a, c) return Matrix.Bureau.OnUnencryptedComms(a, c) end)
exports('ReportLogisticsRun',     function(t) return Matrix.Bureau.LogPatternEvent(t) end)
exports('ReceiveSnitchLeak',      function(t) return Matrix.Bureau.ReceiveSnitchLeak(t) end)
exports('IssueRaid',              function(t) return Matrix.Bureau.IssueRaid(t) end)
exports('ResolveRaidOutcome',     function(t, o) return Matrix.Bureau.ResolveRaidOutcome(t, o) end)

exports('OnDeadDropForensicPickup', function(dropId, quality, supplierId, citizenid)
    return Matrix.Bureau.OnDeadDropForensicPickup(dropId, quality, supplierId, citizenid)
end)
exports('TickDropForensics', function()
    return Matrix.Bureau.TickDropForensics()
end)

-- =====================================================================
-- MONOKROM TAKTİK DEBUG PANELİ
-- =====================================================================
local function Reply(src, msg)
    if type(src) == 'number' and src > 0 then
        TriggerClientEvent('chat:addMessage', src, { args = { '[BUREAU]', msg } })
    else
        print(('[MATRIX:BUREAU:CONSOLE] %s'):format(msg))
    end
end

local function ParseCoordNumber(s)
    return tonumber((tostring(s or ''):gsub(',', '')))
end

Matrix.Security.RegisterGatedCommand('traphouseekle', function(src, args)
    local label = args[1]
    local x, y, z = ParseCoordNumber(args[2]), ParseCoordNumber(args[3]), ParseCoordNumber(args[4])
    if not x or not y or not z then
        Reply(src, 'Kullanim: /traphouseekle [label] [x] [y] [z]  (boslukla ayirin, virgul KULLANMAYIN)'); return
    end

    local ok, errOrResult = pcall(Matrix.Bureau.CreateTrapHouse, label, vector3(x, y, z))
    if not ok then
        Reply(src, ('HATA: trap house olusturulamadi (%s). Server konsolunu kontrol edin.'):format(tostring(errOrResult)))
        Matrix.Log('BUREAU', '[HATA] /traphouseekle basarisiz: %s', tostring(errOrResult))
        return
    end
    if errOrResult == false then
        Reply(src, 'HATA: gecersiz koordinat.')
        return
    end

    Reply(src, 'Trap house olusturma istegi gonderildi (async). Birkac saniye sonra /traphousedurum ile dogrulayin.')
end)

RegisterCommand('traphousedurum', function(src, args)
    local id = tonumber(args[1])
    local house = id and Matrix.TrapHouses[id]
    if not house then Reply(src, 'Kullanim: /traphousedurum [id]'); return end

    Reply(src, ('#%d %s | Deşifre:%.4f/%.2f | Heat:%.3f | Düzenlilik:%.3f | Baskın:%s'):format(
        id, house.label, house.decryption_confidence, Config.Bureau.RaidDecryptionThreshold,
        cyberLeakHeatmap[id] or 0.0, ComputePatternRegularity(id), tostring(house.raid_ordered)))
end, false)

Matrix.Security.RegisterGatedCommand('desifreekle', function(src, args)
    local id = tonumber(args[1])
    local amount = tonumber(args[2])
    if not id or not Matrix.TrapHouses[id] or not amount then
        Reply(src, 'Kullanim: /desifreekle [id] [miktar]'); return
    end
    Matrix.Bureau.AdvanceDecryption(id, amount)
    Reply(src, ('Trap #%d deşifre: %.4f'):format(id, Matrix.TrapHouses[id].decryption_confidence))
end)

Matrix.Security.RegisterGatedCommand('propagandatetikle', function(src, args)
    local id = tonumber(args[1])
    if not id or not Matrix.TrapHouses[id] then Reply(src, 'Kullanim: /propagandatetikle [id]'); return end
    local momentum, heat = Matrix.Bureau.TriggerPropaganda(id)
    Reply(src, ('Momentum:%.3f Heat:%.3f'):format(momentum, heat))
end)

Matrix.Security.RegisterGatedCommand('baskinzorla', function(src, args)
    local id = tonumber(args[1])
    if not id or not Matrix.TrapHouses[id] then Reply(src, 'Kullanim: /baskinzorla [id]'); return end
    Matrix.Bureau.IssueRaid(id)
    Reply(src, ('Trap #%d için baskın ZORLA tetiklendi (test modu).'):format(id))
end)

Matrix.Security.RegisterGatedCommand('baskinsonuclandir', function(src, args)
    local id = tonumber(args[1])
    local outcome = args[2]
    if not id or not outcome then
        Reply(src, 'Kullanim: /baskinsonuclandir [id] [captured|escaped|eliminated]'); return
    end
    local ok = Matrix.Bureau.ResolveRaidOutcome(id, outcome)
    Reply(src, ok and 'Sonuç kaydedildi.' or 'Geçersiz sonuç veya aktif baskın kaydı yok.')
end)

Matrix.Security.RegisterGatedCommand('yayinbaslat', function(src)
    local ok = Matrix.Bureau.StartLivestream(src)
    Reply(src, ok and 'Canlı yayın başlatıldı (test).' or 'Zaten yayında veya geçersiz src.')
end)

Matrix.Security.RegisterGatedCommand('yayinbitir', function(src)
    local ok = Matrix.Bureau.StopLivestream(src)
    Reply(src, ok and 'Canlı yayın bitirildi (test).' or 'Aktif yayın bulunamadı.')
end)

RegisterCommand('momentumgoster', function(src)
    Reply(src, ('Propaganda momentum: %.4f'):format(propagandaMomentum))
end, false)

Matrix.Security.RegisterGatedCommand('dropsizintiekle', function(src, args)
    local dropId     = tonumber(args[1])
    local quality    = tonumber(args[2])
    local supplierId = tonumber(args[3])
    local citizenid  = args[4] or 'TEST-CID'
    if not dropId or not quality or not supplierId then
        Reply(src, 'Kullanim: /dropsizintiekle [dropId] [kalite 0-1] [supplierId] [citizenid]'); return
    end
    local ok = Matrix.Bureau.OnDeadDropForensicPickup(dropId, quality, supplierId, citizenid)
    Reply(src, ok and ('Örnek eklendi. Toplam: %d'):format(#(DropForensicsByDropId[dropId] and DropForensicsByDropId[dropId].samples or {}))
              or 'Geçersiz parametre.')
end)

Matrix.Security.RegisterGatedCommand('dropsizintidurum', function(src)
    local count = 0
    for dropId, rec in pairs(DropForensicsByDropId) do
        count = count + 1
        local certainty, avgQ, N = ComputeDropForensicCertainty(dropId, rec)
        Reply(src, ('Drop #%d → Toptancı #%d | Örnek:%d avgQ:%.3f Kesinlik:%.3f | Sızdı:%s | Mağdur:%s'):format(
            dropId, rec.supplier_id, N, avgQ, certainty,
            tostring(rec.leaked), tostring(rec.citizenid)))
    end
    Reply(src, ('--- Toplam %d drop adli kaydi ---'):format(count))
    Reply(src, ('BureauLeakCertaintyThreshold: %.2f'):format(CfgBureau('BureauLeakCertaintyThreshold', 0.65)))
end)

Matrix.Security.RegisterGatedCommand('dropsizintisifirla', function(src, args)
    local dropId = tonumber(args[1])
    if not dropId then Reply(src, 'Kullanim: /dropsizintisifirla [dropId]'); return end
    if DropForensicsByDropId[dropId] then
        DropForensicsByDropId[dropId] = nil
        Reply(src, ('Drop #%d adli toplayicisi sifirlandi.'):format(dropId))
    else
        Reply(src, 'Bu drop için aktif adli kayit yok.')
    end
end)

-- =====================================================================
-- KATMAN 7 [T4] FAZ 1: BÜRO KİLİDİ
-- =====================================================================
local learningCore      = {}
local dirtyLearningCore = {}

local function GetLearningState(trapHouseId)
    local state = learningCore[trapHouseId]
    if not state then
        state = {
            frequent_zones             = {},
            radio_breach_count         = 0,
            average_purity_intercepted = 0.0,
            lockdown_active            = false
        }
        learningCore[trapHouseId] = state
    end
    return state
end

function Matrix.Bureau.LoadLearningCore()
    local rows = MySQL.query.await('SELECT * FROM matrix_bureau_learning_core', {}) or {}
    for _, row in ipairs(rows) do
        local zones = {}
        if row.frequent_zones and row.frequent_zones ~= '' then
            local ok, decoded = pcall(json.decode, row.frequent_zones)
            if ok and type(decoded) == 'table' then zones = decoded end
        end
        learningCore[row.trap_house_id] = {
            frequent_zones             = zones,
            radio_breach_count         = tonumber(row.radio_breach_count) or 0,
            average_purity_intercepted = tonumber(row.average_purity_intercepted) or 0.0,
            purity_sample_count        = tonumber(row.purity_sample_count) or 0,
            lockdown_active            = row.lockdown_active == 1
        }
    end
    Matrix.Log('BUREAU', '[T4] %d ogrenme hafizasi kaydi RAM onbellege kilitlendi.', #rows)
end

CreateThread(function()
    Matrix.Bureau.LoadLearningCore()
end)

local function FlushDirtyLearningCore()
    local queries = {}
    for trapHouseId in pairs(dirtyLearningCore) do
        local state = learningCore[trapHouseId]
        if state then
            queries[#queries + 1] = {
                query = [[
                    INSERT INTO matrix_bureau_learning_core
                        (trap_house_id, frequent_zones, radio_breach_count, average_purity_intercepted, purity_sample_count, lockdown_active, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, NOW())
                    ON DUPLICATE KEY UPDATE
                        frequent_zones             = VALUES(frequent_zones),
                        radio_breach_count         = VALUES(radio_breach_count),
                        average_purity_intercepted = VALUES(average_purity_intercepted),
                        purity_sample_count        = VALUES(purity_sample_count),
                        lockdown_active            = VALUES(lockdown_active),
                        updated_at                 = NOW()
                ]],
                values = {
                    trapHouseId,
                    json.encode(state.frequent_zones),
                    state.radio_breach_count,
                    state.average_purity_intercepted,
                    state.purity_sample_count or 0,
                    state.lockdown_active and 1 or 0
                }
            }
        end
        dirtyLearningCore[trapHouseId] = nil
    end
    if #queries == 0 then return end
    local ok, err = pcall(function() return MySQL.transaction.await(queries) end)
    if not ok or err == false then
        Matrix.Log('BUREAU', '[HATA][SEC-3] FlushDirtyLearningCore transaction basarisiz (yutulmadi, log icin): %s', tostring(err))
    end
end

CreateThread(function()
    local interval = Config.Persistence.TrapHouseFlushIntervalMs or 20000
    while true do
        Wait(interval)
        FlushDirtyLearningCore()
    end
end)

AddEventHandler('txAdmin:events:serverShuttingDown', function()
    Matrix.Log('BUREAU', '[SEC-3] Sunucu kapaniyor -- dirty-set son kurtarma flush islemi baslatildi.')
    local ok, err = pcall(function()
        FlushDirtyDecryption()
        FlushDirtyIntel()
        FlushDirtyPatternLog()
        FlushDirtyLearningCore()
    end)
    if not ok then
        Matrix.Log('BUREAU', '[HATA][SEC-3] Kapanis flush islemi sirasinda hata (yutulmadi, log icin): %s', tostring(err))
    else
        Matrix.Log('BUREAU', '[SEC-3] Kapanis flush islemi tamamlandi.')
    end
end)

local PATTERN_DECAY_INTERVAL_MS = 24 * 60 * 60 * 1000
local PATTERN_DECAY_FACTOR      = 0.5

CreateThread(function()
    while true do
        Wait(PATTERN_DECAY_INTERVAL_MS)
        for trapHouseId, buckets in pairs(patternLog) do
            local changed = false
            for key, count in pairs(buckets) do
                local decayed = math_floor(count * PATTERN_DECAY_FACTOR)
                if decayed ~= count then
                    buckets[key] = decayed
                    changed = true
                end
            end
            if changed then
                dirtyPatternLog[trapHouseId] = true
            end
        end
        Matrix.Log('BUREAU', '[SEC-5] Pattern log tazelik rotini calisti (x%.2f decay).', PATTERN_DECAY_FACTOR)
    end
end)

local function ComputeLockdownCoefficient(trapHouseId)
    local state = GetLearningState(trapHouseId)
    local breachRatio = math_min(state.radio_breach_count / Config.Bureau.LockdownBreachCeiling, 1.0)
    local purityRatio = math_min(state.average_purity_intercepted, 1.0)
    return (breachRatio * Config.Bureau.LockdownBreachWeight) + (purityRatio * Config.Bureau.LockdownPurityWeight)
end

local function EvaluateLockdown(trapHouseId)
    local state       = GetLearningState(trapHouseId)
    local coefficient = ComputeLockdownCoefficient(trapHouseId)

    if coefficient >= Config.Bureau.LockdownEvidenceThreshold and not state.lockdown_active then
        Matrix.Bureau.TriggerLockdown(trapHouseId, coefficient)
    elseif coefficient < Config.Bureau.LockdownEvidenceThreshold and state.lockdown_active then
        Matrix.Bureau.LiftLockdown(trapHouseId, coefficient)
    end

    return coefficient
end

local function MarkLearningZone(state, label)
    local zones = state.frequent_zones
    for i = 1, #zones do
        if zones[i] == label then return end
    end
    zones[#zones + 1] = label
end

function Matrix.Bureau.RecordRadioBreach(trapHouseId)
    local house = Matrix.TrapHouses[trapHouseId]
    if not house then return end

    local state = GetLearningState(trapHouseId)
    state.radio_breach_count = state.radio_breach_count + 1
    MarkLearningZone(state, house.label)

    dirtyLearningCore[trapHouseId] = true
    EvaluateLockdown(trapHouseId)
end

function Matrix.Bureau.RecordLivestreamRadioLeak(trapHouseId, multiplier)
    local house = Matrix.TrapHouses[trapHouseId]
    if not house then return end

    local state = GetLearningState(trapHouseId)
    state.livestream_leak_accumulator = (state.livestream_leak_accumulator or 0.0)
        + (Config.Bureau.LivestreamRadioLeakPerTick * (multiplier or 1.0))

    local wholeBreaches = math_floor(state.livestream_leak_accumulator)
    if wholeBreaches < 1 then return end

    state.livestream_leak_accumulator = state.livestream_leak_accumulator - wholeBreaches
    state.radio_breach_count = state.radio_breach_count + wholeBreaches
    MarkLearningZone(state, house.label)

    dirtyLearningCore[trapHouseId] = true
    EvaluateLockdown(trapHouseId)
end

function Matrix.Bureau.RecordPurityIntercepted(trapHouseId)
    if not Matrix.TrapHouses[trapHouseId] then return end

    MySQL.query('SELECT output_purity FROM matrix_kitchen_batches WHERE trap_house_id = ? ORDER BY id DESC LIMIT 1',
        { trapHouseId },
        function(rows)
            local row = rows and rows[1]
            if not row or row.output_purity == nil then return end

            local state  = GetLearningState(trapHouseId)
            local sample = Matrix.Clamp(tonumber(row.output_purity) or 0.0, 0.0, 1.0)

            state.purity_sample_count = (state.purity_sample_count or 0) + 1
            local n = state.purity_sample_count
            state.average_purity_intercepted = state.average_purity_intercepted + ((sample - state.average_purity_intercepted) / n)

            dirtyLearningCore[trapHouseId] = true
            EvaluateLockdown(trapHouseId)
        end)
end

function Matrix.Bureau.TriggerLockdown(trapHouseId, coefficient)
    local state = GetLearningState(trapHouseId)
    state.lockdown_active = true
    dirtyLearningCore[trapHouseId] = true

    TriggerEvent('matrix:internal:bureauLockdown', trapHouseId, true)

    local house = Matrix.TrapHouses[trapHouseId]
    Matrix.Log('BUREAU', '[T4][BURO KILIDI] Trap #%d (%s) icin NUKLEER ABLUKA DEVREDE (katsayi=%.3f/%.2f).',
        trapHouseId, (house and house.label) or '?', coefficient, Config.Bureau.LockdownEvidenceThreshold)
end

function Matrix.Bureau.LiftLockdown(trapHouseId, coefficient)
    local state = GetLearningState(trapHouseId)
    state.lockdown_active = false
    dirtyLearningCore[trapHouseId] = true

    TriggerEvent('matrix:internal:bureauLockdown', trapHouseId, false)

    local house = Matrix.TrapHouses[trapHouseId]
    Matrix.Log('BUREAU', '[T4][BURO KILIDI] Trap #%d (%s) ablukasi kalkti (katsayi=%.3f/%.2f).',
        trapHouseId, (house and house.label) or '?', coefficient, Config.Bureau.LockdownEvidenceThreshold)
end

function Matrix.Bureau.IsLockedDown(trapHouseId)
    local state = learningCore[trapHouseId]
    return state ~= nil and state.lockdown_active == true
end

function Matrix.Bureau.GetLockdownBulletin(trapHouseId)
    if not trapHouseId or not Matrix.Bureau.IsLockedDown(trapHouseId) then return nil end
    return '[ADLI ANOMALI: BURO KILIDI DEVREDE]', true
end

RegisterCommand('burokilitdurum', function(src, args)
    local id = tonumber(args[1])
    if not id or not Matrix.TrapHouses[id] then Reply(src, 'Kullanim: /burokilitdurum [trapHouseId]'); return end

    local state       = GetLearningState(id)
    local coefficient = ComputeLockdownCoefficient(id)
    Reply(src, ('Trap #%d | Telsiz-Ihlali:%d Ort.Saflik:%.3f | Katsayi:%.3f/%.2f | Kilit:%s'):format(
        id, state.radio_breach_count, state.average_purity_intercepted,
        coefficient, Config.Bureau.LockdownEvidenceThreshold,
        Matrix.FormatMilSimStatus(state.lockdown_active, '🚨 ABLUKA DEVREDE', '🟢 EMNİYETTE')))
end, false)

Matrix.Security.RegisterGatedCommand('burokilitzorla', function(src, args)
    local id = tonumber(args[1])
    if not id or not Matrix.TrapHouses[id] then Reply(src, 'Kullanim: /burokilitzorla [trapHouseId]'); return end
    Matrix.Bureau.TriggerLockdown(id, ComputeLockdownCoefficient(id))
    Reply(src, ('Trap #%d icin BURO KILIDI ZORLA tetiklendi (test modu).'):format(id))
end)

lib.callback.register('matrix:callback:getLearningCoreReport', function(src)
    local entries = {}

    for trapHouseId, house in pairs(Matrix.TrapHouses) do
        local state       = GetLearningState(trapHouseId)
        local coefficient = ComputeLockdownCoefficient(trapHouseId)

        local text = ('Trap #%d (%s) | Telsiz-Ihlali:%d | Ort.Saflik:%.3f | Katsayi:%.3f/%.2f | Kilit:%s'):format(
            trapHouseId, house.label, state.radio_breach_count, state.average_purity_intercepted,
            coefficient, Config.Bureau.LockdownEvidenceThreshold, state.lockdown_active and 'DEVREDE' or 'kapali')

        entries[#entries + 1] = {
            trap_house_id              = trapHouseId,
            label                      = house.label,
            radio_breach_count         = state.radio_breach_count,
            average_purity_intercepted = state.average_purity_intercepted,
            coefficient                = coefficient,
            threshold                  = Config.Bureau.LockdownEvidenceThreshold,
            lockdown_active            = state.lockdown_active,
            text                       = text
        }
    end

    table.sort(entries, function(a, b) return a.trap_house_id < b.trap_house_id end)
    return entries
end)

CreateThread(function()
    while true do
        Wait((Config.AI_Matrix_Brain.analysisIntervalMinutes or 60) * 60000)

        if Config.AI_Matrix_Brain.enabled then
            local ok, err = pcall(Matrix.Bureau.RunAIAdvisoryPass)
            if not ok then
                Matrix.Log('BUREAU', '[T4][AI] RunAIAdvisoryPass hata verdi (yutuldu): %s', tostring(err))
            end
        end
    end
end)

function Matrix.Bureau.RunAIAdvisoryPass()
    if Config.AI_Matrix_Brain.provider ~= 'openai' or not Config.AI_Matrix_Brain.apiKey or Config.AI_Matrix_Brain.apiKey == 'sk-...' then
        Matrix.Log('BUREAU', '[T4][AI] enabled=true fakat apiKey yapilandirilmamis, deterministik motor degismeden devam ediyor.')
        return
    end

    local payload = {}
    for trapHouseId, state in pairs(learningCore) do
        payload[#payload + 1] = {
            trap_house_id              = trapHouseId,
            frequent_zones             = state.frequent_zones,
            radio_breach_count         = state.radio_breach_count,
            average_purity_intercepted = state.average_purity_intercepted,
            lockdown_active            = state.lockdown_active
        }
    end

    local body = json.encode({
        model = 'gpt-4o-mini',
        messages = {
            { role = 'system', content = 'You are a deterministic police-heat auditor for a GTA roleplay server. Summarize risk trends only, never invent data, never suggest a course of action.' },
            { role = 'user', content = json.encode(payload) }
        }
    })

    -- ★ [SEC] pcall guard: Authorization header'ı burada inşa edilir --
    -- apiKey (server/config_secrets.lua, server-only) HİÇBİR log/Reply
    -- satırına asla YAZILMAZ; bir hata olsa bile yalnızca jenerik bir
    -- mesaj basılır, anahtarın kendisi ASLA konsola/oyuncuya sızmaz.
    local reqOk, reqErr = pcall(function()
        PerformHttpRequest('https://api.openai.com/v1/chat/completions', function(statusCode, response)
            if statusCode ~= 200 then
                Matrix.Log('BUREAU', '[T4][AI] OpenAI istegi basarisiz (HTTP %s); fallbackToDeterministic=%s, ogrenme motoru degismeden calismaya devam ediyor.',
                    tostring(statusCode), tostring(Config.AI_Matrix_Brain.fallbackToDeterministic))
                return
            end

            local ok, decoded = pcall(json.decode, response)
            if not ok then
                Matrix.Log('BUREAU', '[T4][AI] OpenAI yaniti cozumlenemedi, deterministik motor etkilenmedi.')
                return
            end

            TriggerEvent('matrix:internal:aiAdvisoryReceived', decoded)
        end, 'POST', body, {
            ['Content-Type']  = 'application/json',
            ['Authorization'] = 'Bearer ' .. tostring(Config.AI_Matrix_Brain.apiKey)
        })
    end)
    if not reqOk then
        -- ★ reqErr KASITLI OLARAK loglanmaz: Authorization header'i AYNI
        -- pcall govdesinde insa edildigi icin bir hata mesaji teorik
        -- olarak header string'ini icerebilir -- apiKey'in en ufak bir
        -- ihtimalle bile loga sizmasini onlemek icin yalnizca sabit,
        -- jenerik bir mesaj basilir.
        Matrix.Log('BUREAU', '[T4][AI] PerformHttpRequest cagrisi basarisiz (yutuldu, detay bilerek loglanmadi -- sir sizintisi riski).')
    end
end

-- =====================================================================
-- [OPSEC FAZ 1] POLİS KİŞİLİK GENETİĞİ + RÜŞVET MOTORU
-- =====================================================================
local function ChecksumOf(raw, salt)
    local sum = 0
    for i = 1, #raw do
        sum = (sum + (raw:byte(i) * (i + salt))) % 0xFFFFFFF
    end
    return sum
end

local PolicePersonalityCache = {}

function Matrix.Bureau.GetPolicePersonality(citizenid, npcModelHash, npcCoords)
    local identityKey
    if type(citizenid) == 'string' and citizenid ~= '' then
        identityKey = citizenid
    elseif npcModelHash ~= nil and IsValidCoords(npcCoords) then
        identityKey = ('NPC#%s#%.2f#%.2f#%.2f'):format(tostring(npcModelHash), npcCoords.x, npcCoords.y, npcCoords.z)
    else
        return nil
    end

    local cached = PolicePersonalityCache[identityKey]
    if cached then return cached end

    local sum = ChecksumOf(identityKey, 89)
    local personality = {
        integrity = Matrix.Clamp((sum % 1000) / 1000.0, 0.0, 1.0),
        greed     = Matrix.Clamp((math_floor(sum / 1000) % 1000) / 1000.0, 0.0, 1.0)
    }
    PolicePersonalityCache[identityKey] = personality

    Matrix.Log('BUREAU', '[OPSEC][KISILIK GENETIGI] %s -> integrity=%.3f greed=%.3f (salt=89, deterministik)',
        identityKey, personality.integrity, personality.greed)
    return personality
end

local function ChargeSuspectCash(src, amount)
    local ok, player = pcall(function() return Matrix.QBX:GetPlayer(src) end)
    if not ok or not player or not player.PlayerData then return false end

    local cash = (player.PlayerData.money and player.PlayerData.money.cash) or 0
    if cash < amount then return false end

    local removeOk, removeResult = pcall(function() return player.Functions.RemoveMoney('cash', amount, 'bribe-offer') end)
    return removeOk and removeResult == true
end

local function PaySuspectCashToOfficer(officerSrc, amount)
    local ok, officer = pcall(function() return Matrix.QBX:GetPlayer(officerSrc) end)
    if not ok or not officer then return false end
    pcall(function() officer.Functions.AddMoney('cash', amount, 'bribe-accepted') end)
    return true
end

function Matrix.Bureau.ProcessBribeOffer(officerSrc, suspectSrc, moneyAmount, caseId)
    if type(officerSrc) ~= 'number' or officerSrc <= 0 then return false, 'bad_officer' end
    if type(suspectSrc) ~= 'number' or suspectSrc <= 0 then return false, 'bad_suspect' end
    moneyAmount = tonumber(moneyAmount) or 0.0
    if moneyAmount ~= moneyAmount or moneyAmount <= 0.0 then return false, 'bad_amount' end

    local officerState = Matrix.GetOrCreatePlayerState(officerSrc)
    local suspectState = Matrix.GetOrCreatePlayerState(suspectSrc)
    if not officerState or not officerState.citizenid then return false, 'officer_unresolved' end
    if not suspectState or not suspectState.citizenid then return false, 'suspect_unresolved' end

    local cortisol = Matrix.Clamp((suspectState.biology and suspectState.biology.cortisol_level) or 0.0, 0.0, 1.0)

    local suspectPed    = GetPlayerPed(suspectSrc)
    local suspectCoords = (suspectPed and suspectPed ~= 0) and GetEntityCoords(suspectPed) or nil
    local trapHouseId   = suspectCoords and FindNearestTrapHouse(suspectCoords)

    if cortisol > Config.Kitchen.SnitchThreshold then
        if trapHouseId and Matrix.Bureau.RecordRadioBreach then
            Matrix.Bureau.RecordRadioBreach(trapHouseId)
        end
        Matrix.Log('BUREAU',
            '[RUSVET REDDEDILDI: PANIK] Supheli %s kortizol krizinde (%.3f > %.2f) -- adli surec isliyor.',
            suspectState.citizenid, cortisol, Config.Kitchen.SnitchThreshold)
        return false, { reason = 'suspect_panicking', cortisol = cortisol }
    end

    local personality = Matrix.Bureau.GetPolicePersonality(officerState.citizenid)
    if not personality then return false, 'officer_personality_unresolved' end

    local refAmount   = Config.Bureau.BribeReferenceAmount
    local moneyFactor = Matrix.Clamp(moneyAmount / math_max(refAmount, 1.0), 0.0, Config.Bureau.BribeMoneyFactorCeiling)
        * Config.Bureau.BribeMoneyWeight

    local score =
        (personality.greed * Config.Bureau.BribeGreedWeight)
        - (personality.integrity * Config.Bureau.BribeIntegrityWeight)
        - (cortisol * Config.Bureau.BribeCortisolWeight)
        + moneyFactor

    local threshold = Config.Bureau.BribeSuccessThreshold
    local success    = score >= threshold

    if success then
        local charged = ChargeSuspectCash(suspectSrc, moneyAmount)
        if charged then
            PaySuspectCashToOfficer(officerSrc, moneyAmount)
        end

        local tamperedCaseId = nil
        if type(caseId) == 'string' and caseId ~= '' and Matrix.Forensics and Matrix.Forensics.TamperEvidenceLockup then
            local tOk = Matrix.Forensics.TamperEvidenceLockup(officerState.citizenid, caseId, true)
            if tOk then tamperedCaseId = caseId end
        end

        Matrix.Log('BUREAU',
            '[RUSVET BASARILI] Memur %s (greed=%.3f integrity=%.3f) <- Supheli %s $%.0f | skor=%.3f/%.2f | odeme:%s | sabote-edilen-vaka:%s',
            officerState.citizenid, personality.greed, personality.integrity,
            suspectState.citizenid, moneyAmount, score, threshold, tostring(charged), tostring(tamperedCaseId))

        return true, { score = score, threshold = threshold, charged = charged, tampered_case = tamperedCaseId }
    end

    if trapHouseId and Matrix.Bureau.RecordRadioBreach then
        Matrix.Bureau.RecordRadioBreach(trapHouseId)
    end

    Matrix.Log('BUREAU',
        '[RUSVET REDDEDILDI] Memur %s (greed=%.3f integrity=%.3f) <- Supheli %s $%.0f | skor=%.3f/%.2f | adli surec isliyor',
        officerState.citizenid, personality.greed, personality.integrity,
        suspectState.citizenid, moneyAmount, score, threshold)

    return false, { score = score, threshold = threshold, reason = 'refused' }
end

RegisterNetEvent('matrix:server:bureau:offerBribe', function(officerSrc, moneyAmount, caseId)
    local suspectSrc = source
    if type(suspectSrc) ~= 'number' or suspectSrc <= 0 then return end
    officerSrc = tonumber(officerSrc)
    if not officerSrc then return end

    local ok, resultOrReason = Matrix.Bureau.ProcessBribeOffer(officerSrc, suspectSrc, moneyAmount, caseId)
    local detail = (type(resultOrReason) == 'table' and resultOrReason.reason) or tostring(resultOrReason)

    TriggerClientEvent('matrix:client:actionNotify', suspectSrc, ok,
        ok and 'Memur rusveti kabul etti.' or ('Rusvet reddedildi: %s'):format(tostring(detail)))

    if officerSrc > 0 and officerSrc ~= suspectSrc then
        TriggerClientEvent('matrix:client:actionNotify', officerSrc, ok,
            ok and 'Bir supheli rusvet teklif etti ve kabul ettiniz.' or 'Bir supheli rusvet teklif etti, reddettiniz/panikledi.')
    end
end)

RegisterCommand('rusvetteklifi', function(src, args)
    local officerSrc  = tonumber(args[1])
    local moneyAmount = tonumber(args[2])
    local caseId      = args[3]
    if not officerSrc or not moneyAmount then
        Reply(src, 'Kullanim: /rusvetteklifi [memurSrc] [miktar] [caseId/ballisticId (opsiyonel)]'); return
    end

    local ok, resultOrReason = Matrix.Bureau.ProcessBribeOffer(officerSrc, src, moneyAmount, caseId)
    if ok then
        Reply(src, ('Rusvet KABUL EDILDI (skor:%.3f/%.2f)%s.'):format(
            resultOrReason.score, resultOrReason.threshold,
            resultOrReason.tampered_case and (' | Vaka #%s sabote edildi'):format(resultOrReason.tampered_case) or ''))
    else
        local detail = (type(resultOrReason) == 'table')
            and ('%s | skor:%.3f/%.2f'):format(tostring(resultOrReason.reason), resultOrReason.score or 0, resultOrReason.threshold or 0)
            or tostring(resultOrReason)
        Reply(src, ('Rusvet REDDEDILDI (%s).'):format(detail))
    end
end, false)

Matrix.Security.RegisterGatedCommand('polisgenetigi', function(src, args)
    local citizenid = args[1]
    if type(citizenid) ~= 'string' then Reply(src, 'Kullanim: /polisgenetigi [citizenid]'); return end

    local personality = Matrix.Bureau.GetPolicePersonality(citizenid)
    if not personality then Reply(src, 'Kisilik hesaplanamadi.'); return end

    Reply(src, ('%s -> Integrity:%.3f Greed:%.3f'):format(citizenid, personality.integrity, personality.greed))
end)

exports('GetPolicePersonality', function(citizenid, npcModelHash, npcCoords)
    return Matrix.Bureau.GetPolicePersonality(citizenid, npcModelHash, npcCoords)
end)
exports('ProcessBribeOffer', function(officerSrc, suspectSrc, moneyAmount)
    return Matrix.Bureau.ProcessBribeOffer(officerSrc, suspectSrc, moneyAmount)
end)

-- =====================================================================
-- [OPSEC FAZ 1 EK] FEAR COEFFICIENT
-- =====================================================================
local cachedFearCoefficient = 0.0
local cachedEliminatedCount = 0

local function RefreshFearCoefficient()
    local rows = MySQL.query.await("SELECT COUNT(*) AS n FROM matrix_raid_log WHERE outcome = 'eliminated'", {})
    local n = (rows and rows[1] and tonumber(rows[1].n)) or 0
    cachedEliminatedCount = n

    local ceiling = CfgBureau('FearCoefficientEliminationCeiling', 20)
    cachedFearCoefficient = Matrix.Clamp(n / math_max(ceiling, 1), 0.0, 1.0)
end

CreateThread(function()
    local ok, err = pcall(RefreshFearCoefficient)
    if not ok then
        Matrix.Log('BUREAU', '[HATA] RefreshFearCoefficient ilk yukleme basarisiz (yutuldu): %s', tostring(err))
    end
    while true do
        Wait(CfgBureau('FearCoefficientRefreshIntervalMs', 120000))
        local tickOk, tickErr = pcall(RefreshFearCoefficient)
        if not tickOk then
            Matrix.Log('BUREAU', '[HATA] RefreshFearCoefficient hata verdi (yutuldu): %s', tostring(tickErr))
        end
    end
end)

function Matrix.Bureau.GetFearCoefficient()
    return cachedFearCoefficient
end

function Matrix.Bureau.GetEffectiveSnitchThreshold()
    local base    = Config.Kitchen.SnitchThreshold
    local ceiling = CfgBureau('FearCoefficientSnitchCeiling', 0.95)
    local raised  = base + ((ceiling - base) * cachedFearCoefficient)
    return Matrix.Clamp(raised, base, ceiling)
end

RegisterCommand('korkudurum', function(src)
    Reply(src, ('Infaz-Sayisi:%d | FearCoefficient:%.3f | Taban-Esik:%.2f -> Efektif-Esik:%.3f (tavan:%.2f)'):format(
        cachedEliminatedCount, cachedFearCoefficient,
        Config.Kitchen.SnitchThreshold, Matrix.Bureau.GetEffectiveSnitchThreshold(),
        CfgBureau('FearCoefficientSnitchCeiling', 0.95)))
end, false)

exports('GetFearCoefficient', function() return Matrix.Bureau.GetFearCoefficient() end)
exports('GetEffectiveSnitchThreshold', function() return Matrix.Bureau.GetEffectiveSnitchThreshold() end)

-- =====================================================================
-- [GLOBAL CONVAR] GetBureaucraticVelocity
-- =====================================================================
function Matrix.Bureau.GetBureaucraticVelocity()
    local intensity = GetConvarFloat('matrix_bureau_intensity', 1.0)
    if type(intensity) ~= 'number' or intensity ~= intensity or intensity <= 0.0 then
        intensity = 1.0
    end
    return intensity
end

exports('GetBureaucraticVelocity', function() return Matrix.Bureau.GetBureaucraticVelocity() end)

-- =====================================================================
-- [ADLİ RPG] MAHKEME İFADE ZİNCİRİ
-- =====================================================================
local TrialSessions = {}

function Matrix.Bureau.RequestAITrialNarrative(officerSrc, session)
    if Config.AI_Matrix_Brain.provider ~= 'openai' or not Config.AI_Matrix_Brain.apiKey or Config.AI_Matrix_Brain.apiKey == 'sk-...' then
        Reply(officerSrc, '[ADLİ İFADE] enabled=true fakat apiKey yapılandırılmamış; deterministik veriler değişmeden gösteriliyor.')
        Reply(officerSrc, ('Sanık DNA:%s | Eşleşme: %%%.1f'):format(session.dna_id, session.match_certainty * 100.0))
        return
    end

    local body = json.encode({
        model = 'gpt-4o-mini',
        messages = {
            { role = 'system', content = 'You are a Turkish-speaking courtroom narrator for a fictional GTA roleplay server. Given deterministic forensic match data, write a short reasoned (gerekceli) verdict narrative in Turkish. Never invent data beyond what is given, never claim it is a real legal proceeding.' },
            { role = 'user', content = json.encode({
                dna_id          = session.dna_id,
                ballistic_id    = session.ballistic_id,
                match_certainty = session.match_certainty
            }) }
        }
    })

    -- ★ [SEC] pcall guard -- bkz. RunAIAdvisoryPass'teki AYNI yorum:
    -- apiKey (server-only) hicbir Reply/Log satirina ASLA yazilmaz.
    local reqOk = pcall(function()
        PerformHttpRequest('https://api.openai.com/v1/chat/completions', function(statusCode, response)
            if statusCode ~= 200 then
                Reply(officerSrc, ('[ADLİ İFADE] OpenAI istegi basarisiz (HTTP %s); deterministik motor degismeden devam ediyor.'):format(tostring(statusCode)))
                return
            end
            local ok, decoded = pcall(json.decode, response)
            if not ok or not decoded.choices or not decoded.choices[1] then
                Reply(officerSrc, '[ADLİ İFADE] OpenAI yaniti cozumlenemedi.')
                return
            end
            local narrative = decoded.choices[1].message and decoded.choices[1].message.content
            Reply(officerSrc, '[MAHKEME KARARI - AI GEREKCE]')
            Reply(officerSrc, tostring(narrative or 'Anlati uretilemedi.'))
        end, 'POST', body, {
            ['Content-Type']  = 'application/json',
            ['Authorization'] = 'Bearer ' .. tostring(Config.AI_Matrix_Brain.apiKey)
        })
    end)
    if not reqOk then
        Reply(officerSrc, '[ADLİ İFADE] OpenAI istegi baslatilamadi (dahili hata, detay bilerek loglanmadi).')
    end
end

function Matrix.Bureau.OpenTrial(officerSrc, defendantSrc, dnaId)
    defendantSrc = tonumber(defendantSrc)
    if not defendantSrc or type(dnaId) ~= 'string' or dnaId == '' then return false, 'bad_args' end

    local defendantState = Matrix.GetOrCreatePlayerState(defendantSrc)
    if not defendantState or not defendantState.citizenid then return false, 'defendant_unresolved' end

    local rows = MySQL.query.await(
        'SELECT ballistic_id, match_certainty FROM matrix_forensic_evidence WHERE fingerprint_id = ? ORDER BY match_certainty DESC',
        { dnaId }) or {}

    local ballisticId, matchCertainty = nil, 0.0
    if rows[1] then
        ballisticId = rows[1].ballistic_id
        local total = 0.0
        for _, r in ipairs(rows) do total = total + (tonumber(r.match_certainty) or 0.0) end
        matchCertainty = total / #rows
    end

    local session = {
        defendant_src       = defendantSrc,
        defendant_citizenid = defendantState.citizenid,
        dna_id              = dnaId,
        ballistic_id        = ballisticId,
        match_certainty     = matchCertainty,
        lie_count           = 0,
        conviction_weight   = matchCertainty,
        opened_at           = Matrix.Now()
    }
    TrialSessions[defendantState.citizenid] = session

    MySQL.insert([[
        INSERT INTO matrix_trial_records
            (defendant_citizenid, dna_id, ballistic_id, match_certainty, lie_count, conviction_weight, verdict, opened_at)
        VALUES (?, ?, ?, ?, 0, ?, 'pending', NOW())
    ]], { defendantState.citizenid, dnaId, ballisticId, matchCertainty, matchCertainty })

    if not Config.AI_Matrix_Brain.enabled then
        Reply(officerSrc,
            ('[ADLİ İFADE - FAZ 1] Sanik DNA:%s | Namlu izi eslesmesi: %%%.1f%s'):format(
                dnaId, matchCertainty * 100.0,
                ballisticId and (' (Balistik #%s)'):format(ballisticId) or ' (eslesen balistik kaydi yok)'))
        Reply(officerSrc,
            matchCertainty >= Config.Forensics.MatchCertaintyThreshold
                and 'Kanitlar saniği dogrudan isaret ediyor. /davasorgula ile ifadesini sorgulayin.'
                or 'Kanitlar zayif. Sanik makul bir itirazla temize cikabilir.')
    else
        Reply(officerSrc, '[ADLİ İFADE - FAZ 1] Dava dosyasi OpenAI analiz koprusune gonderildi, gerekceli karar hazirlaniyor...')
        pcall(Matrix.Bureau.RequestAITrialNarrative, officerSrc, session)
    end

    return true, session
end

function Matrix.Bureau.RecordTrialResponse(officerSrc, defendantSrc, responseKind)
    defendantSrc = tonumber(defendantSrc)
    if not defendantSrc then return false, 'bad_args' end

    local defendantState = Matrix.GetOrCreatePlayerState(defendantSrc)
    if not defendantState or not defendantState.citizenid then return false, 'defendant_unresolved' end

    local session = TrialSessions[defendantState.citizenid]
    if not session then return false, 'no_open_case' end

    responseKind = tostring(responseKind or ''):lower()
    local isLie       = (responseKind == 'yalan' or responseKind == 'inkar')
    local isConfession = (responseKind == 'itiraf' or responseKind == 'dogru')
    if not isLie and not isConfession then return false, 'bad_response_kind' end

    if isConfession then
        session.conviction_weight = 1.0
    else
        if session.match_certainty >= Config.Forensics.MatchCertaintyThreshold then
            session.lie_count = session.lie_count + 1
            session.conviction_weight = math_min(
                (session.conviction_weight * Config.Bureau.TrialConvictionGeometricFactor) + Config.Bureau.TrialConvictionIncrement,
                1.0
            )
        end
    end

    MySQL.prepare([[
        UPDATE matrix_trial_records
        SET lie_count = ?, conviction_weight = ?
        WHERE defendant_citizenid = ? AND verdict = 'pending'
        ORDER BY opened_at DESC LIMIT 1
    ]], { session.lie_count, session.conviction_weight, session.defendant_citizenid })

    Reply(officerSrc, ('[ADLİ İFADE - FAZ 2] Yalan-Sayaci:%d | Mahkumiyet-Skoru:%%%.1f'):format(
        session.lie_count, session.conviction_weight * 100.0))

    if session.conviction_weight >= 1.0 then
        Matrix.Bureau.ExecuteVerdict(officerSrc, session)
        TrialSessions[session.defendant_citizenid] = nil
        return true, { verdict = 'imprisoned' }
    end

    return true, { verdict = 'pending' }
end

function Matrix.Bureau.ExecuteVerdict(officerSrc, session)
    local citizenid   = session.defendant_citizenid
    local defendantSrc = session.defendant_src

    MySQL.prepare('UPDATE matrix_player_state SET imprisoned = 1 WHERE citizenid = ?', { citizenid })
    MySQL.prepare([[
        UPDATE matrix_trial_records
        SET verdict = 'imprisoned', lie_count = ?, conviction_weight = 1.0, closed_at = NOW()
        WHERE defendant_citizenid = ? AND verdict = 'pending'
    ]], { session.lie_count, citizenid })

    local dbOk, dbErr = pcall(function()
        return MySQL.query.await('UPDATE matrix_bots SET status = ? WHERE handler_citizenid = ?', { 'disbanded', citizenid })
    end)
    if not dbOk then
        Matrix.Log('BUREAU', '[HATA] ExecuteVerdict bulk-disband DB guncellemesi basarisiz: %s', tostring(dbErr))
    end

    local disbandedCount = 0
    for id, bot in pairs(Matrix.Bots) do
        if bot.handler_citizenid == citizenid then
            if Matrix.Dispatches and Matrix.Dispatches[id] then
                Matrix.DespawnDispatchEntity(id, Matrix.Dispatches[id])
                Matrix.Dispatches[id] = nil
            end
            Matrix.Bots[id] = nil
            disbandedCount = disbandedCount + 1
        end
    end

    Matrix.Log('BUREAU',
        '[KARAKTER WIPE - MAHKUM] %s -> imprisoned=1, %d bagli otonom bot disbanded moduna cekildi.',
        citizenid, disbandedCount)

    Reply(officerSrc, ('[MAHKEME KARARI] %s -> %%100 Mahkumiyet Skoru. Karakter kilitlendi ve sunucudan tekmelendi.'):format(citizenid))

    if defendantSrc then
        pcall(function()
            DropPlayer(defendantSrc, 'MAHKUM EDILDINIZ: Adli surec sonucunda karakteriniz kalici olarak muhurlendi.')
        end)
    end
end

-- ★ [SEC][YETKI KAPISI EKLENDI] /davaac ve /davasorgula ÖNCEDEN hiçbir
-- kontrol taşımıyordu -- herhangi bir bağlı oyuncu, polis/Büro rolünde
-- OLMASA BİLE, başka HERHANGİ bir oyuncuyu (defendantSrc) doğrudan dava
-- açıp mahkum edebiliyordu (bkz. Matrix.Bureau.ExecuteVerdict zinciri).
-- Artık Matrix.IsOnDutyPolice(src) (GÖREVDE polis/şerif/LEO) ZORUNLU.
RegisterCommand('davaac', function(src, args)
    if not Matrix.IsOnDutyPolice(src) then
        Reply(src, 'Yetkisiz: dava acmak icin gorevde polis/serif olmaniz gerekir.')
        if Matrix.Security and Matrix.Security.LogTamperAttempt then
            Matrix.Security.LogTamperAttempt(src, 'davaac', args)
        end
        return
    end
    local defendantSrc = tonumber(args[1])
    local dnaId = args[2]
    if not defendantSrc or type(dnaId) ~= 'string' then
        Reply(src, 'Kullanim: /davaac [defendantRef(src)] [dnaId]'); return
    end
    local ok, resultOrReason = Matrix.Bureau.OpenTrial(src, defendantSrc, dnaId)
    if not ok then
        Reply(src, ('Dava acilamadi: %s'):format(tostring(resultOrReason)))
    end
end, false)

RegisterCommand('davasorgula', function(src, args)
    if not Matrix.IsOnDutyPolice(src) then
        Reply(src, 'Yetkisiz: sorgu yapmak icin gorevde polis/serif olmaniz gerekir.')
        if Matrix.Security and Matrix.Security.LogTamperAttempt then
            Matrix.Security.LogTamperAttempt(src, 'davasorgula', args)
        end
        return
    end
    local defendantSrc = tonumber(args[1])
    local responseKind = args[2]
    if not defendantSrc or not responseKind then
        Reply(src, 'Kullanim: /davasorgula [defendantRef(src)] [itiraf|yalan]'); return
    end
    local ok, resultOrReason = Matrix.Bureau.RecordTrialResponse(src, defendantSrc, responseKind)
    if not ok then
        Reply(src, ('Sorgu basarisiz: %s'):format(tostring(resultOrReason)))
    end
end, false)

exports('OpenTrial', function(officerSrc, defendantSrc, dnaId) return Matrix.Bureau.OpenTrial(officerSrc, defendantSrc, dnaId) end)
exports('RecordTrialResponse', function(officerSrc, defendantSrc, responseKind) return Matrix.Bureau.RecordTrialResponse(officerSrc, defendantSrc, responseKind) end)

-- =====================================================================
-- [KOR NOKTA] /telefonuyoket — TELEFON HATTI ADLİ SABOTAJI
-- =====================================================================
function Matrix.Bureau.SabotagePhoneLine(src, dnaId)
    if type(src) ~= 'number' or src <= 0 then return false, 'bad_src' end

    if type(dnaId) ~= 'string' or dnaId == '' then
        local state = Matrix.GetOrCreatePlayerState(src)
        dnaId = state and state.dna_id
    end
    if type(dnaId) ~= 'string' or dnaId == '' then return false, 'bad_dna' end

    local queries = {
        { query = 'DELETE FROM matrix_encrypted_messages WHERE dna_id = ?', values = { dnaId } },
        { query = "DELETE FROM matrix_forensic_evidence WHERE fingerprint_id = ? AND evidence_type = 'cyber' AND sealed_as_crime_weapon = 0", values = { dnaId } }
    }

    local ok, result = pcall(function() return MySQL.transaction.await(queries) end)
    if not ok or result == false then
        Matrix.Log('BUREAU', '[HATA] SabotagePhoneLine transaction basarisiz: %s', tostring(result))
        return false, 'db_error'
    end

    Matrix.Log('BUREAU',
        '[TELEFON HATTI SABOTAJI] %s -> kriptolu mesajlar + kesinlesmemis siber deliller TEK atomik transaction ile kazindi.',
        dnaId)
    return true, { dna_id = dnaId }
end

-- ★ [SEC-5][PARAMETRE ENJEKSIYONU DUZELTMESI] Bu komut ZORUNLU bir sivil
-- komuttur (bkz. README Sandbox bölümü) ve YALNIZCA çağıranın KENDİ
-- player_state.dna_id'sine kilitlenmelidir. Önceki sürüm args[1]'i
-- (çağıranın chat'e yazdığı KEYFİ bir string) doğrudan Matrix.Bureau.
-- SabotagePhoneLine'a dnaId olarak iletiyordu -- bu, herhangi bir
-- oyuncunun BAŞKA bir oyuncunun/botun dna_id'sini bilerek/tahmin ederek
-- ONLARIN şifreli mesajlarını ve mühürsüz siber delillerini silmesine
-- izin veriyordu (server/phone_bridge.lua'nın matrix:server:phone:
-- remoteWipe net-event'i ZATEN doğru şekilde kendi dna_id'sine kilitliydi
-- -- bu chat-komutu yolu GÖZDEN KAÇMIŞTI). args[1] artık TAMAMEN YOK
-- SAYILIR; hedef HER ZAMAN çağıranın kendi state'inden çözülür.
RegisterCommand('telefonuyoket', function(src)
    local ok, resultOrReason = Matrix.Bureau.SabotagePhoneLine(src, nil)
    if ok then
        Reply(src, ('[HAT SABOTAJI] %s hattina ait kriptolu mesajlar ve kesinlesmemis siber deliller kalici olarak kazindi.'):format(resultOrReason.dna_id))
    else
        Reply(src, ('Basarisiz: %s'):format(tostring(resultOrReason)))
    end
end, false)

exports('SabotagePhoneLine', function(src, dnaId) return Matrix.Bureau.SabotagePhoneLine(src, dnaId) end)

-- =====================================================================
-- [KOR NOKTA] KOMA MODU
-- =====================================================================
local ComaClock = {}

local function ProcessComaCycle()
    for botId, bot in pairs(Matrix.Bots) do
        if bot.status == 'active' and bot.biology and (bot.biology.withdrawal_index or 0.0) >= 1.0 then
            bot.status = 'comatose'
            Matrix.MarkBotDirty(botId)
            ComaClock[botId] = Matrix.Now()

            if Matrix.Dispatches and Matrix.Dispatches[botId] then
                Matrix.CompleteDispatch(botId, 'panic_recall')
            end

            Matrix.Log('CORE',
                '[KOMA MODU] Bot #%d withdrawal_index=%.3f -- sevk emirleri VE telsiz iletisimi TAMAMEN bloke edildi.',
                botId, bot.biology.withdrawal_index)
        elseif bot.status == 'comatose' then
            local since = ComaClock[botId]
            local ceilingHours = Config.Kitchen.ComaToDeceasedRealHours or 2
            if since and (Matrix.Now() - since) >= (ceilingHours * 3600) then
                ComaClock[botId] = nil
                Matrix.Log('CORE',
                    '[KOMA -> OLUM] Bot #%d %d saat mudahalesiz koma modunda kaldi, deceased arsivine dustu.',
                    botId, ceilingHours)
                Matrix.RemoveBot(botId, 'deceased')
            end
        end
    end
end

CreateThread(function()
    while true do
        Wait(Config.Tick.SecondsPerMinute * Config.Tick.IntervalMs)
        local ok, err = pcall(ProcessComaCycle)
        if not ok then
            Matrix.Log('CORE', '[HATA] ProcessComaCycle hata verdi (yutuldu): %s', tostring(err))
        end
    end
end)

-- =====================================================================
-- [KOR NOKTA] SAATLİK MALİ DENETİM
-- =====================================================================
function Matrix.Bureau.RunHourlyFinancialAudit()
    local ok, result = pcall(function()
        return MySQL.query.await('DELETE FROM matrix_purchase_logs WHERE created_at < (NOW() - INTERVAL 24 HOUR)', {})
    end)
    if not ok then
        Matrix.Log('BUREAU', '[HATA] RunHourlyFinancialAudit budama basarisiz: %s', tostring(result))
        return
    end
    local affected = (type(result) == 'table' and (result.affectedRows or result.numAffected)) or 0
    Matrix.Log('BUREAU', '[SAATLIK MALI DENETIM] matrix_purchase_logs budandi (24 saatten eski %s satir silindi).', tostring(affected))
end

CreateThread(function()
    while true do
        Wait(3600000)
        local ok, err = pcall(Matrix.Bureau.RunHourlyFinancialAudit)
        if not ok then
            Matrix.Log('BUREAU', '[HATA] RunHourlyFinancialAudit hata verdi (yutuldu): %s', tostring(err))
        end
    end
end)

exports('RunHourlyFinancialAudit', function() return Matrix.Bureau.RunHourlyFinancialAudit() end)

-- =====================================================================
-- ★★★ KATMAN 8 — CEPHE B: ANONİM KRİPTO CÜZDAN AĞLARI (SEC-6) ★★★
-- Rolling cipher mutasyon protokolü. FiveM server Lua ortamında saf
-- SHA-256 mevcut değildir; bu kod tabanının KENDİ ChecksumOf disipliniyle
-- tutarlı olarak 64-karakter deterministik hex üretimi yapılır.
-- SIFIR RNG: math.random YOKTUR.
--
-- ★★★ YAMA 2 (BU SÜRÜM) ★★★
--   • _BurnAndRaid KALDIRILDI → _BurnAndRaidByHolder(holderIdentifier).
--     Ceza artık çağıranın targetIdentifier'ına DEĞİL, DB satır kilidinden
--     okunan GERÇEK holder'a yönelir. Asimetrik grief vector kapatıldı.
--   • ProcessBribeCryptoTransaction:
--       - Lua-seviyesi satır kilidi (Matrix.Bureau.__CryptoLocks).
--       - SELECT ... FOR UPDATE ile InnoDB satır kilidi.
--       - Context drift, holderIdentifier üzerinden (DB'den okunan) teyit.
--       - CAS UPDATE (WHERE rolling_cipher_key = oldKey).
--       - Yalnızca KAZANAN CAS RAM önbelleğine yazar.
--   • [YAMA 5 KOD SAVUNMASI] Multi-match uyarısı: dna_id UNIQUE KEY
--     migration eksikse bile ikinci eşleşme SİLİNMEZ.
-- =====================================================================

Matrix.Bureau.CryptoWallets = Matrix.Bureau.CryptoWallets or {}
Matrix.Bureau.__CryptoLocks = Matrix.Bureau.__CryptoLocks or {}

local function _CryptoSha256Like(input)
    local out = {}
    for i = 1, 16 do
        local raw = ('%s#%d'):format(input, i)
        local sum = 0
        for j = 1, #raw do
            sum = (sum + (raw:byte(j) * (j + 97 + i))) % 0xFFFFFFF
        end
        out[i] = ('%04X'):format(sum % 0x10000)
    end
    return table.concat(out, '')
end

function Matrix.Bureau.GenerateWalletAddress(holderIdentifier, holderType)
    local seed = ('%s#%s#%s'):format(tostring(holderIdentifier), tostring(holderType), GetCurrentResourceName())
    return '0x' .. _CryptoSha256Like(seed):sub(1, 62)
end

local function _LoadCryptoWallet(walletAddress)
    local cached = Matrix.Bureau.CryptoWallets[walletAddress]
    if cached then return cached end
    local row = MySQL.single.await(
        'SELECT wallet_address, holder_identifier, holder_type, crypto_balance, rolling_cipher_key, tx_sequence FROM matrix_crypto_wallets WHERE wallet_address = ?',
        { walletAddress })
    if not row then return nil end
    cached = {
        wallet_address     = row.wallet_address,
        holder_identifier  = row.holder_identifier,
        holder_type        = row.holder_type,
        crypto_balance     = tonumber(row.crypto_balance) or 0.0,
        rolling_cipher_key = row.rolling_cipher_key,
        tx_sequence        = tonumber(row.tx_sequence) or 0,
    }
    Matrix.Bureau.CryptoWallets[walletAddress] = cached
    return cached
end

function Matrix.Bureau.EnsureCryptoWallet(holderIdentifier, holderType)
    if type(holderIdentifier) ~= 'string' or holderIdentifier == '' then return nil end
    holderType = (holderType == 'bot') and 'bot' or 'player'
    local addr = Matrix.Bureau.GenerateWalletAddress(holderIdentifier, holderType)
    local existing = _LoadCryptoWallet(addr)
    if existing then return existing end

    local initialKey = _CryptoSha256Like(('%s#%s#GENESIS'):format(addr, holderIdentifier))
    local rec = {
        wallet_address     = addr,
        holder_identifier  = holderIdentifier,
        holder_type        = holderType,
        crypto_balance     = 0.0,
        rolling_cipher_key = initialKey,
        tx_sequence        = 0,
    }
    MySQL.insert([[
        INSERT INTO matrix_crypto_wallets
            (wallet_address, holder_identifier, holder_type, crypto_balance, rolling_cipher_key, tx_sequence)
        VALUES (?, ?, ?, 0.0, ?, 0)
    ]], { addr, holderIdentifier, holderType, initialKey })
    Matrix.Bureau.CryptoWallets[addr] = rec
    return rec
end

--- ★ [YAMA 2 + YAMA 5] Burn + Raid — YALNIZCA DB'den okunan meşru
--- holder_identifier ile çağrılır. Çağıranın targetIdentifier'ına ASLA
--- güvenilmez. Multi-match görürse ikinci eşleşmeyi SİLMEZ, UYARI basar.
local function _BurnAndRaidByHolder(holderIdentifier)
    if type(holderIdentifier) ~= 'string' or holderIdentifier == '' then return end

    -- ★ [YAMA 5] Tek-eşleşme zorlaması (dna_id UNIQUE KEY migration'ı
    -- uygulanmamışsa belt-and-suspenders).
    local matchedBotId
    for id, bot in pairs(Matrix.Bots or {}) do
        if bot.dna_id == holderIdentifier then
            if matchedBotId then
                Matrix.Log('BUREAU',
                    '[YAMA 5][MULTI-MATCH] dna_id=%s id=%d ile id=%d arasinda cakisti -- UNIQUE KEY migration eksik. Ikinci SILINMEDI.',
                    holderIdentifier, matchedBotId, id)
                break
            end
            matchedBotId = id
        end
    end

    if matchedBotId then
        local bot = Matrix.Bots[matchedBotId]
        if bot and bot.status ~= 'burned' then
            bot.status = 'burned'
            Matrix.MarkBotDirty(matchedBotId)
        end
    end

    -- Trap house seçimi: EN KÜÇÜK id (deterministik, RNG yok).
    local firstTrapId
    for id in pairs(Matrix.TrapHouses or {}) do
        if not firstTrapId or id < firstTrapId then firstTrapId = id end
    end
    if firstTrapId and Matrix.Bureau.IssueRaid then
        pcall(Matrix.Bureau.IssueRaid, firstTrapId)
    end
end

--- ★ [SEC-6 v1 — ARTIK YALNIZCA FALLBACK] Rolling cipher mutasyon protokolü
--- — Lua-seviyesi satır kilidi + SELECT ... FOR UPDATE + DB CAS.
---
--- ★★★ BİLİNEN AÇIK (bu yüzden v2'ye taşındı): oxmysql'in her `.await()`
--- çağrısı havuzdan (pool) BAĞIMSIZ bir bağlantı alabilir. `SELECT ... FOR
--- UPDATE` ile ardından gelen `UPDATE` AYRI İKİ round-trip olduğu ve
--- aralarında açık bir `START TRANSACTION`/`COMMIT` BULUNMADIĞI için
--- (autocommit altında), InnoDB satır kilidi SELECT ifadesi biter bitmez
--- "havada" bırakılabilir -- yani yorumdaki "InnoDB satır kilidi" iddiası
--- yanıltıcıdır. Bu fonksiyon YİNE DE güvenlidir çünkü nihai doğruluk CAS
--- UPDATE'in (WHERE rolling_cipher_key = oldKey) kendisinden gelir, ama
--- gerçek atomiklik garantisi YOKTUR. Şimdi yalnızca sp_matrix_process_
--- bribe_crypto_transaction (bkz. sql/matrix_financial_core.sql, TEK bir
--- MariaDB transaction'ında SELECT...FOR UPDATE + UPDATE + COMMIT) migration'ı
--- HENÜZ uygulanmamış eski dağıtımlar için bir GÜVENLİ AZALMA (fallback)
--- olarak tutuluyor -- bkz. Matrix.Bureau.ProcessBribeCryptoTransaction (v2).
---
--- Akış:
---   1) __CryptoLocks[walletAddress] al (aynı cüzdana eşzamanlı giriş yasak).
---   2) SELECT ... FOR UPDATE (InnoDB satır kilidi, taze okuma -- yukarıdaki
---      not: tek başına atomiklik GARANTİ ETMEZ, CAS bunu telafi eder).
---   3) Context drift kontrolü — DB holder ile target uyuşmuyorsa RED.
---   4) CAS UPDATE (WHERE rolling_cipher_key = oldKey).
---   5) Yalnızca affected == 1 ise RAM önbelleğine yaz.
---   6) Kilit HER durumda bırakılır (pcall/finally).
function Matrix.Bureau._ProcessBribeCryptoTransactionLegacyFallback(walletAddress, amount, targetIdentifier)
    if type(walletAddress) ~= 'string' or walletAddress == '' then return false, 'bad_wallet' end
    amount = tonumber(amount)
    if not amount or amount ~= amount or amount <= 0.0 then return false, 'bad_amount' end
    if type(targetIdentifier) ~= 'string' or targetIdentifier == '' then return false, 'bad_target' end

    -- ★ 1) Lua-seviyesi satır kilidi (aynı cüzdan için yarış serializasyonu).
    if Matrix.Bureau.__CryptoLocks[walletAddress] then
        return false, 'wallet_busy'
    end
    Matrix.Bureau.__CryptoLocks[walletAddress] = true

    local function _releaseLock()
        Matrix.Bureau.__CryptoLocks[walletAddress] = nil
    end

    -- ★ 2) SELECT ... FOR UPDATE (InnoDB satır kilidi).
    local selOk, selRows = pcall(function()
        return MySQL.query.await(
            'SELECT holder_identifier, holder_type, crypto_balance, rolling_cipher_key, tx_sequence FROM matrix_crypto_wallets WHERE wallet_address = ? FOR UPDATE',
            { walletAddress })
    end)
    if not selOk or type(selRows) ~= 'table' or not selRows[1] then
        _releaseLock()
        return false, 'wallet_not_found'
    end
    local row = selRows[1]
    local holderIdentifier = row.holder_identifier
    local balance          = tonumber(row.crypto_balance) or 0.0
    local oldKey           = row.rolling_cipher_key
    local oldSeq           = tonumber(row.tx_sequence) or 0

    -- ★ 3) Context drift: DB holder ile target uyuşmuyor.
    -- KURBAN KORUMASI: burn+raid DB'den okunan meşru holder üzerinde.
    if holderIdentifier ~= targetIdentifier then
        _releaseLock()
        Matrix.Bureau.CryptoWallets[walletAddress] = nil
        _BurnAndRaidByHolder(holderIdentifier)
        Matrix.Log('BUREAU',
            '[SEC-6][CONTEXT DRIFT] wallet=%s legit-holder=%s caller-target=%s -- ROLLBACK, burn+raid LEGIT holder uzerinde.',
            walletAddress, holderIdentifier, targetIdentifier)
        return false, 'context_drift'
    end

    if balance < amount then
        _releaseLock()
        return false, 'insufficient_balance'
    end

    -- ★ 4) Cipher mutasyonu (deterministik, RNG yok).
    local newSeq = oldSeq + 1
    local mutationInput = ('%s#%.4f#%s#%d'):format(oldKey, amount, holderIdentifier, newSeq)
    local newKey     = _CryptoSha256Like(mutationInput)
    local newBalance = balance - amount

    -- ★ 5) CAS UPDATE — WHERE rolling_cipher_key = oldKey.
    local updOk, affected = pcall(function()
        return MySQL.update.await([[
            UPDATE matrix_crypto_wallets
            SET crypto_balance = ?, rolling_cipher_key = ?, tx_sequence = ?, updated_at = NOW()
            WHERE wallet_address = ? AND rolling_cipher_key = ?
        ]], { newBalance, newKey, newSeq, walletAddress, oldKey })
    end)

    _releaseLock()

    if not updOk or type(affected) ~= 'number' or affected == 0 then
        -- CAS başarısız. RAM önbelleği SİLİNİR (lazy reload).
        -- ★ KURBAN KORUMASI: burn+raid DB'den okunan holder üzerinde.
        Matrix.Bureau.CryptoWallets[walletAddress] = nil
        _BurnAndRaidByHolder(holderIdentifier)
        Matrix.Log('BUREAU',
            '[SEC-6][CIPHER DRIFT / RACE] wallet=%s -- CAS reddedildi, burn+raid LEGIT holder (%s) uzerinde.',
            walletAddress, holderIdentifier)
        return false, 'cipher_drift'
    end

    -- ★ 6) Yalnızca KAZANAN CAS RAM önbelleğine yazar.
    Matrix.Bureau.CryptoWallets[walletAddress] = {
        wallet_address     = walletAddress,
        holder_identifier  = holderIdentifier,
        holder_type        = row.holder_type,
        crypto_balance     = newBalance,
        rolling_cipher_key = newKey,
        tx_sequence        = newSeq,
    }

    Matrix.Log('BUREAU',
        '[SEC-6][CRYPTO] wallet=%s -> $%.4f transfer, tx_seq=%d, cipher mutasyona ugradi.',
        walletAddress, amount, newSeq)
    return true, { tx_sequence = newSeq, balance = newBalance }
end

--- Stored procedure'ün `CALL sp_...(...)` sonunda döndürdüğü SELECT
--- sonucunu, oxmysql/mysql2'nin CALL için verebileceği birkaç olası
--- şekilden (düz satır dizisi, iç içe result-set dizisi) paranoyakça çözer.
local function _UnwrapProcedureRow(rawResult)
    if type(rawResult) ~= 'table' then return nil end
    if rawResult.result_code ~= nil then return rawResult end
    local first = rawResult[1]
    if type(first) == 'table' then
        if first.result_code ~= nil then return first end
        if type(first[1]) == 'table' and first[1].result_code ~= nil then return first[1] end
    end
    return nil
end

--- ★★★ [SEC-6 v2 — TEK ATOMİK SAKLI YORDAM] ★★★
--- sp_matrix_process_bribe_crypto_transaction (sql/matrix_financial_core.sql)
--- SELECT ... FOR UPDATE + context-drift/bakiye kontrolü + CAS UPDATE'i TEK
--- bir MariaDB transaction'ı (START TRANSACTION ... COMMIT/ROLLBACK) içinde,
--- TEK round-trip'te (CALL'ın sonundaki SELECT aynı yanıtla döner) çalıştırır.
--- Bu, v1'deki "iki ayrı .await() arasında satır kilidinin havada kalması"
--- açığını KÖKTEN kapatır -- artık kilit ve mutasyon aynı bağlantı, aynı
--- transaction, aynı round-trip içindedir.
---
--- Lua __CryptoLocks mutex'i AYRICA korunur: aynı sürecte eşzamanlı iki
--- çağrıyı DB'ye hiç gitmeden 'wallet_busy' ile geri çevirir (gereksiz
--- round-trip'i önler) -- SP'nin kendi atomikliğine bir alternatif değil,
--- ek bir savunma katmanıdır (Config/mimari "0 RNG, katı serialization"
--- ilkesiyle tutarlı).
---
--- Migration henüz uygulanmamışsa (CALL hata verir: "PROCEDURE ... does
--- not exist" vb.) otomatik olarak v1 (_ProcessBribeCryptoTransactionLegacyFallback)
--- CAS akışına düşer -- production hiçbir zaman sert şekilde kırılmaz.
function Matrix.Bureau.ProcessBribeCryptoTransaction(walletAddress, amount, targetIdentifier)
    if type(walletAddress) ~= 'string' or walletAddress == '' then return false, 'bad_wallet' end
    amount = tonumber(amount)
    if not amount or amount ~= amount or amount <= 0.0 then return false, 'bad_amount' end
    if type(targetIdentifier) ~= 'string' or targetIdentifier == '' then return false, 'bad_target' end

    if Matrix.Bureau.__CryptoLocks[walletAddress] then
        return false, 'wallet_busy'
    end
    Matrix.Bureau.__CryptoLocks[walletAddress] = true

    local spOk, spRows = pcall(function()
        return MySQL.query.await(
            'CALL sp_matrix_process_bribe_crypto_transaction(?, ?, ?)',
            { walletAddress, amount, targetIdentifier })
    end)

    Matrix.Bureau.__CryptoLocks[walletAddress] = nil

    if not spOk then
        Matrix.Log('BUREAU',
            '[SEC-6][SP FALLBACK] sp_matrix_process_bribe_crypto_transaction cagrisi basarisiz (%s) -- v1 Lua-seviyesi CAS fallback yoluna dusuluyor. Migration uygulandi mi kontrol edin (sql/matrix_financial_core.sql).',
            tostring(spRows))
        return Matrix.Bureau._ProcessBribeCryptoTransactionLegacyFallback(walletAddress, amount, targetIdentifier)
    end

    local row = _UnwrapProcedureRow(spRows)
    if not row then
        Matrix.Log('BUREAU',
            '[SEC-6][SP FALLBACK] Beklenmeyen/bos SP sonuc sekli -- v1 Lua-seviyesi CAS fallback yoluna dusuluyor.')
        return Matrix.Bureau._ProcessBribeCryptoTransactionLegacyFallback(walletAddress, amount, targetIdentifier)
    end

    local code             = row.result_code
    local holderIdentifier = row.holder_identifier

    if code == 'ok' then
        local newBalance = tonumber(row.new_balance) or 0.0
        local newSeq     = tonumber(row.new_tx_sequence) or 0
        -- ★ RAM önbelleği bilinçli olarak GEÇERSİZ KILINIR (nil), doldurulmaz:
        -- gerçek rolling_cipher_key artık yalnızca SP içinde (SHA2) üretiliyor
        -- ve Lua'ya hiç dönmüyor. Yarım/nil bir cipher_key ile önbelleği
        -- doldurmak yerine bir sonraki okuma _LoadCryptoWallet üzerinden
        -- DB'den TAZE gelir -- staleness riski SIFIRDIR.
        Matrix.Bureau.CryptoWallets[walletAddress] = nil
        Matrix.Log('BUREAU',
            '[SEC-6][CRYPTO][SP-ATOMIK] wallet=%s -> $%.4f transfer, tx_seq=%d.',
            walletAddress, amount, newSeq)
        return true, { tx_sequence = newSeq, balance = newBalance }
    end

    -- ★ context_drift / cipher_drift: KURBAN KORUMASI, SP'nin transaction
    -- icinde DB'den okudugu LEGIT holder uzerinde (targetIdentifier'a DEGIL).
    if code == 'context_drift' or code == 'cipher_drift' then
        Matrix.Bureau.CryptoWallets[walletAddress] = nil
        if holderIdentifier then
            _BurnAndRaidByHolder(holderIdentifier)
        end
        Matrix.Log('BUREAU',
            '[SEC-6][%s][SP-ATOMIK] wallet=%s legit-holder=%s -- ROLLBACK (tek transaction icinde), burn+raid LEGIT holder uzerinde.',
            tostring(code):upper(), walletAddress, tostring(holderIdentifier))
        return false, code
    end

    if code == 'wallet_not_found' or code == 'insufficient_balance' then
        return false, code
    end

    -- Bilinmeyen/beklenmeyen result_code (ör. SQLEXCEPTION handler'i) ->
    -- FAIL-CLOSED: parayi ASLA dusurme, islemi reddet.
    Matrix.Log('BUREAU', '[SEC-6][SP-ATOMIK] Bilinmeyen result_code=%s -- islem reddedildi (fail-closed).', tostring(code))
    return false, 'sp_unknown_result'
end

exports('ProcessBribeCryptoTransaction', function(walletAddress, amount, targetIdentifier)
    return Matrix.Bureau.ProcessBribeCryptoTransaction(walletAddress, amount, targetIdentifier)
end)
exports('EnsureCryptoWallet', function(holderIdentifier, holderType)
    return Matrix.Bureau.EnsureCryptoWallet(holderIdentifier, holderType)
end)
exports('GenerateWalletAddress', function(holderIdentifier, holderType)
    return Matrix.Bureau.GenerateWalletAddress(holderIdentifier, holderType)
end)

-- =====================================================================
-- KATMAN 8 — CEPHE C1: TELSİZ SPEKTRUM PARAZİTİ
-- ★ [SELF-HEALING FIX] RIGID SUBTABLE INIT — Matrix.Bureau.RadioSpectrum
-- daha önce başka bir kod yolu tarafından kısmen doldurulmuş olabilir;
-- her alt tablo (PushToTalkAccum/JamStrength/BreachAccum) AYRI AYRI
-- garanti altına alınır. Eksik alt tablo → O(1) boş tablo ataması,
-- hiçbir state array sıfırlanmaz (memory leak YOK, veri kaybı YOK).
-- =====================================================================
Matrix.Bureau.RadioSpectrum = Matrix.Bureau.RadioSpectrum or {}
Matrix.Bureau.RadioSpectrum.PushToTalkAccum =
    Matrix.Bureau.RadioSpectrum.PushToTalkAccum or {}
Matrix.Bureau.RadioSpectrum.JamStrength =
    Matrix.Bureau.RadioSpectrum.JamStrength or {}
Matrix.Bureau.RadioSpectrum.BreachAccum =
    Matrix.Bureau.RadioSpectrum.BreachAccum or {}

local _RADIO_TICK_MS          = 1000
local _RADIO_GAIN_PER_TICK    = 0.02
local _RADIO_MAX_GAIN         = 1.0
local _RADIO_STATIC_STEP      = 0.05
local _RADIO_DECAY_PER_TICK   = 0.005
local _RADIO_BREACH_PER_TICK  = 0.01

-- ★ [SELF-HEALING FIX] Push-to-talk accumulator — external resource
-- (server/kitchen.lua) yükleme sırası ne olursa olsun HİÇBİR Kitchen
-- çağrısı YAPMAZ; yalnızca iki skaler toplamla ilerler. Bu yol tamamen
-- deterministiktir: aynı durationSeconds → aynı accumulator değeri.
function Matrix.Bureau.RegisterPushToTalk(citizenid, durationSeconds)
    if type(citizenid) ~= 'string' or citizenid == '' then return end
    durationSeconds = tonumber(durationSeconds) or 0.0
    if durationSeconds ~= durationSeconds or durationSeconds <= 0.0 then return end

    local spectrum = Matrix.Bureau.RadioSpectrum
    if type(spectrum) ~= 'table'
        or type(spectrum.PushToTalkAccum) ~= 'table'
        or type(spectrum.BreachAccum) ~= 'table' then
        return
    end

    local prevGain   = tonumber(spectrum.PushToTalkAccum[citizenid]) or 0.0
    local prevBreach = tonumber(spectrum.BreachAccum[citizenid]) or 0.0
    if prevGain   ~= prevGain   then prevGain   = 0.0 end
    if prevBreach ~= prevBreach then prevBreach = 0.0 end

    spectrum.PushToTalkAccum[citizenid] = prevGain   + (durationSeconds * _RADIO_GAIN_PER_TICK)
    spectrum.BreachAccum[citizenid]     = prevBreach + (durationSeconds * _RADIO_BREACH_PER_TICK)
end

-- =====================================================================
-- ★ [SELF-HEALING FIX] Radio Spectrum tick — Matrix.Kitchen'a BAĞIMLI
-- OLMAYAN, tamamen skaler/deterministik döngü. AdvanceDecryption zaten
-- pcall'lıdır; ek olarak çağrı öncesi tip guard'ı eklendi. Accumulator
-- state array'leri yalnızca `decayed <= 0` durumunda silinir (mevcut
-- davranış KORUNDU, memory leak YOK).
-- =====================================================================
CreateThread(function()
    while true do
        Wait(_RADIO_TICK_MS)

        local spectrum = Matrix.Bureau.RadioSpectrum
        if type(spectrum) ~= 'table' then goto continue end
        if type(spectrum.PushToTalkAccum) ~= 'table' then goto continue end
        if type(spectrum.JamStrength)     ~= 'table' then goto continue end
        if type(spectrum.BreachAccum)     ~= 'table' then goto continue end

        for citizenid, rawGain in pairs(spectrum.PushToTalkAccum) do
            local gain = tonumber(rawGain) or 0.0
            if gain ~= gain then gain = 0.0 end

            local silent = false
            if Matrix.RadioSilence and type(Matrix.RadioSilence.IsActive) == 'function' then
                local okSil, silResult = pcall(Matrix.RadioSilence.IsActive, citizenid)
                silent = okSil and silResult == true
            end

            if silent then
                local decayed = gain - _RADIO_DECAY_PER_TICK
                if decayed <= 0.0 then
                    spectrum.PushToTalkAccum[citizenid] = nil
                    spectrum.JamStrength[citizenid]     = nil
                    spectrum.BreachAccum[citizenid]     = nil
                else
                    spectrum.PushToTalkAccum[citizenid] = decayed
                end
            else
                local newGain = math.min(gain + _RADIO_GAIN_PER_TICK, _RADIO_MAX_GAIN)
                spectrum.PushToTalkAccum[citizenid] = newGain

                local prevJam = tonumber(spectrum.JamStrength[citizenid]) or 0.0
                if prevJam ~= prevJam then prevJam = 0.0 end
                local newJam = math.min(prevJam + _RADIO_STATIC_STEP, 1.0)
                spectrum.JamStrength[citizenid] = newJam

                local nearestTrapId
                for id in pairs(Matrix.TrapHouses or {}) do nearestTrapId = id; break end

                if nearestTrapId
                    and Matrix.Bureau
                    and type(Matrix.Bureau.AdvanceDecryption) == 'function'
                    and newGain > 0.01 then
                    -- ★ pcall + tip guard: AdvanceDecryption nil/NaN döndürse
                    -- bile tick döngüsü ASLA çökmez.
                    pcall(Matrix.Bureau.AdvanceDecryption, nearestTrapId, newGain * 0.001)
                end

                if Matrix.PlayerSourceIndex and Matrix.Radio
                    and type(Matrix.Radio.ApplyStatic) == 'function' then
                    for src, cid in pairs(Matrix.PlayerSourceIndex) do
                        if cid == citizenid then
                            pcall(Matrix.Radio.ApplyStatic, src, newJam, 'radio_spectrum')
                        end
                    end
                end
            end
        end

        ::continue::
    end
end)

RegisterNetEvent('matrix:server:radio:pushToTalk', function(durationSeconds)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    local state = Matrix.GetOrCreatePlayerState(src)
    if not state or not state.citizenid then return end
    Matrix.Bureau.RegisterPushToTalk(state.citizenid, durationSeconds)
end)

exports('RegisterPushToTalk', function(citizenid, durationSeconds)
    return Matrix.Bureau.RegisterPushToTalk(citizenid, durationSeconds)
end)

-- =====================================================================
-- ★ [FAZ 1] SEC-7 DİNAMİK PAROLA + OPSEC TAMPER LOG
-- Additive. Mevcut hiçbir fonksiyon gövdesi DEĞİŞTİRİLMEDİ.
-- =====================================================================

-- SHA256-benzeri checksum (mevcut _CryptoSha256Like ile AYNI aile).
local function _OpsecChecksum(raw, salt)
    local sum = 0
    for i = 1, #raw do
        sum = (sum + (raw:byte(i) * (i + salt))) % 0xFFFFFFF
    end
    return sum
end

local function _OpsecHash(passphrase)
    local input = tostring(passphrase or '')
    local out = {}
    for i = 1, 16 do
        local raw = ('OPSEC#%s#%d'):format(input, i)
        out[i] = ('%04X'):format(_OpsecChecksum(raw, 173 + i) % 0x10000)
    end
    return table.concat(out, '')
end
Matrix.Bureau.__OpsecHash = _OpsecHash

-- ---------------------------------------------------------------
-- Parola rotasyonu (oyun içi /opsecparola ile tetiklenir)
-- ---------------------------------------------------------------
function Matrix.Bureau.SetOpsecPassphrase(trapHouseId, rawPassphrase)
    trapHouseId = tonumber(trapHouseId)
    if not trapHouseId or not Matrix.TrapHouses[trapHouseId] then
        return false, 'bad_trap_house'
    end

    if rawPassphrase == nil or rawPassphrase == '' then
        Matrix.TrapHouses[trapHouseId].opsec_passphrase = Config.Bureau.OpsecDefaultPassphrase
        pcall(function()
            MySQL.prepare('UPDATE matrix_trap_houses SET opsec_passphrase = ? WHERE id = ?',
                { Config.Bureau.OpsecDefaultPassphrase, trapHouseId })
        end)
        return true, 'default_restored'
    end

    if type(rawPassphrase) ~= 'string'
        or #rawPassphrase < (Config.Bureau.OpsecPassphraseMinLength or 4)
        or #rawPassphrase > (Config.Bureau.OpsecPassphraseMaxLength or 64) then
        return false, 'bad_passphrase'
    end

    local hash = _OpsecHash(rawPassphrase)
    Matrix.TrapHouses[trapHouseId].opsec_passphrase = hash
    pcall(function()
        MySQL.prepare('UPDATE matrix_trap_houses SET opsec_passphrase = ? WHERE id = ?', { hash, trapHouseId })
    end)

    Matrix.Log('BUREAU', '[SEC-7] Trap #%d parola rotasyona girdi.', trapHouseId)
    return true, 'set'
end

-- ---------------------------------------------------------------
-- Parola doğrulama (darkchat'ten tetiklenir)
-- ---------------------------------------------------------------
function Matrix.Bureau.VerifyOpsecPassphrase(trapHouseId, citizenid, rawPassphrase)
    trapHouseId = tonumber(trapHouseId)
    local house = trapHouseId and Matrix.TrapHouses[trapHouseId]
    if not house then return false, 'bad_trap_house' end

    local storedHash = house.opsec_passphrase
    if type(storedHash) ~= 'string' or storedHash == '' then
        storedHash = _OpsecHash(Config.Bureau.OpsecDefaultPassphrase)
    end

    local attemptHash = _OpsecHash(rawPassphrase)
    if attemptHash == storedHash then
        return true, 'match'
    end

    -- Yanlış parola → üssel adım + adli iz
    local step = tonumber(Config.Bureau.OpsecPassphraseGeometricStep) or 0.08
    pcall(Matrix.Bureau.AdvanceDecryption, trapHouseId, step)

    pcall(function()
        MySQL.insert([[
            INSERT INTO matrix_opsec_tamper_log
                (trap_house_id, citizenid, attempted_passphrase_hash,
                 geometric_step, decryption_after, created_at)
            VALUES (?, ?, ?, ?, ?, NOW())
        ]], {
            trapHouseId, tostring(citizenid or 'UNKNOWN'), attemptHash,
            step, house.decryption_confidence or 0.0
        })
    end)

    Matrix.Log('BUREAU',
        '[SEC-7 IHLALI] Trap #%d yanlış parola (vatandaş=%s). Üssel adım=%.4f → yeni deşifre=%.4f',
        trapHouseId, tostring(citizenid or 'UNKNOWN'), step, house.decryption_confidence or 0.0)
    return false, 'passphrase_mismatch'
end

-- ---------------------------------------------------------------
-- RAM ön belleğe opsec_passphrase'i yükle (bureau.lua'nın mevcut
-- LoadTrapHouses'u bu kolonu okumuyor — tek seferlik tamamlayıcı).
-- ---------------------------------------------------------------
CreateThread(function()
    Wait(2500)
    local ok, rows = pcall(function()
        return MySQL.query.await('SELECT id, opsec_passphrase FROM matrix_trap_houses', {})
    end)
    if not ok or type(rows) ~= 'table' then
        Matrix.Log('BUREAU', '[SEC-7] opsec_passphrase yüklenemedi (yutuldu).')
        return
    end
    local loaded = 0
    for _, row in ipairs(rows) do
        local house = Matrix.TrapHouses[row.id]
        if house and type(row.opsec_passphrase) == 'string' and row.opsec_passphrase ~= '' then
            house.opsec_passphrase = row.opsec_passphrase
            loaded = loaded + 1
        end
    end
    Matrix.Log('BUREAU', '[SEC-7] %d trap house için dinamik parola RAM ön belleğe alındı.', loaded)
end)

-- ---------------------------------------------------------------
-- Darkchat parola deneme kanalı
-- ---------------------------------------------------------------
RegisterNetEvent('matrix:server:darkchat:submitPassphrase', function(trapHouseId, rawPassphrase)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    trapHouseId = tonumber(trapHouseId)
    if not trapHouseId then return end

    local state = Matrix.GetOrCreatePlayerState(src)
    local citizenid = state and state.citizenid

    local ok, reason = Matrix.Bureau.VerifyOpsecPassphrase(trapHouseId, citizenid, rawPassphrase)
    TriggerClientEvent('matrix:client:darkchat:passphraseResult', src, ok, reason, trapHouseId)
end)

RegisterCommand('opsecparola', function(src, args)
    local trapHouseId = tonumber(args[1])
    if not trapHouseId then
        Reply(src, 'Kullanım: /opsecparola [trapHouseId] [yeniParola|boş]'); return
    end
    if Matrix.Hierarchy and Matrix.Hierarchy.HasCommandAuthority then
        local st = Matrix.GetOrCreatePlayerState(src)
        if not st or not st.citizenid or not Matrix.Hierarchy.HasCommandAuthority(st.citizenid) then
            Reply(src, 'Yetkisiz.'); return
        end
    end
    local newPass = args[2] or ''
    local ok, reason = Matrix.Bureau.SetOpsecPassphrase(trapHouseId, newPass)
    Reply(src, ok and ('Parola: %s'):format(reason) or ('Başarısız: %s'):format(tostring(reason)))
end, false)

-- =====================================================================
-- ★ [FAZ 2] COMINT RADYO SPEKTRUM AKÜMÜLATÖRÜ
-- PushToTalkAccum + BreachAccum → deşifre tırmanması + statik parazit.
-- Mevcut RNG YASAK — her şey tick sayaçları ile deterministik.
-- Self-healing: Matrix.Kitchen nil dönerse cyberSkill=1.0 fallback.
-- =====================================================================

Matrix.Bureau.RadioSpectrum = Matrix.Bureau.RadioSpectrum or {}
Matrix.Bureau.RadioSpectrum.PushToTalkAccum = Matrix.Bureau.RadioSpectrum.PushToTalkAccum or {}
Matrix.Bureau.RadioSpectrum.JamStrength     = Matrix.Bureau.RadioSpectrum.JamStrength     or {}
Matrix.Bureau.RadioSpectrum.BreachAccum     = Matrix.Bureau.RadioSpectrum.BreachAccum     or {}

local _RADIO_TICK_MS = 1000

--- Self-healing skill resolver — Kitchen yoksa/nil dönerse 1.0.
local function _ResolveRadioCyberSkill(trapHouseId)
    if not Matrix.Kitchen or type(Matrix.Kitchen.GetEffectiveSkill) ~= 'function' then
        return 1.0
    end
    if type(Matrix.Bots) ~= 'table' then return 1.0 end

    local resolved = 1.0
    for _, bot in pairs(Matrix.Bots) do
        if bot and bot.state and bot.state.trap_house_id == trapHouseId then
            local ok, skill = pcall(Matrix.Kitchen.GetEffectiveSkill, bot, 'skill_cyber')
            if ok and type(skill) == 'number' and skill == skill
                and skill ~= math.huge and skill ~= -math.huge then
                resolved = skill
            end
            break
        end
    end
    if type(resolved) ~= 'number' or resolved ~= resolved then resolved = 1.0 end
    return resolved
end

--- Push-to-talk kaydı — client'ın telsiz bas-konuş event'i buraya bağlanır.
function Matrix.Bureau.RegisterPushToTalk(citizenid, durationSeconds)
    if type(citizenid) ~= 'string' or citizenid == '' then return end
    durationSeconds = tonumber(durationSeconds) or 0.0
    if durationSeconds ~= durationSeconds or durationSeconds <= 0.0 then return end

    local spectrum = Matrix.Bureau.RadioSpectrum
    if type(spectrum.PushToTalkAccum) ~= 'table' or type(spectrum.BreachAccum) ~= 'table' then
        return
    end

    local gain   = tonumber(spectrum.PushToTalkAccum[citizenid]) or 0.0
    local breach = tonumber(spectrum.BreachAccum[citizenid]) or 0.0

    spectrum.PushToTalkAccum[citizenid] = gain + (durationSeconds * (Config.Bureau.RadioAccumGainPerTick or 0.02))
    spectrum.BreachAccum[citizenid]     = breach + (durationSeconds * (Config.Bureau.RadioBreachGainPerTick or 0.01))
end

-- Radyo ticker — 1 sn, Wait(0) YOK.
CreateThread(function()
    while true do
        Wait(_RADIO_TICK_MS)

        local spectrum = Matrix.Bureau.RadioSpectrum
        if type(spectrum) ~= 'table' then goto continue end
        if type(spectrum.PushToTalkAccum) ~= 'table' then goto continue end
        if type(spectrum.JamStrength)     ~= 'table' then goto continue end
        if type(spectrum.BreachAccum)     ~= 'table' then goto continue end

        for citizenid, rawGain in pairs(spectrum.PushToTalkAccum) do
            local gain = tonumber(rawGain) or 0.0
            if gain ~= gain then gain = 0.0 end

            -- /sessizlik aktif mi?
            local silent = false
            if Matrix.RadioSilence and type(Matrix.RadioSilence.IsActive) == 'function' then
                local okSil, res = pcall(Matrix.RadioSilence.IsActive, citizenid)
                silent = okSil and res == true
            end

            if silent then
                -- Sessizlik: yavaş azalım
                local decayed = gain - (Config.Bureau.RadioDecayPerTick or 0.005)
                if decayed <= 0.0 then
                    spectrum.PushToTalkAccum[citizenid] = nil
                    spectrum.JamStrength[citizenid]     = nil
                    spectrum.BreachAccum[citizenid]     = nil
                else
                    spectrum.PushToTalkAccum[citizenid] = decayed
                end
            else
                -- Aktif: doğrusal tırmanma + statik parazit + deşifre kazancı
                local newGain = math.min(gain + (Config.Bureau.RadioAccumGainPerTick or 0.02),
                                          Config.Bureau.RadioAccumMaxGain or 1.0)
                spectrum.PushToTalkAccum[citizenid] = newGain

                local prevJam = tonumber(spectrum.JamStrength[citizenid]) or 0.0
                if prevJam ~= prevJam then prevJam = 0.0 end
                local maxStatic = Config.Bureau.RadioStaticMaxIntensity or 0.90
                local newJam = math.min(prevJam + (Config.Bureau.RadioStaticStep or 0.05), maxStatic)
                spectrum.JamStrength[citizenid] = newJam

                -- En yakın trap house (deterministik: en küçük id)
                local nearestTrapId
                for id in pairs(Matrix.TrapHouses or {}) do
                    if not nearestTrapId or id < nearestTrapId then nearestTrapId = id end
                end

                if nearestTrapId and Matrix.Bureau and type(Matrix.Bureau.AdvanceDecryption) == 'function'
                    and newGain > 0.01 then
                    local cyberSkill = _ResolveRadioCyberSkill(nearestTrapId)
                    cyberSkill = math.max(cyberSkill, 0.1)
                    local gainPerTick = (Config.Bureau.RadioBreachGainPerTick or 0.01) * cyberSkill
                    pcall(Matrix.Bureau.AdvanceDecryption, nearestTrapId, gainPerTick)
                end

                -- Statik parazit: kaynağı bul ve ApplyStatic çağır.
                if Matrix.PlayerSourceIndex and Matrix.Radio
                    and type(Matrix.Radio.ApplyStatic) == 'function' then
                    for src, cid in pairs(Matrix.PlayerSourceIndex) do
                        if cid == citizenid then
                            pcall(Matrix.Radio.ApplyStatic, src, newJam, 'radio_spectrum')
                        end
                    end
                end
            end
        end

        ::continue::
    end
end)

-- Client → server bas-konuş event
RegisterNetEvent('matrix:server:radio:pushToTalk', function(durationSeconds)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    local state = Matrix.GetOrCreatePlayerState(src)
    if not state or not state.citizenid then return end
    Matrix.Bureau.RegisterPushToTalk(state.citizenid, durationSeconds)
end)

exports('RegisterPushToTalk', function(citizenid, durationSeconds)
    return Matrix.Bureau.RegisterPushToTalk(citizenid, durationSeconds)
end)