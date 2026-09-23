-- =====================================================================
-- MATRIX MUHAFIZ/KURYE TAKİPÇİLERİ / server/mercenary_followers.lua
-- (KATMAN 1)
--
-- ★ KATMAN 23 DÜZELTMESİ: Matrix.Mercenary.* fonksiyon kancaları artık
-- diagnostics/ModularSimulationQueue tarafından probe edilebilir. Önceki
-- sürüm yalnızca RegisterNetEvent handler'ları taşıyordu; hiçbir isim
-- alanı kancası yoktu — bu yüzden matrix_diagnostics.lua'daki
-- `Matrix.Mercenary.RequestSummon` probe'u nil dönüyordu.
-- =====================================================================

Matrix.Mercenary = Matrix.Mercenary or {}

local SummonCooldown = {} -- [src] = sonraki izinli cagri zamani (Unix saniye)
local FollowerCount  = {} -- [src] = su anki aktif takipci sayisi

-- ★ KALICI MUHAFIZ KİMLİĞİ (Aşama 0): [citizenid][slot] = botId. RAM'de
-- tutulur (resource ayakta kaldığı sürece kalıcı) — her (citizenid, slot)
-- çifti İLK çağrıldığında Matrix.CreateBotRecord ile bir kez oluşturulur,
-- sonraki her çağrıda AYNI bot.id (dolayısıyla Matrix.ResolveBotIdentity'nin
-- ürettiği AYNI ped modeli + AYNI rumuz) yeniden kullanılır -- "her
-- seferinde farklı pedle geliyorlar" sorunu bu eşlemeyle yapısal olarak
-- ortadan kalkar.
local FollowerBotIdByCitizen = {} -- [citizenid][slot] = botId

local function ResolveFollowerBot(src, slot)
    local state = Matrix.GetOrCreatePlayerState and Matrix.GetOrCreatePlayerState(src)
    local citizenid = state and state.citizenid
    if not citizenid then return nil end

    FollowerBotIdByCitizen[citizenid] = FollowerBotIdByCitizen[citizenid] or {}
    local slotMap = FollowerBotIdByCitizen[citizenid]

    local botId = slotMap[slot]
    local bot = botId and Matrix.Bots[botId]
    if not bot then
        bot = Matrix.CreateBotRecord({
            role               = 'guard',
            handler_citizenid  = citizenid,
            name               = ('Muhafiz-%s-%d'):format(citizenid, slot)
        })
        slotMap[slot] = bot.id
    end

    local pedModel, pedHash, displayName = Matrix.ResolveBotIdentity(bot)
    return bot.id, pedModel, displayName
end

--- ★ SAF/SENKRON KANCA: diagnostics tarafindan probe edilebilir.
--- Config.Mercenary.EnablePhysicalFollowers KAPALI iken erken ve GÜVENLİ
--- döner (Safe-Exit) — nil/global runtime hatası ASLA fırlatmaz.
function Matrix.Mercenary.RequestSummon(src)
    if type(src) ~= 'number' or src <= 0 then return false, 'bad_src' end
    if not Config.Mercenary or not Config.Mercenary.EnablePhysicalFollowers then
        return false, 'disabled'
    end

    local now = Matrix.Now()
    if SummonCooldown[src] and now < SummonCooldown[src] then
        return false, 'cooldown'
    end

    local current = FollowerCount[src] or 0
    if current >= (Config.Mercenary.MaxFollowers or 2) then
        return false, 'max_reached'
    end

    SummonCooldown[src] = now + math.floor((Config.Mercenary.SummonCooldownMs or 5000) / 1000)
    FollowerCount[src]   = current + 1

    local slot = FollowerCount[src]
    local botId, pedModel, displayName = ResolveFollowerBot(src, slot)

    return true, FollowerCount[src], botId, pedModel, displayName
end

--- ★ SAF/SENKRON KANCA: client 'matrix:server:mercenary:reportDismiss'
--- event'inden geldiginde sayaci senkronlar. Manuel probe icin de guvenli.
function Matrix.Mercenary.ReportDismiss(src, remainingCount)
    if type(src) ~= 'number' or src <= 0 then return false end
    FollowerCount[src] = math.max(0, tonumber(remainingCount) or 0)
    return true
end

--- Salt-okunur getter — diagnostics/HUD/rapor icin.
function Matrix.Mercenary.GetFollowerCount(src)
    return FollowerCount[src] or 0
end

