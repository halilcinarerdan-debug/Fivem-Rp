-- =====================================================================
-- MATRIX DOOR REINFORCEMENT / server/door_reinforcement.lua (KATMAN 6 — YENİ)
--
-- Kapı Sürgü Tahkimatı: F10 üzerinden satın alınan barikat seviyesi
-- (0-3), Büro Şafak Baskını tetiklendiğinde (server/bureau.lua Matrix.
-- Bureau.IssueRaid — DEĞİŞTİRİLMEDİ, yalnızca KÜÇÜK bir guard'lı köprü
-- eklendi, bkz. bureau.lua ComputeRaidSquad yorumu) kapı kırılma süresine
-- (escapeWindow) bir bonus ekler. Bureau'nun kendi mürettebat/breach/
-- desifre formülleri bu dosyaya HİÇ bağımlı değildir — bağlantı TEK
-- yönlüdür (bureau.lua -> Matrix.DoorReinforcement.GetBreachDelaySeconds).
--
-- Geri sayım/last-stand durumu, bureau.lua'nın fırlattığı iki pasif
-- server-içi event ile senkronize edilir (bureau.lua bu dosyanın var
-- olup olmadığını BİLMEZ, yalnızca event'i yayınlar):
--   'matrix:internal:raidIssued'  (trapHouseId, escapeWindow, breachMethod, squadSize)
--   'matrix:internal:raidResolved'(trapHouseId, outcome)
-- =====================================================================


Matrix.DoorReinforcement = Matrix.DoorReinforcement or {}


local pairs, ipairs, type, tostring = pairs, ipairs, type, tostring
local tonumber, math                = tonumber, math
local math_max, math_floor          = math.max, math.floor
local TriggerClientEvent            = TriggerClientEvent
local GetPlayerPed                  = GetPlayerPed
local GetEntityCoords               = GetEntityCoords


local function Reply(src, msg)
    if type(src) == 'number' and src > 0 then
        TriggerClientEvent('chat:addMessage', src, { args = { '[TAHKIMAT]', msg } })
    else
        print(('[MATRIX:DOORREINFORCEMENT:CONSOLE] %s'):format(msg))
    end
end


local function HasCommandAuthority(src)
    if not (Matrix.Hierarchy and Matrix.Hierarchy.HasCommandAuthority) then return true end
    local state = Matrix.GetOrCreatePlayerState(src)
    if not state or not state.citizenid then return false end
    return Matrix.Hierarchy.HasCommandAuthority(state.citizenid)
end


local function ChargeCash(src, amount)
    local ok, player = pcall(function() return Matrix.QBX:GetPlayer(src) end)
    if not ok or not player or not player.PlayerData then return false, 'player_not_found' end
    local cash = (player.PlayerData.money and player.PlayerData.money.cash) or 0
    if cash < amount then return false, 'insufficient_funds' end
    local removeOk = pcall(function() return player.Functions.RemoveMoney('cash', amount, 'door-reinforcement') end)
    if not removeOk then return false, 'charge_failed' end
    return true
end


-- =====================================================================
-- SEVİYE DURUMU (RAM + kalıcı)
-- =====================================================================
local DoorLevel  = {} -- trapHouseId -> 0..MaxLevel
local dirtyLevel = {} -- trapHouseId -> citizenid (kim yukselttiyse)


local function LoadDoorLevels()
    local callOk = pcall(function()
        MySQL.query('SELECT trap_house_id, level FROM matrix_door_reinforcement', {}, function(rows)
            pcall(function()
                if type(rows) == 'table' then
                    for _, row in ipairs(rows) do
                        if row and row.trap_house_id then
                            DoorLevel[row.trap_house_id] = tonumber(row.level) or 0
                        end
                    end
                    Matrix.Log('DOORREINFORCEMENT', '%d kapi tahkimat kaydi yuklendi.', #rows)
                end
            end)
        end)
    end)
    if not callOk then
        Matrix.Log('DOORREINFORCEMENT', '[HATA] matrix_door_reinforcement sorgu cagrisi reddedildi; RAM bos baslatildi.')
    end
end


CreateThread(function()
    LoadDoorLevels()
end)


-- ★ CRITICAL FIX: toplu MySQL.transaction.await; RAM bayraklari SADECE
-- basari sonrasi temizlenir.
local function FlushDirtyLevels()
    local pendingHouses = {}
    for trapHouseId in pairs(dirtyLevel) do
        pendingHouses[#pendingHouses + 1] = trapHouseId
    end
    if #pendingHouses == 0 then return end


    local queries = {}
    for _, trapHouseId in ipairs(pendingHouses) do
        local citizenid = dirtyLevel[trapHouseId]
        queries[#queries + 1] = {
            query = [[
                INSERT INTO matrix_door_reinforcement (trap_house_id, level, installed_by_citizenid, updated_at)
                VALUES (?, ?, ?, NOW())
                ON DUPLICATE KEY UPDATE level = VALUES(level), installed_by_citizenid = VALUES(installed_by_citizenid), updated_at = NOW()
            ]],
            values = { trapHouseId, DoorLevel[trapHouseId] or 0, citizenid }
        }
    end


    local ok, result = pcall(function() return MySQL.transaction.await(queries) end)
    if ok and result ~= false then
        for _, trapHouseId in ipairs(pendingHouses) do dirtyLevel[trapHouseId] = nil end
    else
        Matrix.Log('DOORREINFORCEMENT',
            '[HATA][KRITIK] FlushDirtyLevels transaction basarisiz -- dirty bayraklar KORUNDU, tekrar denenecek: %s',
            tostring(result))
    end
end


CreateThread(function()
    local interval = (Config.Persistence and Config.Persistence.TrapHouseFlushIntervalMs) or 20000
    while true do
        Wait(interval)
        FlushDirtyLevels()
    end
end)


function Matrix.DoorReinforcement.GetLevel(trapHouseId)
    return DoorLevel[trapHouseId] or 0
end


--- ★ bureau.lua ComputeRaidSquad'ın okuduğu SAF getter. Bureau'nun kendi
--- formülüne HİÇ dokunmaz — yalnızca ekstra saniye DEĞERİ döner.
function Matrix.DoorReinforcement.GetBreachDelaySeconds(trapHouseId)
    local level = Matrix.DoorReinforcement.GetLevel(trapHouseId)
    local cfg = Config.DoorReinforcement.Levels[level]
    return cfg and cfg.breach_bonus_seconds or 0
end


function Matrix.DoorReinforcement.Install(src, trapHouseId, targetLevel)
    trapHouseId = tonumber(trapHouseId)
    targetLevel = tonumber(targetLevel)
    if not trapHouseId or not Matrix.TrapHouses[trapHouseId] then return false, 'bad_trap_house' end
    if not targetLevel or not Config.DoorReinforcement.Levels[targetLevel] then return false, 'bad_level' end
    if not HasCommandAuthority(src) then return false, 'no_authority' end


    local currentLevel = Matrix.DoorReinforcement.GetLevel(trapHouseId)
    if targetLevel ~= currentLevel + 1 then return false, 'must_upgrade_sequentially' end


    local cfg = Config.DoorReinforcement.Levels[targetLevel]
    local ok, reason = ChargeCash(src, cfg.price)
    if not ok then return false, reason end


    DoorLevel[trapHouseId] = targetLevel
    local state = Matrix.GetOrCreatePlayerState(src)
    dirtyLevel[trapHouseId] = (state and state.citizenid) or 'UNKNOWN'


    Matrix.Log('DOORREINFORCEMENT', '[TAHKIMAT YUKSELTILDI] Trap #%d -> Seviye %d (%s) | %s',
        trapHouseId, targetLevel, cfg.label, tostring(state and state.citizenid))


    return true, cfg
end


RegisterNetEvent('matrix:server:doorReinforcement:install', function(trapHouseId, targetLevel)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end


    local ok, resultOrReason = Matrix.DoorReinforcement.Install(src, trapHouseId, targetLevel)
    if not ok then
        local messages = {
            bad_trap_house              = 'Gecersiz trap house.',
            bad_level                   = 'Gecersiz tahkimat seviyesi.',
            no_authority                = 'Bu islemi yapmak icin yeterli rutbeniz yok (Logistics_Officer veya Leader gerekir).',
            must_upgrade_sequentially   = 'Tahkimat yalnizca bir ust seviyeye sirayla yukseltilebilir.',
            insufficient_funds          = 'Yetersiz nakit.',
            player_not_found            = 'Oyuncu profili cozulemedi.',
            charge_failed               = 'Odeme basarisiz.'
        }
        Reply(src, messages[resultOrReason] or ('Tahkimat basarisiz: %s'):format(tostring(resultOrReason)))
        return
    end


    Reply(src, ('%s monte edildi. Kapı kırılma süresi artık daha uzun.'):format(resultOrReason.label))
end)


-- =====================================================================
-- ★ DÜŞMAN TRAP HOUSE KAPI KIRMA DONANIMI (breaching_tool) ★
--
-- Server-otoriteli: HİÇBİR adım client'ın "başardım" beyanına güvenmez.
--   1) Hedef trap house'un GERÇEKTEN tahkim edilmiş olması gerekir
--      (DoorLevel > 0) -- sıfır seviyede kırma aleti GEREKSİZDİR.
--   2) Aynı anda YALNIZCA bir kişi bir kapıyı kırabilir (ActiveBreaches
--      ile per-trapHouse mutex) -- eşzamanlı çoklu kırma girişimi engeli.
--   3) Süre boyunca HER RecheckIntervalMs'de mesafe + item + ped varlığı
--      YENİDEN doğrulanır -- "başlat ve uzaklaş" veya "aleti sat/düşür"
--      ile bypass İMKANSIZDIR.
--   4) Alet yalnızca BAŞARILI kırmada tüketilir (RemoveItem) -- iptal/
--      kesinti durumunda oyuncu aleti kaybetmez.
--   5) Örgüt hiyerarşisi (HasCommandAuthority) BİLİNÇLİ OLARAK aranmaz --
--      bu, Install'ın (yukarıda) tam tersi: "dışarıdan" bir saldırı eylemi.
-- =====================================================================
local ActiveBreaches = {} -- trapHouseId -> { src, started_at, duration, level }


