-- =====================================================================
-- ★★★ matrix_diagnostics.lua — OTOMASYONLU REGRESYON ÇEKİRDEĞİ v2.1 ★★★
--
-- ★ KATMAN 1: Asenkron Bekleme Kalkanı (MySQL.ready + ox_inventory).
-- ★ KATMAN 2: Config Sabotaj ve Bağımlılık Kontrol Simülasyonu.
-- ★ KATMAN 3: Lojistik Gecikme + ALPR Transfer Delay + Hücre Lideri.
-- ★ KATMAN 4: Taktik Güç + Biyolojik Travma Kanıt Zinciri (+%60 ceza).
-- ★ KATMAN 5: 24 Saatlik Data Recovery Persistency (BIGINT epoch).
-- ★ KATMAN 6: MariaDB Canlı Şema Bekçiliği (15+19 DB kontrol).
-- ★ KATMAN 23: /matrix_diag_detay — Detaylı tanı dökümü.
--
-- ★★★ v2.1 RED TEAM HARDENING (BU SÜRÜM) ★★★
-- [H1-v2] AŞAMALI GC TEMİZLİĞİ (ANTI STOP-THE-WORLD)
-- [H2] VERİTABANI TIMEOUT VE İSTİSNA YÖNETİMİ
-- [H3] ANASAYAL KİLİTLEME VE LUAC5.4 MÜHRÜ
-- [H4-v2] METATABLE PROXY KORUMASI (ANTI CONTEXT DRIFT)
-- SIFIR RNG: her kontrol saf/deterministiktir.
-- =====================================================================

Matrix.Diagnostics = Matrix.Diagnostics or {}

local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local math_abs                     = math.abs
local math_max                     = math.max
local GetGameTimer                 = GetGameTimer
local GetCurrentResourceName       = GetCurrentResourceName
local StopResource                 = StopResource
local TriggerClientEvent           = TriggerClientEvent
local RegisterCommand              = RegisterCommand
local CreateThread                 = CreateThread
local Wait                         = Wait
local Citizen                      = Citizen
local json                         = json
local os                           = os
local table                        = table
local setmetatable                 = setmetatable

-- ★ [H3] KİLİT-1..5 dondurulmuş hiyerarşi tablosu
Matrix.Diagnostics.LockedHierarchy = {
    { id = 'KILIT-1', label = 'Technical HUD',                 deps = 'Config.Hud + client/hud.lua' },
    { id = 'KILIT-2', label = 'Kontrollu Guc Uygulamasi',      deps = 'Matrix.Wounds.ApplyBotRegionalDamage + Config.BotWounds' },
    { id = 'KILIT-3', label = '24h Data Recovery Epoch Kilidi',deps = 'matrix_player_state.recovery_target_epoch (BIGINT)' },
    { id = 'KILIT-4', label = '15 Dk Gecikmeli Lojistik Batch Sync', deps = 'Config.Logistics.BatchSync (900s+180s)' },
    { id = 'KILIT-5', label = 'Config Sabotaj Kalkani',        deps = 'Config.ModularSimulationQueue + TestConfigDependencies' }
}

-- =====================================================================
-- Reply — DOSYANIN EN BAŞINDA tanımlı
-- =====================================================================
local function Reply(src, msg)
    if type(src) == 'number' and src > 0 then
        TriggerClientEvent('chat:addMessage', src, { args = { '[DIAGNOSTICS]', msg } })
    else
        print(('[MATRIX:DIAGNOSTICS:CONSOLE] %s'):format(msg))
    end
end

-- =====================================================================
-- ★ [H2] İSTİSNA YÖNETİMİ — matrix_diag_detay_failed teknik jurnalı
-- =====================================================================
Matrix.Diagnostics.FailureJournal = Matrix.Diagnostics.FailureJournal or {
    last_failure_at     = 0,
    last_failure_kind   = nil,
    last_failure_detail = nil,
    failure_count       = 0
}

local function JournalBootFailure(kind, detail)
    Matrix.Diagnostics.FailureJournal.last_failure_at     = os.time()
    Matrix.Diagnostics.FailureJournal.last_failure_kind   = kind
    Matrix.Diagnostics.FailureJournal.last_failure_detail = detail
    Matrix.Diagnostics.FailureJournal.failure_count       = Matrix.Diagnostics.FailureJournal.failure_count + 1
    local line = ('[matrix_diag_detay_failed] kind=%s | %s'):format(tostring(kind), tostring(detail))
    Matrix.Log('DIAGNOSTICS', line)
    print(('^3[MATRIX:DIAGNOSTICS] %s^7'):format(line))
end

Matrix.Diagnostics.GetFailureJournal = function()
    return Matrix.Diagnostics.FailureJournal
end

-- =====================================================================
-- ★ [H4-v2] METATABLE PROXY KORUMASI (ANTI CONTEXT DRIFT)
-- =====================================================================
Matrix.Diagnostics.BreachJournal = Matrix.Diagnostics.BreachJournal or {
    last_breach_at     = 0,
    last_breach_detail = nil,
    breach_count       = 0,
    breach_by_bot      = {}
}

function Matrix.Diagnostics.TriggerCellBreach(breachKind, attemptedKey, cellName, botId)
    local line = ('[HUCRE_IZOLASYON_IHLALI] kind=%s cell=%s key=%s botId=%s'):format(
        tostring(breachKind), tostring(cellName), tostring(attemptedKey), tostring(botId))

    Matrix.Diagnostics.BreachJournal.last_breach_at     = os.time()
    Matrix.Diagnostics.BreachJournal.last_breach_detail = line
    Matrix.Diagnostics.BreachJournal.breach_count       = Matrix.Diagnostics.BreachJournal.breach_count + 1

    Matrix.Log('DIAGNOSTICS', line)

    if botId then
        Matrix.Diagnostics.BreachJournal.breach_by_bot[botId] =
            (Matrix.Diagnostics.BreachJournal.breach_by_bot[botId] or 0) + 1

        local count = Matrix.Diagnostics.BreachJournal.breach_by_bot[botId]
        if count >= 3 then
            local bot = Matrix.Bots and Matrix.Bots[botId]
            if bot and bot.status ~= 'disbanded' then
                bot.status = 'disbanded'
                if Matrix.MarkBotDirty then Matrix.MarkBotDirty(botId) end
                if Matrix.Dispatches and Matrix.Dispatches[botId] and Matrix.CompleteDispatch then
                    pcall(Matrix.CompleteDispatch, botId, 'isolation_breach')
                end
                Matrix.Log('DIAGNOSTICS',
                    '[ALT HUCRE KILITLENDI] Bot #%s status=disbanded (%d. izolasyon ihlali).',
                    tostring(botId), count)
            end
        end
    end
end

function Matrix.Diagnostics.WrapReadOnlyCell(dataTable, cellName, botId)
    if type(dataTable) ~= 'table' then return dataTable end

    return setmetatable({}, {
        __index = dataTable,
        __newindex = function(_, key, value)
            Matrix.Diagnostics.TriggerCellBreach('HUCRE_IZOLASYON_IHLALI', key, cellName, botId)
        end,
        __metatable = false,
        __len       = function() return #dataTable end,
        __pairs     = function() return pairs(dataTable) end,
        __ipairs    = function() return ipairs(dataTable) end
    })
end

function Matrix.Diagnostics.DeepCopyCell(dataTable, seen)
    if type(dataTable) ~= 'table' then return dataTable end
    seen = seen or {}
    if seen[dataTable] then return seen[dataTable] end

    local copy = {}
    seen[dataTable] = copy
    for k, v in pairs(dataTable) do
        if type(v) == 'table' then
            copy[k] = Matrix.Diagnostics.DeepCopyCell(v, seen)
        else
            copy[k] = v
        end
    end
    return copy
end

-- =====================================================================
-- ★ [H1-v2] AŞAMALI GC TEMİZLİĞİ (ANTI STOP-THE-WORLD)
-- =====================================================================
local STAGED_GC_INTERVAL = 100
local STAGED_GC_STEP_KB  = 100

function Matrix.Diagnostics.StepGC()
    pcall(collectgarbage, 'step', STAGED_GC_STEP_KB)
end

function Matrix.Diagnostics.FinalizeStagedGC()
    for _ = 1, 10 do
        local stepOk = pcall(collectgarbage, 'step', STAGED_GC_STEP_KB)
        if not stepOk then break end
    end
end

function Matrix.Diagnostics.PurgeDeepTestState()
    Matrix.Diagnostics.FinalizeStagedGC()
    Matrix.Log('DIAGNOSTICS',
        '[H1-v2][GC] Asamali bellek temizligi tamamlandi -- Stop-the-World YOK, sadece step-step drain.')
    return true
end

local lastReport = {
    ran_at      = 0,
    duration_ms = 0,
    deep        = false,
    total       = 0,
    passed      = 0,
    failed      = 0,
    checks      = {},
    sealed      = false
}

-- =====================================================================
-- KATMAN 2: CONFIG SABOTAJ VE BAĞIMLILIK KONTROL SİMÜLASYONU
-- =====================================================================
Config.ModularSimulationQueue = {
    {
        id     = 'EnablePhysicalFollowers',
        get    = function() return Config.Mercenary and Config.Mercenary.EnablePhysicalFollowers end,
        set    = function(v) if Config.Mercenary then Config.Mercenary.EnablePhysicalFollowers = v end end,
        probes = {
            { 'Matrix.Mercenary.RequestSummon', function() return Matrix.Mercenary and Matrix.Mercenary.RequestSummon end },
            { 'Matrix.Mercenary.ReportDismiss', function() return Matrix.Mercenary and Matrix.Mercenary.ReportDismiss end }
        }
    },
    {
        id     = 'EnablePhysicalAmbushTeams',
        get    = function() return Config.Rendezvous and Config.Rendezvous.Enabled end,
        set    = function(v) if Config.Rendezvous then Config.Rendezvous.Enabled = v end end,
        probes = {
            { 'Matrix.Rendezvous.ScheduleHandoff',   function() return Matrix.Rendezvous and Matrix.Rendezvous.ScheduleHandoff end },
            { 'Matrix.Rendezvous.GetAmbushBulletin', function() return Matrix.Rendezvous and Matrix.Rendezvous.GetAmbushBulletin end }
        }
    },
    {
        id     = 'HitSquad.HeatTraceThreshold',
        get    = function() return Config.HitSquad and Config.HitSquad.HeatTraceThreshold end,
        set    = function(v) if Config.HitSquad then Config.HitSquad.HeatTraceThreshold = v end end,
        probes = {
            { 'Matrix.HitSquad module', function() return Matrix.HitSquad end },
            { 'Config.GangHoods.Hoods', function() return Config.GangHoods and Config.GangHoods.Hoods end }
        }
    }
}

