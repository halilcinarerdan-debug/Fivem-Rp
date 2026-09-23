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

-- ★ [MODUL 10] src -> { [i] = followerNetId } -- client/mercenary_followers.
-- lua'nin ZATEN VAR OLAN Followers listesinden (CreatePed, yani otomatik
-- network nesnesi) turetilen network id'ler; server/hitsquad.lua'nin
-- kolektif hedef havuzu ICIN tek kaynak -- ikinci bir "takipci konumu"
-- tablosu ICAT EDILMEZ, yalnizca client'in zaten sahip oldugu netId'ler
-- rapor edilir.
local FollowerNetIds = {}

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
    return true, FollowerCount[src]
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


--- ★ [MODUL 10] SAF/SENKRON KANCA: client'in en son bildirdigi takipci
--- network id listesinin bir KOPYASINI dondurur (cagiran taraf orijinal
--- tabloyu mutasyona ugratamaz). server/hitsquad.lua kolektif hedef
--- havuzunu bu listeden (NetworkGetEntityFromNetworkId ile) kurar.
function Matrix.Mercenary.GetFollowerNetIds(src)
    local ids = FollowerNetIds[src]
    if not ids then return {} end
    local copy = {}
    for i = 1, #ids do copy[i] = ids[i] end
    return copy
end


RegisterNetEvent('matrix:server:mercenary:requestSummon', function()
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    if not Config.Mercenary or not Config.Mercenary.EnablePhysicalFollowers then return end

    local ok, newCountOrReason = Matrix.Mercenary.RequestSummon(src)
    if not ok then
        local msg = (newCountOrReason == 'cooldown')
            and 'Takipci cagirma kisa bir sure sonra tekrar kullanilabilir.'
            or (newCountOrReason == 'max_reached')
                and 'Zaten maksimum takipci sayisina ulastiniz.'
                or 'Cagri baslatilamadi.'
        TriggerClientEvent('matrix:client:actionNotify', src, false, msg)
        return
    end

    TriggerClientEvent('matrix:client:mercenary:summonApproved', src, newCountOrReason)
end)


RegisterNetEvent('matrix:server:mercenary:reportDismiss', function(remainingCount)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    Matrix.Mercenary.ReportDismiss(src, remainingCount)
end)


-- ★ [MODUL 10] client/mercenary_followers.lua roster her degistiginde
-- (cagirma/olum/salma) guncel netId listesini gonderir -- ACE/permission
-- kontrolu GEREKMEZ (yalnizca kendi src'sinin listesini yazabilir, source
-- her zaman event'i tetikleyen client'tir, spoof edilemez).
RegisterNetEvent('matrix:server:mercenary:reportFollowerNetIds', function(netIds)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    if type(netIds) ~= 'table' then netIds = {} end

    local clean = {}
    for _, netId in ipairs(netIds) do
        local n = tonumber(netId)
        if n and n > 0 then clean[#clean + 1] = n end
    end
    FollowerNetIds[src] = clean
end)


AddEventHandler('playerDropped', function()
    local src = source
    SummonCooldown[src] = nil
    FollowerCount[src]   = nil
    FollowerNetIds[src]  = nil
end)


exports('RequestSummon',  function(src)               return Matrix.Mercenary.RequestSummon(src) end)
exports('ReportDismiss',  function(src, remaining)    return Matrix.Mercenary.ReportDismiss(src, remaining) end)
exports('GetFollowerCount', function(src)             return Matrix.Mercenary.GetFollowerCount(src) end)
exports('GetFollowerNetIds', function(src)            return Matrix.Mercenary.GetFollowerNetIds(src) end)