local function CountPlayerItem(src, itemName)
    local ok, count = pcall(function()
        return exports['ox_inventory']:Search(src, 'count', itemName)
    end)
    if not ok or type(count) ~= 'number' then return 0 end
    return count
end


local function DistanceToTrapHouse(src, trapHouseId)
    local house = Matrix.TrapHouses[trapHouseId]
    if not house or not house.coords then return math.huge end
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return math.huge end
    local okCoords, coords = pcall(GetEntityCoords, ped)
    if not okCoords or not coords then return math.huge end
    local dx, dy, dz = coords.x - house.coords.x, coords.y - house.coords.y, coords.z - house.coords.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end


--- Kırma girişimini BAŞLATIR (henüz tamamlamaz). Tüm ön-koşullar server
--- tarafında doğrulanır; başarısızlıkta net bir 'reason' döner.
function Matrix.DoorReinforcement.StartBreach(src, trapHouseId)
    trapHouseId = tonumber(trapHouseId)
    if not trapHouseId or not Matrix.TrapHouses[trapHouseId] then return false, 'bad_trap_house' end

    local level = Matrix.DoorReinforcement.GetLevel(trapHouseId)
    if level <= 0 then return false, 'not_reinforced' end

    if ActiveBreaches[trapHouseId] then return false, 'already_being_breached' end
    for _, breach in pairs(ActiveBreaches) do
        if breach.src == src then return false, 'already_breaching_elsewhere' end
    end

    local toolCfg = Config.DoorReinforcement.BreachingTool
    if CountPlayerItem(src, toolCfg.ItemName) < 1 then return false, 'missing_tool' end

    if DistanceToTrapHouse(src, trapHouseId) > toolCfg.MaxRangeMeters then
        return false, 'too_far'
    end

    local duration = toolCfg.BaseSeconds + (level * toolCfg.PerLevelSecondsBonus)

    ActiveBreaches[trapHouseId] = {
        src         = src,
        started_at  = Matrix.Now(),
        duration    = duration,
        level       = level
    }

    -- İçerideki savunucular İÇİN adil telegraf: barikat zorlanıyor uyarısı
    -- (Last Stand ile AYNI occupant-bulma deseni).
    local occupants = (Matrix.TrapHouseInterior and Matrix.TrapHouseInterior.GetOccupants
        and Matrix.TrapHouseInterior.GetOccupants(trapHouseId)) or {}
    for _, occupantSrc in ipairs(occupants) do
        TriggerClientEvent('matrix:client:doorReinforcement:breachStarted', occupantSrc, trapHouseId, duration)
    end

    Matrix.Log('DOORREINFORCEMENT',
        '[KAPI KIRMA BASLADI] src=%d trap=#%d seviye=%d sure=%ds alet=%s',
        src, trapHouseId, level, duration, toolCfg.ItemName)

    return true, duration
