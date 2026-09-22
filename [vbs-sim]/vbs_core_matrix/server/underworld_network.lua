-- =====================================================================
-- MATRIX YERALTI AĞI / server/underworld_network.lua
-- (KATMAN 5: Deterministik Satıcı Dağılımı + Sorgu, KATMAN 6: Parçalanmış
--  İstihbarat Defteri + Karşı-İstihbarat Vetting)
--
-- Aynı kaynağın PAYLAŞIMLI Lua ortamı gereği Matrix.Bureau/Matrix.Market/
-- Matrix.Inspector/Matrix.QBX doğrudan çağrılır (server/district_hubs.lua
-- İLE AYNI intra-resource çağrı disiplini) -- exports() yalnızca
-- kaynaklar-arası köprü için kullanılır, burada gerekmez.
-- =====================================================================


Matrix.VendorPool      = Matrix.VendorPool or {}
Matrix.FragmentedIntel = Matrix.FragmentedIntel or {}


local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local math_min, math_max, math_floor          = math.min, math.max, math.floor
local math_huge                               = math.huge


local function Reply(src, msg)
    if type(src) == 'number' and src > 0 then
        TriggerClientEvent('chat:addMessage', src, { args = { '[YERALTI AGI]', msg } })
    else
        print(('[MATRIX:UNDERWORLD:CONSOLE] %s'):format(msg))
    end
end