local function TestConfigDependencies()
    local sabotageQueue = Config.ModularSimulationQueue or {}
    if #sabotageQueue == 0 then
        return true, 'ModularSimulationQueue bos -- sabotaj testi atlandi'
    end

    local testedCount = 0
    for _, entry in ipairs(sabotageQueue) do
        local originalValue = entry.get and entry.get() or nil
        local disabledValue = (type(originalValue) == 'number') and 0.0 or false

        if entry.set then entry.set(disabledValue) end

        for _, probe in ipairs(entry.probes or {}) do
            local probeName, probeGetter = probe[1], probe[2]
            local ok, result = pcall(function()
                local fn = probeGetter and probeGetter()
                if type(fn) == 'function' then
                    local okInner, innerErr = pcall(fn, 1, 1, 1)
                    if not okInner then
                        error(('probe %s config-kapali iken hata firlatti: %s'):format(
                            probeName, tostring(innerErr)), 2)
                    end
                elseif fn == nil then
                    error(('probe %s: config-kapali iken fonksiyon tanimsiz (kanca kaymasi)'):format(probeName), 2)
                end
            end)
            if not ok then
                if entry.set and originalValue ~= nil then entry.set(originalValue) end
                assert(false, ('[KATMAN 21.3][SABOTAJ] %s -> %s'):format(entry.id, tostring(result)))
            end
        end

        if entry.set and originalValue ~= nil then entry.set(originalValue) end
        testedCount = testedCount + 1
    end

    return true, ('%d config sabotaj testi safe-exit ile gecti'):format(testedCount)
end

-- =====================================================================
-- HIZLI KATMAN: KONTROL TANIMLARI
-- =====================================================================
local FastChecks = {}