end


local function CancelBreach(trapHouseId, reason)
    local breach = ActiveBreaches[trapHouseId]
    if not breach then return end
    ActiveBreaches[trapHouseId] = nil
    TriggerClientEvent('matrix:client:doorReinforcement:breachCancelled', breach.src, trapHouseId, reason)
    Matrix.Log('DOORREINFORCEMENT',
        '[KAPI KIRMA IPTAL] src=%s trap=#%d sebep=%s',
        tostring(breach.src), trapHouseId, tostring(reason))
end


local function CompleteBreach(trapHouseId)
    local breach = ActiveBreaches[trapHouseId]
    if not breach then return end
    ActiveBreaches[trapHouseId] = nil

    -- ★ Alet YALNIZCA burada, gerçek tamamlanma anında tüketilir.
    local toolCfg = Config.DoorReinforcement.BreachingTool
    local removeOk, removed = pcall(function()
        return exports['ox_inventory']:RemoveItem(breach.src, toolCfg.ItemName, 1)
    end)
    if not (removeOk and removed == true) then
        Matrix.Log('DOORREINFORCEMENT',
            '[KAPI KIRMA IPTAL] src=%d trap=#%d sebep=alet_artik_yok (tamamlanma anında dogrulama basarisiz)',
            breach.src, trapHouseId)
        TriggerClientEvent('matrix:client:actionNotify', breach.src, false, 'Kirma aleti artik envanterinizde yok.')
        return
    end

    local newLevel = math_max(0, breach.level - toolCfg.LevelsBypassedOnBreach)
    DoorLevel[trapHouseId] = newLevel
    dirtyLevel[trapHouseId] = 'BREACHED'

    TriggerClientEvent('matrix:client:doorReinforcement:breachSucceeded', breach.src, trapHouseId, newLevel)

    local occupants = (Matrix.TrapHouseInterior and Matrix.TrapHouseInterior.GetOccupants
        and Matrix.TrapHouseInterior.GetOccupants(trapHouseId)) or {}
    for _, occupantSrc in ipairs(occupants) do
        TriggerClientEvent('matrix:client:doorReinforcement:breachSucceeded', occupantSrc, trapHouseId, newLevel)
    end

    -- ★ Adli değerlendirme köprüsü (server/forensics.lua) -- pcall'lı,
    -- forensics.lua yüklenmemiş/kaldırılmış olsa bile bu dosya ÇÖKMEZ.
    if Matrix.Forensics and Matrix.Forensics.RecordBreachToolMarks then
        pcall(Matrix.Forensics.RecordBreachToolMarks, breach.src, trapHouseId, toolCfg.ItemName)
    end

    Matrix.Log('DOORREINFORCEMENT',
        '[KAPI KIRILDI] src=%d trap=#%d eski_seviye=%d -> yeni_seviye=%d',
        breach.src, trapHouseId, breach.level, newLevel)