local function VectorDistance(a, b)
    if not a or not b then return math_huge end
    local dx, dy, dz = a.x - b.x, a.y - b.y, (a.z or 0.0) - (b.z or 0.0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end


-- RNG YOK: server/blackmarket.lua ChecksumOf İLE AYNI desen.
local function ChecksumOf(raw, salt)
    local sum = 0
    for i = 1, #raw do
        sum = (sum + (raw:byte(i) * (i + salt))) % 0xFFFFFFF
    end
    return sum
end


-- =====================================================================
-- [KATMAN 5] TAZE-KURULUM DETERMİNİSTİK SATICI DAĞILIMI
-- İlk açılışta (tablo boşsa) server/DB adı + satıcı id'sinin sağlama
-- toplamından koordinat/gang_loyalty/fear_index türetilir -- her restart
-- AYNI dağılımı üretir (RNG YOK).
-- =====================================================================
Matrix.VendorPool.Vendors = {} -- [id] = { coord_x, coord_y, coord_z, gang_loyalty, fear_index, status, compromised }


local LS_CENTER = vector3(0.0, 0.0, 30.0)


local function SeedVendorPool()
    local dbName = GetConvar('mysql_connection_string', GetCurrentResourceName())
    local seed = ('%s#%s'):format(GetCurrentResourceName(), tostring(dbName))

    for i = 1, (Config.VendorPool.SpawnCount or 5) do
        local raw = ('%s#VENDOR#%d'):format(seed, i)
        local sum = ChecksumOf(raw, 53)

        local angle  = (sum % 360)
        local radius = (Config.VendorPool.SpreadRadiusMeters or 900.0) * (0.35 + ((sum % 1000) / 1000.0) * 0.65)
        local x = LS_CENTER.x + radius * math.cos(math.rad(angle))
        local y = LS_CENTER.y + radius * math.sin(math.rad(angle))
        local z = 30.0

        local loyalty = ((sum % 1000) / 1000.0)
        local fear    = (((sum * 7) % 1000) / 1000.0)

        MySQL.insert([[
            INSERT INTO matrix_vendor_pool (coord_x, coord_y, coord_z, gang_loyalty, fear_index, status)
            VALUES (?, ?, ?, ?, ?, 'active')
        ]], { x, y, z, loyalty, fear })
    end

    Matrix.Log('UNDERWORLD', '[DETERMINISTIK KURULUM] %d satici deterministik olarak dagitildi.', Config.VendorPool.SpawnCount or 5)
end


CreateThread(function()
    local count = MySQL.scalar.await('SELECT COUNT(*) FROM matrix_vendor_pool') or 0
    if tonumber(count) == 0 then
        SeedVendorPool()
    end

    local rows = MySQL.query.await('SELECT * FROM matrix_vendor_pool') or {}
    for _, row in ipairs(rows) do
        Matrix.VendorPool.Vendors[row.id] = {
            vendor_citizenid = row.vendor_citizenid,
            coords           = vector3(row.coord_x, row.coord_y, row.coord_z),
            gang_loyalty     = tonumber(row.gang_loyalty) or 0.5,
            fear_index       = tonumber(row.fear_index) or 0.3,
            status           = row.status or 'active',
            compromised      = row.compromised == 1
        }
    end
    Matrix.Log('UNDERWORLD', 'Satici havuzu yuklendi (%d satici).', #rows)
end)


local function PersistVendor(id, v)
    MySQL.prepare([[
        UPDATE matrix_vendor_pool
        SET gang_loyalty = ?, fear_index = ?, status = ?, compromised = ?
        WHERE id = ?
    ]], { v.gang_loyalty, v.fear_index, v.status, v.compromised and 1 or 0, id })
end


-- =====================================================================
-- [KATMAN 5] SATICIDAN DOĞRUDAN SATIN ALMA — düşman-finansmanlı satıcılar
-- (gang_loyalty düşük = düşman çete finansmanlı) satışı reddedebilir veya
-- gizlice sattığı silaha jam_accumulator (server/forensics.lua'nın ZATEN
-- VAR OLAN alanı) yüksek başlangıçla eker.
-- =====================================================================
local function FindVendorCatalogEntry(weaponRef)
    for _, w in ipairs(Config.BlackMarket.Weapons) do
        if w.id == weaponRef then return w end
    end
    return nil
end


RegisterNetEvent('matrix:server:vendorPool:purchaseWeapon', function(vendorId, weaponRef)
    local src = source
    vendorId = tonumber(vendorId)
    local vendor = vendorId and Matrix.VendorPool.Vendors[vendorId]
    if not vendor or vendor.status == 'flipped' then
        TriggerClientEvent('matrix:client:actionNotify', src, false, 'Satici bulunamadi.')
        return
    end

    local catalog = FindVendorCatalogEntry(weaponRef)
    if not catalog then
        TriggerClientEvent('matrix:client:actionNotify', src, false, 'Katalog kalemi bulunamadi.')
        return
    end

    local ped = GetPlayerPed(src)
    local coords = ped and ped ~= 0 and GetEntityCoords(ped) or nil
    if not coords or VectorDistance(coords, vendor.coords) > 15.0 then
        TriggerClientEvent('matrix:client:actionNotify', src, false, 'Saticinin konumunda degilsiniz.')
        return
    end

    if vendor.gang_loyalty <= (Config.VendorPool.EnemyLoyaltyRefuseThreshold or 0.25) then
        TriggerClientEvent('matrix:client:actionNotify', src, false, 'Satici dusman finansmanli -- satisi reddediyor.')
        return
    end

    local player = Matrix.QBX:GetPlayer(src)
    if not player then return end
    local cash = (player.PlayerData.money and player.PlayerData.money.cash) or 0
    if cash < catalog.price then
        TriggerClientEvent('matrix:client:actionNotify', src, false, 'Yetersiz nakit.')
        return
    end

    local removeOk, removeResult = pcall(function() return player.Functions.RemoveMoney('cash', catalog.price, 'vendor-pool-purchase') end)
    if not removeOk or removeResult ~= true then
        TriggerClientEvent('matrix:client:actionNotify', src, false, 'Odeme basarisiz.')
        return
    end

    local weaponSerial = Matrix.BlackMarket.GenerateWeaponSerial(player.PlayerData.citizenid, catalog.item)
    local metadata = {
        weapon_serial = weaponSerial,
        durability    = catalog.durability
    }

    if vendor.gang_loyalty <= (Config.VendorPool.EnemyLoyaltySabotageThreshold or 0.45) then
        metadata.jam_accumulator = Config.VendorPool.SabotageJamAccumulatorSeed or 0.55
        Matrix.Log('UNDERWORLD', '[SABOTAJ] Satici #%d src=%d icin sattigi %s silahina onceden yuksek jam_accumulator ekti.',
            vendorId, src, catalog.item)
    end

    local addOk = pcall(function() return exports['ox_inventory']:AddItem(src, catalog.item, 1, metadata) end)
    if not addOk then
        pcall(function() player.Functions.AddMoney('cash', catalog.price, 'vendor-pool-refund') end)
        TriggerClientEvent('matrix:client:actionNotify', src, false, 'Envanter dolu -- odeme iade edildi.')
        return
    end

    TriggerClientEvent('matrix:client:actionNotify', src, true, ('%s satin alindi.'):format(catalog.label))
end)


-- =====================================================================
-- [KATMAN 5] /zorkullan — satıcı/kartel ele geçirme sorgusu
-- =====================================================================
RegisterCommand(Config.VendorPool.InterrogateCommand, function(src, args)
    local vendorId = tonumber(args[1])
    local vendor = vendorId and Matrix.VendorPool.Vendors[vendorId]
    if not vendor then
        Reply(src, ('Kullanim: /%s [saticiId] (F10 -> Yeralti Agi listesinden ID alin)'):format(Config.VendorPool.InterrogateCommand))
        return
    end

    local ped = GetPlayerPed(src)
    local coords = ped and ped ~= 0 and GetEntityCoords(ped) or nil
    if not coords or VectorDistance(coords, vendor.coords) > (Config.VendorPool.InterrogateRadius or 5.0) then
        Reply(src, 'Saticinin konumunda degilsiniz.')
        return
    end

    local momentum = Matrix.Bureau.GetPropagandaMomentum and Matrix.Bureau.GetPropagandaMomentum() or 0.0
    local pressure = momentum * (Config.VendorPool.InterrogateMomentumWeight or 0.20)

    if pressure < vendor.fear_index then
        Reply(src, ('Sorgu basarisiz -- satici korku esigi asilamadi (%.2f < %.2f).'):format(pressure, vendor.fear_index))
        return
    end

    vendor.gang_loyalty = 1.0
    vendor.status       = 'flipped'
    PersistVendor(vendorId, vendor)

    local player = Matrix.QBX:GetPlayer(src)
    local citizenid = player and player.PlayerData.citizenid
    if citizenid then
        Matrix.FragmentedIntel.Add(citizenid, 'cartel_safehouse', ('vendor_%d'):format(vendorId),
            Config.VendorPool.IntelLeakOnFlip or 0.50)
    end

    Reply(src, ('[ITTIFAK DEGISTI] Satici #%d artik size sadik. Dusman kartel guvenli-ev koordinati sizdirildi (+%%%d parcali istihbarat).'):format(
        vendorId, math_floor((Config.VendorPool.IntelLeakOnFlip or 0.50) * 100)))
end, false)


-- =====================================================================
-- [KATMAN 5] /savcitasaboteet — savcıyı şantajla, davanın Mahkumiyet
-- Skorunu (MEVCUT matrix_trial_records.conviction_weight) periyodik
-- olarak %20 düşür.
-- =====================================================================
local ProsecutorCooldown = {} -- [src] = sonraki kullanim zamani (Matrix.Now())


RegisterCommand(Config.VendorPool.ProsecutorBribeCommand, function(src, args)
    local defendantCitizenid = args[1]
    if not defendantCitizenid then
        Reply(src, ('Kullanim: /%s [sanikCitizenid]'):format(Config.VendorPool.ProsecutorBribeCommand))
        return
    end

    local now = Matrix.Now()
    if ProsecutorCooldown[src] and now < ProsecutorCooldown[src] then
        Reply(src, 'Savci zaten yakin zamanda sizden rusvet aldi -- bekleyin.')
        return
    end
    ProsecutorCooldown[src] = now + math_floor((Config.VendorPool.ProsecutorCooldownMs or 300000) / 1000)

    local affected = MySQL.update.await([[
        UPDATE matrix_trial_records
        SET conviction_weight = conviction_weight * ?
        WHERE defendant_citizenid = ? AND verdict = 'pending'
    ]], { 1.0 - (Config.VendorPool.ProsecutorGuiltReductionPct or 0.20), defendantCitizenid })

    if tonumber(affected) and tonumber(affected) > 0 then
        Reply(src, ('[SAVCI SATIN ALINDI] %s icin acik dava(lar)in Mahkumiyet Skoru %%%d dusuruldu.'):format(
            defendantCitizenid, math_floor((Config.VendorPool.ProsecutorGuiltReductionPct or 0.20) * 100)))
    else
        Reply(src, 'Bu sanik icin acik (pending) bir dava bulunamadi.')
    end
end, false)


-- =====================================================================
-- [KATMAN 6] PARÇALANMIŞ İSTİHBARAT DEFTERİ
-- =====================================================================
function Matrix.FragmentedIntel.Add(citizenid, contactType, contactRef, amount)
    if not citizenid or not contactType then return end
    amount = tonumber(amount) or (Config.FragmentedIntel.GainPerAction or 0.10)

    MySQL.query.await([[
        INSERT INTO matrix_fragmented_intel (citizenid, contact_type, contact_ref, intel_fragments, updated_at)
        VALUES (?, ?, ?, ?, NOW())
        ON DUPLICATE KEY UPDATE intel_fragments = intel_fragments + VALUES(intel_fragments), updated_at = NOW()
    ]], { citizenid, contactType, contactRef, amount })

    local row = MySQL.single.await(
        'SELECT id, intel_fragments FROM matrix_fragmented_intel WHERE citizenid = ? AND contact_type = ? AND (contact_ref = ? OR (contact_ref IS NULL AND ? IS NULL)) ORDER BY id DESC LIMIT 1',
        { citizenid, contactType, contactRef, contactRef })

    if row and tonumber(row.intel_fragments) >= (Config.FragmentedIntel.DiscoveredThreshold or 1.0) then
        MySQL.prepare('UPDATE matrix_fragmented_intel SET discovered = 1 WHERE id = ?', { row.id })
    end
end


-- ★ Dealing/rüşvet/dinleme -- ZATEN VAR OLAN üç event'e İKİNCİ dinleyici
-- eklenir (AddEventHandler, orijinal handler'lar DEĞİŞTİRİLMEZ).
local function GrantIntelForSrc(src, contactType)
    local player = Matrix.QBX:GetPlayer(src)
    local citizenid = player and player.PlayerData.citizenid
    if citizenid then
        Matrix.FragmentedIntel.Add(citizenid, contactType, nil, Config.FragmentedIntel.GainPerAction or 0.10)
    end
end


AddEventHandler('matrix:server:streetDealing:attemptSale', function()
    local src = source
    GrantIntelForSrc(src, 'dealing')
end)


AddEventHandler('matrix:server:bureau:offerBribe', function()
    local src = source
    GrantIntelForSrc(src, 'bribery')
end)


AddEventHandler('matrix:server:reportUnencryptedComms', function()
    local src = source
    GrantIntelForSrc(src, 'wiretap')
end)


lib.callback.register('matrix:callback:getDiscoveredContacts', function(src)
    local player = Matrix.QBX:GetPlayer(src)
    local citizenid = player and player.PlayerData.citizenid
    if not citizenid then return {} end

    local rows = MySQL.query.await(
        'SELECT contact_type, contact_ref, intel_fragments, discovered, compromised FROM matrix_fragmented_intel WHERE citizenid = ? AND discovered = 1',
        { citizenid }) or {}
    return rows
end)


-- =====================================================================
-- [KATMAN 6] KARŞI-İSTİHBARAT VETTİNG — bir satıcı/doktorla etkileşimden
-- önce oyuncunun siber-ısı oranı (en yakın trap house'un MEVCUT
-- Matrix.Bureau.GetHeat/CyberLeakMaxIntensity oranı, Config.Rendezvous.
-- AmbushTraceLevelThreshold İLE AYNI olcek) bu esigi GECERSE kontak
-- kicker: islem reddedilir VE o kontak kilitlenir (discovered=0,
-- intel_fragments=0.0).
-- =====================================================================
local function GetPlayerCyberHeatRatio(coords)
    local nearestId, nearestDist = nil, math_huge
    for id, house in pairs(Matrix.TrapHouses or {}) do
        local d = VectorDistance(coords, house.coords)
        if d < nearestDist then nearestId, nearestDist = id, d end
    end
    if not nearestId then return 0.0 end
    local heat = Matrix.Bureau.GetHeat and Matrix.Bureau.GetHeat(nearestId) or 0.0
    return heat / (Config.Bureau.CyberLeakMaxIntensity or 5.0)
end


function Matrix.FragmentedIntel.VetInteraction(src, contactType, contactRef)
    local ped = GetPlayerPed(src)
    local coords = ped and ped ~= 0 and GetEntityCoords(ped) or nil
    if not coords then return true end

    local heatRatio = GetPlayerCyberHeatRatio(coords)
    if heatRatio < (Config.FragmentedIntel.VettingHeatThreshold or 0.80) then return true end

    local player = Matrix.QBX:GetPlayer(src)
    local citizenid = player and player.PlayerData.citizenid
    if citizenid then
        MySQL.prepare([[
            UPDATE matrix_fragmented_intel
            SET discovered = 0, intel_fragments = 0.0
            WHERE citizenid = ? AND contact_type = ? AND (contact_ref = ? OR (contact_ref IS NULL AND ? IS NULL))
        ]], { citizenid, contactType, contactRef, contactRef })
    end

    TriggerClientEvent('matrix:client:actionNotify', src, false,
        ('Kontak sizi kovdu -- siber-isi oraniniz cok yuksek (%%%.0f). Kontak kilitlendi.'):format(heatRatio * 100))
    return false
end


RegisterNetEvent('matrix:server:vendorPool:requestInteraction', function(vendorId)
    local src = source
    Matrix.FragmentedIntel.VetInteraction(src, 'vendor', tostring(tonumber(vendorId)))
end)


RegisterNetEvent('matrix:server:phantomDoctor:requestInteraction', function()
    local src = source
    Matrix.FragmentedIntel.VetInteraction(src, 'doctor', 'phantom_doctor')
end)


-- =====================================================================
-- [KATMAN 6] STING (PUSU) — bir kurye botu köstebek işaretlenirse
-- (Matrix.Inspector.IsMoleFlagged, ZATEN VAR OLAN), o bota en yakın
-- satıcı contact'ı compromised=1 olarak işaretlenir. Oyuncu orada işlem
-- yapmaya devam ederse en yakın bölgenin MEVCUT audit_anomaly_rate'i
-- üstel olarak sıçrar (front company gizli +%50).
-- =====================================================================
local function FindNearestVendor(coords)
    local nearestId, nearestDist, nearest = nil, math_huge, nil
    for id, v in pairs(Matrix.VendorPool.Vendors) do
        local d = VectorDistance(coords, v.coords)
        if d < nearestDist then nearestId, nearestDist, nearest = id, d, v end
    end
    return nearestId, nearest
end


AddEventHandler('matrix:internal:mole_flagged', function(botId)
    local bot = Matrix.Bots and Matrix.Bots[botId]
    if not bot or not bot.state or not bot.state.coords then return end
    local vendorId, vendor = FindNearestVendor(bot.state.coords)
    if vendor and not vendor.compromised then
        vendor.compromised = true
        PersistVendor(vendorId, vendor)
        Matrix.Log('UNDERWORLD', '[STING] Bot #%d cevrildi -- en yakin Satici #%d compromised olarak isaretlendi.', botId, vendorId)
    end
end)


RegisterNetEvent('matrix:server:vendorPool:transactAtCompromised', function(vendorId)
    local src = source
    vendorId = tonumber(vendorId)
    local vendor = vendorId and Matrix.VendorPool.Vendors[vendorId]
    if not vendor or not vendor.compromised then return end

    local zoneId = Matrix.Market.FindNearestZone and Matrix.Market.FindNearestZone(vendor.coords)
    if not zoneId then return end

    MySQL.prepare([[
        INSERT INTO matrix_zone_ledger (zone_id, audit_anomaly_rate, updated_at)
        VALUES (?, ?, NOW())
        ON DUPLICATE KEY UPDATE audit_anomaly_rate = (audit_anomaly_rate + 0.01) * ?, updated_at = NOW()
    ]], { zoneId, Config.FragmentedIntel.StingAuditExponentialMultiplier or 1.5, Config.FragmentedIntel.StingAuditExponentialMultiplier or 1.5 })

    Matrix.Log('UNDERWORLD', '[STING DEVAM EDIYOR] src=%d compromised Satici #%d ile islem yapmaya devam etti -- bolge #%d denetim anomalisi ustel sicradi.',
        src, vendorId, zoneId)
end)