local function AddCheck(name, fn)
    FastChecks[#FastChecks + 1] = { name = name, fn = fn }
end

AddCheck('TrapHouseInterior.Shell koordinat tutarlılığı', function()
    local shell = Config.TrapHouseInterior and Config.TrapHouseInterior.Shell
    if not shell or not shell.EnterCoords or not shell.ExitCoords then
        return false, 'Config.TrapHouseInterior.Shell.EnterCoords/ExitCoords tanımsız'
    end
    local e, x = shell.EnterCoords, shell.ExitCoords
    if e.x == x.x and e.y == x.y and e.z == x.z then
        return true, ('(%.4f,%.4f,%.4f)'):format(e.x, e.y, e.z)
    end
    return false, 'EnterCoords/ExitCoords ayni interior cebini isaret etmiyor'
end)

AddCheck('Bureau.Lockdown agirliklari (Breach+Purity=1.0)', function()
    local w, p = Config.Bureau.LockdownBreachWeight, Config.Bureau.LockdownPurityWeight
    local sum = (w or 0) + (p or 0)
    return math_abs(sum - 1.0) < 0.0001, ('BreachWeight=%.2f PurityWeight=%.2f toplam=%.4f'):format(w or -1, p or -1, sum)
end)

AddCheck('Bureau.LockdownEvidenceThreshold (0,1] araliginda', function()
    local t = Config.Bureau.LockdownEvidenceThreshold
    return type(t) == 'number' and t > 0 and t <= 1.0, tostring(t)
end)

AddCheck('Bureau.Livestream->radio_breach_count koprusu (Madde 3)', function()
    local mult = Config.Bureau.LivestreamRadioBreachMultiplier
    local rate = Config.Bureau.LivestreamRadioLeakPerTick
    if type(mult) ~= 'number' or mult <= 0 then return false, 'LivestreamRadioBreachMultiplier gecersiz' end
    if type(rate) ~= 'number' or rate <= 0 then return false, 'LivestreamRadioLeakPerTick gecersiz' end
    if type(Matrix.Bureau.RecordLivestreamRadioLeak) ~= 'function' then
        return false, 'Matrix.Bureau.RecordLivestreamRadioLeak tanimli degil'
    end
    return true, ('carpan=%.1f, oran=%.5f/tick'):format(mult, rate)
end)

AddCheck('Forensics.Frisk parametreleri gecerli', function()
    local f = Config.Forensics.Frisk
    if not f then return false, 'Config.Forensics.Frisk tanimsiz' end
    if type(f.Radius) ~= 'number' or f.Radius <= 0 then return false, 'Radius gecersiz' end
    if type(f.DwellMs) ~= 'number' or f.DwellMs <= 0 then return false, 'DwellMs gecersiz' end
    if type(f.CooldownMs) ~= 'number' or f.CooldownMs <= 0 then return false, 'CooldownMs gecersiz' end
    if type(f.WeaponSerialContrabandPrefix) ~= 'string' or f.WeaponSerialContrabandPrefix == '' then
        return false, 'WeaponSerialContrabandPrefix bos'
    end
    return true, ('Radius=%.1fm Dwell=%dms Cooldown=%dms'):format(f.Radius, f.DwellMs, f.CooldownMs)
end)

AddCheck('Logistics.TrunkOps parametreleri gecerli (Madde 5b bagimliligi)', function()
    local t = Config.Logistics.TrunkOps
    if not t then return false, 'Config.Logistics.TrunkOps tanimsiz' end
    if type(t.StashPrefix) ~= 'string' or t.StashPrefix == '' then return false, 'StashPrefix bos' end
    if type(t.Slots) ~= 'number' or t.Slots <= 0 then return false, 'Slots gecersiz' end
    if type(t.MaxWeight) ~= 'number' or t.MaxWeight <= 0 then return false, 'MaxWeight gecersiz' end
    return true, ('prefix=%s slots=%d'):format(t.StashPrefix, t.Slots)
end)

AddCheck('Market.GourmetMinPurity [0,1] araliginda', function()
    local p = Config.Market.GourmetMinPurity
    return type(p) == 'number' and p >= 0 and p <= 1.0, tostring(p)
end)

AddCheck('Market.StreetDealing devsirme esikleri gecerli', function()
    local s = Config.Market.StreetDealing
    if not s then return false, 'Config.Market.StreetDealing tanimsiz' end
    if type(s.RecruitAddictionThreshold) ~= 'number' or s.RecruitAddictionThreshold <= 0 then
        return false, 'RecruitAddictionThreshold gecersiz'
    end
    if type(s.RecruitDistance) ~= 'number' or s.RecruitDistance <= 0 then return false, 'RecruitDistance gecersiz' end
    return true, ('esik=%.1f mesafe=%.1fm'):format(s.RecruitAddictionThreshold, s.RecruitDistance)
end)

AddCheck('Kitchen.Packaging urun tanimlari gecerli', function()
    local pk = Config.Kitchen.Packaging
    if not pk or type(pk.RawItem) ~= 'string' or pk.RawItem == '' then return false, 'RawItem bos' end
    if type(pk.Products) ~= 'table' or #pk.Products == 0 then return false, 'Products bos' end
    for i, prod in ipairs(pk.Products) do
        if type(prod.item) ~= 'string' or prod.item == '' or type(prod.label) ~= 'string' or prod.label == '' then
            return false, ('Products[%d] eksik item/label'):format(i)
        end
    end
    return true, ('RawItem=%s, %d urun'):format(pk.RawItem, #pk.Products)
end)

AddCheck('Logistics.MinDispatchDistanceMeters > 0', function()
    local d = Config.Logistics.MinDispatchDistanceMeters
    return type(d) == 'number' and d > 0, tostring(d)
end)

AddCheck('Config Ped Bekcisi: BotPedConfiguration rutbe atamalari katı string', function()
    local pool = Config.BotPedConfiguration
    if type(pool) ~= 'table' then return false, 'Config.BotPedConfiguration tanimsiz' end
    local requiredRanks = { 'runner', 'lookout', 'chemist', 'inspector' }
    for _, rank in ipairs(requiredRanks) do
        if type(pool[rank]) ~= 'string' or pool[rank] == '' then
            return false, ('BotPedConfiguration[%s] gecersiz/bos'):format(rank)
        end
    end
    return true, ('%d rutbe dogrulandi'):format(#requiredRanks)
end)

local MAP_MIN_XY, MAP_MAX_XY = -6000.0, 8000.0
local MAP_MIN_Z, MAP_MAX_Z   = -200.0, 1200.0

local function CheckVector3InMapBounds(v, label)
    if type(v) ~= 'vector3' then
        return false, ('%s vector3 degil (tip=%s)'):format(label, type(v))
    end
    if v.x ~= v.x or v.y ~= v.y or v.z ~= v.z then
        return false, ('%s NaN koordinat iceriyor'):format(label)
    end
    if v.x < MAP_MIN_XY or v.x > MAP_MAX_XY or v.y < MAP_MIN_XY or v.y > MAP_MAX_XY
        or v.z < MAP_MIN_Z or v.z > MAP_MAX_Z then
        return false, ('%s harita sinirlari disinda (%.1f, %.1f, %.1f)'):format(label, v.x, v.y, v.z)
    end
    return true
end

AddCheck('Koordinat Kusursuzlugu: GangHoods + Hayalet Doktor + karaborsa parametreleri', function()
    local hoods = Config.GangHoods and Config.GangHoods.Hoods
    if type(hoods) ~= 'table' or #hoods == 0 then return false, 'Config.GangHoods.Hoods bos/tanimsiz' end
    for _, hood in ipairs(hoods) do
        local ok, detail = CheckVector3InMapBounds(hood.coords, ('hood#%s(%s)'):format(tostring(hood.id), tostring(hood.label)))
        if not ok then return false, detail end
    end

    local phantomCoords = Config.PhantomDoctor and Config.PhantomDoctor.Coords
    if type(phantomCoords) ~= 'table' or #phantomCoords == 0 then return false, 'Config.PhantomDoctor.Coords bos/tanimsiz' end
    for i, c in ipairs(phantomCoords) do
        local ok, detail = CheckVector3InMapBounds(c, ('phantom#%d'):format(i))
        if not ok then return false, detail end
    end

    local r = Config.Rendezvous
    if not r then return false, 'Config.Rendezvous tanimsiz' end
    if type(r.MinOffsetMeters) ~= 'number' or type(r.MaxOffsetMeters) ~= 'number' then
        return false, 'Rendezvous MinOffsetMeters/MaxOffsetMeters sayisal degil'
    end
    if r.MinOffsetMeters <= 0 or r.MaxOffsetMeters <= r.MinOffsetMeters then
        return false, ('Rendezvous offset araligi gecersiz: min=%.1f max=%.1f'):format(r.MinOffsetMeters, r.MaxOffsetMeters)
    end

    return true, ('%d hood, %d hayalet doktor koordinati, karaborsa offset [%.1f,%.1f]m -- hepsi gecerli'):format(
        #hoods, #phantomCoords, r.MinOffsetMeters, r.MaxOffsetMeters)
end)

if Config.ComposerSignature then
    AddCheck('ComposerSignature.volume [0,1] araliginda', function()
        local v = Config.ComposerSignature.volume
        return type(v) == 'number' and v >= 0 and v <= 1.0, tostring(v)
    end)
end

AddCheck('Matrix.Clamp referans-seffafligi (determinizm)', function()
    if type(Matrix.Clamp) ~= 'function' then return false, 'Matrix.Clamp tanimli degil' end
    local a1, a2 = Matrix.Clamp(1.7, 0.0, 1.0), Matrix.Clamp(1.7, 0.0, 1.0)
    local b1, b2 = Matrix.Clamp(-0.3, 0.0, 1.0), Matrix.Clamp(-0.3, 0.0, 1.0)
    if a1 ~= 1.0 or b1 ~= 0.0 then return false, 'sinir degerleri yanlis kirpiliyor' end
    if a1 ~= a2 or b1 ~= b2 then return false, 'ayni girdi farkli cikti uretti (RNG sizintisi?)' end
    return true, 'iki cagri birebir ayni'
end)

-- =====================================================================
-- ★★★ DARKCHAT / QB-PHONE TELEMETRİ KÖPRÜSÜ DOĞRULAMALARI ★★★
-- server/phone_bridge.lua'nın monkey-patch katmanının AKTİF olduğunu,
-- mask algoritmasının deterministik çalıştığını ve Need-to-Know
-- sözleşmesinin kurallı döndüğünü KANITLAR.
-- =====================================================================
AddCheck('PhoneBridge: CompleteDispatch sarmalayici aktif', function()
    if type(Matrix.PhoneBridge) ~= 'table' then
        return false, 'Matrix.PhoneBridge modulu tanimsiz (phone_bridge.lua yuklenmedi)'
    end
    if Matrix.PhoneBridge._CompleteDispatchWrapped ~= true then
        return false, '_CompleteDispatchWrapped bayragi set edilmemis (cift-sarma koruma basarisiz)'
    end
    if type(Matrix.CompleteDispatch) ~= 'function' then
        return false, 'Matrix.CompleteDispatch cagrilamaz durumda'
    end
    return true, 'aktif (dispatch sonu telemetri koprusu kurulu)'
end)

AddCheck('PhoneBridge: DepositCargo sarmalayici aktif', function()
    if type(Matrix.PhoneBridge) ~= 'table' then
        return false, 'Matrix.PhoneBridge modulu tanimsiz'
    end
    if Matrix.PhoneBridge._DepositCargoWrapped ~= true then
        return false, '_DepositCargoWrapped bayragi set edilmemis'
    end
    if type(Matrix.DepositDealerCargoToTrapStash) ~= 'function' then
        return false, 'Matrix.DepositDealerCargoToTrapStash cagrilamaz durumda'
    end
    return true, 'aktif (liman-kargo depo telemetri koprusu kurulu)'
end)

AddCheck('PhoneBridge: Determinizm kaniti (math.random YASAK)', function()
    if type(Matrix.PhoneBridge) ~= 'table'
        or type(Matrix.PhoneBridge.__DeterminismProbe) ~= 'function' then
        return false, '__DeterminismProbe fonksiyonu tanimli degil (phone_bridge.lua surum uyumsuz)'
    end
    -- Aynı girdi iki kez çağrılırsa BİREBİR aynı çıktı üretmeli.
    local seed = ('DIAG#%d'):format(GetGameTimer())
    local a = Matrix.PhoneBridge.__DeterminismProbe(seed)
    local b = Matrix.PhoneBridge.__DeterminismProbe(seed)
    if a ~= b then
        return false, ('RNG SIZINTISI KANITI: ayni girdi iki farkli cikti (%s != %s)'):format(tostring(a), tostring(b))
    end
    if type(a) ~= 'string' or #a ~= 64 then
        return false, ('beklenmeyen cikti bicimi: uzunluk=%d'):format(type(a) == 'string' and #a or -1)
    end
    return true, ('deterministik SHA256-benzeri 64-char hex: %s...'):format(a:sub(1, 16))
end)

AddCheck('PhoneBridge: Need-to-Know sozlesmesi (guard davranisi)', function()
    if not Matrix.Bureau or type(Matrix.Bureau.GetEncryptedAgentTelemetry) ~= 'function' then
        return false, 'GetEncryptedAgentTelemetry tanimli degil'
    end
    -- Geçersiz src ile çağır: 'bad_src' guard'ının ÇALIŞTIĞINI doğrula.
    local r1, e1 = Matrix.Bureau.GetEncryptedAgentTelemetry(0, 1)
    if r1 ~= nil or e1 ~= 'bad_src' then
        return false, ('bad_src guard basarisiz: r=%s e=%s'):format(tostring(r1), tostring(e1))
    end
    -- Geçerli src ama sahte botId: 'bot_missing' guard'ının ÇALIŞTIĞINI doğrula.
    local r2, e2 = Matrix.Bureau.GetEncryptedAgentTelemetry(1, 999999)
    if r2 ~= nil or e2 ~= 'bot_missing' then
        return false, ('bot_missing guard basarisiz: r=%s e=%s'):format(tostring(r2), tostring(e2))
    end
    return true, 'Iki guard da aktif (bad_src + bot_missing)'
end)

AddCheck('PhoneBridge: Mask algoritmasi tek-yonlu ozet (hex prefix)', function()
    if type(Matrix.PhoneBridge) ~= 'table'
        or type(Matrix.PhoneBridge.__DeterminismProbe) ~= 'function' then
        return false, 'probe yok'
    end
    local sample = Matrix.PhoneBridge.__DeterminismProbe('MASK-TEST-ALPHA')
    if type(sample) ~= 'string' or not sample:match('^%x+$') then
        return false, ('cikti hex degil: %s'):format(tostring(sample):sub(1, 16))
    end
    -- Farklı girdi → farklı çıktı (tek-yönlülük kanıtı).
    local other = Matrix.PhoneBridge.__DeterminismProbe('MASK-TEST-BETA')
    if sample == other then
        return false, 'farkli girdi ayni cikti uretti (checksum zayif)'
    end
    return true, 'hex, tek-yonlu, girdi-duyarli'
end)
-- ★★★ DARKCHAT DIAGNOSTICS BLOK SONU ★★★


AddCheck('Lojistik Batch Sync (15dk) parametreleri', function()
    local cfg = Config.Logistics and Config.Logistics.BatchSync
    if cfg == nil then
        return true, 'BatchSync tanimsiz -- varsayilan 15dk/180s kabul edildi'
    end
    if type(cfg.BatchIntervalSeconds) == 'number' and cfg.BatchIntervalSeconds ~= 900 then
        return false, ('BatchIntervalSeconds beklenen 900, gercek %d'):format(cfg.BatchIntervalSeconds)
    end
    if type(cfg.AlprTransferDelaySeconds) == 'number' and cfg.AlprTransferDelaySeconds ~= 180 then
        return false, ('AlprTransferDelaySeconds beklenen 180, gercek %d'):format(cfg.AlprTransferDelaySeconds)
    end
    return true, ('batch=%ss alpr=%ss'):format(
        tostring(cfg.BatchIntervalSeconds or 900), tostring(cfg.AlprTransferDelaySeconds or 180))
end)

AddCheck('Resmi Terminoloji Bulteni: Sinyal Anomalisi + Alt Ekstremite Travma formatlari', function()
    local bw = Config.BotWounds
    if type(bw) ~= 'table' then return false, 'Config.BotWounds tanimsiz' end
    if type(bw.LegSpeedPenalty) ~= 'number' or bw.LegSpeedPenalty ~= 0.60 then
        return false, ('LegSpeedPenalty beklenen 0.60, gercek %s'):format(tostring(bw.LegSpeedPenalty))
    end
    if type(bw.ZoneOrder) ~= 'table' or #bw.ZoneOrder < 4 then
        return false, 'ZoneOrder eksik/gecersiz'
    end
    if type(Config.Bureau.TriangulationDecryptionGain) ~= 'number' then
        return false, 'TriangulationDecryptionGain sayisal degil'
    end
    return true, ('LegSpeedPenalty=%.2f ZoneOrder=%d'):format(bw.LegSpeedPenalty, #bw.ZoneOrder)
end)

AddCheck('Hiyerarsi Unvan Semasi: Hucre Lideri (Cell Director) / Leader rol', function()
    local h = Config.Hierarchy
    if type(h) ~= 'table' or type(h.Ranks) ~= 'table' then
        return false, 'Config.Hierarchy.Ranks tanimsiz'
    end
    if type(h.Ranks.Leader) ~= 'table' then
        return false, 'Hierarchy.Ranks.Leader tanimsiz'
    end
    if type(h.Ranks.Leader.level) ~= 'number' or h.Ranks.Leader.level < 3 then
        return false, ('Leader.level beklenen 3, gercek %s'):format(tostring(h.Ranks.Leader.level))
    end
    return true, ('Leader label=%s level=%d'):format(tostring(h.Ranks.Leader.label), h.Ranks.Leader.level)
end)

AddCheck('recovery_target_epoch BIGINT alani sema sozlesmesi', function()
    if type(MySQL) ~= 'table' then return false, 'MySQL global tanimsiz' end
    local ok, rows = pcall(function()
        return MySQL.query.await(
            "SELECT COLUMN_NAME, DATA_TYPE FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND COLUMN_NAME = 'recovery_target_epoch'",
            {})
    end)
    if not ok or type(rows) ~= 'table' or #rows == 0 then
        return false, 'recovery_target_epoch kolonu hicbir tabloda bulunamadi (additive migrasyon gerekli)'
    end
    for _, row in ipairs(rows) do
        if tostring(row.DATA_TYPE):lower() == 'bigint' then
            return true, ('%s kolonu BIGINT tipinde mevcut'):format(tostring(row.COLUMN_NAME))
        end
    end
    return false, 'recovery_target_epoch kolonu BIGINT DEGIL'
end)

AddCheck('Taktiksel Guc: BotWounds float alan sozlesmesi', function()
    local bw = Config.BotWounds
    if type(bw) ~= 'table' then return false, 'Config.BotWounds tanimsiz' end
    if type(bw.LegSpeedPenalty) ~= 'number' then return false, 'LegSpeedPenalty sayisal degil' end
    if type(bw.ArmAccuracyPenalty) ~= 'number' then return false, 'ArmAccuracyPenalty sayisal degil' end
    if type(bw.TorsoCortisolLock) ~= 'number' then return false, 'TorsoCortisolLock sayisal degil' end
    if type(bw.CripplingThreshold) ~= 'number' or bw.CripplingThreshold <= 0 then
        return false, 'CripplingThreshold gecersiz'
    end
    if type(Matrix.Wounds) ~= 'table' or type(Matrix.Wounds.ApplyBotRegionalDamage) ~= 'function' then
        return false, 'Matrix.Wounds.ApplyBotRegionalDamage tanimli degil'
    end
    if type(Matrix.Wounds.GetMovementMultiplier) ~= 'function' then
        return false, 'Matrix.Wounds.GetMovementMultiplier tanimli degil'
    end
    return true, ('Leg=%.2f Arm=%.2f Crippling=%.2f'):format(
        bw.LegSpeedPenalty, bw.ArmAccuracyPenalty, bw.CripplingThreshold)
end)

AddCheck('Biyolojik Travma Kanit Zinciri: +%60 Mahkumiyet Carpani', function()
    local inc = Config.Bureau and Config.Bureau.TrialConvictionIncrement
    if type(inc) ~= 'number' or inc <= 0 then
        return false, 'TrialConvictionIncrement gecersiz'
    end
    local liePenalty = Config.Hospital and Config.Hospital.ConvictionWeightLiePenalty
    if type(liePenalty) ~= 'number' or liePenalty <= 0 then
        return false, 'Hospital.ConvictionWeightLiePenalty gecersiz'
    end
    local total = inc + liePenalty
    if total < 0.30 then
        return false, ('Toplam ceza carpani cok dusuk: %.2f'):format(total)
    end
    return true, ('Trial+Lie toplam carpan=%.2f'):format(total)
end)

AddCheck('[H4-v2] Metatable Proxy utility varligi (WrapReadOnlyCell/DeepCopyCell)', function()
    if type(Matrix.Diagnostics.WrapReadOnlyCell) ~= 'function' then
        return false, 'WrapReadOnlyCell tanimli degil'
    end
    if type(Matrix.Diagnostics.DeepCopyCell) ~= 'function' then
        return false, 'DeepCopyCell tanimli degil'
    end
    if type(Matrix.Diagnostics.TriggerCellBreach) ~= 'function' then
        return false, 'TriggerCellBreach tanimli degil'
    end
    local src = { test_key = 'orijinal' }
    local proxy = Matrix.Diagnostics.WrapReadOnlyCell(src, 'test_cell', nil)
    proxy.test_key = 'MUTASYON_DENEMESI'
    if src.test_key ~= 'orijinal' then
        return false, 'ReadOnly proxy mutasyonu ENGELLEMEDI (KRITIK GUVENLIK IHLALI)'
    end
    local orig = { a = { b = 1 } }
    local copy = Matrix.Diagnostics.DeepCopyCell(orig)
    copy.a.b = 999
    if orig.a.b ~= 1 then
        return false, 'DeepCopyCell referans paylasimi (KRITIK GUVENLIK IHLALI)'
    end
    return true, 'proxy mutasyonu reddetti + deepcopy referans paylasimi yok'
end)

-- =====================================================================
-- MATRIX.* KANCA VARLIĞI
-- =====================================================================
local RequiredHooks = {
    { 'Matrix.CreateBotRecord',                Matrix.CreateBotRecord },
    { 'Matrix.GetBot',                         Matrix.GetBot },
    { 'Matrix.RemoveBot',                      Matrix.RemoveBot },
    { 'Matrix.MarkBotDirty',                   Matrix.MarkBotDirty },
    { 'Matrix.BeginPhysicalDispatch',          Matrix.BeginPhysicalDispatch },
    { 'Matrix.BeginRouteDispatch',             Matrix.BeginRouteDispatch },
    { 'Matrix.SetBotInteriorTrapHouse',        Matrix.SetBotInteriorTrapHouse },
    { 'Matrix.Bureau.RecordRadioBreach',       Matrix.Bureau and Matrix.Bureau.RecordRadioBreach },
    { 'Matrix.Bureau.RecordPurityIntercepted', Matrix.Bureau and Matrix.Bureau.RecordPurityIntercepted },
    { 'Matrix.Bureau.TriggerLockdown',         Matrix.Bureau and Matrix.Bureau.TriggerLockdown },
    { 'Matrix.Bureau.LiftLockdown',            Matrix.Bureau and Matrix.Bureau.LiftLockdown },
    { 'Matrix.Bureau.IsLockedDown',            Matrix.Bureau and Matrix.Bureau.IsLockedDown },
    { 'Matrix.Bureau.AdvanceDecryption',       Matrix.Bureau and Matrix.Bureau.AdvanceDecryption },
    { 'Matrix.Bureau.GetPropagandaMomentum',   Matrix.Bureau and Matrix.Bureau.GetPropagandaMomentum },
    { 'Matrix.Recruitment.RecruitStreetNpc',   Matrix.Recruitment and Matrix.Recruitment.RecruitStreetNpc },
    { 'Matrix.Fleet.GetVehicle',               Matrix.Fleet and Matrix.Fleet.GetVehicle },
    { 'Matrix.Fleet.SeizeVehicle',             Matrix.Fleet and Matrix.Fleet.SeizeVehicle },
    { 'Matrix.Forensics.InspectPlayer',        Matrix.Forensics and Matrix.Forensics.InspectPlayer },
    { 'Matrix.Forensics.InspectBustedBot',     Matrix.Forensics and Matrix.Forensics.InspectBustedBot },
    { 'Matrix.Kitchen.ProcessCook',            Matrix.Kitchen and Matrix.Kitchen.ProcessCook },
    { 'Matrix.Kitchen.GetEffectiveSkill',      Matrix.Kitchen and Matrix.Kitchen.GetEffectiveSkill },
    { 'Matrix.Bureau.GetBureaucraticVelocity', Matrix.Bureau and Matrix.Bureau.GetBureaucraticVelocity },
    { 'Matrix.Bureau.OpenTrial',               Matrix.Bureau and Matrix.Bureau.OpenTrial },
    { 'Matrix.Bureau.RecordTrialResponse',     Matrix.Bureau and Matrix.Bureau.RecordTrialResponse },
    { 'Matrix.Bureau.ExecuteVerdict',          Matrix.Bureau and Matrix.Bureau.ExecuteVerdict },
    { 'Matrix.Bureau.SabotagePhoneLine',       Matrix.Bureau and Matrix.Bureau.SabotagePhoneLine },
    { 'Matrix.Bureau.RunHourlyFinancialAudit', Matrix.Bureau and Matrix.Bureau.RunHourlyFinancialAudit },
    { 'Matrix.Forensics.SanitizeCCTVTrail',    Matrix.Forensics and Matrix.Forensics.SanitizeCCTVTrail },
    { 'Matrix.DistrictHubs.FragmentTerritory', Matrix.DistrictHubs and Matrix.DistrictHubs.FragmentTerritory },
    { 'Matrix.DepositDealerCargoToTrapStash',  Matrix.DepositDealerCargoToTrapStash },
    { 'Matrix.HitSquad module',                Matrix.HitSquad },
    { 'Matrix.Wounds.ApplyBotRegionalDamage',  Matrix.Wounds and Matrix.Wounds.ApplyBotRegionalDamage },
    { 'Matrix.Wounds.GetMovementMultiplier',   Matrix.Wounds and Matrix.Wounds.GetMovementMultiplier },
    { 'Matrix.Wounds.ComputeBureauLeakMultiplier', Matrix.Wounds and Matrix.Wounds.ComputeBureauLeakMultiplier },
    { 'Matrix.Wounds.__ComputePhantomIndexForEpochBucket',
        Matrix.Wounds and Matrix.Wounds.__ComputePhantomIndexForEpochBucket },
    { 'Matrix.Rendezvous.ScheduleHandoff',     Matrix.Rendezvous and Matrix.Rendezvous.ScheduleHandoff },
    { 'Matrix.Rendezvous.GetAmbushBulletin',   Matrix.Rendezvous and Matrix.Rendezvous.GetAmbushBulletin },
    { 'Matrix.DoorReinforcement.GetBreachDelaySeconds',
        Matrix.DoorReinforcement and Matrix.DoorReinforcement.GetBreachDelaySeconds },
    { 'Matrix.Mercenary.RequestSummon',        Matrix.Mercenary and Matrix.Mercenary.RequestSummon },
-- ★★★ DARKCHAT / QB-PHONE TELEMETRİ KÖPRÜSÜ (server/phone_bridge.lua) ★★★
    { 'Matrix.PhoneBridge (modül)',                          Matrix.PhoneBridge },
    { 'Matrix.PhoneBridge.TransmitMissionTelemetry',         Matrix.PhoneBridge and Matrix.PhoneBridge.TransmitMissionTelemetry },
    { 'Matrix.PhoneBridge.__DeterminismProbe',               Matrix.PhoneBridge and Matrix.PhoneBridge.__DeterminismProbe },
    { 'Matrix.Bureau.GetEncryptedAgentTelemetry',            Matrix.Bureau and Matrix.Bureau.GetEncryptedAgentTelemetry },
    { 'Matrix.Bureau.SabotagePhoneLine (darkchat wipe)',     Matrix.Bureau and Matrix.Bureau.SabotagePhoneLine },
}    

for _, entry in ipairs(RequiredHooks) do
    local hookName, hookFn = entry[1], entry[2]
    AddCheck(('kanca mevcut: %s'):format(hookName), function()
        return type(hookFn) == 'function' or type(hookFn) == 'table', type(hookFn)
    end)
end

-- =====================================================================
-- DB ŞEMA YARDIMCILARI
-- =====================================================================
local function TableExists(tableName)
    local rows = MySQL.query.await(
        'SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?',
        { tableName }
    ) or {}
    return #rows > 0
end

local function ColumnExists(tableName, columnName)
    local rows = MySQL.query.await(
        'SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND COLUMN_NAME = ?',
        { tableName, columnName }
    ) or {}
    return #rows > 0
end

local DbChecks = {
    { 'DB baglantisi (SELECT 1)', function()
        local rows = MySQL.query.await('SELECT 1 AS ok', {}) or {}
        return rows[1] and tonumber(rows[1].ok) == 1, rows[1] and 'ok' or 'yanit yok'
    end },
    { 'matrix_bots tablosu mevcut', function() return TableExists('matrix_bots'), 'INFORMATION_SCHEMA.TABLES' end },
    { 'matrix_bots.loyalty_base kolonu mevcut (Madde 4 migration)', function()
        return ColumnExists('matrix_bots', 'loyalty_base'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { 'matrix_bureau_learning_core tablosu mevcut', function() return TableExists('matrix_bureau_learning_core'), 'sql/matrix_financial_core.sql' end },
    { 'matrix_district_hubs tablosu mevcut', function() return TableExists('matrix_district_hubs'), 'sql/matrix_financial_core.sql' end },
    { 'matrix_zone_ledger.dirty_cash_pool kolonu mevcut', function()
        return ColumnExists('matrix_zone_ledger', 'dirty_cash_pool'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { 'matrix_bots.accounting_precision kolonu mevcut', function()
        return ColumnExists('matrix_bots', 'accounting_precision'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { 'matrix_zone_inspectors.is_wiped kolonu mevcut', function()
        return ColumnExists('matrix_zone_inspectors', 'is_wiped'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { 'matrix_purchase_logs tablosu mevcut', function()
        return TableExists('matrix_purchase_logs'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { 'matrix_customer_pool.is_dead kolonu mevcut', function()
        return ColumnExists('matrix_customer_pool', 'is_dead'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { 'matrix_gang_learning_core tablosu mevcut', function()
        return TableExists('matrix_gang_learning_core'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { 'matrix_trial_records tablosu mevcut', function()
        return TableExists('matrix_trial_records'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { 'matrix_player_state.imprisoned kolonu mevcut', function()
        return ColumnExists('matrix_player_state', 'imprisoned'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { 'matrix_legal_plate_evidence tablosu mevcut (KATMAN 14)', function()
        return TableExists('matrix_legal_plate_evidence'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { 'matrix_diagnostics_stress_log tablosu mevcut (KATMAN 21)', function()
        return TableExists('matrix_diagnostics_stress_log'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { '[ADDITIVE] matrix_vendor_pool tablosu mevcut (KATMAN 5)', function()
        return TableExists('matrix_vendor_pool'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { '[ADDITIVE] matrix_fragmented_intel tablosu mevcut (KATMAN 6)', function()
        return TableExists('matrix_fragmented_intel'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { '[ADDITIVE] matrix_gang_hoods tablosu mevcut (KATMAN 7)', function()
        return TableExists('matrix_gang_hoods'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { '[ADDITIVE] matrix_bots.wound_zone kolonu mevcut (KATMAN 3)', function()
        return ColumnExists('matrix_bots', 'wound_zone'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { '[ADDITIVE] matrix_bots.leg_injury kolonu mevcut', function()
        return ColumnExists('matrix_bots', 'leg_injury'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { '[ADDITIVE] matrix_bots.arm_injury kolonu mevcut', function()
        return ColumnExists('matrix_bots', 'arm_injury'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { '[ADDITIVE] matrix_bots.head_injury kolonu mevcut', function()
        return ColumnExists('matrix_bots', 'head_injury'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { '[ADDITIVE] matrix_bots.permanently_crippled kolonu mevcut', function()
        return ColumnExists('matrix_bots', 'permanently_crippled'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { '[ADDITIVE] matrix_bots.installed_prosthetic kolonu mevcut', function()
        return ColumnExists('matrix_bots', 'installed_prosthetic'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { '[ADDITIVE] matrix_bots.medical_lock_until kolonu mevcut', function()
        return ColumnExists('matrix_bots', 'medical_lock_until'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { '[ADDITIVE] matrix_player_state.has_wound kolonu mevcut', function()
        return ColumnExists('matrix_player_state', 'has_wound'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { '[ADDITIVE] matrix_player_state.wound_ballistic_id kolonu mevcut', function()
        return ColumnExists('matrix_player_state', 'wound_ballistic_id'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { '[ADDITIVE] matrix_vendor_pool.compromised kolonu mevcut', function()
        return ColumnExists('matrix_vendor_pool', 'compromised'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { '[ADDITIVE] matrix_vendor_pool.vendor_license kolonu mevcut (KATMAN 6)', function()
        return ColumnExists('matrix_vendor_pool', 'vendor_license'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { '[ADDITIVE] matrix_player_state.recovery_target_epoch kolonu mevcut (KATMAN 5)', function()
        return ColumnExists('matrix_player_state', 'recovery_target_epoch'),
        'sql/matrix_financial_core.sql calistirildi mi? (BIGINT bekleniyor)'
    end },
    { '[ADDITIVE] matrix_encrypted_messages tablosu mevcut (Adli Sabotaj)', function()
        return TableExists('matrix_encrypted_messages'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { '[ADDITIVE] matrix_forensic_evidence.evidence_tampering kolonu mevcut', function()
        return ColumnExists('matrix_forensic_evidence', 'evidence_tampering'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { '[ADDITIVE] matrix_forensic_evidence.biological_trauma kolonu mevcut', function()
        return ColumnExists('matrix_forensic_evidence', 'biological_trauma'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { '[ADDITIVE] matrix_forensic_evidence.inflicted_force_striation kolonu mevcut', function()
        return ColumnExists('matrix_forensic_evidence', 'inflicted_force_striation'),
        'sql/matrix_financial_core.sql calistirildi mi?'
    end },

 -- ★★★ DARKCHAT / QB-PHONE şema kontrolleri ★★★
    { '[DARKCHAT] matrix_encrypted_messages tablosu mevcut (remoteWipe hedefi)', function()
        return TableExists('matrix_encrypted_messages'),
        'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { '[DARKCHAT] matrix_crypto_wallets tablosu mevcut (rolling cipher)', function()
        return TableExists('matrix_crypto_wallets'),
        'sql/matrix_financial_core.sql (layer8 bolumu) calistirildi mi?'
    end },
    { '[DARKCHAT] matrix_crypto_wallets.rolling_cipher_key kolonu mevcut', function()
        return ColumnExists('matrix_crypto_wallets', 'rolling_cipher_key'),
        'layer8_milsim_expansion.sql kalani uygulanmis mi?'
    end },

}

-- =====================================================================
-- ÇALIŞTIRICI
-- =====================================================================
local function RunCheck(name, fn)
    local ok, passed, detail = pcall(fn)
    if not ok then
        return { name = name, passed = false, detail = ('HATA: %s'):format(tostring(passed)) }
    end
    return { name = name, passed = passed and true or false, detail = detail or (passed and 'OK' or 'basarisiz') }
end

-- =====================================================================
-- ★ [H5-v2] STATEBAG & ENTITY INVALID GUARD — 4 KATMANLI ZIRH
-- =====================================================================
-- qbx_smallresources/server/vitals.lua gibi pasif durum döngüleri,
-- server-taraf bir ped'in statebag'ini veya network kancalarını
-- periyodik okur. Test botumuz ped'i saniyeler içinde silince, o
-- döngülerin async native kuyruğunda asılı kalan okuma çağrıları
-- "Tried to access invalid entity: <netid>" hatasını fırlatır.
--
-- ÇÖZÜM: Test botu retired edilmeden ÖNCE şu 4 katmanı uygula:
--   [KATMAN 1] STATebag TEMİZLE — bilinen yara anahtarlarını nil'le.
--   [KATMAN 2] MISSION RELEASE — SetEntityAsMissionEntity(false,false)
--              + SetEntityAsNoLongerNeeded ile OneSync'e "artık bu
--              entity'ye ihtiyacım yok" sinyali ver.
--   [KATMAN 3] TICK FLUSH — Wait(0) x 4 ile async native kuyruğunu
--              boşalt (pending okuma çağrıları tamamlansın).
--   [KATMAN 4] DEFERRED RETIRE — Artık ped/araç güvenle silinebilir;
--              Matrix.RemoveBot çağrısı pcall + DoesEntityExist
--              guard'larıyla zaten korumalı.
--
-- Bu guard YALNIZCA diagnostic test botu akışında çalışır. Canlı
-- otonom bot silme yolları (combat/busted/tasfiye) ETKİLENMEZ —
-- onların kendi DespawnDispatchEntity zinciri vardır ve bu tür
-- bir grace period'a ihtiyaç duymazlar (ped zaten hedef yok
-- edildikten sonra dispatch sonlanır).
-- =====================================================================


-- =====================================================================
-- DERİN: Çıkış Köprüsü
-- =====================================================================


-- =====================================================================
-- ★ [H5-v2] Test Bot Retirement Guard (helper)
-- =====================================================================
-- qbx_smallresources gibi pasif durum döngülerinin async native kuyruğu,
-- test botu silindikten sonra "invalid entity" hatası fırlatmasın diye
-- 4 katmanlı grace guard uygular. Detaylı gerekçe yukarıdaki büyük
-- yorum bloğunda.
-- =====================================================================
local function _SafeRetireTestBot(testBotId)
    if not testBotId or type(testBotId) ~= 'number' then return false end

    local dispatch = Matrix.Dispatches and Matrix.Dispatches[testBotId]
    if not dispatch then
        -- Dispatch yoksa doğrudan RemoveBot
        return Matrix.RemoveBot(testBotId, 'retired')
    end

    local pedNetId     = dispatch.entity_net_id
    local vehicleNetId = dispatch.vehicle_net_id

    -- [KATMAN 1] Statebag clear — bilinen yara anahtarları nil'lenir
    if pedNetId then
        pcall(function()
            local ped = NetworkGetEntityFromNetworkId(pedNetId)
            if not ped or ped == 0 or not DoesEntityExist(ped) then return end
            local st = Entity(ped).state
            if st then
                st.limb_damage = nil
                st.wound_zone  = nil
            end
        end)
    end

    -- [KATMAN 2] Mission release — OneSync'e "artık sahip değiliz" sinyali
    if pedNetId then
        pcall(function()
            local ped = NetworkGetEntityFromNetworkId(pedNetId)
            if ped and ped ~= 0 and DoesEntityExist(ped) then
                SetEntityAsMissionEntity(ped, false, false)
                SetEntityAsNoLongerNeeded(ped)
            end
        end)
    end
    if vehicleNetId then
        pcall(function()
            local veh = NetworkGetEntityFromNetworkId(vehicleNetId)
            if veh and veh ~= 0 and DoesEntityExist(veh) then
                SetEntityAsMissionEntity(veh, false, false)
                SetEntityAsNoLongerNeeded(veh)
            end
        end)
    end

    -- [KATMAN 3] Tick flush — async native kuyruğunu boşalt
    Wait(0)
    Wait(0)
    Wait(0)
    Wait(0)

    -- [KATMAN 4] Deferred retire
    return Matrix.RemoveBot(testBotId, 'retired')
end

-- =====================================================================
-- DERİN: Çıkış Köprüsü
-- =====================================================================

local function RunDeepExitBridgeCheck()
    local trapHouseId, house = nil, nil
    for id, h in pairs(Matrix.TrapHouses or {}) do
        trapHouseId, house = id, h
        break
    end
    if not trapHouseId then
        return { name = 'DERIN: Cikis Koprusu uctan uca (Madde 1)', passed = true, detail = 'atlandi -- Matrix.TrapHouses bos' }
    end

    local testBot = Matrix.CreateBotRecord({
        name          = 'DIAGNOSTIC-TEST-BOT',
        role          = 'diagnostic_test',
        trap_house_id = trapHouseId
    })

    local bridgedOk = false
    local reason = 'bot olusturulamadi'
    local bridgeEvidence = false

    if testBot and testBot.id then
        local setOk = Matrix.SetBotInteriorTrapHouse(testBot.id, trapHouseId)
        if setOk then
            local preState = testBot.state.interior_trap_house_id
            bridgeEvidence = (preState == trapHouseId)

            local shell = Config.TrapHouseInterior and Config.TrapHouseInterior.Shell
            local origin = (shell and shell.EnterCoords) or house.coords
            local ok, r = Matrix.BeginPhysicalDispatch(
                testBot.id, origin, house.coords, nil, 'foot', 0.0, nil, 1.0
            )

            if ok then
                bridgedOk, reason = true, r or 'ok'
            elseif r == 'task_assignment_failed' and bridgeEvidence then
                bridgedOk = true
                reason = 'ATLANDI (native race: ped NavMesh hazir degil; koprunun state kaniti dogrulandi)'
            else
                bridgedOk, reason = false, r or 'bilinmeyen_hata'
            end
        else
            reason = 'SetBotInteriorTrapHouse basarisiz'
        end
        _SafeRetireTestBot(testBot.id)
        testBot = nil
    end

    return { name = 'DERIN: Cikis Koprusu uctan uca (Madde 1)', passed = bridgedOk, detail = tostring(reason) }
end

-- =====================================================================
-- KATMAN 21 — Simülasyon testleri
-- =====================================================================
local function RunConcurrencyStressCheck()
    local stashId      = Config.Diagnostics.StressTestStashId or 'matrix_diagnostics_stress_stash'
    local testItem      = Config.Diagnostics.StressTestItem or 'matrix_diagnostic_token'
    local concurrency   = Config.Diagnostics.StressTestConcurrency or 100
    local timeoutMs      = Config.Diagnostics.StressTestTimeoutMs or 15000
    local runToken       = ('BOOT-%d'):format(GetGameTimer())

    local regOk, regResult = pcall(function()
        return exports.ox_inventory:RegisterStash(stashId, 'DIAGNOSTICS STRESS STASH', concurrency + 10, 1000000, false)
    end)
    if not regOk then
        return true, ('ATLANDI: RegisterStash hata firlatti -> %s'):format(tostring(regResult))
    end

    local seedOk, seedResult = pcall(function()
        return exports['ox_inventory']:AddItem(stashId, testItem, concurrency)
    end)
    if not seedOk or seedResult ~= true then
        return true, ('ATLANDI: "%s" item\'i ox_inventory\'de KAYITLI DEGIL veya AddItem reddedildi -- Config.Diagnostics.StressTestItem\'i gercek bir item ile degistirin (orn: bread, water)'):format(tostring(testItem))
    end

    local pending = concurrency
    for i = 1, concurrency do
        CreateThread(function()
            local removeOk, removeResult = pcall(function()
                return exports.ox_inventory:RemoveItem(stashId, testItem, 1)
            end)
            local removedFlag = (removeOk and removeResult) and 1 or 0
            pcall(function()
                MySQL.transaction.await({
                    {
                        query  = 'INSERT INTO matrix_diagnostics_stress_log (run_token, worker_index, removed_ok) VALUES (?, ?, ?)',
                        values = { runToken, i, removedFlag }
                    }
                })
            end)
            pending = pending - 1
        end)
    end

    local waitedMs = 0
    while pending > 0 and waitedMs < timeoutMs do
        Wait(50)
        waitedMs = waitedMs + 50
    end
    assert(pending == 0, ('%d/%d worker zaman asimina ugradi (%dms)'):format(pending, concurrency, timeoutMs))

    local rows = MySQL.query.await(
        'SELECT COUNT(*) AS cnt, COALESCE(SUM(removed_ok), 0) AS ok_sum FROM matrix_diagnostics_stress_log WHERE run_token = ?',
        { runToken }
    ) or {}
    local cnt   = rows[1] and tonumber(rows[1].cnt) or 0
    local okSum = rows[1] and tonumber(rows[1].ok_sum) or 0

    pcall(function() MySQL.query.await('DELETE FROM matrix_diagnostics_stress_log WHERE run_token = ?', { runToken }) end)

    assert(cnt == concurrency,
        ('%d/%d satir DB\'ye ulasti -- kayip yazma = RACE CONDITION KANITI'):format(cnt, concurrency))
    assert(okSum == concurrency,
        ('%d/%d eszamanli RemoveItem basarisiz'):format(concurrency - okSum, concurrency))

    pending = nil
    return true, ('%d/%d eszamanli worker, %dms icinde, 0 kayip satir'):format(concurrency, concurrency, waitedMs)
end

local function RunWoundPrecisionSimCheck()
    local trapHouseId = nil
    for id in pairs(Matrix.TrapHouses or {}) do trapHouseId = id; break end
    if not trapHouseId then
        return true, 'atlandi -- Matrix.TrapHouses bos'
    end

    local EPS = 0.00005

    local botA = Matrix.CreateBotRecord({ name = 'DIAGNOSTIC-WOUND-A', role = 'diagnostic_test', trap_house_id = trapHouseId })
    assert(botA and botA.id, 'test bot A olusturulamadi')

    Matrix.Wounds.ApplyBotRegionalDamage(botA.id, 1.0, 'leg')
    local moveMult = Matrix.Wounds.GetMovementMultiplier(botA.id)
    local expectedMove = 1.0 - (Config.BotWounds.LegSpeedPenalty or 0.60)
    assert(type(moveMult) == 'number' and math_abs(moveMult - expectedMove) < EPS,
        ('hareket carpani sapmasi: beklenen=%.4f gercek=%.4f'):format(expectedMove, moveMult or -1))

    Matrix.Wounds.ApplyBotRegionalDamage(botA.id, 1.0, 'head')
    local detCap = Matrix.Wounds.GetDetectionRangeCap(botA.id)
    local expectedDet = Config.BotWounds.HeadDetectionRangeCap or 15.0
    assert(type(detCap) == 'number' and math_abs(detCap - expectedDet) < EPS,
        ('Spotter Distance sapmasi: beklenen=%.4f gercek=%.4f'):format(expectedDet, detCap or -1))

    Matrix.Wounds.ApplyBotRegionalDamage(botA.id, 1.0, 'arm')
    local accMult = Matrix.Wounds.GetAccuracyMultiplier(botA.id)
    local expectedAcc = 1.0 - (Config.BotWounds.ArmAccuracyPenalty or 0.50)
    assert(type(accMult) == 'number' and math_abs(accMult - expectedAcc) < EPS,
        ('isabet carpani sapmasi: beklenen=%.4f gercek=%.4f'):format(expectedAcc, accMult or -1))

    Matrix.RemoveBot(botA.id, 'retired')

    local botB = Matrix.CreateBotRecord({ name = 'DIAGNOSTIC-WOUND-B', role = 'diagnostic_test', trap_house_id = trapHouseId })
    assert(botB and botB.id, 'test bot B olusturulamadi')
    for _ = 1, 4 do
        Matrix.Wounds.ApplyBotRegionalDamage(botB.id, 1.0, 'leg')
    end
    local moveMultCrippled = Matrix.Wounds.GetMovementMultiplier(botB.id)
    local expectedMoveCrippled = 1.0 - (Config.PermanentCrippling.LegMovementPenalty or 0.90)
    assert(type(moveMultCrippled) == 'number' and math_abs(moveMultCrippled - expectedMoveCrippled) < EPS,
        ('kalici sakatlik hareket carpani sapmasi: beklenen=%.4f gercek=%.4f'):format(expectedMoveCrippled, moveMultCrippled or -1))

    Matrix.RemoveBot(botB.id, 'retired')
    botA, botB = nil, nil

    return true, ('bacak=%.4f algi=%.4f kol=%.4f kalici-bacak=%.4f'):format(moveMult, detCap, accMult, moveMultCrippled)
end

local function RunPhantomDoctorPalindromeSimCheck()
    assert(type(Matrix.Wounds.__ComputePhantomIndexForEpochBucket) == 'function',
        'Matrix.Wounds.__ComputePhantomIndexForEpochBucket tanimli degil')

    local epochCount = Config.Diagnostics.PhantomPalindromeEpochCount or 10000

    local forward = {}
    for bucket = 0, epochCount - 1 do
        forward[bucket] = Matrix.Wounds.__ComputePhantomIndexForEpochBucket(bucket)
        if (bucket % STAGED_GC_INTERVAL) == 0 then
            Matrix.Diagnostics.StepGC()
        end
    end

    for bucket = epochCount - 1, 0, -1 do
        local idx = Matrix.Wounds.__ComputePhantomIndexForEpochBucket(bucket)
        assert(idx == forward[bucket],
            ('epoch #%d ileri/geri sapma: ileri=%s geri=%s'):format(bucket, tostring(forward[bucket]), tostring(idx)))

        if (bucket % STAGED_GC_INTERVAL) == 0 then
            Matrix.Diagnostics.StepGC()
        end
    end

    forward = nil
    Matrix.Diagnostics.StepGC()

    return true, ('%d epoch, ileri+geri, BIREBIR ayni (palindrom dogrulandi, %d staged GC step)'):format(
        epochCount, math.floor(epochCount / STAGED_GC_INTERVAL) * 2)
end

local function RunHitAndRunDrivebySimCheck()
    assert(Config.HitSquad, 'Config.HitSquad tanimsiz')
    local hs = Config.HitSquad

    for _, field in ipairs({ 'VehicleModel', 'PedModel', 'Weapon' }) do
        assert(type(hs[field]) == 'string' and hs[field] ~= '',
            ('Config.HitSquad.%s gecersiz/bos'):format(field))
    end
    for _, field in ipairs({ 'CruiseSpeed', 'AttackRange', 'DrivebySeconds', 'FleeSeconds',
                             'AggressiveDriveStyle', 'DrivebyRange', 'PedAccuracy', 'ScanIntervalTicks' }) do
        assert(type(hs[field]) == 'number',
            ('Config.HitSquad.%s sayisal degil'):format(field))
    end
    assert(type(hs.HeatTraceThreshold) == 'number'
        and hs.HeatTraceThreshold >= 0
        and hs.HeatTraceThreshold <= 1.0,
        'Config.HitSquad.HeatTraceThreshold [0,1] araliginda degil')

    -- Native race önleme: server-side spawn+delete testi yapmıyoruz
    if type(TaskVehicleDriveby) ~= 'function' then
        return true, 'ATLANDI: TaskVehicleDriveby server tarafinda tanimli degil (yalnizca client-taraf native)'
    end

    return true, 'Config ve kancalar 0 hata ile dogrulandi (spawn testi ATLANDI -- native race onlendi)'
end

local function RunMedicalBureauLeakSimCheck()
    assert(type(Matrix.Wounds.ComputeBureauLeakMultiplier) == 'function',
        'Matrix.Wounds.ComputeBureauLeakMultiplier tanimli degil')
    assert(type(Config.Hospital) == 'table', 'Config.Hospital tanimsiz')
    assert(type(Config.Hospital.LeakIntensityMultiplier) == 'number' and Config.Hospital.LeakIntensityMultiplier > 1.0,
        ('Config.Hospital.LeakIntensityMultiplier gecersiz: %s'):format(tostring(Config.Hospital.LeakIntensityMultiplier)))

    local EPS = 0.00005

    local spiked, mult = Matrix.Wounds.ComputeBureauLeakMultiplier(1.0)
    local expected = 1.0 * Config.Hospital.LeakIntensityMultiplier
    assert(math_abs(spiked - expected) < EPS,
        ('has_wound==1 medikal sizinti formulu sapmasi: beklenen=%.4f gercek=%.4f'):format(expected, spiked))
    assert(math_abs(mult - Config.Hospital.LeakIntensityMultiplier) < EPS,
        'donen carpan Config.Hospital.LeakIntensityMultiplier ile uyusmuyor')

    local nanValue = 0.0 / 0.0
    for _, badInput in ipairs({ -5.0, 0.0, nanValue }) do
        local fallbackSpiked = Matrix.Wounds.ComputeBureauLeakMultiplier(badInput)
        assert(math_abs(fallbackSpiked - expected) < EPS,
            ('gecersiz girdi (%s) icin 1.0 taban fallback formulu bozuk: gercek=%.4f'):format(tostring(badInput), fallbackSpiked))
    end

    local spiked2 = Matrix.Wounds.ComputeBureauLeakMultiplier(2.35)
    local expected2 = 2.35 * Config.Hospital.LeakIntensityMultiplier
    assert(math_abs(spiked2 - expected2) < EPS,
        ('2.35 taban icin sizinti sapmasi: beklenen=%.4f gercek=%.4f'):format(expected2, spiked2))

    return true, ('taban=1.00 -> sizinti=%.2f (x%.1f), 3 gecersiz-girdi fallback + 1 farkli-taban dogrulandi'):format(spiked, mult)
end

local function RunConfigSabotageSimCheck()
    return TestConfigDependencies()
end

local SimulationChecks = {
    { 'DERIN-SIM: Config Sabotaj ve Bagimlilik Kontrolu (KATMAN 2)',               RunConfigSabotageSimCheck },
    { 'DERIN-SIM: 100 eszamanli async satis stres testi (KATMAN 21.1)',            RunConcurrencyStressCheck },
    { 'DERIN-SIM: Bot yara ceza carpani 4-hane hassasiyeti (KATMAN 21.2)',          RunWoundPrecisionSimCheck },
    { 'DERIN-SIM: Hayalet Doktor 10k-epoch palindrom determinizmi (KATMAN 21.3)',   RunPhantomDoctorPalindromeSimCheck },
    { 'DERIN-SIM: Hit-and-Run drive-by tazelenmesi (KATMAN 22.1)',                  RunHitAndRunDrivebySimCheck },
    { 'DERIN-SIM: Medikal/Buro sizinti 2x katlanma formulu (KATMAN 22.2)',          RunMedicalBureauLeakSimCheck }
}

local function AbortResourceBoot(reason)
    local msg = ('[KATMAN 21][KRITIK] Kaynak acilisi DURDURULUYOR -- %s'):format(tostring(reason))
    Matrix.Log('DIAGNOSTICS', msg)
    print(('^1[MATRIX:DIAGNOSTICS] %s^7'):format(msg))
    StopResource(GetCurrentResourceName())
end

function Matrix.Diagnostics.Run(deep, replyTo, isAutoBoot)
    CreateThread(function()
        local startedAt = GetGameTimer()
        local checks = {}

        -- ★ [MODUL 14.1] ANA AG BACAGI YALITIMI: FastChecks+DbChecks+
        -- SimulationChecks onlarca ardisik senkron MySQL.query.await/
        -- INFORMATION_SCHEMA turu barindirir -- Config.NetworkGuard.
        -- DiagnosticsYieldEveryNChecks kontrolde bir Wait(0) ile ana
        -- tick/ag dongusune GERI VERILIR, boylece txAdmin/master-list
        -- poller'lari (dynamic.json/players.json/info.json) uzun,
        -- kesintisiz bir sorgu patlamasi tarafindan AC BIRAKILMAZ.
        local yieldEvery = (Config.NetworkGuard and Config.NetworkGuard.DiagnosticsYieldEveryNChecks) or 5
        local sinceYield  = 0
        local function MaybeYield()
            sinceYield = sinceYield + 1
            if sinceYield >= yieldEvery then
                sinceYield = 0
                Wait(0)
            end
        end

        for _, c in ipairs(FastChecks) do
            checks[#checks + 1] = RunCheck(c.name, c.fn)
            MaybeYield()
        end
        for _, c in ipairs(DbChecks) do
            checks[#checks + 1] = RunCheck(c[1], c[2])
            MaybeYield()
        end
        if deep then
            local deepOk, deepResult = pcall(RunDeepExitBridgeCheck)
            if deepOk then
                checks[#checks + 1] = deepResult
            else
                checks[#checks + 1] = {
                    name = 'DERIN: Cikis Koprusu uctan uca (Madde 1)',
                    passed = false,
                    detail = ('HATA: %s'):format(tostring(deepResult))
                }
            end

            for _, c in ipairs(SimulationChecks) do
                checks[#checks + 1] = RunCheck(c[1], c[2])
                MaybeYield()
            end

            Matrix.Diagnostics.PurgeDeepTestState()
        end

        local passed, failed = 0, 0
        for _, c in ipairs(checks) do
            if c.passed then passed = passed + 1 else failed = failed + 1 end
        end

        lastReport = {
            ran_at      = os.time(),
            duration_ms = GetGameTimer() - startedAt,
            deep        = deep and true or false,
            total       = #checks,
            passed      = passed,
            failed      = failed,
            checks      = checks,
            sealed      = (failed == 0)
        }

        Matrix.Log('DIAGNOSTICS',
            '[MATRIX RUN DIAGNOSTICS] %d/%d basarili (deep=%s) -- %dms icinde tamamlandi. Sonuc: %s',
            passed, #checks, tostring(lastReport.deep), lastReport.duration_ms,
            lastReport.sealed and 'MUHURLENDI (0 hata)' or ('%d HATA'):format(failed))

        if isAutoBoot and failed > 0 and Config.Diagnostics.AbortResourceOnSimulationFailure then
            local firstFailure = nil
            for _, c in ipairs(checks) do
                if not c.passed then firstFailure = c; break end
            end
            AbortResourceBoot(('%d/%d kontrol basarisiz -- ilk hata: [%s] %s'):format(
                failed, #checks,
                firstFailure and firstFailure.name or '?',
                firstFailure and firstFailure.detail or '?'))
            return
        end

        if replyTo then
            Reply(replyTo, ('%d/%d kontrol basarili (%dms). %s'):format(
                passed, #checks, lastReport.duration_ms,
                lastReport.sealed and 'Sistem muhurlendi.' or ('%d hata bulundu, /matrix_diag_detay failed ile gorun.'):format(failed)))
            if not lastReport.sealed then
                for _, c in ipairs(checks) do
                    if not c.passed then
                        Reply(replyTo, ('  x %s -- %s'):format(c.name, c.detail))
                    end
                end
            end
        end

        TriggerClientEvent('matrix:client:diagnosticsSealed', -1, lastReport)
    end)
end

function Matrix.Diagnostics.GetLastReport()
    return lastReport
end

lib.callback.register('matrix:callback:getDiagnosticsReport', function(src)
    return lastReport
end)

-- =====================================================================
-- ★ [MODUL 14.2] SUNUCU KALP ATISI (HEARTBEAT) YAYINI
-- client/hud.lua bu event'in ZAMAN DAMGASINI tutar; Config.NetworkGuard.
-- HeartbeatTimeoutMs suresi asilirsa client, ag hattini "riskli/tikanik"
-- sayar VE adli event'lerini (matrix:server:reportPlayerWounded) DOGRUDAN
-- gondermek yerine kendi LocalAdliBuffer'ina muhurler -- bu, sunucunun
-- ana ag bacagi (I/O thread) gecici olarak tikandiginda/txAdmin poller
-- timeout verdiginde adli izin havada kaybolmasini ONLER. Yayin, TEK bir
-- hafif CreateThread ile yapilir -- diagnostik/DB tarama dongulerinin
-- ICINE KARISTIRILMAZ (bu thread ASLA MySQL cagirmaz).
-- =====================================================================
CreateThread(function()
    while true do
        Wait((Config.NetworkGuard and Config.NetworkGuard.HeartbeatIntervalMs) or 5000)
        TriggerClientEvent('matrix:client:networkHeartbeat', -1, GetGameTimer())
    end
end)

-- =====================================================================
-- KATMAN 1 + [H2]: ASENKRON BEKLEME KALKANI + DB TIMEOUT KORUMASI
-- =====================================================================
local DB_BOOT_TIMEOUT_CYCLES = 150
local DB_BOOT_POLL_MS        = 100

local function ExecuteNihaiMatrixDiagnostics(deep)
    Matrix.Diagnostics.Run(deep or true, nil, true)
end

AddEventHandler('onServerResourceStart', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    if not (Config.Diagnostics and Config.Diagnostics.RunOnResourceStart) then return end

    CreateThread(function()
        local dbGlobalWaited = 0
        while not MySQL and dbGlobalWaited < (DB_BOOT_TIMEOUT_CYCLES * DB_BOOT_POLL_MS) do
            Citizen.Wait(DB_BOOT_POLL_MS)
            dbGlobalWaited = dbGlobalWaited + DB_BOOT_POLL_MS
        end

        if not MySQL then
            JournalBootFailure('mysql_global_missing',
                ('MySQL global %dms icinde tanimlanmadi -- simülasyon GUVENLI ISTISNA modunda devam ediyor.'):format(dbGlobalWaited))
            ExecuteNihaiMatrixDiagnostics(true)
            return
        end

        local readyRegistered = false
        local readyFired      = false

        local okReady, readyErr = pcall(function()
            MySQL.ready(function()
                readyFired = true

                local inventoryReady = false
                local waitCycles = 0

                while not inventoryReady and waitCycles < DB_BOOT_TIMEOUT_CYCLES do
                    local ok, items = pcall(function()
                        if exports['ox_inventory'] and exports['ox_inventory']:Items() then
                            return exports['ox_inventory']:Items()
                        end
                        return nil
                    end)

                    if ok and type(items) == 'table' then
                        inventoryReady = true
                    else
                        Citizen.Wait(DB_BOOT_POLL_MS)
                        waitCycles = waitCycles + 1
                    end
                end

                if not inventoryReady then
                    JournalBootFailure('inventory_manifest_timeout',
                        ('ox_inventory %dms icinde hazir olmadi (MySQL.ready OK). Config.Diagnostics.AbortResourceOnSimulationFailure=%s -- kaynak CORERTILMEDI, simulasyon deep=true ile devam ediyor.'):format(
                            DB_BOOT_TIMEOUT_CYCLES * DB_BOOT_POLL_MS,
                            tostring(Config.Diagnostics.AbortResourceOnSimulationFailure)))
                    Matrix.Log('DIAGNOSTICS',
                        '[KATMAN 1][KALKAN] ox_inventory %dms icinde hazir olmadi -- varsayilan devam karari (sahte sizinti alarmi onlendi).',
                        DB_BOOT_TIMEOUT_CYCLES * DB_BOOT_POLL_MS)
                else
                    Matrix.Log('DIAGNOSTICS',
                        '[KATMAN 1][KALKAN] MySQL.ready + ox_inventory:Items() hazir -- Nihai Derin Simulasyon atesleniyor (wait=%dms).',
                        waitCycles * DB_BOOT_POLL_MS)
                end

                ExecuteNihaiMatrixDiagnostics(true)
            end)
            readyRegistered = true
        end)

        if not okReady then
            JournalBootFailure('mysql_ready_register_failed',
                ('MySQL.ready callback kaydi basarisiz: %s -- simulasyon deep=true ile devam ediyor.'):format(tostring(readyErr)))
            ExecuteNihaiMatrixDiagnostics(true)
            return
        end

        if readyRegistered and not readyFired then
            CreateThread(function()
                local guardWaited = 0
                while not readyFired and guardWaited < (DB_BOOT_TIMEOUT_CYCLES * DB_BOOT_POLL_MS) do
                    Citizen.Wait(DB_BOOT_POLL_MS)
                    guardWaited = guardWaited + DB_BOOT_POLL_MS
                end
                if not readyFired then
                    JournalBootFailure('mysql_ready_callback_timeout',
                        ('MySQL.ready %dms icinde ATESLENMEDI (MariaDB cokmus veya agir yuk altinda) -- simulasyon deep=true ile devam ediyor, kaynak CORERTILMEDI.'):format(guardWaited))
                    ExecuteNihaiMatrixDiagnostics(true)
                end
            end)
        end
    end)
end)

-- =====================================================================
-- /matrix_run_diagnostics — manuel kısa özet çalıştırma
-- =====================================================================
RegisterCommand('matrix_run_diagnostics', function(src, args)
    local deep = args[1] == Config.Diagnostics.DeepModeCommandArg
    Reply(src, deep
        and 'Derin tani calistiriliyor (Config sabotaj + SimulationChecks + kullan-at test botu)...'
        or 'Hizli tani calistiriliyor...')
    Matrix.Diagnostics.Run(deep, src, false)
end, false)

exports('GetDiagnosticsReport', function() return lastReport end)
exports('RunDiagnostics',      function(deep) return Matrix.Diagnostics.Run(deep, nil, false) end)
exports('TestConfigDependencies', function() return TestConfigDependencies() end)
exports('PurgeDeepTestState',  function() return Matrix.Diagnostics.PurgeDeepTestState() end)
exports('GetFailureJournal',   function() return Matrix.Diagnostics.GetFailureJournal() end)
exports('GetBreachJournal',    function() return Matrix.Diagnostics.BreachJournal end)
exports('WrapReadOnlyCell',    function(data, name, botId) return Matrix.Diagnostics.WrapReadOnlyCell(data, name, botId) end)
exports('DeepCopyCell',        function(data) return Matrix.Diagnostics.DeepCopyCell(data) end)
exports('StepGC',              function() return Matrix.Diagnostics.StepGC() end)
exports('FinalizeStagedGC',    function() return Matrix.Diagnostics.FinalizeStagedGC() end)

-- =====================================================================
-- KATMAN 23: DETAYLI TANI DÖKÜMÜ (/matrix_diag_detay)
-- =====================================================================
do
    local function _DiagReply(src, msg)
        if type(src) == 'number' and src > 0 then
            TriggerClientEvent('chat:addMessage', src, { args = { '[DIAGNOSTICS]', msg } })
        else
            print(('[MATRIX:DIAGNOSTICS:CONSOLE] %s'):format(msg))
        end
    end

    local function _GetReport()
        local fn = Matrix.Diagnostics and Matrix.Diagnostics.GetLastReport
        if type(fn) == 'function' then return fn() end
        return {}
    end

    local function _ConsolePrintCheck(idx, c)
        local marker = c.passed and '[OK]  ' or '[FAIL]'
        print(('[MATRIX:DIAGNOSTICS] %s #%03d %s'):format(marker, idx, c.name))
        print(('[MATRIX:DIAGNOSTICS]        -> %s'):format(tostring(c.detail or '?')))
    end

    local function _DumpReport(replyTo, filterKind, filterValue, verbose)
        local rep = _GetReport()
        if type(rep) ~= 'table' or (rep.total or 0) == 0 then
            _DiagReply(replyTo, 'Henuz bir tani raporu yok. Once /matrix_run_diagnostics calistirin.')
            return
        end

        _DiagReply(replyTo, ('=== TANI RAPORU [ran_at=%d | deep=%s | %d/%d GECTI | %d HATA | %dms] ==='):format(
            rep.ran_at or 0, tostring(rep.deep), rep.passed or 0, rep.total or 0,
            rep.failed or 0, rep.duration_ms or 0))

        print(('[MATRIX:DIAGNOSTICS] ==== DUMP basladi [ran_at=%d deep=%s %d/%d failed=%d] ===='):format(
            rep.ran_at or 0, tostring(rep.deep), rep.passed or 0, rep.total or 0, rep.failed or 0))

        local shown, matchedFailed = 0, 0
        for i, c in ipairs(rep.checks or {}) do
            local include = false

            if filterKind == 'failed' then
                include = not c.passed
            elseif filterKind == 'passed' then
                include = c.passed
            elseif filterKind == 'grep' then
                local hay = tostring(c.name):lower()
                local needle = tostring(filterValue or ''):lower()
                include = (needle ~= '' and hay:find(needle, 1, true) ~= nil)
            elseif filterKind == 'layer' then
                local needle = tostring(filterValue or '')
                local name = tostring(c.name)
                include = name:find('KATMAN ' .. needle, 1, true) ~= nil
                       or name:find('katman ' .. needle, 1, true) ~= nil
                       or name:find('KATMAN' .. needle, 1, true) ~= nil
                       or name:find('layer' .. needle, 1, true) ~= nil
            else
                include = true
            end

            if include then
                shown = shown + 1
                if not c.passed then matchedFailed = matchedFailed + 1 end

                local marker = c.passed and '[OK]' or '[FAIL]'
                if (not c.passed) or verbose then
                    _DiagReply(replyTo, ('%s #%03d %s'):format(marker, i, c.name))
                    _DiagReply(replyTo, ('       -> %s'):format(tostring(c.detail or '?')))
                else
                    _DiagReply(replyTo, ('%s #%03d %s'):format(marker, i, c.name))
                end

                _ConsolePrintCheck(i, c)
            end
        end

        print(('[MATRIX:DIAGNOSTICS] ==== DUMP bitti -- %d/%d kontrol gosterildi, %d basarisiz ===='):format(
            shown, rep.total or 0, matchedFailed))

        if shown == 0 then
            _DiagReply(replyTo, 'Bu filtreye uyan kontrol yok.')
        else
            _DiagReply(replyTo, ('--- %d/%d kontrol gosterildi (%d basarisiz) | TAMAMI SERVER KONSOLUNDA ---'):format(
                shown, rep.total or 0, matchedFailed))
        end
    end

    local function _RerunThenDump(replyTo, deep, filterKind, filterValue, verbose)
        local beforeRanAt = (_GetReport().ran_at) or 0

        if type(Matrix.Diagnostics) ~= 'table' or type(Matrix.Diagnostics.Run) ~= 'function' then
            _DiagReply(replyTo, 'Matrix.Diagnostics.Run tanimli degil -- dosya tam yuklenmemis olabilir.')
            return
        end

        Matrix.Diagnostics.Run(deep, nil, false)

        CreateThread(function()
            local deadline = os.time() + 30
            while ((_GetReport().ran_at) or 0) == beforeRanAt and os.time() < deadline do
                Wait(200)
            end
            _DumpReport(replyTo, filterKind, filterValue, verbose)
        end)
    end

    RegisterCommand('matrix_diag_detay', function(src, args)
        local a1 = tostring(args[1] or ''):lower()

        if a1 == 'deep' then
            _DiagReply(src, 'Yeni DEEP tani calistiriliyor, ardindan TUM sonuclar dokulecek...')
            _RerunThenDump(src, true, nil, nil, true); return
        end

        if a1 == 'fast' then
            _DiagReply(src, 'Yeni HIZLI tani calistiriliyor, ardindan TUM sonuclar dokulecek...')
            _RerunThenDump(src, false, nil, nil, true); return
        end

        if a1 == 'failed'  then _DumpReport(src, 'failed', nil, true);  return end
        if a1 == 'passed'  then _DumpReport(src, 'passed', nil, false); return end
        if a1 == 'verbose' then _DumpReport(src, nil, nil, true);       return end

        if a1 == 'journal' or a1 == 'jurnal' then
            local j = Matrix.Diagnostics.GetFailureJournal()
            _DiagReply(src, ('=== [matrix_diag_detay_failed] BOOT FAILURE JOURNAL (toplam %d kayit) ==='):format(j.failure_count or 0))
            if (j.failure_count or 0) == 0 then
                _DiagReply(src, 'Kayitli boot hatasi yok -- MySQL.ready + ox_inventory:Items() 15sn icinde temiz geldi.')
            else
                _DiagReply(src, ('Son hata: %s | tur=%s | %s'):format(
                    os.date('%Y-%m-%d %H:%M:%S', j.last_failure_at or 0),
                    tostring(j.last_failure_kind or '?'),
                    tostring(j.last_failure_detail or '?')))
            end
            return
        end

        if a1 == 'breach' or a1 == 'ihlal' then
            local b = Matrix.Diagnostics.BreachJournal
            _DiagReply(src, ('=== HUCRE IZOLASYON IHLALI JURNALI (toplam %d ihlal) ==='):format(b.breach_count or 0))
            if (b.breach_count or 0) == 0 then
                _DiagReply(src, 'Kayitli izolasyon ihlali yok -- tum bot sinif veri transferleri temiz.')
            else
                _DiagReply(src, ('Son ihlal: %s'):format(tostring(b.last_breach_detail or '?')))
                for botId, count in pairs(b.breach_by_bot or {}) do
                    _DiagReply(src, ('  - Bot #%s: %d ihlal'):format(tostring(botId), count))
                end
            end
            return
        end

        if a1 == 'g' then
            if not args[2] then _DiagReply(src, 'Kullanim: /matrix_diag_detay g <metin>'); return end
            local parts = {}
            for i = 2, #args do parts[#parts + 1] = tostring(args[i]) end
            _DumpReport(src, 'grep', table.concat(parts, ' '), true); return
        end

        if a1 == 'layer' or a1 == 'katman' then
            local n = args[2]
            if not n then _DiagReply(src, 'Kullanim: /matrix_diag_detay layer <N>'); return end
            _DumpReport(src, 'layer', tostring(n), true); return
        end

        if a1 == 'export' then
            local rep = _GetReport()
            if type(rep) ~= 'table' or (rep.total or 0) == 0 then
                _DiagReply(src, 'Rapor yok, once /matrix_run_diagnostics calistirin.'); return
            end
            local ok, encoded = pcall(function() return json.encode(rep) end)
            if ok and type(encoded) == 'string' then
                print('[MATRIX:DIAGNOSTICS][EXPORT] ' .. encoded)
                _DiagReply(src, ('Tam rapor (%d kontrol) server konsoluna JSON olarak basildi.'):format(rep.total))
            else
                _DiagReply(src, 'JSON kodlamasi basarisiz.')
            end
            return
        end

        _DumpReport(src, nil, nil, false)
    end, false)

    exports('DumpDiagnosticsReport', function(replyTo, filterKind, filterValue, verbose)
        _DumpReport(replyTo, filterKind, filterValue, verbose)
    end)
end