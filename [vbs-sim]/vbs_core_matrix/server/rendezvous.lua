-- =====================================================================
-- MATRIX RENDEZVOUS / server/rendezvous.lua  (KATMAN 6 — YENİ)
--
-- Karaborsa silah/mühimmat "Dead Drop" teslimatı + Büro pususu. server/
-- blackmarket.lua'nın buyWeapon/buyAmmo akışı ödeme başarılı olduktan
-- SONRA Matrix.Rendezvous.ScheduleHandoff'u çağırır — mal ANINDA
-- envantere düşmez, bir buluşma koordinatı üretilir ve oyuncu fiziksel
-- olarak satıcı NPC'ye gidip teslim almalıdır.
--
-- ★ TASARIM KARARLARI:
--   [R1] "0 RNG" HARFİYEN korunur: buluşma koordinatı citizenid + monoton
--        sayaç + GetGameTimer()'dan türetilen bir sağlama toplamıyla
--        (server/blackmarket.lua'nın ChecksumOf deseniyle AYNI) belirlenir.
--        Aynı girdi HER ZAMAN aynı koordinatı üretir.
--   [R2] Pusu tetikleyicisi de deterministiktir: handoff anında en yakın
--        trap house'un Büro siber ısısı (Matrix.Bureau.GetHeat — mevcut
--        salt-okunur getter, DEĞİŞTİRİLMEDİ) normalize edilip
--        Config.Rendezvous.AmbushTraceLevelThreshold ile karşılaştırılır.
--        RNG YOK — zar atışı değil, eşik karşılaştırması.
--   [R3] Ödeme zaten blackmarket.lua'da tahsil edildiği için burada asla
--        ikinci bir ücret alınmaz; bu dosyanın tek işi TESLİMATI (ve buna
--        bağlı pusu riskini) yönetmektir.
--   [R4] Malın kendisi handoff anında (pusu tetiklense de tetiklenmese de)
--        teslim edilir — pusu, teslimatı iptal eden değil, teslimat
--        SIRASINDA patlak veren ayrı bir tehdit katmanıdır (oyuncu parasını
--        zaten ödedi; risk aldığı şey teslim alırken saldırıya uğramaktır).
-- =====================================================================


Matrix.Rendezvous = Matrix.Rendezvous or {}


local pairs, ipairs, type, tostring = pairs, ipairs, type, tostring
local tonumber, math                = tonumber, math
local math_huge, math_max            = math.huge, math.max
local GetGameTimer                   = GetGameTimer
local GetPlayerPed                   = GetPlayerPed
local GetEntityCoords                = GetEntityCoords
local TriggerClientEvent             = TriggerClientEvent


local function Reply(src, msg)
    if type(src) == 'number' and src > 0 then
        TriggerClientEvent('chat:addMessage', src, { args = { '[RENDEZVOUS]', msg } })
    else
        print(('[MATRIX:RENDEZVOUS:CONSOLE] %s'):format(msg))
    end
end


-- =====================================================================
-- [R1] DETERMİNİSTİK KOORDİNAT ÜRETİMİ (RNG YOK) — bkz. dosya başı notu.
-- =====================================================================
local handoffSequence = 0
local function NextHandoffId()
    handoffSequence = handoffSequence + 1
    return handoffSequence
end


local function ChecksumOf(raw, salt)
    local sum = 0
    for i = 1, #raw do
        sum = (sum + (raw:byte(i) * (i + salt))) % 0xFFFFFFF
    end
    return sum
end


local function ComputeHandoffCoords(citizenid, seq, origin)
    local raw = ('%s#%d#%d'):format(tostring(citizenid), GetGameTimer(), seq)
    local sum = ChecksumOf(raw, 41)


    local angleDeg  = sum % 360
    local minOff    = Config.Rendezvous.MinOffsetMeters
    local maxOff    = Config.Rendezvous.MaxOffsetMeters
    local dist      = minOff + ((math.floor(sum / 360) % 1000) / 1000.0) * math_max(maxOff - minOff, 0.0)
    local angleRad  = math.rad(angleDeg)


    return vector3(
        origin.x + (math.cos(angleRad) * dist),
        origin.y + (math.sin(angleRad) * dist),
        origin.z
    )
