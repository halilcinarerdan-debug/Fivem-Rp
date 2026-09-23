-- =====================================================================
-- MATRIX FORENSICS / forensics.lua
-- In-memory balistik cache, lokal ID allocator, async insert.
--
-- ★★★ YAMA 3 (BU SÜRÜM) — HAYALET DB REWRITE CANLANMA ENGELLEYİCİ ★★★
--   • WipeBallisticRecord artık DELETE'ten ÖNCE SENKRON bir "drain barrier"
--     (FlushPendingWearSynchronously) çalıştırır. Havada kalan asenkron
--     UPDATE'lerin hepsi diske yazılır; DELETE hiçbir stale UPDATE ile
--     yarışmaz.
--   • _wearFlushWipeBarrier bayrağı, Wipe sürerken ticker'ın erken
--     çıkmasını sağlar — havada yeni UPDATE yaratılmaz.
--   • DELETE'ler tek MySQL.transaction.await içinde çalışır (FK sırası:
--     önce evidence, sonra weapon).
-- =====================================================================


Matrix.Forensics = Matrix.Forensics or {}


local pairs, ipairs, type, tostring = pairs, ipairs, type, tostring
local tonumber, table, math       = tonumber, table, math
local math_max, math_min          = math.max, math.min
local math_exp                    = math.exp
local GetGameTimer                = GetGameTimer


local BALLISTIC_CACHE_MAX = 4096


local BallisticCache = {}
local BallisticInsertOrder = {}
local PendingWearUpdates = {}
local WearRetryQueue = {}


-- ★ [YAMA 3] Wipe sürerken wear-flush ticker'ının erken çıkmasını sağlayan
-- senkron bayrak. WipeBallisticRecord başında true, sonunda false.
local _wearFlushWipeBarrier = false


local EvidenceNextId     = 1
local EvidenceIdSynced   = false


local function EvictBallisticCacheIfNeeded()
    local n = 0
    for _ in pairs(BallisticCache) do n = n + 1 end
    if n <= BALLISTIC_CACHE_MAX then return end


    local excess = n - BALLISTIC_CACHE_MAX
    local removed = 0
    local i = 1
    while removed < excess and i <= #BallisticInsertOrder do
        local serial = BallisticInsertOrder[i]
        if serial and BallisticCache[serial] then
            BallisticCache[serial] = nil
            removed = removed + 1
        end
        BallisticInsertOrder[i] = nil
        i = i + 1
    end
    local j = 1
    for k = i, #BallisticInsertOrder do
        BallisticInsertOrder[j] = BallisticInsertOrder[k]
        j = j + 1
    end
    for k = j, #BallisticInsertOrder do BallisticInsertOrder[k] = nil end
end


local function GetActorDnaId(actor)
    if not actor then return 'UNKNOWN' end
    return actor.dna_id or 'UNKNOWN'
end


local function GetActorCortisol(actor)
    if not actor or not actor.biology then return 0.0 end
    return Matrix.Clamp(actor.biology.cortisol_level or 0.0, 0.0, 1.0)
end


local function GetWeaponDurability(weaponInventoryId, weaponSlot)
    if not weaponInventoryId or type(weaponSlot) ~= 'number' then return 1.0 end
    local meta = Matrix.Inventory.GetSlotMetadata(weaponInventoryId, weaponSlot)
    local durability = tonumber(meta.durability)
    if not durability then return 1.0 end
    return Matrix.Clamp(durability / 100.0, 0.0, 1.0)
end


function Matrix.Forensics.ComputeFingerprintQuality(actor)
    local cortisol = GetActorCortisol(actor)
    return Matrix.Clamp(1.0 - (cortisol * Config.Forensics.FingerprintQualityCortisolWeight), 0.0, 1.0)
end


function Matrix.Forensics.ComputeJamChance(weaponDurability)
    weaponDurability = Matrix.Clamp(tonumber(weaponDurability) or 1.0, 0.0, 1.0)
    local threshold = Config.Forensics.WeaponJamChanceThreshold
    if weaponDurability >= threshold then return 0.0 end


    local deficitRatio = (threshold - weaponDurability) / math_max(threshold, 0.0001)
    return Matrix.Clamp(Config.Forensics.WeaponJamBaseChance * (1.0 + deficitRatio), 0.0, 1.0)
end


function Matrix.Forensics.GetHardDeleteRiskIfJammed(weaponDurability)
    if Matrix.Forensics.ComputeJamChance(weaponDurability) > 0.0 then
        return Config.Forensics.WeaponJamHardDeleteRisk
    end
    return 0.0
end


function Matrix.Forensics.GetWeaponShotLifespan(weaponItemName)
    local table_ = Config.Forensics.WeaponShotLifespan
    local lifespan = (type(weaponItemName) == 'string' and table_[weaponItemName])
        or Config.Forensics.WeaponShotLifespanDefault
        or 15000
    lifespan = tonumber(lifespan) or 15000
    if lifespan <= 0 then lifespan = 15000 end
    return lifespan
end


function Matrix.Forensics.ComputeMechanicalJamProbability(durability)
    durability = Matrix.Clamp(tonumber(durability) or 100.0, 0.0, 100.0)
    local threshold = Config.Forensics.MechanicalJamThresholdPercent
    if durability >= threshold then return 0.0 end


    local ratio = Matrix.Clamp(1.0 - (durability / math_max(threshold, 0.0001)), 0.0, 1.0)
    local exponent = Config.Forensics.MechanicalJamExponent or 3
    local probability = (ratio ^ exponent) * (Config.Forensics.MechanicalJamCoefficient or 0.35)
    return Matrix.Clamp(probability, 0.0, 1.0)
end