--- F10 menüsü/nametag için: bu oyuncunun kalıcı muhafız kadrosu.
--- Döner: { {slot, botId, displayName, pedModel, role, status, trap_house_id}, ... }
function Matrix.Mercenary.GetFollowerRoster(src)
    local state = Matrix.GetOrCreatePlayerState and Matrix.GetOrCreatePlayerState(src)
    local citizenid = state and state.citizenid
    if not citizenid then return {} end

    local slotMap = FollowerBotIdByCitizen[citizenid]
    if not slotMap then return {} end

    local roster = {}
    for slot, botId in pairs(slotMap) do
        local bot = Matrix.Bots[botId]
        if bot then
            local pedModel, _, displayName = Matrix.ResolveBotIdentity(bot)
            roster[#roster + 1] = {
                slot          = slot,
                botId         = botId,
                displayName   = displayName,
                pedModel      = pedModel,
                role          = bot.role,
                status        = bot.status,
                trap_house_id = bot.state.trap_house_id
            }
        end
    end
    table.sort(roster, function(a, b) return a.slot < b.slot end)
    return roster
end


RegisterNetEvent('matrix:server:mercenary:requestSummon', function()
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    if not Config.Mercenary or not Config.Mercenary.EnablePhysicalFollowers then return end

    local ok, newCountOrReason, botId, pedModel, displayName = Matrix.Mercenary.RequestSummon(src)
    if not ok then
        local msg = (newCountOrReason == 'cooldown')
            and 'Takipci cagirma kisa bir sure sonra tekrar kullanilabilir.'
            or (newCountOrReason == 'max_reached')
                and 'Zaten maksimum takipci sayisina ulastiniz.'
                or 'Cagri baslatilamadi.'
        TriggerClientEvent('matrix:client:actionNotify', src, false, msg)
        return
    end

    TriggerClientEvent('matrix:client:mercenary:summonApproved', src, newCountOrReason, botId, pedModel, displayName)
end)


RegisterNetEvent('matrix:server:mercenary:reportDismiss', function(remainingCount)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    Matrix.Mercenary.ReportDismiss(src, remainingCount)
end)


AddEventHandler('playerDropped', function()
    local src = source
    SummonCooldown[src] = nil
    FollowerCount[src]   = nil
end)


exports('RequestSummon',  function(src)               return Matrix.Mercenary.RequestSummon(src) end)
exports('ReportDismiss',  function(src, remaining)    return Matrix.Mercenary.ReportDismiss(src, remaining) end)
exports('GetFollowerCount', function(src)             return Matrix.Mercenary.GetFollowerCount(src) end)
exports('GetFollowerRoster', function(src)            return Matrix.Mercenary.GetFollowerRoster(src) end)


-- =====================================================================
-- ARMA 3 TARZI KOMUT MENÜSÜ — F10'dan seçilen bir muhafıza mod atar.
-- Mod client tarafında yorumlanır (follow/hold/guard/attack); burada
-- sadece bot.state üzerinde kalıcı/deterministik olarak saklanır ki
-- diagnostics/roster sorguları da aynı durumu görsün.
-- =====================================================================
-- ★ Not: kasıtlı olarak "suppressive fire" gibi gerçekçi-olmayan/oyun
-- dengesini bozan bir mod EKLENMEDİ (kullanıcı isteği). "observe" (gözlem)
-- gerçekçi bir Arma 3 komutu — bot ateş etmeden, sessizce pozisyonda kalıp
-- görüş hattındaki düşmanları izler/raporlar.
local VALID_MODES = { follow = true, hold = true, guard = true, attack = true, observe = true }

function Matrix.Mercenary.SetFollowerMode(src, botId, mode, extra)
    if not VALID_MODES[mode] then return false, 'bad_mode' end
    local bot = Matrix.Bots[tonumber(botId)]
    if not bot then return false, 'bot_missing' end

    local state = Matrix.GetOrCreatePlayerState and Matrix.GetOrCreatePlayerState(src)
    if not state or bot.handler_citizenid ~= state.citizenid then return false, 'not_owner' end

    bot.state.guard_mode      = mode
    bot.state.guard_mode_coords = (mode == 'hold' or mode == 'guard') and extra or nil
    Matrix.MarkBotDirty(bot.id)
    return true
end

RegisterNetEvent('matrix:server:mercenary:setFollowerMode', function(botId, mode, extra)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    local ok, reason = Matrix.Mercenary.SetFollowerMode(src, botId, mode, extra)
    if not ok then
        TriggerClientEvent('matrix:client:actionNotify', src, false, 'Komut uygulanamadi: ' .. tostring(reason))
        return
    end
    TriggerClientEvent('matrix:client:mercenary:modeApplied', src, tonumber(botId), mode, extra)
end)

exports('SetFollowerMode', function(src, botId, mode, extra) return Matrix.Mercenary.SetFollowerMode(src, botId, mode, extra) end)