end


-- =====================================================================
-- Trap house yakınlık yardımcısı — bureau.lua/logistics.lua/market.lua
-- ile AYNI local desen (paylaşımlı bir export yerine dosya-yerel kopya;
-- mevcut kod tabanının kendi konvansiyonu).
-- =====================================================================
local function VectorDistance(a, b)
    if not a or not b then return math_huge end
    return #(a - b)
end


local function FindNearestTrapHouse(coords)
    local nearestId, nearestDist = nil, math_huge
    for id, house in pairs(Matrix.TrapHouses or {}) do
        local d = VectorDistance(coords, house.coords)
        if d < nearestDist then nearestId, nearestDist = id, d end
    end
    return nearestId, nearestDist
end


-- =====================================================================
-- RUNTIME STATE
-- [handoffId] = { src, citizenid, catalog_type, catalog_id, label, item,
--                 count, metadata, coords, expires_at, resolved }
-- =====================================================================
local PendingHandoffs = {}
-- src -> { trap_house_id, started_at }  (aktif pusu — K panel bülteni bunu okur)
local ActiveAmbush    = {}


local AMBUSH_BULLETIN_SECONDS = (Config.Rendezvous and Config.Rendezvous.AmbushBulletinDurationSeconds) or 90


-- =====================================================================
-- SCHEDULE HANDOFF — server/blackmarket.lua buyWeapon/buyAmmo'dan çağrılır.
-- =====================================================================
function Matrix.Rendezvous.ScheduleHandoff(src, citizenid, opts)
    if type(src) ~= 'number' or src <= 0 then return false, 'bad_src' end
    if type(opts) ~= 'table' or type(opts.item) ~= 'string' then return false, 'bad_opts' end
    if not Config.Rendezvous or not Config.Rendezvous.Enabled then return false, 'disabled' end


    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false, 'no_ped' end
    local origin = GetEntityCoords(ped)


    local handoffId = NextHandoffId()
    local coords = ComputeHandoffCoords(citizenid, handoffId, origin)


    PendingHandoffs[handoffId] = {
        src          = src,
        citizenid    = citizenid,
        catalog_type = opts.catalog_type,
        catalog_id   = opts.catalog_id,
        label        = opts.label or 'Karaborsa Teslimatı',
        item         = opts.item,
        count        = opts.count or 1,
        metadata     = opts.metadata,
        coords       = coords,
        expires_at   = Matrix.Now() + Config.Rendezvous.PickupWindowSeconds,
        resolved     = false
    }


    MySQL.prepare([[
        INSERT INTO matrix_rendezvous_events
            (id, citizenid, catalog_type, catalog_id, handoff_x, handoff_y, handoff_z,
             trace_level_at_handoff, ambush_triggered, outcome, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, 0.0, 0, 'pending', NOW())
    ]], { handoffId, citizenid, opts.catalog_type, tostring(opts.catalog_id), coords.x, coords.y, coords.z })


    TriggerClientEvent('matrix:client:rendezvousAssigned', src, {
        handoff_id = handoffId,
        label      = opts.label,
        coords     = coords
    })


    TriggerClientEvent('matrix:client:rendezvous:spawnSeller', src, {
        handoff_id = handoffId,
        coords     = coords,
        ped_model  = Config.Rendezvous.SellerPedModel,
        scenario   = Config.Rendezvous.SellerScenario,
        radius     = Config.Rendezvous.PickupRadiusMeters
    })


    Matrix.Log('RENDEZVOUS', 'Buluşma #%d ayarlandı: %s -> %s (%.1f,%.1f,%.1f)',
        handoffId, tostring(citizenid), opts.label or opts.item, coords.x, coords.y, coords.z)


    return true, handoffId
end