-- =====================================================================
-- LOAD CACHE
-- =====================================================================
function Matrix.Forensics.LoadCaches()
    local rows = MySQL.query.await('SELECT weapon_serial, ballistic_id, wear_level FROM matrix_ballistic_weapons', {}) or {}
    for _, row in ipairs(rows) do
        BallisticCache[row.weapon_serial] = {
            ballistic_id = row.ballistic_id,
            wear_level   = row.wear_level or 0.0
        }
        BallisticInsertOrder[#BallisticInsertOrder + 1] = row.weapon_serial
    end
    Matrix.Log('FORENSICS', '%d balistik silah önbelleğe yüklendi.', #rows)
    EvictBallisticCacheIfNeeded()


    local r = MySQL.query.await('SELECT COALESCE(MAX(id),0) AS mx FROM matrix_forensic_evidence', {}) or {}
    local mx = (r[1] and r[1].mx) or 0
    EvidenceNextId   = mx + 1
    EvidenceIdSynced = true
    Matrix.Log('FORENSICS', 'Kanıt ID watermark: %d', EvidenceNextId)
end


CreateThread(function()
    local ok, err = pcall(Matrix.Forensics.LoadCaches)
    if not ok then
        Matrix.Log('FORENSICS', '[HATA] LoadCaches basarisiz (yutuldu): %s', tostring(err))
    end
end)


local function NextEvidenceId()
    if not EvidenceIdSynced then return nil end
    local id = EvidenceNextId
    EvidenceNextId = id + 1
    return id
end


-- =====================================================================
-- BALLISTIC REGISTRATION
-- =====================================================================
function Matrix.Forensics.RegisterOrGetBallisticId(weaponSerial, weaponWear)
    if type(weaponSerial) ~= 'string' or weaponSerial == '' then return nil end
    weaponWear = Matrix.Clamp(tonumber(weaponWear) or 0.0, 0.0, 1.0)


    local cached = BallisticCache[weaponSerial]
    if cached then
        if cached.wear_level ~= weaponWear then
            cached.wear_level = weaponWear
            PendingWearUpdates[cached.ballistic_id] = weaponWear
        end
        return cached.ballistic_id
    end


    local ballisticId = ('BAL-%s-%06X'):format(
        weaponSerial:sub(-4),
        (GetGameTimer() + #weaponSerial) % 0xFFFFFF
    )


    BallisticCache[weaponSerial] = {
        ballistic_id = ballisticId,
        wear_level   = weaponWear
    }
    BallisticInsertOrder[#BallisticInsertOrder + 1] = weaponSerial


    MySQL.prepare([[
        INSERT INTO matrix_ballistic_weapons
            (ballistic_id, weapon_serial, wear_level, sealed_as_crime_weapon, first_registered)
        VALUES (?, ?, ?, 0, NOW())
        ON DUPLICATE KEY UPDATE wear_level = VALUES(wear_level)
    ]], { ballisticId, weaponSerial, weaponWear })


    EvictBallisticCacheIfNeeded()


    Matrix.Log('FORENSICS', 'Yeni balistik imza: %s (Seri: %s)', ballisticId, weaponSerial)
    return ballisticId
end


-- =====================================================================
-- WEAPON FIRE SIMULATION
-- =====================================================================
function Matrix.Forensics.SimulateWeaponFire(actorRef, weaponSerial, weaponWear, evidenceType, weaponDurability)
    local actor = Matrix.ResolveActor(actorRef)
    if not actor then return nil end


    weaponWear       = Matrix.Clamp(tonumber(weaponWear) or 0.0, 0.0, 1.0)
    evidenceType     = evidenceType or 'casing'
    weaponDurability = Matrix.Clamp(tonumber(weaponDurability) or 1.0, 0.0, 1.0)


    local ballisticId = Matrix.Forensics.RegisterOrGetBallisticId(weaponSerial, weaponWear)
    if not ballisticId then return nil end


    local cortisol = GetActorCortisol(actor)
    local qKovanBase = Matrix.Clamp(
        1.0 - (weaponWear * Config.Forensics.CasingWearWeight)
            - (cortisol   * Config.Forensics.CasingCortisolWeight),
        0.0, 1.0
    )


    local qKovan = Matrix.Clamp(qKovanBase * weaponDurability, 0.0, 1.0)


    local fingerprintQuality = Matrix.Forensics.ComputeFingerprintQuality(actor)
    local dnaId              = GetActorDnaId(actor)
    local matchCertainty     = Matrix.Clamp(qKovan * Config.BallisticStriationPrecision, 0.0, 1.0)


    if weaponDurability < Config.Forensics.WeaponDurabilityLabBlindnessThreshold then
        local deficit = Config.Forensics.WeaponDurabilityLabBlindnessThreshold - weaponDurability
        local rate    = math_max(Config.Forensics.WeaponDurabilityBlindnessDecayRate or 0.0, 1e-9)
        matchCertainty = Matrix.Clamp(matchCertainty * math_exp(-rate * deficit), 0.0, 1.0)
    end


    local sealed = matchCertainty > Config.Forensics.MatchCertaintyThreshold


    local stateCoords = actor.state and actor.state.coords
    local cx, cy, cz  = 0.0, 0.0, 0.0
    if stateCoords then cx, cy, cz = stateCoords.x, stateCoords.y, stateCoords.z end


    local evidenceId = NextEvidenceId()


    if evidenceId then
        MySQL.prepare([[
            INSERT INTO matrix_forensic_evidence
                (id, ballistic_id, evidence_type, striation_quality, fingerprint_id, fingerprint_quality,
                 match_certainty, sealed_as_crime_weapon, coords_x, coords_y, coords_z, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NOW())
        ]], {
            evidenceId, ballisticId, evidenceType, qKovan, dnaId, fingerprintQuality,
            matchCertainty, sealed and 1 or 0, cx, cy, cz
        })
    else
        MySQL.prepare([[
            INSERT INTO matrix_forensic_evidence
                (ballistic_id, evidence_type, striation_quality, fingerprint_id, fingerprint_quality,
                 match_certainty, sealed_as_crime_weapon, coords_x, coords_y, coords_z, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NOW())
        ]], {
            ballisticId, evidenceType, qKovan, dnaId, fingerprintQuality,
            matchCertainty, sealed and 1 or 0, cx, cy, cz
        })
    end


    if sealed then
        MySQL.prepare([[
            UPDATE matrix_ballistic_weapons
            SET sealed_as_crime_weapon = 1, seal_certainty = ?
            WHERE ballistic_id = ?
        ]], { matchCertainty, ballisticId })
        Matrix.Log('FORENSICS', '[MÜHÜRLENDI] %s suç aleti (%.4f)', ballisticId, matchCertainty)
    end


    return {
        evidence_id         = evidenceId or -1,
        ballistic_id        = ballisticId,
        dna_id              = dnaId,
        weapon_wear         = weaponWear,
        weapon_durability   = weaponDurability,
        striation_quality   = qKovan,
        fingerprint_quality = fingerprintQuality,
        match_certainty     = matchCertainty,
        sealed              = sealed,
        jam_chance          = Matrix.Forensics.ComputeJamChance(weaponDurability),
        hard_delete_risk    = Matrix.Forensics.GetHardDeleteRiskIfJammed(weaponDurability)
    }
end


function Matrix.Forensics.ForceSeal(ballisticId)
    if type(ballisticId) ~= 'string' or ballisticId == '' then return false end


    MySQL.prepare([[
        UPDATE matrix_ballistic_weapons
        SET sealed_as_crime_weapon = 1, seal_certainty = 1.0
        WHERE ballistic_id = ?
    ]], { ballisticId })


    Matrix.Log('FORENSICS', '[UNDERCOVER TETİĞİ] %s otomatik %%100 kesinlikle mühürlendi.', ballisticId)
    return true
end


-- =====================================================================
-- ★ [YAMA 3] SENKRON DRAIN BARRIER
-- Bekleyen TÜM asenkron wear UPDATE'lerini diske yazar. Yeni yazma
-- başlatmaz. WipeBallisticRecord tarafından DELETE'ten ÖNCE çağrılır.
-- =====================================================================
local function FlushPendingWearSynchronously()
    -- ★ Ticker'ı blokla: wipe sürerken yeni UPDATE üretilmesin.
    _wearFlushWipeBarrier = true

    -- Retry kuyruğunu pending'e taşı (tek pass).
    for bid, wear in pairs(WearRetryQueue) do
        if not PendingWearUpdates[bid] then PendingWearUpdates[bid] = wear end
        WearRetryQueue[bid] = nil
    end

    -- Kalan tüm pending'leri SENKRON await ile diske yaz.
    local hadAny = false
    for bid, wear in pairs(PendingWearUpdates) do
        hadAny = true
        local ok = pcall(function()
            MySQL.update.await(
                'UPDATE matrix_ballistic_weapons SET wear_level = ? WHERE ballistic_id = ?',
                { wear, bid })
        end)
        if not ok then
            Matrix.Log('FORENSICS',
                '[YAMA 3][SYNC FLUSH] ballistic_id=%s wear UPDATE basarisiz (yutuldu).', tostring(bid))
        end
        PendingWearUpdates[bid] = nil
    end

    if hadAny then
        Matrix.Log('FORENSICS',
            '[YAMA 3][SYNC FLUSH] Tum bekleyen wear UPDATE leri senkron diske yazildi.')
    end

    _wearFlushWipeBarrier = false
end


-- =====================================================================
-- ★ [YAMA 3] TAM BALİSTİK ARŞİV SİLME (Namlu Değişimi)
--
-- SIRA:
--   1) FlushPendingWearSynchronously() — havada kalan wear UPDATE'leri
--      diske yazılır. DELETE ile yarış penceresi KAPANIR.
--   2) RAM kuyruklarından ilgili referanslar temizlenir (belt-suspenders).
--   3) DELETE'ler TEK MySQL.transaction.await içinde (FK sırası: evidence
--      sonra weapon).
-- =====================================================================
function Matrix.Forensics.WipeBallisticRecord(weaponSerial)
    if type(weaponSerial) ~= 'string' or weaponSerial == '' then return false end


    local cached = BallisticCache[weaponSerial]
    local ballisticId = cached and cached.ballistic_id


    -- ★ [YAMA 3] Asenkron write barrier — DELETE'ten ÖNCE tüm havada
    -- UPDATE'ler diske inmiş olur.
    FlushPendingWearSynchronously()


    BallisticCache[weaponSerial] = nil


    if not ballisticId then
        -- Silinecek balistik kayıt yok; sadece cache/index temizliği.
        local compacted = {}
        for i = 1, #BallisticInsertOrder do
            if BallisticInsertOrder[i] ~= weaponSerial then
                compacted[#compacted + 1] = BallisticInsertOrder[i]
            end
        end
        BallisticInsertOrder = compacted
        return true
    end


    -- ★ Kuyruk temizliği (belt-and-suspenders; drain sonrası zaten boş
    -- olmalı, ama race'te kalan referans varsa kazınır).
    PendingWearUpdates[ballisticId] = nil
    WearRetryQueue[ballisticId]     = nil
    local compacted = {}
    for i = 1, #BallisticInsertOrder do
        if BallisticInsertOrder[i] ~= weaponSerial then
            compacted[#compacted + 1] = BallisticInsertOrder[i]
        end
    end
    BallisticInsertOrder = compacted


    -- ★ [YAMA 3] DELETE'ler TEK transaction — FK sırası: evidence önce,
    -- weapon sonra. Havada UPDATE ile yarış penceresi YOK.
    local delOk = pcall(function()
        MySQL.transaction.await({
            { query = 'DELETE FROM matrix_forensic_evidence WHERE ballistic_id = ?', values = { ballisticId } },
            { query = 'DELETE FROM matrix_ballistic_weapons WHERE ballistic_id = ?',   values = { ballisticId } },
        })
    end)
    if not delOk then
        Matrix.Log('FORENSICS', '[YAMA 3][HATA] Wipe DELETE transaction basarisiz: %s', tostring(ballisticId))
    end


    Matrix.Log('FORENSICS',
        '[BURO KORLESTIRILDI] Namlu degisimi: %s balistik kaydi tamamen silindi (sync barrier gecti).',
        ballisticId)
    return true
end


-- =====================================================================
-- GERÇEK-ZAMANLI ATIŞ İŞLEME (Mekanik Tutukluk)
-- =====================================================================
function Matrix.Forensics.OnWeaponShotFired(actorRef, weaponItemName, weaponSerial, weaponInventoryId, weaponSlot)
    if not weaponInventoryId or type(weaponSlot) ~= 'number' then return nil, 'bad_slot' end
    if type(weaponSerial) ~= 'string' or weaponSerial == '' then return nil, 'bad_serial' end


    local meta = Matrix.Inventory.GetSlotMetadata(weaponInventoryId, weaponSlot)
    if meta.jammed then return nil, 'already_jammed' end


    local shotsFired = (tonumber(meta.shots_fired) or 0) + 1
    local lifespan    = Matrix.Forensics.GetWeaponShotLifespan(weaponItemName)
    local durability  = Matrix.Clamp(100.0 * (1.0 - (shotsFired / lifespan)), 0.0, 100.0)


    local jamProbability = Matrix.Forensics.ComputeMechanicalJamProbability(durability)


    local accumulator = (tonumber(meta.jam_accumulator) or 0.0) + jamProbability
    local jammed = false
    if accumulator >= 1.0 then
        jammed = true
        accumulator = accumulator - 1.0
    end


    Matrix.Inventory.MergeMetadata(weaponInventoryId, weaponSlot, {
        weapon_serial   = weaponSerial,
        shots_fired     = shotsFired,
        durability      = durability,
        jam_accumulator = accumulator,
        jammed          = jammed
    })


    return {
        durability      = durability,
        jam_probability = jamProbability,
        jammed          = jammed,
        shots_fired     = shotsFired
    }
end


function Matrix.Forensics.ClearMechanicalJam(weaponInventoryId, weaponSlot)
    if not weaponInventoryId or type(weaponSlot) ~= 'number' then return false end
    local meta = Matrix.Inventory.GetSlotMetadata(weaponInventoryId, weaponSlot)
    if not meta.jammed then return false end


    Matrix.Inventory.MergeMetadata(weaponInventoryId, weaponSlot, { jammed = false })
    return true
end


-- =====================================================================
-- ADLİ KRİMİNAL RAPORU
-- =====================================================================
local REPORT_WIDTH = 36
local REPORT_BORDER = ('='):rep(REPORT_WIDTH)
local REPORT_DIVIDER = ('-'):rep(REPORT_WIDTH)


local function ReportLine(label, value)
    return ('%-13s: %s'):format(label, tostring(value))
end


function Matrix.Forensics.BuildForensicReport(data)
    local lines = {
        REPORT_BORDER,
        '     ADLI KRIMINAL RAPORU',
        REPORT_DIVIDER,
        ReportLine('BALISTIK ID', data.ballistic_id or 'BILINMIYOR'),
        ReportLine('KANIT TIPI', data.evidence_type or 'casing'),
        ReportLine('STRIASYON', ('%.3f'):format(data.striation_quality or 0.0)),
        ReportLine('PARMAK IZI', data.fingerprint_id or 'BILINMIYOR'),
        ReportLine('IZ NETLIGI', ('%.3f'):format(data.fingerprint_quality or 0.0)),
        ReportLine('ESLESME', ('%.3f'):format(data.match_certainty or 0.0)),
        ReportLine('MUHUR', data.sealed and 'MUHURLENDI' or 'MUHURLENMEDI')
    }


    if data.weapon_durability ~= nil then
        lines[#lines + 1] = ReportLine('SILAH CANI', ('%.1f%%'):format(data.weapon_durability * 100.0))
        lines[#lines + 1] = ReportLine('TUTUKLUK RISKI', ('%.3f'):format(data.jam_chance or 0.0))
    end


    lines[#lines + 1] = REPORT_DIVIDER
    lines[#lines + 1] = ReportLine('KAYIT', os.date('%Y-%m-%d %H:%M:%S'))
    lines[#lines + 1] = REPORT_BORDER


    return table.concat(lines, '\n')
end


function Matrix.Forensics.OnWeaponFired(actorRef, weaponSerial, casingInventoryId, casingSlot, weaponInventoryId, weaponSlot)
    if not casingInventoryId or type(casingSlot) ~= 'number' then return nil end


    local casingMeta = Matrix.Inventory.GetSlotMetadata(casingInventoryId, casingSlot)
    local durability = tonumber(casingMeta.durability) or 100.0
    durability = Matrix.Clamp(durability, 0.0, 100.0)
    local weaponWear = Matrix.Clamp(1.0 - (durability / 100.0), 0.0, 1.0)


    local weaponDurability = GetWeaponDurability(weaponInventoryId, weaponSlot)


    local result = Matrix.Forensics.SimulateWeaponFire(actorRef, weaponSerial, weaponWear, 'casing', weaponDurability)
    if not result then return nil end


    local report = Matrix.Forensics.BuildForensicReport({
        ballistic_id        = result.ballistic_id,
        evidence_type        = 'casing',
        striation_quality    = result.striation_quality,
        fingerprint_id        = result.dna_id,
        fingerprint_quality  = result.fingerprint_quality,
        match_certainty      = result.match_certainty,
        sealed                = result.sealed
    })


    Matrix.Inventory.MergeMetadata(casingInventoryId, casingSlot, {
        ballistic_id       = result.ballistic_id,
        striation_quality  = result.striation_quality,
        fingerprint_id     = result.dna_id,
        fingerprint_quality= result.fingerprint_quality,
        description        = report
    })


    if weaponInventoryId and type(weaponSlot) == 'number' then
        Matrix.Inventory.MergeMetadata(weaponInventoryId, weaponSlot, {
            ballistic_id      = result.ballistic_id,
            weapon_wear       = result.weapon_wear,
            weapon_durability = result.weapon_durability,
            jam_chance        = result.jam_chance,
            description       = Matrix.Forensics.BuildForensicReport({
                ballistic_id         = result.ballistic_id,
                evidence_type         = 'weapon',
                striation_quality     = result.striation_quality,
                fingerprint_id         = result.dna_id,
                fingerprint_quality   = result.fingerprint_quality,
                match_certainty       = result.match_certainty,
                sealed                 = result.sealed,
                weapon_durability     = result.weapon_durability,
                jam_chance             = result.jam_chance
            })
        })
    end


    return result.evidence_id, result.match_certainty, result.sealed, result.jam_chance, result.hard_delete_risk
end


-- =====================================================================
-- TOUCH STAMP
-- =====================================================================
function Matrix.Forensics.StampTouch(actorRef, inventoryId, slot)
    local actor = Matrix.ResolveActor(actorRef)
    if not actor then return nil end
    if not inventoryId or type(slot) ~= 'number' then return nil end


    local q  = Matrix.Forensics.ComputeFingerprintQuality(actor)
    local dna= GetActorDnaId(actor)


    Matrix.Inventory.MergeMetadata(inventoryId, slot, {
        fingerprint_id      = dna,
        fingerprint_quality = q
    })


    MySQL.prepare([[
        INSERT INTO matrix_touch_log
            (fingerprint_id, fingerprint_quality, inventory_id, slot_id, created_at)
        VALUES (?, ?, ?, ?, NOW())
    ]], { dna, q, tostring(inventoryId), slot })


    return q
end


-- =====================================================================
-- ★ DÜŞMAN TRAP HOUSE KAPI KIRMA ADLİ İZİ (breaching_tool)
-- server/door_reinforcement.lua Matrix.Forensics.RecordBreachToolMarks'ı
-- BAŞARILI bir kırma tamamlandığında (pcall'lı, bu dosya yüklenmemiş
-- olsa bile o dosya çökmez) çağırır. matrix_forensic_evidence'a
-- YAZILAMAZ (ballistic_id FK NOT NULL, kırma olayının bir balistik
-- kaydı yoktur) -- bu yüzden AYRI, kendi INDEX'li tablosu vardır
-- (matrix_breach_forensics, bkz. sql/matrix_financial_core.sql).
-- =====================================================================
function Matrix.Forensics.RecordBreachToolMarks(src, trapHouseId, toolItemName)
    local actor = Matrix.ResolveActor(src)
    if not actor then return false end

    local dna = GetActorDnaId(actor)
    local q   = Matrix.Forensics.ComputeFingerprintQuality(actor)

    local ok = pcall(function()
        MySQL.prepare([[
            INSERT INTO matrix_breach_forensics
                (trap_house_id, tool_item, fingerprint_id, tool_mark_quality, created_at)
            VALUES (?, ?, ?, ?, NOW())
        ]], { tonumber(trapHouseId) or 0, tostring(toolItemName), dna, q })
    end)

    if ok then
        Matrix.Log('FORENSICS',
            '[KIRMA ADLI IZI] Trap #%s | Alet:%s | Parmak Izi Kalitesi:%.3f | DNA:%s',
            tostring(trapHouseId), tostring(toolItemName), q, tostring(dna))
    else
        Matrix.Log('FORENSICS', '[HATA] RecordBreachToolMarks INSERT basarisiz (yutuldu).')
    end

    return ok
end

exports('RecordBreachToolMarks', function(src, trapHouseId, toolItemName)
    return Matrix.Forensics.RecordBreachToolMarks(src, trapHouseId, toolItemName)
end)


-- =====================================================================
-- LAB ANALYSIS
-- =====================================================================
function Matrix.Forensics.AnalyzeEvidence(evidenceId)
    if type(evidenceId) ~= 'number' then return nil end


    local rows = MySQL.query.await('SELECT * FROM matrix_forensic_evidence WHERE id = ?', { evidenceId })
    local evidence = rows and rows[1]
    if not evidence then return nil end


    local q        = Matrix.Clamp(tonumber(evidence.striation_quality) or 0.0, 0.0, 1.0)
    local match    = Matrix.Clamp(q * Config.BallisticStriationPrecision, 0.0, 1.0)
    local sealed   = match > Config.Forensics.MatchCertaintyThreshold


    MySQL.prepare([[
        UPDATE matrix_forensic_evidence
        SET match_certainty = ?, sealed_as_crime_weapon = ?
        WHERE id = ?
    ]], { match, sealed and 1 or 0, evidenceId })


    if sealed then
        MySQL.prepare([[
            UPDATE matrix_ballistic_weapons
            SET sealed_as_crime_weapon = 1, seal_certainty = ?
            WHERE ballistic_id = ?
        ]], { match, evidence.ballistic_id })
        Matrix.Log('FORENSICS', 'Lab: kanıt #%d -> %s mühürlendi (%.4f)', evidenceId, evidence.ballistic_id, match)
    else
        Matrix.Log('FORENSICS', 'Lab: kanıt #%d yetersiz eşleşme (%.4f)', evidenceId, match)
    end


    return match, sealed
end


-- =====================================================================
-- WEAR FLUSH (★ YAMA 3: wipe-barrier duyarlı)
-- =====================================================================
CreateThread(function()
    while true do
        Wait(20000)


        -- ★ [YAMA 3] Wipe sürerken ticker ERKEN ÇIKAR — havada yeni
        -- UPDATE üretmez. Wipe drain tamamlandıktan sonra bir sonraki
        -- tick normal akışına döner.
        if not _wearFlushWipeBarrier then
            for bid, wear in pairs(WearRetryQueue) do
                PendingWearUpdates[bid] = wear
                WearRetryQueue[bid] = nil
            end


            for bid, wear in pairs(PendingWearUpdates) do
                -- İkinci guard: Wipe thread'i döngü ortasında araya girdiyse
                -- dur.
                if _wearFlushWipeBarrier then break end
                PendingWearUpdates[bid] = nil
                local ok = pcall(function()
                    MySQL.update.await(
                        'UPDATE matrix_ballistic_weapons SET wear_level = ? WHERE ballistic_id = ?',
                        { wear, bid })
                end)
                if not ok then
                    WearRetryQueue[bid] = wear
                end
            end
        end
    end
end)


-- =====================================================================
-- EVENT BRIDGE
-- =====================================================================
RegisterNetEvent('matrix:server:reportWeaponDischarge', function(weaponSerial, casingInventoryId, casingSlot, weaponInventoryId, weaponSlot)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    if type(weaponSerial) ~= 'string' or #weaponSerial == 0 or #weaponSerial > 64 then return end
    if type(casingInventoryId) ~= 'string' or type(casingSlot) ~= 'number' then return end
    if weaponInventoryId ~= nil and type(weaponInventoryId) ~= 'string' then weaponInventoryId = nil end
    if type(weaponSlot) ~= 'number' then weaponSlot = nil end
    local ok, err = pcall(Matrix.Forensics.OnWeaponFired, { kind = 'player', source = src }, weaponSerial, casingInventoryId, casingSlot, weaponInventoryId, weaponSlot)
    if not ok then Matrix.Log('FORENSICS', '[HATA] reportWeaponDischarge basarisiz (yutuldu): %s', tostring(err)) end
end)


RegisterNetEvent('matrix:server:reportObjectTouch', function(inventoryId, slot)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    if type(inventoryId) ~= 'string' or type(slot) ~= 'number' then return end
    local ok, err = pcall(Matrix.Forensics.StampTouch, { kind = 'player', source = src }, inventoryId, slot)
    if not ok then Matrix.Log('FORENSICS', '[HATA] reportObjectTouch basarisiz (yutuldu): %s', tostring(err)) end
end)


RegisterNetEvent('matrix:server:reportWeaponShotFired', function(weaponItemName, weaponSlot)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    if type(weaponItemName) ~= 'string' or #weaponItemName == 0 or #weaponItemName > 64 then return end
    if type(weaponSlot) ~= 'number' then return end


    local weaponInventoryId = tostring(src)
    local meta = Matrix.Inventory.GetSlotMetadata(weaponInventoryId, weaponSlot)
    local weaponSerial = meta.weapon_serial
    if type(weaponSerial) ~= 'string' or weaponSerial == '' then return end


    local ok, result = pcall(Matrix.Forensics.OnWeaponShotFired,
        { kind = 'player', source = src }, weaponItemName, weaponSerial, weaponInventoryId, weaponSlot)
    if not ok then
        Matrix.Log('FORENSICS', '[HATA] reportWeaponShotFired basarisiz (yutuldu): %s', tostring(result))
        return
    end


    if type(result) == 'table' and result.jammed then
        TriggerClientEvent('matrix:client:weaponJamStateChanged', src, weaponSlot, true)
        Matrix.Log('FORENSICS', '[MEKANIK TUTUKLUK] src=%d slot=%d silah=%s durability=%.1f%% jam_p=%.3f',
            src, weaponSlot, weaponItemName, result.durability, result.jam_probability)
    end
end)


RegisterNetEvent('matrix:server:clearWeaponJam', function(weaponSlot)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    if type(weaponSlot) ~= 'number' then return end


    local weaponInventoryId = tostring(src)
    local ok, cleared = pcall(Matrix.Forensics.ClearMechanicalJam, weaponInventoryId, weaponSlot)
    if not ok then
        Matrix.Log('FORENSICS', '[HATA] clearWeaponJam basarisiz (yutuldu): %s', tostring(cleared))
        return
    end
    if cleared then
        TriggerClientEvent('matrix:client:weaponJamStateChanged', src, weaponSlot, false)
        Matrix.Log('FORENSICS', '[TUTUKLUK GIDERILDI] src=%d slot=%d (risk namlu degisene kadar yuksek kalir).', src, weaponSlot)
    end
end)


-- =====================================================================
-- /namludegistir — YEDEK NAMLU DEĞİŞİMİ
-- =====================================================================
RegisterCommand('namludegistir', function(src, args)
    local weaponSlot = tonumber(args[1])
    if type(src) ~= 'number' or src <= 0 or not weaponSlot then
        if type(src) == 'number' and src > 0 then
            TriggerClientEvent('chat:addMessage', src, { args = { '[FORENSICS]', 'Kullanim: /namludegistir [silahSlotu] (F10 menusunden kullanin)' } })
        end
        return
    end


    local weaponInventoryId = tostring(src)
    local ok, weaponItem = pcall(exports['ox_inventory'].GetSlot, exports['ox_inventory'], weaponInventoryId, weaponSlot)
    if not ok or type(weaponItem) ~= 'table' or type(weaponItem.name) ~= 'string' then
        TriggerClientEvent('chat:addMessage', src, { args = { '[FORENSICS]', 'Belirtilen slotta silah bulunamadi.' } })
        return
    end


    if not (Config.BlackMarket and Config.BlackMarket.ReplaceableWeaponItems and Config.BlackMarket.ReplaceableWeaponItems[weaponItem.name]) then
        TriggerClientEvent('chat:addMessage', src, { args = { '[FORENSICS]', 'Bu silah turu icin namlu degisimi desteklenmiyor.' } })
        return
    end


    local barrelItem = Config.BlackMarket and Config.BlackMarket.SpareBarrelItem
    if not barrelItem then
        TriggerClientEvent('chat:addMessage', src, { args = { '[FORENSICS]', 'Yedek Namlu sistemi yapilandirilmamis.' } })
        return
    end


    local countOk, barrelCount = pcall(exports['ox_inventory'].Search, exports['ox_inventory'], weaponInventoryId, 'count', barrelItem)
    barrelCount = (countOk and tonumber(barrelCount)) or 0
    if barrelCount < 1 then
        TriggerClientEvent('chat:addMessage', src, { args = { '[FORENSICS]', 'Yedek Namlu bulunamadi. Once Karaborsa Ticaret Agi uzerinden satin alin.' } })
        return
    end


    local removeOk = pcall(function()
        return exports['ox_inventory']:RemoveItem(weaponInventoryId, barrelItem, 1)
    end)
    if not removeOk then
        TriggerClientEvent('chat:addMessage', src, { args = { '[FORENSICS]', 'Yedek Namlu tuketilemedi.' } })
        return
    end


    local oldMeta   = weaponItem.metadata or {}
    local oldSerial = oldMeta.weapon_serial


    local state = Matrix.GetOrCreatePlayerState(src)
    local citizenid = (state and state.citizenid) or ('SRC-%d'):format(src)


    local newSerial
    if Matrix.BlackMarket and Matrix.BlackMarket.GenerateWeaponSerial then
        newSerial = Matrix.BlackMarket.GenerateWeaponSerial(citizenid, weaponItem.name)
    else
        newSerial = ('BM-%s-%07X'):format(weaponItem.name:sub(-6):upper(), (GetGameTimer() + weaponSlot) % 0xFFFFFFF)
    end


    if type(oldSerial) == 'string' and oldSerial ~= '' then
        pcall(Matrix.Forensics.WipeBallisticRecord, oldSerial)
    end


    Matrix.Inventory.MergeMetadata(weaponInventoryId, weaponSlot, {
        weapon_serial   = newSerial,
        shots_fired     = 0,
        durability      = 100.0,
        jam_accumulator = 0.0,
        jammed          = false,
        description     = '[YENI NAMLU TAKILDI]\nBuro balistik arsivi tamamen silindi.'
    })


    TriggerClientEvent('matrix:client:weaponJamStateChanged', src, weaponSlot, false)
    TriggerClientEvent('chat:addMessage', src, { args = { '[FORENSICS]', '[NAMLU DEGISTIRILDI] Buro balistik arsivi tamamen kor edildi. Silah fabrika ayarlarina donduruldu.' } })
    Matrix.Log('FORENSICS', '[NAMLU DEGISIMI] src=%d silah=%s eski-seri=%s yeni-seri=%s', src, weaponItem.name, tostring(oldSerial), newSerial)
end, false)


-- =====================================================================
-- MONOKROM TAKTİK DEBUG PANELİ
-- =====================================================================
local function Reply(src, msg)
    if type(src) == 'number' and src > 0 then
        TriggerClientEvent('chat:addMessage', src, { args = { '[FORENSICS]', msg } })
    else
        print(('[MATRIX:FORENSICS:CONSOLE] %s'):format(msg))
    end
end


Matrix.Security.RegisterGatedCommand('forensicdump', function(src, args)
    local ballisticId = args[1]
    if type(ballisticId) ~= 'string' then Reply(src, 'Kullanim: /forensicdump [ballisticId]'); return end


    local weaponRows = MySQL.query.await('SELECT * FROM matrix_ballistic_weapons WHERE ballistic_id = ?', { ballisticId }) or {}
    local weapon = weaponRows[1]
    if not weapon then Reply(src, 'Balistik ID bulunamadı.'); return end


    Reply(src, ('Silah: %s | Seri:%s | Aşınma:%.3f | Mühür:%s | Kesinlik:%s'):format(
        weapon.ballistic_id, weapon.weapon_serial, weapon.wear_level,
        Matrix.FormatMilSimStatus(weapon.sealed_as_crime_weapon == 1, '🔒 SIZDIRMAZ (Suç Silahı)', '🟢 MÜHÜRSÜZ'),
        tostring(weapon.seal_certainty)))


    local evidenceRows = MySQL.query.await(
        'SELECT * FROM matrix_forensic_evidence WHERE ballistic_id = ? ORDER BY id DESC LIMIT 10', { ballisticId }
    ) or {}
    Reply(src, ('--- %d kanıt satırı (en yeni 10) ---'):format(#evidenceRows))
    for _, ev in ipairs(evidenceRows) do
        Reply(src, ('  #%d [%s] Striasyon:%.3f Eşleşme:%.3f Mühür:%s'):format(
            ev.id, ev.evidence_type, ev.striation_quality, ev.match_certainty,
            Matrix.FormatMilSimStatus(ev.sealed_as_crime_weapon == 1, '🔒 SIZDIRMAZ', '🟢 MÜHÜRSÜZ')))
    end
end)


Matrix.Security.RegisterGatedCommand('forensicrapor', function(src, args)
    local evidenceId = tonumber(args[1])
    if not evidenceId then Reply(src, 'Kullanim: /forensicrapor [evidenceId]'); return end


    local rows = MySQL.query.await('SELECT * FROM matrix_forensic_evidence WHERE id = ?', { evidenceId })
    local evidence = rows and rows[1]
    if not evidence then Reply(src, 'Kanıt bulunamadı.'); return end


    local report = Matrix.Forensics.BuildForensicReport({
        ballistic_id         = evidence.ballistic_id,
        evidence_type        = evidence.evidence_type,
        striation_quality    = evidence.striation_quality,
        fingerprint_id       = evidence.fingerprint_id,
        fingerprint_quality  = evidence.fingerprint_quality,
        match_certainty      = evidence.match_certainty,
        sealed               = evidence.sealed_as_crime_weapon == 1
    })
    print(report)
    Reply(src, ('Kanıt #%d raporu konsola basıldı.'):format(evidenceId))
end)


Matrix.Security.RegisterGatedCommand('asinmaayarla', function(src, args)
    local serial = args[1]
    local wear = Matrix.Clamp(tonumber(args[2]) or 0.0, 0.0, 1.0)
    if type(serial) ~= 'string' then Reply(src, 'Kullanim: /asinmaayarla [seri] [0.0-1.0]'); return end


    local cached = BallisticCache[serial]
    if not cached then Reply(src, 'Bu seri henüz balistik olarak kayıtlı değil (önce ateşlenmeli).'); return end


    cached.wear_level = wear
    MySQL.prepare('UPDATE matrix_ballistic_weapons SET wear_level = ? WHERE weapon_serial = ?', { wear, serial })
    Reply(src, ('%s aşınması %.3f olarak ayarlandı.'):format(serial, wear))
end)


RegisterCommand('silahasindir', function(src, args)
    local slot = tonumber(args[1])
    local amount = Matrix.Clamp(tonumber(args[2]) or 100.0, 0.0, 100.0)
    if type(src) ~= 'number' or src <= 0 or not slot then
        Reply(src, 'Kullanim: /silahasindir [slot] [miktar 0-100]'); return
    end


    local inventoryId = tostring(src)
    Matrix.Inventory.MergeMetadata(inventoryId, slot, { durability = amount })


    Reply(src, ('Slot #%d silah canı %.1f olarak ayarlandı (Jam_Chance:%.3f). Bir sonraki ateşlemede Q_kovan mutasyona uğrayacak.'):format(
        slot, amount, Matrix.Forensics.ComputeJamChance(amount / 100.0)))
end, false)


RegisterCommand('balistikcache', function(src)
    local n = 0
    for _ in pairs(BallisticCache) do n = n + 1 end
    local pn = 0
    for _ in pairs(PendingWearUpdates) do pn = pn + 1 end
    local rn = 0
    for _ in pairs(WearRetryQueue) do rn = rn + 1 end


    Reply(src, ('BallisticCache: %d/%d | InsertOrder:%d | PendingWear:%d | WearRetry:%d | WipeBarrier:%s'):format(
        n, BALLISTIC_CACHE_MAX, #BallisticInsertOrder, pn, rn, tostring(_wearFlushWipeBarrier)))
end, false)


-- =====================================================================
-- KATMAN 7 FAZ 2: REAL-TIME ÜST ARAMA / ÇEVİRME
-- =====================================================================
local function IsPackagedProduct(itemName)
    for _, product in ipairs(Config.Kitchen.Packaging.Products) do
        if product.item == itemName then return true end
    end
    return false
end


local function ScanInventoryContraband(inventoryId)
    local findings = {}
    local invOk, inv = pcall(function() return exports['ox_inventory']:GetInventory(inventoryId) end)
    if not invOk or type(inv) ~= 'table' or type(inv.items) ~= 'table' then return findings end


    local now = Matrix.Now()
    for slot, item in pairs(inv.items) do
        if type(item) == 'table' and type(item.name) == 'string' then
            local meta = item.metadata or {}
            if type(meta.weapon_serial) == 'string'
                and meta.weapon_serial:sub(1, #Config.Forensics.Frisk.WeaponSerialContrabandPrefix) == Config.Forensics.Frisk.WeaponSerialContrabandPrefix then
                findings[#findings + 1] = { kind = 'weapon', inventory_id = inventoryId, slot = slot, item = item.name, count = tonumber(item.count) or 1, serial = meta.weapon_serial }
            elseif meta.imei_masked == true and type(meta.acquired_at) == 'number'
                and (now - meta.acquired_at) > Config.Forensics.Frisk.BurnerPhoneMaxHoldSeconds then
                findings[#findings + 1] = { kind = 'burner_phone', inventory_id = inventoryId, slot = slot, item = item.name, count = tonumber(item.count) or 1 }
            elseif IsPackagedProduct(item.name) and type(meta.purity) == 'number'
                and meta.purity < Config.Market.GourmetMinPurity then
                findings[#findings + 1] = { kind = 'drugs', inventory_id = inventoryId, slot = slot, item = item.name, count = tonumber(item.count) or 1 }
            end
        end
    end
    return findings
end


local function ScanTrunkContraband(plate)
    if type(plate) ~= 'string' or plate == '' then return {} end
    if not (Matrix.Fleet and Matrix.Fleet.GetVehicle and Matrix.Fleet.GetVehicle(plate)) then return {} end

    local trunkId = Config.Logistics.TrunkOps.StashPrefix .. plate
    pcall(function()
        exports['ox_inventory']:RegisterStash(trunkId, ('%s Bagaji'):format(plate),
            Config.Logistics.TrunkOps.Slots, Config.Logistics.TrunkOps.MaxWeight)
    end)
    return ScanInventoryContraband(trunkId)
end


local function SeizeContraband(finding, dnaId)
    if finding.kind == 'vehicle' then
        pcall(function() Matrix.Fleet.SeizeVehicle(finding.plate, 'frisk_search', dnaId, nil) end)
        return
    end


    pcall(function()
        exports['ox_inventory']:RemoveItem(finding.inventory_id, finding.item, finding.count, nil, finding.slot)
    end)


    if finding.kind == 'weapon' and Matrix.Forensics.WipeBallisticRecord then
        Matrix.Forensics.WipeBallisticRecord(finding.serial)
    end
end


local function FindNearestTrapHouseForFrisk(coords)
    local nearestId, nearestDist = nil, math.huge
    for id, house in pairs(Matrix.TrapHouses or {}) do
        local d = #(coords - house.coords)
        if d < nearestDist then nearestId, nearestDist = id, d end
    end
    return nearestId
end


function Matrix.Forensics.InspectBustedBot(botId, trapHouseId, plate)
    local bot = Matrix.Bots[botId]
    if not bot then return false end


    local inventoryId = ('dealer_%d'):format(botId)
    local findings = ScanInventoryContraband(inventoryId)


    if type(plate) == 'string' and plate ~= '' then
        local vehicle = Matrix.Fleet and Matrix.Fleet.GetVehicle and Matrix.Fleet.GetVehicle(plate)
        if vehicle and (vehicle.vin_status == 'scratched' or vehicle.verified_stolen_plate) then
            findings[#findings + 1] = { kind = 'vehicle', plate = plate }
        end

        for _, trunkFinding in ipairs(ScanTrunkContraband(plate)) do
            findings[#findings + 1] = trunkFinding
        end
    end


    if #findings == 0 then return false end


    for _, finding in ipairs(findings) do
        SeizeContraband(finding, bot.dna_id)
    end


    if trapHouseId and Matrix.Bureau and Matrix.Bureau.AdvanceDecryption then
        Matrix.Bureau.AdvanceDecryption(trapHouseId, Config.Forensics.Frisk.EvidenceIndexJumpRatio)
    end


    Matrix.Log('FORENSICS', '[UST ARAMA] Bot #%d yakalandi: %d kontrabant bulundu, delil indeksi %.2f ziladi.',
        botId, #findings, Config.Forensics.Frisk.EvidenceIndexJumpRatio)
    return true
end


function Matrix.Forensics.InspectPlayer(officerSrc, suspectSrc)
    local inventoryId = tostring(suspectSrc)
    local findings = ScanInventoryContraband(inventoryId)


    local ped = GetPlayerPed(suspectSrc)
    if ped and ped ~= 0 then
        local okVeh, veh = pcall(function() return GetVehiclePedIsIn(ped, false) end)
        if okVeh and veh and veh ~= 0 then
            local okPlate, plate = pcall(function() return GetVehicleNumberPlateText(veh) end)
            plate = (okPlate and type(plate) == 'string') and plate:gsub('%s+$', '') or nil
            local vehicle = plate and Matrix.Fleet and Matrix.Fleet.GetVehicle and Matrix.Fleet.GetVehicle(plate)
            if vehicle and (vehicle.vin_status == 'scratched' or vehicle.verified_stolen_plate) then
                findings[#findings + 1] = { kind = 'vehicle', plate = plate }
            end

            if vehicle then
                for _, trunkFinding in ipairs(ScanTrunkContraband(plate)) do
                    findings[#findings + 1] = trunkFinding
                end
            end
        end
    end


    if #findings == 0 then
        Reply(officerSrc, 'Ust arama tamamlandi: kontrabant bulunamadi.')
        return false
    end


    local actor = Matrix.ResolveActor({ kind = 'player', source = suspectSrc })
    local dnaId = (actor and actor.dna_id) or 'UNKNOWN'
    for _, finding in ipairs(findings) do
        SeizeContraband(finding, dnaId)
    end


    local coords = ped and ped ~= 0 and GetEntityCoords(ped) or nil
    local trapHouseId = coords and FindNearestTrapHouseForFrisk(coords)
    if trapHouseId and Matrix.Bureau and Matrix.Bureau.AdvanceDecryption then
        Matrix.Bureau.AdvanceDecryption(trapHouseId, Config.Forensics.Frisk.EvidenceIndexJumpRatio)
    end


    Reply(officerSrc, ('Ust arama tamamlandi: %d kontrabant el konuldu.'):format(#findings))
    TriggerClientEvent('chat:addMessage', suspectSrc, { args = { '[UST ARAMA]', ('%d esyaniza el konuldu.'):format(#findings) } })
    Matrix.Log('FORENSICS', '[UST ARAMA] Memur #%d, supheli #%d: %d kontrabant bulundu.', officerSrc, suspectSrc, #findings)
    return true
end


local FriskPoliceSources        = {}
local friskPoliceFailCount      = 0
local friskPoliceDisabledUntil  = 0


local function RefreshFriskPoliceCache()
    if Matrix.Now() < friskPoliceDisabledUntil then return end


    local ok, players = pcall(function() return Matrix.QBX:GetQBPlayers() end)
    if not ok or type(players) ~= 'table' then
        friskPoliceFailCount = friskPoliceFailCount + 1
        if friskPoliceFailCount >= 5 then
            friskPoliceDisabledUntil = Matrix.Now() + 60
            friskPoliceFailCount = 0
            Matrix.Log('FORENSICS', '[UYARI] GetQBPlayers 5 kez ust uste basarisiz oldu; 60sn devre disi birakildi.')
        end
        return
    end
    friskPoliceFailCount = 0


    local fresh = {}
    for src, player in pairs(players) do
        if player and player.PlayerData and player.PlayerData.job then
            local job = player.PlayerData.job
            if job.onduty and (job.name == 'police' or job.name == 'sheriff' or job.type == 'leo') then
                fresh[src] = true
            end
        end
    end
    FriskPoliceSources = fresh
end


CreateThread(function()
    while true do
        Wait(5000)
        RefreshFriskPoliceCache()
    end
end)


local FriskDwellMs       = {}
local FriskCooldownUntil = {}


CreateThread(function()
    while true do
        Wait(1000)


        local now = Matrix.Now()
        local activePairs = {}


        for officerSrc in pairs(FriskPoliceSources) do
            local officerPed = GetPlayerPed(officerSrc)
            if officerPed and officerPed ~= 0 then
                local officerCoords = GetEntityCoords(officerPed)


                for _, suspectSrcStr in ipairs(GetPlayers()) do
                    local suspectSrc = tonumber(suspectSrcStr)
                    if suspectSrc and suspectSrc ~= officerSrc and not FriskPoliceSources[suspectSrc] then
                        local suspectPed = GetPlayerPed(suspectSrc)
                        if suspectPed and suspectPed ~= 0 and (FriskCooldownUntil[suspectSrc] or 0) <= now then
                            local suspectCoords = GetEntityCoords(suspectPed)
                            if #(officerCoords - suspectCoords) <= Config.Forensics.Frisk.Radius then
                                local pairKey = officerSrc .. '#' .. suspectSrc
                                activePairs[pairKey] = true
                                FriskDwellMs[pairKey] = (FriskDwellMs[pairKey] or 0) + 1000


                                if FriskDwellMs[pairKey] >= Config.Forensics.Frisk.DwellMs then
                                    FriskDwellMs[pairKey] = nil
                                    FriskCooldownUntil[suspectSrc] = now + math.floor(Config.Forensics.Frisk.CooldownMs / 1000)


                                    local ok, err = pcall(Matrix.Forensics.InspectPlayer, officerSrc, suspectSrc)
                                    if not ok then
                                        Matrix.Log('FORENSICS', '[HATA] InspectPlayer hata verdi (yutuldu): %s', tostring(err))
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end


        for key in pairs(FriskDwellMs) do
            if not activePairs[key] then FriskDwellMs[key] = nil end
        end
    end
end)


-- =====================================================================
-- OPSEC FAZ 1 EK: FİZİKSEL VE SİBER DELİL İMHA MEKANİZMASI
-- =====================================================================


local function IsValidWorldCoords(c)
    if type(c) ~= 'table' and type(c) ~= 'userdata' and type(c) ~= 'vector3' and type(c) ~= 'vector4' then return false end
    if c.x == nil or c.y == nil or c.z == nil then return false end
    if type(c.x) ~= 'number' or type(c.y) ~= 'number' or type(c.z) ~= 'number' then return false end
    if c.x ~= c.x or c.y ~= c.y or c.z ~= c.z then return false end
    return true
end


local function ComputeSkillGatedDurationMs(baseDurationMs, floorDurationMs, skill)
    skill = Matrix.Clamp(tonumber(skill) or 0.0, 0.0, 1.0)
    local duration = baseDurationMs - ((baseDurationMs - floorDurationMs) * skill)
    if duration < floorDurationMs then duration = floorDurationMs end
    return math.floor(duration)
end


function Matrix.Forensics.CollectShells(botId, coords)
    botId = tonumber(botId)
    local bot = botId and Matrix.Bots[botId]
    if not bot then return false, 'bot_missing' end
    if not IsValidWorldCoords(coords) then return false, 'bad_coords' end


    local radius = Config.Forensics.ShellCollectionRadiusMeters or 3.0
    local rows = MySQL.query.await([[
        SELECT id, ballistic_id, coords_x, coords_y, coords_z FROM matrix_forensic_evidence
        WHERE coords_x BETWEEN ? AND ? AND coords_y BETWEEN ? AND ? AND coords_z BETWEEN ? AND ?
    ]], {
        coords.x - radius, coords.x + radius,
        coords.y - radius, coords.y + radius,
        coords.z - radius, coords.z + radius
    }) or {}


    local matched = {}
    for _, row in ipairs(rows) do
        local dx = (tonumber(row.coords_x) or 0.0) - coords.x
        local dy = (tonumber(row.coords_y) or 0.0) - coords.y
        local dz = (tonumber(row.coords_z) or 0.0) - coords.z
        if math.sqrt((dx * dx) + (dy * dy) + (dz * dz)) <= radius then
            matched[#matched + 1] = row
        end
    end
    if #matched == 0 then return false, 'no_evidence_here' end


    local skill = (Matrix.Kitchen and Matrix.Kitchen.GetEffectiveSkill and Matrix.Kitchen.GetEffectiveSkill(bot, 'skill_logistics')) or 0.0
    local durationMs = ComputeSkillGatedDurationMs(
        Config.Forensics.ShellCollectionBaseDurationMs, Config.Forensics.ShellCollectionSkillDurationFloorMs, skill)
    local cortisolSpike = Config.Forensics.ShellCollectionBaseCortisolSpike * (1.0 - Matrix.Clamp(skill, 0.0, 1.0))


    local inventoryId = ('dealer_%d'):format(bot.id)
    local collectedCount = 0
    for _, row in ipairs(matched) do
        local addOk = pcall(function()
            return exports['ox_inventory']:AddItem(inventoryId, Config.Forensics.ShellCasingEvidenceItem, 1, {
                ballistic_id = row.ballistic_id,
                description  = ('[TOPLANMIS KOVAN]\nBalistik ID: %s\nAdli kayit fiziksel olarak imha edildi.'):format(row.ballistic_id)
            })
        end)
        if addOk then
            MySQL.prepare('DELETE FROM matrix_forensic_evidence WHERE id = ?', { row.id })
            collectedCount = collectedCount + 1
        end
    end
    if collectedCount == 0 then return false, 'inventory_full' end


    if cortisolSpike > 0.0 and bot.biology then
        bot.biology.cortisol_level = Matrix.Clamp(bot.biology.cortisol_level + cortisolSpike, 0.0, 1.0)
        Matrix.MarkBotDirty(bot.id)
    end


    Matrix.Log('FORENSICS',
        '[KOVAN TOPLAMA] Bot #%d (%s) (%.1f,%.1f,%.1f) civarinda %d/%d kovan topladi ve matrix_forensic_evidence dan kalici olarak sildi (skill_logistics=%.3f sure=%dms kortizol-sicramasi=%.3f).',
        bot.id, bot.dna_id, coords.x, coords.y, coords.z, collectedCount, #matched, skill, durationMs, cortisolSpike)


    return true, { collected = collectedCount, found = #matched, duration_ms = durationMs, cortisol_spike = cortisolSpike }
end


function Matrix.Forensics.HackCCTVNetwork(actorRef, zoneId)
    zoneId = tonumber(zoneId)
    if not zoneId then return false, 'bad_zone' end


    local actor = Matrix.ResolveActor(actorRef)
    if not actor then return false, 'actor_unresolved' end


    local skill = (Matrix.Kitchen and Matrix.Kitchen.GetEffectiveSkill and Matrix.Kitchen.GetEffectiveSkill(actor, 'skill_cyber')) or 0.0
    local durationMs = ComputeSkillGatedDurationMs(
        Config.Forensics.CCTVHackBaseDurationMs, Config.Forensics.CCTVHackSkillDurationFloorMs, skill)
    local cortisolSpike = Config.Forensics.CCTVHackBaseCortisolSpike * (1.0 - Matrix.Clamp(skill, 0.0, 1.0))


    MySQL.prepare([[
        DELETE FROM matrix_cctv_logs
        WHERE zone_id = ? AND masked = 0 AND created_at >= (NOW() - INTERVAL 30 MINUTE)
    ]], { zoneId })


    if cortisolSpike > 0.0 and actor.biology then
        actor.biology.cortisol_level = Matrix.Clamp(actor.biology.cortisol_level + cortisolSpike, 0.0, 1.0)
    end


    Matrix.Log('FORENSICS',
        '[MOBESE HACK] %s -> Bolge #%d son 30dk maskesiz/supheli kiyafet gecmisi silindi (skill_cyber=%.3f sure=%dms kortizol-sicramasi=%.3f).',
        actor.dna_id or 'UNKNOWN', zoneId, skill, durationMs, cortisolSpike)


    return true, { duration_ms = durationMs, cortisol_spike = cortisolSpike }
end


local function VerifyAtRouter(src)
    if not (Matrix.TrapHouseInterior and Matrix.TrapHouseInterior.GetPlayerTrapHouse) then
        return true
    end


    local trapHouseId = Matrix.TrapHouseInterior.GetPlayerTrapHouse(src)
    if not trapHouseId then return false end


    local shell = Config.TrapHouseInterior and Config.TrapHouseInterior.Shell
    local routerPos = shell and shell.RouterPos
    if not routerPos then return true end


    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false end
    local coords = GetEntityCoords(ped)
    local radius = (Config.Forensics.RouterSanitization and Config.Forensics.RouterSanitization.Radius) or 2.0
    return #(coords - routerPos) <= radius
end


function Matrix.Forensics.SanitizeCCTVTrail(src)
    if type(src) ~= 'number' or src <= 0 then return false, 'bad_src' end


    if not VerifyAtRouter(src) then
        return false, 'not_at_router'
    end


    local state = Matrix.GetOrCreatePlayerState(src)
    if not state or not state.dna_id then return false, 'state_unresolved' end


    local windowMinutes = (Config.Forensics.RouterSanitization and Config.Forensics.RouterSanitization.WindowMinutes) or 30


    local ok, result = pcall(function()
        return MySQL.query.await(
            ('DELETE FROM matrix_cctv_logs WHERE dna_id = ? AND created_at >= (NOW() - INTERVAL %d MINUTE)'):format(windowMinutes),
            { state.dna_id }
        )
    end)
    if not ok then
        Matrix.Log('FORENSICS', '[HATA] SanitizeCCTVTrail DELETE basarisiz: %s', tostring(result))
        return false, 'db_error'
    end


    local affected = (type(result) == 'table' and (result.affectedRows or result.numAffected)) or 0
    Matrix.Log('FORENSICS',
        '[KAMERA VERI TEMIZLIGI] %s -> router kutusu uzerinden son %d dakikalik mobese/kiyafet izi kazindi (%s satir).',
        state.dna_id, windowMinutes, tostring(affected))


    return true, { minutes = windowMinutes, affected = affected }
end


RegisterCommand('kameralogutemizle', function(src, args)
    if type(src) ~= 'number' or src <= 0 then return end


    local ok, resultOrReason = Matrix.Forensics.SanitizeCCTVTrail(src)
    if ok then
        Reply(src, ('[ROUTER SIZMASI] Son %d dakikalik mobese/kiyafet izi kalici olarak kazindi.'):format(resultOrReason.minutes))
    elseif resultOrReason == 'not_at_router' then
        Reply(src, 'Router kutusunun yaninda degilsiniz (bir trap house icine girip router\'a yaklasin).')
    else
        Reply(src, ('Basarisiz: %s'):format(tostring(resultOrReason)))
    end
end, false)


exports('SanitizeCCTVTrail', function(src) return Matrix.Forensics.SanitizeCCTVTrail(src) end)


function Matrix.Forensics.TamperEvidenceLockup(officerCitizenId, caseId, bribeWasSuccessful)
    if type(officerCitizenId) ~= 'string' or officerCitizenId == '' then return false, 'bad_officer' end
    if type(caseId) ~= 'string' or caseId == '' then return false, 'bad_case' end
    if not bribeWasSuccessful then return false, 'bribe_not_successful' end


    local personality = Matrix.Bureau and Matrix.Bureau.GetPolicePersonality and Matrix.Bureau.GetPolicePersonality(officerCitizenId)
    if not personality then return false, 'officer_personality_unresolved' end


    local greedThreshold = Config.Forensics.TamperGreedThreshold
    if personality.greed < greedThreshold then
        return false, 'officer_not_greedy_enough'
    end


    local weaponRows = MySQL.query.await('SELECT ballistic_id FROM matrix_ballistic_weapons WHERE ballistic_id = ?', { caseId }) or {}
    if not weaponRows[1] then return false, 'case_not_found' end


    MySQL.prepare([[
        UPDATE matrix_ballistic_weapons
        SET sealed_as_crime_weapon = 0, seal_certainty = 0.0
        WHERE ballistic_id = ?
    ]], { caseId })


    MySQL.prepare([[
        UPDATE matrix_forensic_evidence
        SET sealed_as_crime_weapon = 0, match_certainty = 0.0
        WHERE ballistic_id = ?
    ]], { caseId })


    Matrix.Log('FORENSICS',
        '[KANIT ODASI SABOTAJI] Memur %s (greed=%.3f >= esik:%.2f) -> Vaka #%s: Mahkumiyet Skoru (chain of custody) SIFIRLANDI.',
        officerCitizenId, personality.greed, greedThreshold, caseId)


    return true, { case_id = caseId, officer_greed = personality.greed }
end


RegisterNetEvent('matrix:server:forensics:collectShells', function(botId, coords)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    local ok, resultOrReason = Matrix.Forensics.CollectShells(botId, coords)
    TriggerClientEvent('matrix:client:actionNotify', src, ok,
        ok and ('%d kovan toplandi, adli kayittan silindi.'):format(resultOrReason.collected)
           or ('Kovan toplama basarisiz: %s'):format(tostring(resultOrReason)))
end)


RegisterNetEvent('matrix:server:forensics:hackCCTV', function(zoneId)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    local ok, resultOrReason = Matrix.Forensics.HackCCTVNetwork({ kind = 'player', source = src }, zoneId)
    TriggerClientEvent('matrix:client:actionNotify', src, ok,
        ok and 'Mobese agina sizildi, gecmis kayitlar silindi.' or ('Mobese hack basarisiz: %s'):format(tostring(resultOrReason)))
end)


-- ★ [SEC] kovantopla/mobesehackle/cctvkaydet/kanitsabotaj admin-only:
-- hepsi ya keyfi/oyuncu-beyanlı koordinat kabul ediyor (kovantopla botun
-- GERÇEK konumu yerine args'tan gelen x/y/z kullanır -- botu fiilen
-- oraya HİÇ götürmeden uzaktan kanıt silinebiliyordu), ya da hiçbir
-- yakınlık/maliyet kontrolü olmadan sivil kardeşi (kameralogutemizle'nin
-- router yakınlık şartı) kadar kısıtlı değil, ya da doğrudan "(test)"
-- olarak etiketlenmiş/gerçek rüşvet akışını (rusvetteklifi) tamamen
-- atlıyor (kanitsabotaj).
Matrix.Security.RegisterGatedCommand('kovantopla', function(src, args)
    local botId = tonumber(args[1])
    local x, y, z = tonumber(args[2]), tonumber(args[3]), tonumber(args[4])
    if not botId or not x or not y or not z then
        Reply(src, 'Kullanim: /kovantopla [botId] [x] [y] [z]'); return
    end


    local ok, result = Matrix.Forensics.CollectShells(botId, vector3(x, y, z))
    if ok then
        Reply(src, ('%d/%d kovan toplandi (sure:%dms kortizol:+%.3f).'):format(result.collected, result.found, result.duration_ms, result.cortisol_spike))
    else
        Reply(src, ('Basarisiz: %s'):format(tostring(result)))
    end
end)


Matrix.Security.RegisterGatedCommand('mobesehackle', function(src, args)
    local zoneId = tonumber(args[1])
    if not zoneId then Reply(src, 'Kullanim: /mobesehackle [zoneId]'); return end


    local ok, result = Matrix.Forensics.HackCCTVNetwork({ kind = 'player', source = src }, zoneId)
    if ok then
        Reply(src, ('Bolge #%d mobese gecmisi silindi (sure:%dms kortizol:+%.3f).'):format(zoneId, result.duration_ms, result.cortisol_spike))
    else
        Reply(src, ('Basarisiz: %s'):format(tostring(result)))
    end
end)


Matrix.Security.RegisterGatedCommand('cctvkaydet', function(src, args)
    local zoneId = tonumber(args[1])
    local dnaId  = args[2]
    local masked = tonumber(args[3]) == 1
    local tag    = args[4] or 'unknown'
    if not zoneId or type(dnaId) ~= 'string' then
        Reply(src, 'Kullanim: /cctvkaydet [zoneId] [dnaId] [maskeli 0|1] [kiyafetEtiketi]'); return
    end


    MySQL.insert('INSERT INTO matrix_cctv_logs (zone_id, dna_id, masked, clothing_tag, created_at) VALUES (?, ?, ?, ?, NOW())',
        { zoneId, dnaId, masked and 1 or 0, tag })
    Reply(src, 'Mobese kaydi eklendi (test).')
end)


Matrix.Security.RegisterGatedCommand('kanitsabotaj', function(src, args)
    local officerCitizenId = args[1]
    local caseId            = args[2]
    if type(officerCitizenId) ~= 'string' or type(caseId) ~= 'string' then
        Reply(src, 'Kullanim: /kanitsabotaj [memurCitizenId] [caseId/ballisticId]'); return
    end


    local ok, result = Matrix.Forensics.TamperEvidenceLockup(officerCitizenId, caseId, true)
    if ok then
        Reply(src, ('Vaka #%s sabote edildi (memur greed=%.3f).'):format(result.case_id, result.officer_greed))
    else
        Reply(src, ('Basarisiz: %s'):format(tostring(result)))
    end
end)


exports('CollectShells', function(botId, coords) return Matrix.Forensics.CollectShells(botId, coords) end)
exports('HackCCTVNetwork', function(actorRef, zoneId) return Matrix.Forensics.HackCCTVNetwork(actorRef, zoneId) end)
exports('TamperEvidenceLockup', function(officerCitizenId, caseId, bribeWasSuccessful)
    return Matrix.Forensics.TamperEvidenceLockup(officerCitizenId, caseId, bribeWasSuccessful)
end)


-- =====================================================================
-- KATMAN 8 — CEPHE C2: ADLİ DELİL ASİMPTOTİK ERİMESİ
--
-- ★ ADLİ BULGU (bu oturumda tespit edildi): Bu blok, aşağıdaki [FAZ 3]
-- bloğuyla BİREBİR AYNI decay formülünü uygulayan, HİÇBİR thread
-- tarafından çağrılmayan (yalnızca dışa export edilmiş) bir "hayalet"
-- ikinci kopyaydı -- server/phone_bridge.lua'daki remoteWipe duplikasyonu
-- ile AYNI SINIF hata. Dış bir kaynak `exports.vbs_core_matrix:
-- TickEvidenceDecay()` çağırsaydı, [FAZ 3]'ün KENDİ bağımsız epoch
-- izleyicisinden (ayrı _lastEvidenceDecayEpoch) habersiz İKİNCİ bir erime
-- turu uygulanır, kanıt kalitesi belgelenen tek asimptotik eğriden DAHA
-- HIZLI erirdi. Tek otorite artık aşağıdaki [FAZ 3] bloğudur; bu kopya
-- kaldırıldı.
-- =====================================================================

-- =====================================================================
-- ★ [FAZ 3] SAATLİK ASİMPTOTİK KANIT ERİMESİ
-- value' = value * exp(-0.002 * elapsed_minutes)
-- Saklama eşiğinin altındaki satırlar otonom silinir.
-- Mühürlü (sealed_as_crime_weapon=1) satırlar KORUNUR.
-- =====================================================================

local _EVIDENCE_DECAY_TICK_MS   = (Config.Forensics.EvidenceDecayTickMs or (60 * 60 * 1000))
local _EVIDENCE_DECAY_RATE      = tonumber(Config.Forensics.EvidenceDecayRate) or 0.002
local _EVIDENCE_RETENTION_FLOOR = tonumber(Config.Forensics.EvidenceDecayRetentionThreshold) or 0.02
local _lastEvidenceDecayEpoch   = nil

function Matrix.Forensics.TickEvidenceDecayHourly()
    local nowEpoch = os.time()
    local deltaMinutes

    if _lastEvidenceDecayEpoch then
        deltaMinutes = math.max((nowEpoch - _lastEvidenceDecayEpoch) / 60.0, 0.0)
    else
        -- Restart fallback: tam 1 tick = 60 dakika
        deltaMinutes = _EVIDENCE_DECAY_TICK_MS / 60000.0
    end
    _lastEvidenceDecayEpoch = nowEpoch

    if deltaMinutes <= 0.0 then return end

    local decayFactor = math.exp(-_EVIDENCE_DECAY_RATE * deltaMinutes)

    local ok, affected = pcall(function()
        return MySQL.update.await([[
            UPDATE matrix_forensic_evidence
            SET striation_quality   = GREATEST(0.0, LEAST(1.0, striation_quality   * ?)),
                fingerprint_quality = GREATEST(0.0, LEAST(1.0, fingerprint_quality * ?))
            WHERE sealed_as_crime_weapon = 0
        ]], { decayFactor, decayFactor })
    end)

    if ok then
        Matrix.Log('FORENSICS',
            '[FAZ 3][ADLİ ERİME] Mühürsüz kanıt delta erimeye tabi (delta=%.2fdk, faktor=%.4f, etkilenen=%s).',
            deltaMinutes, decayFactor, tostring(affected or '?'))
    else
        Matrix.Log('FORENSICS', '[HATA] TickEvidenceDecayHourly UPDATE başarısız (yutuldu).')
    end
end

--- Saklama eşiğinin altına düşen mühürsüz kanıtları otonom imha et.
function Matrix.Forensics.PurgeDecayedEvidence()
    local threshold = _EVIDENCE_RETENTION_FLOOR
    local ok, affected = pcall(function()
        return MySQL.update.await([[
            DELETE FROM matrix_forensic_evidence
            WHERE sealed_as_crime_weapon = 0
              AND striation_quality   < ?
              AND fingerprint_quality < ?
        ]], { threshold, threshold })
    end)
    if not ok then
        Matrix.Log('FORENSICS', '[HATA] PurgeDecayedEvidence DELETE başarısız (yutuldu).')
        return 0
    end
    local n = tonumber(affected) or 0
    if n > 0 then
        Matrix.Log('FORENSICS',
            '[FAZ 3][ADLİ OTONOM SÜPÜRME] %d erimiş kanıt satırı saklama eşiğinin altına indi ve temizlendi.',
            n)
    end
    return n
end

-- Saatlik ticker thread'i — TEK thread, sabit Wait.
CreateThread(function()
    -- İlk çalıştırma: sunucu açılışında hemen ateşleme yok, 1 saat bekle.
    while true do
        Wait(_EVIDENCE_DECAY_TICK_MS)

        local ok1, err1 = pcall(Matrix.Forensics.TickEvidenceDecayHourly)
        if not ok1 then
            Matrix.Log('FORENSICS', '[HATA] Saatlik TickEvidenceDecayHourly başarısız (yutuldu): %s', tostring(err1))
        end

        local ok2, err2 = pcall(Matrix.Forensics.PurgeDecayedEvidence)
        if not ok2 then
            Matrix.Log('FORENSICS', '[HATA] Saatlik PurgeDecayedEvidence başarısız (yutuldu): %s', tostring(err2))
        end
    end
end)

exports('TickEvidenceDecayHourly', function() return Matrix.Forensics.TickEvidenceDecayHourly() end)
exports('PurgeDecayedEvidence',    function() return Matrix.Forensics.PurgeDecayedEvidence() end)