end


RegisterNetEvent('matrix:server:doorReinforcement:startBreach', function(trapHouseId)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end

    local ok, durationOrReason = Matrix.DoorReinforcement.StartBreach(src, trapHouseId)
    if not ok then
        local messages = {
            bad_trap_house           = 'Gecersiz trap house.',
            not_reinforced           = 'Bu kapi zaten tahkimatsiz -- alete gerek yok.',
            already_being_breached   = 'Bu kapi zaten baska biri tarafindan zorlaniyor.',
            already_breaching_elsewhere = 'Zaten baska bir kapiyi zorluyorsunuz.',
            missing_tool             = 'Hidrolik levye (kirma aleti) envanterinizde yok.',
            too_far                  = 'Kapiya yeterince yakin degilsiniz.'
        }
        TriggerClientEvent('matrix:client:actionNotify', src, false,
            messages[durationOrReason] or ('Kirma baslatilamadi: %s'):format(tostring(durationOrReason)))
        return
    end
    TriggerClientEvent('matrix:client:actionNotify', src, true,
        ('Kirma baslatildi. Sure: %ds -- konumunuzu koruyun.'):format(durationOrReason))
end)


exports('StartDoorBreach', function(src, trapHouseId) return Matrix.DoorReinforcement.StartBreach(src, trapHouseId) end)