-- =====================================================================
-- PICKUP — oyuncu satıcı NPC ile fiziksel olarak buluştuğunda client
-- bu event'i tetikler. Sunucu MESAFEYİ KENDİSİ doğrular (client sadece
-- tetikleyici, güven client'a verilmez).
-- =====================================================================
local function ResolveHandoff(handoffId, outcome, ambushTriggered, traceLevel)
    MySQL.prepare([[
        UPDATE matrix_rendezvous_events
        SET outcome = ?, ambush_triggered = ?, trace_level_at_handoff = ?, resolved_at = NOW()
        WHERE id = ?
    ]], { outcome, ambushTriggered and 1 or 0, traceLevel or 0.0, handoffId })
end


RegisterNetEvent('matrix:server:rendezvous:pickup', function(handoffId)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    handoffId = tonumber(handoffId)
    local handoff = handoffId and PendingHandoffs[handoffId]
    if not handoff or handoff.resolved or handoff.src ~= src then
        Reply(src, 'Bu buluşma için aktif bir teslimat kaydı yok.')
        return
    end


    if Matrix.Now() > handoff.expires_at then
        handoff.resolved = true
        PendingHandoffs[handoffId] = nil
        ResolveHandoff(handoffId, 'expired', false, 0.0)
        TriggerClientEvent('matrix:client:rendezvous:despawnSeller', src, handoffId)
        Reply(src, 'Buluşma penceresi doldu, satıcı ortadan kayboldu.')
        return
    end


    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return end
    local playerCoords = GetEntityCoords(ped)
    if VectorDistance(playerCoords, handoff.coords) > (Config.Rendezvous.PickupRadiusMeters + 2.0) then
        Reply(src, 'Satıcıya yeterince yakın değilsiniz.')
        return
    end


    handoff.resolved = true
    PendingHandoffs[handoffId] = nil
    TriggerClientEvent('matrix:client:rendezvous:despawnSeller', src, handoffId)


    -- ★ [R2] Pusu kontrolü: en yakın trap house'un normalize edilmiş siber
    -- ısısı eşiği geçerse Büro pusu botları sızdırılır. RNG YOK.
    local trapHouseId = FindNearestTrapHouse(handoff.coords)
    local heat = (trapHouseId and Matrix.Bureau and Matrix.Bureau.GetHeat and Matrix.Bureau.GetHeat(trapHouseId)) or 0.0
    local maxHeat = (Config.Bureau and Config.Bureau.CyberLeakMaxIntensity) or 5.0
    local traceLevel = Matrix.Clamp(heat / math_max(maxHeat, 0.0001), 0.0, 1.0)
    local ambush = traceLevel >= Config.Rendezvous.AmbushTraceLevelThreshold


    -- Mal ZATEN ÖDENMİŞTİR (blackmarket.lua) — pusu tetiklense de teslimat yapılır.
    local addOk = pcall(function()
        return exports['ox_inventory']:AddItem(src, handoff.item, handoff.count, handoff.metadata)
    end)


    ResolveHandoff(handoffId, addOk and 'delivered' or 'expired', ambush, traceLevel)


    if not addOk then
        Reply(src, 'Teslimat basarisiz (envanter dolu olabilir) — satici malla birlikte kayboldu.')
        Matrix.Log('RENDEZVOUS', '[TESLIMAT BASARISIZ] #%d %s envanter dolu.', handoffId, tostring(handoff.citizenid))
    else
        Reply(src, ('%s teslim alindi.'):format(handoff.label))
    end


    if ambush then
        ActiveAmbush[src] = { trap_house_id = trapHouseId, started_at = Matrix.Now() }


        TriggerClientEvent('matrix:client:rendezvous:triggerAmbush', src, {
            coords       = handoff.coords,
            ped_model    = Config.Rendezvous.AmbushPedModel,
            weapon       = Config.Rendezvous.AmbushWeapon,
            squad_size   = Config.Rendezvous.AmbushSquadSize,
            spawn_radius = Config.Rendezvous.AmbushSpawnRadius,
            aggro_radius = Config.Rendezvous.AmbushAggroRadius
        })


        Matrix.Log('RENDEZVOUS',
            '[BÜRO PUSUSU] #%d %s -> trap #%s izi=%.3f (eşik:%.2f) — pusu botları sızdırıldı.',
            handoffId, tostring(handoff.citizenid), tostring(trapHouseId), traceLevel, Config.Rendezvous.AmbushTraceLevelThreshold)
    else
        Matrix.Log('RENDEZVOUS', 'Teslimat #%d temiz gecti (iz=%.3f, eşik:%.2f).',
            handoffId, traceLevel, Config.Rendezvous.AmbushTraceLevelThreshold)
    end
end)


-- =====================================================================
-- K TUŞU TAKTİK HUD BÜLTENİ — market.lua BuildSnapshot bu getter'ı
-- (yüklüyse) okur. Sıfır Sayı Standardı: çiğ traceLevel/süre YOK,
-- yalnızca sabit askeri metin + danger bayrağı.
-- =====================================================================
function Matrix.Rendezvous.GetAmbushBulletin(src)
    local state = ActiveAmbush[src]
    if not state then return nil, false end


    if (Matrix.Now() - state.started_at) > AMBUSH_BULLETIN_SECONDS then
        ActiveAmbush[src] = nil
        return nil, false
    end


    return '[BÜRO OPERASYONU: RENDEZVOUS DEŞİFRE OLDU — PUSU AKTİF!]', true
end


--- İstemci tarafında pusu çatışması objektif olarak bittiğinde (tüm pusu
--- botları etkisiz hale getirildiğinde) client bu event'i tetikleyip
--- bülteni erken temizleyebilir. Tetiklenmezse AMBUSH_BULLETIN_SECONDS
--- sonunda otomatik kendiliğinden temizlenir (bkz. GetAmbushBulletin) —
--- bu yüzden bu event OPSİYONELDİR, güvenlik açığı oluşturmaz.
RegisterNetEvent('matrix:server:rendezvous:ambushCleared', function()
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    if ActiveAmbush[src] then
        ActiveAmbush[src] = nil
        Matrix.Log('RENDEZVOUS', 'src=%d pusu manuel olarak temizlendi (client bildirimi).', src)
    end
end)


AddEventHandler('playerDropped', function()
    ActiveAmbush[source] = nil
    for id, handoff in pairs(PendingHandoffs) do
        if handoff.src == source then PendingHandoffs[id] = nil end
    end
end)


-- =====================================================================
-- SÜPÜRME: süresi dolan buluşmaları temizler (satıcı NPC sonsuza kadar
-- client'ta asılı kalmasın).
-- =====================================================================
CreateThread(function()
    while true do
        Wait(15000)
        local now = Matrix.Now()
        for handoffId, handoff in pairs(PendingHandoffs) do
            if now > handoff.expires_at then
                PendingHandoffs[handoffId] = nil
                ResolveHandoff(handoffId, 'expired', false, 0.0)
                TriggerClientEvent('matrix:client:rendezvous:despawnSeller', handoff.src, handoffId)
                Matrix.Log('RENDEZVOUS', 'Buluşma #%d süresi doldu, temizlendi.', handoffId)
            end
        end
    end
end)


-- =====================================================================
-- TAKTİK DEBUG PANELİ
-- =====================================================================
RegisterCommand('rendezvousdurum', function(src)
    local count = 0
    for id, h in pairs(PendingHandoffs) do
        count = count + 1
        Reply(src, ('#%d %s -> %s | Kalan:%ds'):format(id, tostring(h.citizenid), h.label, math_max(h.expires_at - Matrix.Now(), 0)))
    end
    Reply(src, ('--- %d aktif buluşma | %d pusu altında oyuncu ---'):format(count, (function()
        local n = 0
        for _ in pairs(ActiveAmbush) do n = n + 1 end
        return n
    end)()))
end, false)


exports('ScheduleHandoff', function(src, citizenid, opts) return Matrix.Rendezvous.ScheduleHandoff(src, citizenid, opts) end)
exports('GetAmbushBulletin', function(src) return Matrix.Rendezvous.GetAmbushBulletin(src) end)