-- =====================================================================
-- BASKIN GERİ SAYIMI (bureau.lua'nın pasif event yayınıyla senkron)
-- =====================================================================
local BreachState = {} -- trapHouseId -> { expires_at, total, breach_method, squad_size, last_stand_fired }


AddEventHandler('matrix:internal:raidIssued', function(trapHouseId, escapeWindow, breachMethod, squadSize)
    trapHouseId = tonumber(trapHouseId)
    if not trapHouseId then return end
    BreachState[trapHouseId] = {
        expires_at       = Matrix.Now() + (tonumber(escapeWindow) or 0),
        total            = tonumber(escapeWindow) or 0,
        breach_method    = breachMethod,
        squad_size       = squadSize,
        last_stand_fired = false
    }
end)


AddEventHandler('matrix:internal:raidResolved', function(trapHouseId, outcome)
    trapHouseId = tonumber(trapHouseId)
    if trapHouseId then BreachState[trapHouseId] = nil end
end)


--- ★ Sıfır Sayı Standardı: K panelinde YALNIZCA formatlanmış MM:SS metni
--- basılır, çiğ saniye asla HUD'a sızmaz. Yalnızca o trap house'un İÇİNDEKİ
--- oyuncuya (Matrix.TrapHouseInterior.GetPlayerTrapHouse ile) gösterilir.
function Matrix.DoorReinforcement.GetBreachCountdownText(src)
    if not (Matrix.TrapHouseInterior and Matrix.TrapHouseInterior.GetPlayerTrapHouse) then return nil, false end
    local trapHouseId = Matrix.TrapHouseInterior.GetPlayerTrapHouse(src)
    if not trapHouseId then return nil, false end


    local state = BreachState[trapHouseId]
    if not state then return nil, false end


    local remaining = math_max(state.expires_at - Matrix.Now(), 0)
    local mm = math_floor(remaining / 60)
    local ss = remaining % 60
    return ('[KAPIDA ADLI ANOMALI: BARIKAT ZORLANIYOR — TAHLIYE SURESI: Kalan %02d:%02d]'):format(mm, ss), true
end


-- =====================================================================
-- LAST STAND: geri sayım sıfırlandığında, o trap house'un İÇİNDEKİ tüm
-- oyunculara tek seferlik bir "son çare" bildirimi + Açık Hat/COMINT
-- görüşmesi otomatik keser (Büro içeri girdiğinde telefonla konuşulmaz).
-- =====================================================================
CreateThread(function()
    while true do
        Wait(1000)
        local now = Matrix.Now()
        for trapHouseId, state in pairs(BreachState) do
            if not state.last_stand_fired and now >= state.expires_at then
                state.last_stand_fired = true


                local occupants = (Matrix.TrapHouseInterior and Matrix.TrapHouseInterior.GetOccupants
                    and Matrix.TrapHouseInterior.GetOccupants(trapHouseId)) or {}


                for _, occupantSrc in ipairs(occupants) do
                    TriggerClientEvent('matrix:client:doorReinforcement:lastStand', occupantSrc, trapHouseId)
                    if Matrix.Comint and Matrix.Comint.ReportCallState then
                        pcall(Matrix.Comint.ReportCallState, occupantSrc, false)
                    end
                end


                Matrix.Log('DOORREINFORCEMENT',
                    '[SON CARE] Trap #%d barikati zorlandi, %d oyuncu son savas moduna gecti.',
                    trapHouseId, #occupants)
            end
        end

        -- ★ KAPI KIRMA (breaching_tool) İLERLEME/YENİDEN-DOĞRULAMA:
        -- ayrı bir Wait(0)/hot-loop AÇILMAZ, AYNI 1000ms tarama bütçesi
        -- paylaşılır (0.00ms ResMon ilkesiyle tutarlı). Her turda mesafe
        -- ve alet varlığı YENİDEN kontrol edilir -- "başlat ve uzaklaş"
        -- veya aleti düşür/sat ile bypass mümkün değildir.
        for trapHouseId, breach in pairs(ActiveBreaches) do
            local toolCfg = Config.DoorReinforcement.BreachingTool
            if DistanceToTrapHouse(breach.src, trapHouseId) > toolCfg.MaxRangeMeters then
                CancelBreach(trapHouseId, 'moved_away')
            elseif CountPlayerItem(breach.src, toolCfg.ItemName) < 1 then
                CancelBreach(trapHouseId, 'tool_lost')
            elseif (now - breach.started_at) >= breach.duration then
                CompleteBreach(trapHouseId)
            end
        end
    end
end)


AddEventHandler('playerDropped', function()
    local src = source
    for trapHouseId, breach in pairs(ActiveBreaches) do
        if breach.src == src then CancelBreach(trapHouseId, 'disconnected') end
    end
end)


-- =====================================================================
-- TAKTİK DEBUG PANELİ
-- =====================================================================
RegisterCommand('tahkimatdurum', function(src, args)
    local id = tonumber(args[1])
    if not id or not Matrix.TrapHouses[id] then Reply(src, 'Kullanim: /tahkimatdurum [trapHouseId]'); return end


    local level = Matrix.DoorReinforcement.GetLevel(id)
    local cfg = Config.DoorReinforcement.Levels[level]
    Reply(src, ('Trap #%d | Seviye:%d (%s) | Kapi Bonusu:+%ds'):format(
        id, level, cfg and cfg.label or '?', cfg and cfg.breach_bonus_seconds or 0))


    local breach = BreachState[id]
    if breach then
        Reply(src, ('AKTIF BASKIN: kalan %ds / toplam %ds'):format(math_max(breach.expires_at - Matrix.Now(), 0), breach.total))
    end
end, false)


exports('GetDoorReinforcementLevel', function(trapHouseId) return Matrix.DoorReinforcement.GetLevel(trapHouseId) end)
exports('GetBreachDelaySeconds', function(trapHouseId) return Matrix.DoorReinforcement.GetBreachDelaySeconds(trapHouseId) end)
exports('InstallDoorReinforcement', function(src, trapHouseId, targetLevel) return Matrix.DoorReinforcement.Install(src, trapHouseId, targetLevel) end)