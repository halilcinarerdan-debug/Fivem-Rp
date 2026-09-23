-- =====================================================================
-- MATRIX BLACK MARKET / server/blackmarket.lua  (KATMAN 6 — RENDEZVOUS)
--
-- Taktik Karaborsa Ticaret Ağı: illegal araç filosu, seri no silinmiş
-- silahlar, mühimmat, Yedek Namlu (bkz. server/forensics.lua /namludegistir)
-- ve sahte IMEI'li Açık Hat (Burner Phone, bkz. server/market.lua Matrix.
-- Comint) satın alma akışlarını tek bir dosyada toplar.
--
-- ★ TASARIM KARARLARI:
--   [B1] "0 RNG" prensibi HARFİYEN korunur: plaka/seri numarası üretimi
--        math.random KULLANMAZ. server/forensics.lua'nın RegisterOrGetBallisticId
--        fonksiyonundaki AYNI desen izlenir — GetGameTimer() + monoton bir
--        sayaç + girdi-türevli bir sağlama toplamı (checksum). Aynı
--        (citizenid, item, sayaç, oyun-zamanlayıcısı) girdisi HER ZAMAN
--        aynı kimliği üretir; iki ardışık satın alma ASLA çakışmaz çünkü
--        sayaç her çağrıda kesin olarak artar.
--   [B2] Ödeme bütünlüğü: Matrix.Fleet.RegisterVehicle, Matrix.Rendezvous.
--        ScheduleHandoff veya ox_inventory AddItem başarısız olursa tahsil
--        edilen nakit OTOMATİK iade edilir — oyuncu asla parasını verip
--        karşılığında hiçbir şey alamadan kalmaz.
--   [B3] Araç kataloğu yalnızca `vehicle_class` (car/motorbike) taşır —
--        server/main.lua'nın DISPATCH_VEHICLE_MODELS tablosu (sınıf bazlı
--        spawn modeli seçimi) DEĞİŞTİRİLMEDİ; katalog bu mevcut mimariyle
--        tutarlı kalması için yalnızca desteklenen sınıflardan seçim sunar.
--
-- ★ KATMAN 6 DEĞİŞİKLİĞİ: "silah veya mühimmat" satın alımı artık ANINDA
--   envantere düşmez. buyWeapon/buyAmmo, ödeme başarılı olduktan sonra
--   server/rendezvous.lua'nın Matrix.Rendezvous.ScheduleHandoff'unu çağırır.
--
-- ★★★ ADLİ DENETİM REVİZYONU (ZERO-TRUST GÜVENLİK KATMANI) ★★★
--   Bu revizyon aşağıdaki 4 zafiyeti kapatır (bureau.lua'daki ayrı denetimle
--   birlikte toplam 7 maddelik rapor):
--   [SEC-1] ChargeCash artık RemoveMoney'nin GERÇEK dönüş değerini kontrol
--           eder (pcall yalnızca "hata fırlatmadı mı" der, "başarılı mı"
--           demez — bu ikisi eskiden karıştırılıyordu). Ayrıca src bazlı
--           bir mutex (kilit), aynı oyuncunun üst üste bindirilmiş
--           tetiklemelerle aynı ödeme penceresini iki kez kullanmasını
--           (dupe/race) engeller.
--   [SEC-2] RefundCash artık oyuncu çevrimdışıysa (GetPlayer nil) ACID bir
--           offline SQL fallback'e düşer (players.money JSON_SET), ve o
--           bile satır bulamazsa para matrix_pending_refunds ledger'ına
--           yazılır — hiçbir zaman sessizce kaybolmaz (Orphan State yok).
--   [SEC-3] GenerateScratchedPlate/GenerateWeaponSerial artık os.time()
--           (gerçek duvar-saati epoch, restart'ta SIFIRLANMAZ) girdiye
--           eklendi; purchaseSequence sunucu açılışında DB'den senkronize
--           edilir (kendisi de restart'ta sıfırlanmaz) — restart sonrası
--           GetGameTimer()+sayaç çakışması artık pratikte imkansız.
--   [SEC-4] "Rolling Cipher" el sıkışma: client, satın alma event'ini
--           tetiklemeden ÖNCE lib.callback.await ile tek kullanımlık,
--           15sn ömürlü bir token ister (bkz. client/hud.lua). Sunucu
--           token'ı DOĞRULAR VE ANINDA İMHA EDER (replay koruması); token
--           yoksa/yanlışsa/süresi geçmişse işlem sessizce reddedilir.
-- =====================================================================


Matrix.BlackMarket = Matrix.BlackMarket or {}


local pairs, ipairs, type, tostring = pairs, ipairs, type, tostring
local tonumber, table, math         = tonumber, table, math
local GetGameTimer                  = GetGameTimer
local TriggerClientEvent            = TriggerClientEvent
local RegisterNetEvent              = RegisterNetEvent
local RegisterCommand               = RegisterCommand


local WARN_MISSING_RENDEZVOUS = false


local function Reply(src, msg)
    if type(src) == 'number' and src > 0 then
        TriggerClientEvent('chat:addMessage', src, { args = { '[KARABORSA]', msg } })
    else
        print(('[MATRIX:BLACKMARKET:CONSOLE] %s'):format(msg))
    end
end


-- =====================================================================
-- [B1] DETERMİNİSTİK KİMLİK ÜRETİMİ (RNG YOK)
-- ★ [SEC-3] purchaseSequence artık salt in-memory değil: sunucu açılışında
-- matrix_blackmarket_purchases.MAX(id)'den senkronize edilir, böylece bir
-- restart sayaci SIFIRLAMAZ. os.time() (epoch) da checksum girdisine
-- eklendi -- GetGameTimer() TEK BAŞINA restart'ta küçük değerlerden
-- yeniden sayar, os.time() ASLA geri sarmaz.
-- =====================================================================
local purchaseSequence = 0
local function NextSequence()
    purchaseSequence = purchaseSequence + 1
    return purchaseSequence
end


CreateThread(function()
    local ok, maxId = pcall(function()
        return MySQL.scalar.await('SELECT COALESCE(MAX(id), 0) FROM matrix_blackmarket_purchases')
    end)
    if ok and type(maxId) == 'number' and maxId > purchaseSequence then
        purchaseSequence = maxId
    end
    Matrix.Log('BLACKMARKET', '[SEC-3] purchaseSequence baslangic degeri DB ile senkronize edildi: %d', purchaseSequence)
end)


local PLATE_ALPHABET = '0123456789ABCDEFGHJKLMNPQRSTUVWXYZ' -- I/O kazayla karismasin diye cikarildi


local function ChecksumOf(raw, salt)
    local sum = 0
    for i = 1, #raw do
        sum = (sum + (raw:byte(i) * (i + salt))) % 0xFFFFFFF
    end
    return sum
end


--- Karaborsa aracı için kazınmış/sahte plaka üretir. RNG YOK: os.time()
--- (epoch) + GetGameTimer() + monoton sayaç + citizenid'den türetilmiş bir
--- sağlama toplamı, sabit-genişlikte bir alfabede kodlanır.
function Matrix.BlackMarket.GenerateScratchedPlate(citizenid)
    local seq = NextSequence()
    local raw = ('%s#%d#%d#%d'):format(tostring(citizenid), os.time(), GetGameTimer(), seq)
    local sum = ChecksumOf(raw, 11)


    local chars = {}
    local base = #PLATE_ALPHABET
    local value = sum
    for i = 1, 7 do
        local idx = (value % base) + 1
        chars[i] = PLATE_ALPHABET:sub(idx, idx)
        value = math.floor(value / base)
    end
    return 'KB' .. table.concat(chars)
end


--- Karaborsa silahı için yeni bir weapon_serial üretir. RNG YOK: os.time()
--- (epoch) + GetGameTimer() + monoton sayaç + citizenid+item'dan türetilmiş
--- bir sağlama toplamı.
function Matrix.BlackMarket.GenerateWeaponSerial(citizenid, weaponItemName)
    local seq = NextSequence()
    local raw = ('%s#%s#%d#%d#%d'):format(tostring(citizenid), tostring(weaponItemName), os.time(), GetGameTimer(), seq)
    local sum = ChecksumOf(raw, 23)
    local suffix = (type(weaponItemName) == 'string' and weaponItemName:sub(-6) or 'XXXXXX'):upper()
    return ('BM-%s-%07X'):format(suffix, sum)
end


-- =====================================================================
-- KATALOG ARAMA YARDIMCILARI
-- =====================================================================
local function FindVehicleCatalogEntry(id)
    for _, v in ipairs(Config.BlackMarket.Vehicles) do
        if v.id == id then return v end
    end
    return nil
end


local function FindWeaponCatalogEntry(id)
    for _, w in ipairs(Config.BlackMarket.Weapons) do
        if w.id == id then return w end
    end
    return nil
end


local function FindAmmoCatalogEntry(id)
    for _, a in ipairs(Config.BlackMarket.Ammo or {}) do
        if a.id == id then return a end
    end
    return nil
end


local function FindBurnerPhoneCatalogEntry(id)
    for _, p in ipairs(Config.BlackMarket.BurnerPhones or {}) do
        if p.id == id then return p end
    end
    return nil
end


-- =====================================================================
-- ★ MODUL 3: qbx_core SİLAH RUHSATI KAPISI
-- Mevcut Matrix.QBX (exports.qbx_core) çağrı deseni (bkz. bureau.lua/
-- main.lua Matrix.QBX:GetPlayer(src)) izlenir. qbx_core, ruhsatları
-- PlayerData.metadata.licences[type] boolean olarak tutar -- bu, bu
-- kod tabanındaki GetPlayer/PlayerData erişim biçimiyle AYNI sözleşmedir.
-- =====================================================================
function Matrix.BlackMarket.HasWeaponLicense(src)
    if type(src) ~= 'number' or src <= 0 then return false end
    local ok, player = pcall(function() return Matrix.QBX:GetPlayer(src) end)
    if not ok or not player or not player.PlayerData then return false end

    local licences = player.PlayerData.metadata and player.PlayerData.metadata.licences
    local licenseType = Config.BlackMarket.WeaponLicenseType or 'weapon'
    return type(licences) == 'table' and licences[licenseType] == true
end


-- =====================================================================
-- ★ MODUL 4: DETERMİNİSTİK KARABORSA STOK PENCERESİ (RNG YOK)
-- bucket = (saat-UTC + trust_checksum + sinif_checksum) % 24
-- bucket < AvailabilityClosedWindowHours ise o silah SINIFI o saat
-- STOKTA YOKTUR. Aynı (saat, trust, sınıf) girdisi HER ZAMAN aynı
-- sonucu üretir -- iki oyuncu aynı anda aynı sınıfı sorgularsa aynı
-- cevabı alır (deterministik, tekrar edilebilir).
-- =====================================================================
function Matrix.BlackMarket.IsWeaponClassAvailableNow(citizenid, weaponClass)
    weaponClass = weaponClass or 'pistol'
    local hourUtc = tonumber(os.date('!%H', os.time())) or 0

    local trust = 0.5
    if Matrix.Supplier and Matrix.Supplier.GetTrust then
        local ok, t = pcall(Matrix.Supplier.GetTrust, citizenid, Config.BlackMarket.AvailabilitySupplierId)
        if ok and type(t) == 'number' then trust = t end
    end

    local trustBucket = ChecksumOf(('%.4f'):format(trust), 7) % 24
    local classBucket = ChecksumOf(weaponClass, 13) % 24
    local combinedBucket = (hourUtc + trustBucket + classBucket) % 24

    return combinedBucket >= (Config.BlackMarket.AvailabilityClosedWindowHours or 0), combinedBucket
end


-- =====================================================================
-- ★ [SEC-1] SRC BAZLI MUTEX (RACE CONDITION / DUPE KORUMASI)
-- Aynı src için üst üste bindirilmiş satın alma tetiklemeleri (50 event'in
-- aynı milisaniyede tetiklenmesi dahil) ikinci pencere açılmadan reddedilir.
-- Kilit HER ZAMAN (başarı/hata/erken dönüş fark etmeksizin) serbest
-- bırakılır -- ilgili event handler'lar gövdelerini bir pcall içine alıp
-- kilidi pcall SONRASINDA serbest bırakır (bkz. aşağıdaki 5 RegisterNetEvent).
-- =====================================================================
local purchaseMutex = {}


local function TryAcquirePurchaseLock(src)
    if purchaseMutex[src] then return false end
    purchaseMutex[src] = true
    return true
end


local function ReleasePurchaseLock(src)
    purchaseMutex[src] = nil
end


-- =====================================================================
-- ★ [SEC-4] ROLLING CIPHER / DİNAMİK TOKEN MATRİSİ
-- İstemci lib.callback.await ile tek kullanımlık bir handshake token'ı
-- ister (bkz. client/hud.lua BuyWithHandshake). Token: src+kind+catalogId'e
-- MÜHÜRLÜDÜR, TOKEN_TTL_MS içinde ve YALNIZCA BİR KEZ kullanılabilir --
-- doğrulama denemesi başarılı OLSUN YA DA OLMASIN token anında imha edilir
-- (replay attack koruması). Bu, güvenlik nonce'udur; [B1]'in "0 RNG"
-- disiplini OYUN EKONOMİSİ kimliklerini (plaka/seri no) kapsar -- bir
-- güvenlik token'ının tam tersine ÖNGÖRÜLEMEZ olması gerekir, bu yüzden
-- burada bilinçli olarak math.random kullanılır.
-- =====================================================================
local pendingPurchaseTokens = {} -- [src] = { token=, kind=, catalog_id=, expires_at= }
local TOKEN_TTL_MS = 15000


local function GenerateHandshakeToken(src, kind, catalogId)
    local raw = ('%d#%s#%s#%d#%d#%d'):format(
        src, tostring(kind), tostring(catalogId), os.time(), GetGameTimer(), math.random(1, 0x7FFFFFFF))
    local sum = ChecksumOf(raw, 47)
    return ('TK-%08X-%X-%X'):format(sum, GetGameTimer() % 0xFFFFFF, math.random(0, 0xFFFF))
end


lib.callback.register('matrix:callback:blackmarket:requestToken', function(src, kind, catalogId)
    if type(src) ~= 'number' or src <= 0 then return nil end
    if type(kind) ~= 'string' then return nil end


    local token = GenerateHandshakeToken(src, kind, catalogId)
    pendingPurchaseTokens[src] = {
        token      = token,
        kind       = kind,
        catalog_id = catalogId,
        expires_at = GetGameTimer() + TOKEN_TTL_MS
    }
    return token
end)


--- Tek kullanımlık doğrulama: token, kontrol SONUCU FARK ETMEKSİZİN
--- anında imha edilir (aynı token iki kez asla kabul edilmez).
local function ConsumeHandshakeToken(src, kind, catalogId, token)
    local pending = pendingPurchaseTokens[src]
    pendingPurchaseTokens[src] = nil


    if not pending or type(token) ~= 'string' then return false end
    if pending.token ~= token then return false end
    if pending.kind ~= kind then return false end
    if tostring(pending.catalog_id) ~= tostring(catalogId) then return false end
    if GetGameTimer() > pending.expires_at then return false end
    return true
end


-- =====================================================================
-- ÖDEME
-- =====================================================================

--- ★ [SEC-1] pcall'ın İKİNCİ dönüş değeri (RemoveMoney'nin GERÇEK
--- başarı/başarısızlık boolean'ı) artık ayrıca kontrol ediliyor. Eskiden
--- yalnızca "pcall hata fırlattı mı" bakılıyordu; RemoveMoney sessizce
--- `false` dönüp bakiye DÜŞÜRMEDEN pcall yine de `true` (hata yok) dönerdi
--- -- bu, ödeme alınmadan mal teslim edilmesine yol açan asıl açıktı.
local function ChargeCash(src, amount)
    local ok, player = pcall(function() return Matrix.QBX:GetPlayer(src) end)
    if not ok or not player or not player.PlayerData then return false, 'player_not_found' end


    local cash = (player.PlayerData.money and player.PlayerData.money.cash) or 0
    if cash < amount then return false, 'insufficient_funds' end


    local removeOk, removeResult = pcall(function()
        return player.Functions.RemoveMoney('cash', amount, 'blackmarket-purchase')
    end)
    if not removeOk or removeResult ~= true then return false, 'charge_failed' end
    return true
end


--- ★ [SEC-2] citizenid artık zorunlu bir parametre: oyuncu bağlantısı
--- ödeme ile iade arasında koparsa (Matrix.QBX:GetPlayer(src) nil döner)
--- ACID bir offline SQL fallback'e düşülür (players.money JSON_SET, tek
--- UPDATE -- InnoDB satır kilidi doğal atomiklik sağlar). O UPDATE 0 satır
--- etkilerse (players'ta karşılık gelen citizenid yoksa) para
--- matrix_pending_refunds ledger'ına yazılır: hiçbir koşulda para
--- sessizce "havada" kalmaz.
local function RefundCash(src, amount, citizenid)
    if type(src) == 'number' and src > 0 then
        local onlineOk, refunded = pcall(function()
            local player = Matrix.QBX:GetPlayer(src)
            if not player then return false end
            player.Functions.AddMoney('cash', amount, 'blackmarket-refund')
            return true
        end)
        if onlineOk and refunded then return true end
    end


    if not citizenid then
        Matrix.Log('BLACKMARKET',
            '[KRITIK][SEC-2] Iade basarisiz VE citizenid bilinmiyor -- para kurtarilamadi! src=%s amount=%.2f',
            tostring(src), amount)
        return false
    end


    local ok, affected = pcall(function()
        return MySQL.update.await(
            "UPDATE players SET money = JSON_SET(money, '$.cash', COALESCE(JSON_EXTRACT(money, '$.cash'), 0) + ?) WHERE citizenid = ?",
            { amount, citizenid }
        )
    end)


    if ok and type(affected) == 'number' and affected > 0 then
        Matrix.Log('BLACKMARKET',
            '[SEC-2][OFFLINE IADE] citizenid=%s $%.2f players.money uzerinden ACID guncellendi (src cevrimdisi/gecersiz).',
            citizenid, amount)
        return true
    end


    -- players tablosunda satır yok (silinmiş/tanınmayan karakter) VEYA
    -- sorgu hata verdi -- son çare: kalıcı bir tahsilat defteri (ledger).
    -- Bir admin bu tabloyu görüp manuel mutabakat yapabilir; para asla
    -- iz bırakmadan yok olmaz.
    pcall(function()
        MySQL.insert.await(
            'INSERT INTO matrix_pending_refunds (citizenid, amount, reason, created_at) VALUES (?, ?, ?, NOW())',
            { citizenid, amount, 'blackmarket-offline-refund-orphan' }
        )
    end)
    Matrix.Log('BLACKMARKET',
        '[KRITIK][SEC-2] Offline iade de basarisiz (players satiri yok/DB hatasi); matrix_pending_refunds ledgerina yazildi: %s $%.2f',
        citizenid, amount)
    return false
end


local function LogPurchase(citizenid, itemType, itemRef, price)
    -- ★ MySQL.prepare -> MySQL.insert: oxmysql'de ikisi de asenkron/
    -- non-blocking'tir, ancak INSERT niyetini adlandıran export burasıdır
    -- (kod okunabilirliği; davranış değişmedi).
    MySQL.insert('INSERT INTO matrix_blackmarket_purchases (citizenid, item_type, item_ref, price_paid, created_at) VALUES (?, ?, ?, ?, NOW())',
        { citizenid, itemType, tostring(itemRef), price })
end


-- =====================================================================
-- SATIN ALMA: ARAÇ  (DEĞİŞMEDİ — anında filoya kaydedilir)
-- =====================================================================
-- İç çekirdek: token doğrulaması YAPMAZ (güvenilir sunucu-içi çağıranlar
-- -- örn. BuyBlackMarketVehicle export'u -- için). Mutex burada da
-- uygulanır: bir oyuncunun aynı anda hem client hem sunucu-içi bir
-- tetikleyiciyle iki kez satın almasını da engeller.
local function DoBuyVehicle(src, catalogId)
    if not TryAcquirePurchaseLock(src) then
        Reply(src, 'Bir onceki karaborsa islemin hala isleniyor, bekle.')
        return
    end


    local ok, err = pcall(function()
        local entry = FindVehicleCatalogEntry(catalogId)
        if not entry then Reply(src, 'Gecersiz karaborsa arac kalemi.'); return end


        local state = Matrix.GetOrCreatePlayerState(src)
        local citizenid = state and state.citizenid
        if not citizenid then Reply(src, 'Profil cozulemedi.'); return end


        local chargeOk, reason = ChargeCash(src, entry.price)
        if not chargeOk then
            Reply(src, reason == 'insufficient_funds' and 'Yetersiz nakit.' or 'Odeme basarisiz.')
            TriggerClientEvent('matrix:client:blackmarket:purchaseResult', src, false, entry.label, nil)
            return
        end


        local plate = Matrix.BlackMarket.GenerateScratchedPlate(citizenid)
        local regOk, regReason = Matrix.Fleet.RegisterVehicle(citizenid, plate, entry.vehicle_class, 'scratched', entry.vehicle_wear)
        if not regOk then
            RefundCash(src, entry.price, citizenid)
            Reply(src, ('Filo kaydi basarisiz, odeme iade edildi: %s'):format(tostring(regReason)))
            TriggerClientEvent('matrix:client:blackmarket:purchaseResult', src, false, entry.label, nil)
            return
        end


        LogPurchase(citizenid, 'vehicle', plate, entry.price)


        Reply(src, ('%s satin alindi. Plaka: %s (VIN kazinmis, illegal filoya eklendi).'):format(entry.label, plate))
        TriggerClientEvent('matrix:client:blackmarket:purchaseResult', src, true, entry.label, plate)
        Matrix.Log('BLACKMARKET', '[SATIS] %s -> arac %s (%s) $%.0f', citizenid, entry.label, plate, entry.price)
    end)
    ReleasePurchaseLock(src)
    if not ok then
        Matrix.Log('BLACKMARKET', '[HATA] buyVehicle ic hata (kilit serbest birakildi): %s', tostring(err))
    end
end


RegisterNetEvent('matrix:server:blackmarket:buyVehicle', function(catalogId, token)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    if not ConsumeHandshakeToken(src, 'vehicle', catalogId, token) then
        Matrix.Log('BLACKMARKET', '[SEC-4][GUVENLIK] src=%d gecersiz/eksik handshake token ile buyVehicle cagirdi (spoofing supheli).', src)
        return
    end
    DoBuyVehicle(src, catalogId)
end)


-- =====================================================================
-- ★ KATMAN 6: ORTAK RENDEZVOUS YÖNLENDİRİCİSİ (silah + mühimmat)
-- Matrix.Rendezvous modülü (server/rendezvous.lua) yüklüyse mal bir
-- buluşma noktasında teslim edilir; DEĞİLSE (savunmacı geri düşüş) mal
-- ESKİ davranışla ANINDA ox_inventory'ye eklenir — hiçbir zaman "ödedim
-- ama hiçbir şey olmadı" durumu oluşmaz.
-- =====================================================================
local function DeliverViaRendezvousOrFallback(src, citizenid, catalogType, entry, itemName, itemCount, metadata)
    if Matrix.Rendezvous and Matrix.Rendezvous.ScheduleHandoff then
        local ok, reasonOrHandoff = pcall(Matrix.Rendezvous.ScheduleHandoff, src, citizenid, {
            catalog_type = catalogType,
            catalog_id   = entry.id,
            label        = entry.label,
            item         = itemName,
            count        = itemCount or 1,
            metadata     = metadata
        })
        if ok and reasonOrHandoff then
            return true, 'rendezvous'
        end
        Matrix.Log('BLACKMARKET', '[UYARI] Matrix.Rendezvous.ScheduleHandoff basarisiz, dogrudan teslimata dusuluyor: %s',
            tostring(reasonOrHandoff))
    elseif not WARN_MISSING_RENDEZVOUS then
        WARN_MISSING_RENDEZVOUS = true
        Matrix.Log('BLACKMARKET',
            '[UYARI] Matrix.Rendezvous yuklu degil; silah/muhimmat satislari ESKI (anlik) teslimat moduna dustu.')
    end


    local addOk = pcall(function()
        return exports['ox_inventory']:AddItem(src, itemName, itemCount or 1, metadata)
    end)
    if not addOk then return false, 'inventory_full' end
    return true, 'direct'
end


-- =====================================================================
-- SATIN ALMA: SİLAH  (★ KATMAN 6: Rendezvous üzerinden teslim)
-- =====================================================================
RegisterNetEvent('matrix:server:blackmarket:buyWeapon', function(catalogId, token)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    if not ConsumeHandshakeToken(src, 'weapon', catalogId, token) then
        Matrix.Log('BLACKMARKET', '[SEC-4][GUVENLIK] src=%d gecersiz/eksik handshake token ile buyWeapon cagirdi (spoofing supheli).', src)
        return
    end
    if not TryAcquirePurchaseLock(src) then
        Reply(src, 'Bir onceki karaborsa islemin hala isleniyor, bekle.')
        return
    end


    local ok, err = pcall(function()
        local entry = FindWeaponCatalogEntry(catalogId)
        if not entry then Reply(src, 'Gecersiz karaborsa silah kalemi.'); return end


        local state = Matrix.GetOrCreatePlayerState(src)
        local citizenid = state and state.citizenid
        if not citizenid then Reply(src, 'Profil cozulemedi.'); return end


        -- ★ MODUL 3: qbx_core 'weapon' ruhsati zorunlu.
        if not Matrix.BlackMarket.HasWeaponLicense(src) then
            Reply(src, 'Silah ruhsatiniz yok/gecersiz -- bu satin alma icin yetkiniz yok.')
            TriggerClientEvent('matrix:client:blackmarket:purchaseResult', src, false, entry.label, nil)
            return
        end


        -- ★ MODUL 4: deterministik stok penceresi -- o saat/sinif icin
        -- karaborsa kapali olabilir (RNG YOK, bkz. IsWeaponClassAvailableNow).
        local available = Matrix.BlackMarket.IsWeaponClassAvailableNow(citizenid, entry.class)
        if not available then
            Reply(src, ('%s sinifi su anda stokta degil (toptanci penceresi kapali). Daha sonra tekrar deneyin.'):format(entry.class or 'silah'))
            TriggerClientEvent('matrix:client:blackmarket:purchaseResult', src, false, entry.label, nil)
            return
        end


        local chargeOk, reason = ChargeCash(src, entry.price)
        if not chargeOk then
            Reply(src, reason == 'insufficient_funds' and 'Yetersiz nakit.' or 'Odeme basarisiz.')
            TriggerClientEvent('matrix:client:blackmarket:purchaseResult', src, false, entry.label, nil)
            return
        end


        local weaponSerial = Matrix.BlackMarket.GenerateWeaponSerial(citizenid, entry.item)
        local metadata = {
            weapon_serial   = weaponSerial,
            durability      = entry.durability,
            shots_fired     = 0,
            jam_accumulator = 0.0,
            jammed          = false,
            description     = ('[KARABORSA SILAHI]\nSeri No: SILINMIS\nAsinma: %.0f%%'):format(entry.durability)
        }


        local deliverOk, mode = DeliverViaRendezvousOrFallback(src, citizenid, 'weapon', entry, entry.item, 1, metadata)
        if not deliverOk then
            RefundCash(src, entry.price, citizenid)
            Reply(src, 'Silah teslimati ayarlanamadi, odeme iade edildi (envanter dolu olabilir).')
            TriggerClientEvent('matrix:client:blackmarket:purchaseResult', src, false, entry.label, nil)
            return
        end


        LogPurchase(citizenid, 'weapon', weaponSerial, entry.price)


        if mode == 'rendezvous' then
            Reply(src, ('%s icin odeme alindi. Buluşma noktasi Taktik Not Defterine islendi — teslimati fiziksel olarak alman gerekiyor.'):format(entry.label))
        else
            Reply(src, ('%s satin alindi. Seri No: SILINMIS.'):format(entry.label))
        end
        TriggerClientEvent('matrix:client:blackmarket:purchaseResult', src, true, entry.label, weaponSerial)
        Matrix.Log('BLACKMARKET', '[SATIS] %s -> silah %s (seri:%s, mod:%s) $%.0f', citizenid, entry.label, weaponSerial, mode, entry.price)
    end)
    ReleasePurchaseLock(src)
    if not ok then
        Matrix.Log('BLACKMARKET', '[HATA] buyWeapon ic hata (kilit serbest birakildi): %s', tostring(err))
    end
end)


-- =====================================================================
-- SATIN ALMA: MÜHİMMAT  (★ KATMAN 6: Rendezvous üzerinden teslim)
-- =====================================================================
RegisterNetEvent('matrix:server:blackmarket:buyAmmo', function(catalogId, token)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    if not ConsumeHandshakeToken(src, 'ammo', catalogId, token) then
        Matrix.Log('BLACKMARKET', '[SEC-4][GUVENLIK] src=%d gecersiz/eksik handshake token ile buyAmmo cagirdi (spoofing supheli).', src)
        return
    end
    if not TryAcquirePurchaseLock(src) then
        Reply(src, 'Bir onceki karaborsa islemin hala isleniyor, bekle.')
        return
    end


    local ok, err = pcall(function()
        local entry = FindAmmoCatalogEntry(catalogId)
        if not entry then Reply(src, 'Gecersiz karaborsa muhimmat kalemi.'); return end


        local state = Matrix.GetOrCreatePlayerState(src)
        local citizenid = state and state.citizenid
        if not citizenid then Reply(src, 'Profil cozulemedi.'); return end


        -- ★ MODUL 3: mühimmat da silahla AYNI ruhsat sözleşmesine tabidir.
        if not Matrix.BlackMarket.HasWeaponLicense(src) then
            Reply(src, 'Silah ruhsatiniz yok/gecersiz -- muhimmat satin alamazsiniz.')
            TriggerClientEvent('matrix:client:blackmarket:purchaseResult', src, false, entry.label, nil)
            return
        end


        -- ★ MODUL 4: deterministik stok penceresi (mühimmat da silah
        -- sinifiyla AYNI toptanci akisina baglidir).
        local available = Matrix.BlackMarket.IsWeaponClassAvailableNow(citizenid, entry.class)
        if not available then
            Reply(src, ('%s muhimmati su anda stokta degil (toptanci penceresi kapali).'):format(entry.class or 'silah'))
            TriggerClientEvent('matrix:client:blackmarket:purchaseResult', src, false, entry.label, nil)
            return
        end


        local chargeOk, reason = ChargeCash(src, entry.price)
        if not chargeOk then
            Reply(src, reason == 'insufficient_funds' and 'Yetersiz nakit.' or 'Odeme basarisiz.')
            TriggerClientEvent('matrix:client:blackmarket:purchaseResult', src, false, entry.label, nil)
            return
        end


        local deliverOk, mode = DeliverViaRendezvousOrFallback(src, citizenid, 'ammo', entry, entry.item, entry.count, nil)
        if not deliverOk then
            RefundCash(src, entry.price, citizenid)
            Reply(src, 'Muhimmat teslimati ayarlanamadi, odeme iade edildi (envanter dolu olabilir).')
            TriggerClientEvent('matrix:client:blackmarket:purchaseResult', src, false, entry.label, nil)
            return
        end


        LogPurchase(citizenid, 'ammo', entry.item, entry.price)


        if mode == 'rendezvous' then
            Reply(src, ('%s icin odeme alindi. Buluşma noktasi Taktik Not Defterine islendi.'):format(entry.label))
        else
            Reply(src, ('%s satin alindi.'):format(entry.label))
        end
        TriggerClientEvent('matrix:client:blackmarket:purchaseResult', src, true, entry.label, entry.item)
        Matrix.Log('BLACKMARKET', '[SATIS] %s -> muhimmat %s x%d (mod:%s) $%.0f', citizenid, entry.label, entry.count, mode, entry.price)
    end)
    ReleasePurchaseLock(src)
    if not ok then
        Matrix.Log('BLACKMARKET', '[HATA] buyAmmo ic hata (kilit serbest birakildi): %s', tostring(err))
    end
end)


-- =====================================================================
-- SATIN ALMA: YEDEK NAMLU  (DEĞİŞMEDİ — anında teslim)
-- =====================================================================
RegisterNetEvent('matrix:server:blackmarket:buySpareBarrel', function(token)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    if not ConsumeHandshakeToken(src, 'barrel', nil, token) then
        Matrix.Log('BLACKMARKET', '[SEC-4][GUVENLIK] src=%d gecersiz/eksik handshake token ile buySpareBarrel cagirdi (spoofing supheli).', src)
        return
    end
    if not TryAcquirePurchaseLock(src) then
        Reply(src, 'Bir onceki karaborsa islemin hala isleniyor, bekle.')
        return
    end


    local ok, err = pcall(function()
        local state = Matrix.GetOrCreatePlayerState(src)
        local citizenid = state and state.citizenid
        if not citizenid then Reply(src, 'Profil cozulemedi.'); return end


        local price = Config.BlackMarket.SpareBarrelPrice
        local item  = Config.BlackMarket.SpareBarrelItem


        local chargeOk, reason = ChargeCash(src, price)
        if not chargeOk then
            Reply(src, reason == 'insufficient_funds' and 'Yetersiz nakit.' or 'Odeme basarisiz.')
            TriggerClientEvent('matrix:client:blackmarket:purchaseResult', src, false, Config.BlackMarket.SpareBarrelLabel, nil)
            return
        end


        local addOk = pcall(function()
            return exports['ox_inventory']:AddItem(src, item, 1)
        end)
        if not addOk then
            RefundCash(src, price, citizenid)
            Reply(src, 'Yedek Namlu teslim edilemedi, odeme iade edildi (envanter dolu olabilir).')
            TriggerClientEvent('matrix:client:blackmarket:purchaseResult', src, false, Config.BlackMarket.SpareBarrelLabel, nil)
            return
        end


        LogPurchase(citizenid, 'barrel', item, price)


        Reply(src, ('%s satin alindi. /namludegistir ile mevcut silahiniza takabilirsiniz.'):format(Config.BlackMarket.SpareBarrelLabel))
        TriggerClientEvent('matrix:client:blackmarket:purchaseResult', src, true, Config.BlackMarket.SpareBarrelLabel, item)
        Matrix.Log('BLACKMARKET', '[SATIS] %s -> Yedek Namlu $%.0f', citizenid, price)
    end)
    ReleasePurchaseLock(src)
    if not ok then
        Matrix.Log('BLACKMARKET', '[HATA] buySpareBarrel ic hata (kilit serbest birakildi): %s', tostring(err))
    end
end)


-- =====================================================================
-- SATIN ALMA: AÇIK HAT (BURNER PHONE)  (DEĞİŞMEDİ — anında teslim)
-- =====================================================================
RegisterNetEvent('matrix:server:blackmarket:buyBurnerPhone', function(catalogId, token)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    if not ConsumeHandshakeToken(src, 'burner_phone', catalogId, token) then
        Matrix.Log('BLACKMARKET', '[SEC-4][GUVENLIK] src=%d gecersiz/eksik handshake token ile buyBurnerPhone cagirdi (spoofing supheli).', src)
        return
    end
    if not TryAcquirePurchaseLock(src) then
        Reply(src, 'Bir onceki karaborsa islemin hala isleniyor, bekle.')
        return
    end


    local ok, err = pcall(function()
        local entry = FindBurnerPhoneCatalogEntry(catalogId)
        if not entry then Reply(src, 'Gecersiz karaborsa kalemi.'); return end


        local state = Matrix.GetOrCreatePlayerState(src)
        local citizenid = state and state.citizenid
        if not citizenid then Reply(src, 'Profil cozulemedi.'); return end


        local chargeOk, reason = ChargeCash(src, entry.price)
        if not chargeOk then
            Reply(src, reason == 'insufficient_funds' and 'Yetersiz nakit.' or 'Odeme basarisiz.')
            TriggerClientEvent('matrix:client:blackmarket:purchaseResult', src, false, entry.label, nil)
            return
        end


        -- ★ KATMAN 7 FAZ 2: acquired_at, server/forensics.lua'nin YENI Real-Time
        -- Ust Arama kontrabant kontrolunun (Config.Forensics.Frisk.
        -- BurnerPhoneMaxHoldSeconds) tek girdisidir -- bu satirin DISINDA hicbir
        -- sey (satis fiyati/IMEI maskeleme) DEGISTIRILMEDI.
        local addOk = pcall(function()
            return exports['ox_inventory']:AddItem(src, entry.item, 1, { imei_masked = true, acquired_at = Matrix.Now() })
        end)
        if not addOk then
            RefundCash(src, entry.price, citizenid)
            Reply(src, 'Acik Hat teslim edilemedi, odeme iade edildi (envanter dolu olabilir).')
            TriggerClientEvent('matrix:client:blackmarket:purchaseResult', src, false, entry.label, nil)
            return
        end


        LogPurchase(citizenid, 'burner_phone', entry.item, entry.price)


        Reply(src, ('%s satin alindi. IMEI maskeleme aktif.'):format(entry.label))
        TriggerClientEvent('matrix:client:blackmarket:purchaseResult', src, true, entry.label, entry.item)
        Matrix.Log('BLACKMARKET', '[SATIS] %s -> Acik Hat $%.0f', citizenid, entry.price)
    end)
    ReleasePurchaseLock(src)
    if not ok then
        Matrix.Log('BLACKMARKET', '[HATA] buyBurnerPhone ic hata (kilit serbest birakildi): %s', tostring(err))
    end
end)


-- =====================================================================
-- ★ MODUL 9: SİLAH MODİFİKASYONU SATIN ALMA + TAKMA
-- glock_switch (yalnizca 'pistol' sinifi) ve mimtac_drop_in_trigger
-- (yalnizca 'rifle' sinifi) -- Config.BlackMarket.WeaponMods'ta tanimli.
-- Satin alma: SpareBarrel ile AYNI (anlik teslim) desen. Takma: hedef
-- silahin item adi Config.BlackMarket.Weapons katalogundan `class`
-- cozulup WeaponMods[modName].compatible_class ile karsilastirilir --
-- UYUMSUZSA REDDEDILIR.
-- =====================================================================
local function FindWeaponClassByItem(itemName)
    for _, w in ipairs(Config.BlackMarket.Weapons) do
        if w.item == itemName then return w.class end
    end
    return nil
end
Matrix.BlackMarket.FindWeaponClassByItem = FindWeaponClassByItem


RegisterNetEvent('matrix:server:blackmarket:buyWeaponMod', function(modName, token)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    if not ConsumeHandshakeToken(src, 'weapon_mod', modName, token) then
        Matrix.Log('BLACKMARKET', '[SEC-4][GUVENLIK] src=%d gecersiz/eksik handshake token ile buyWeaponMod cagirdi (spoofing supheli).', src)
        return
    end
    if not TryAcquirePurchaseLock(src) then
        Reply(src, 'Bir onceki karaborsa islemin hala isleniyor, bekle.')
        return
    end


    local ok, err = pcall(function()
        local modDef = Config.BlackMarket.WeaponMods and Config.BlackMarket.WeaponMods[modName]
        if not modDef then Reply(src, 'Gecersiz silah modifikasyonu.'); return end

        local state = Matrix.GetOrCreatePlayerState(src)
        local citizenid = state and state.citizenid
        if not citizenid then Reply(src, 'Profil cozulemedi.'); return end

        if not Matrix.BlackMarket.HasWeaponLicense(src) then
            Reply(src, 'Silah ruhsatiniz yok/gecersiz -- modifikasyon satin alamazsiniz.')
            TriggerClientEvent('matrix:client:blackmarket:purchaseResult', src, false, modDef.label, nil)
            return
        end

        local chargeOk, reason = ChargeCash(src, modDef.price)
        if not chargeOk then
            Reply(src, reason == 'insufficient_funds' and 'Yetersiz nakit.' or 'Odeme basarisiz.')
            TriggerClientEvent('matrix:client:blackmarket:purchaseResult', src, false, modDef.label, nil)
            return
        end

        local addOk = pcall(function()
            return exports['ox_inventory']:AddItem(src, modName, 1)
        end)
        if not addOk then
            RefundCash(src, modDef.price, citizenid)
            Reply(src, 'Modifikasyon teslim edilemedi, odeme iade edildi (envanter dolu olabilir).')
            TriggerClientEvent('matrix:client:blackmarket:purchaseResult', src, false, modDef.label, nil)
            return
        end

        LogPurchase(citizenid, 'weapon_mod', modName, modDef.price)
        Reply(src, ('%s satin alindi. /silahmodtak ile uyumlu silahiniza takabilirsiniz.'):format(modDef.label))
        TriggerClientEvent('matrix:client:blackmarket:purchaseResult', src, true, modDef.label, modName)
        Matrix.Log('BLACKMARKET', '[SATIS] %s -> mod %s $%.0f', citizenid, modName, modDef.price)
    end)
    ReleasePurchaseLock(src)
    if not ok then
        Matrix.Log('BLACKMARKET', '[HATA] buyWeaponMod ic hata (kilit serbest birakildi): %s', tostring(err))
    end
end)


RegisterCommand('silahmodtak', function(src, args)
    local modSlot    = tonumber(args[1])
    local weaponSlot = tonumber(args[2])
    if type(src) ~= 'number' or src <= 0 or not modSlot or not weaponSlot then
        Reply(src, 'Kullanim: /silahmodtak [modSlotu] [silahSlotu]')
        return
    end

    local inventoryId = tostring(src)

    local modOk, modItem = pcall(function() return exports['ox_inventory']:GetSlot(inventoryId, modSlot) end)
    if not modOk or type(modItem) ~= 'table' or type(modItem.name) ~= 'string' then
        Reply(src, 'Belirtilen slotta bir modifikasyon bulunamadi.'); return
    end

    local modDef = Config.BlackMarket.WeaponMods and Config.BlackMarket.WeaponMods[modItem.name]
    if not modDef then
        Reply(src, 'Bu esya bir silah modifikasyonu degil.'); return
    end

    local weaponOk, weaponItem = pcall(function() return exports['ox_inventory']:GetSlot(inventoryId, weaponSlot) end)
    if not weaponOk or type(weaponItem) ~= 'table' or type(weaponItem.name) ~= 'string' then
        Reply(src, 'Belirtilen slotta silah bulunamadi.'); return
    end

    local weaponClass = FindWeaponClassByItem(weaponItem.name)
    if weaponClass ~= modDef.compatible_class then
        Reply(src, ('%s yalniz "%s" sinifi silahlara uyumludur.'):format(modDef.label, modDef.compatible_class))
        return
    end

    local removeOk = pcall(function() return exports['ox_inventory']:RemoveItem(inventoryId, modItem.name, 1, nil, modSlot) end)
    if not removeOk then
        Reply(src, 'Modifikasyon tuketilemedi.'); return
    end

    -- ★ Global Config MUTASYONA UĞRATILMAZ (bkz. Config.BlackMarket.WeaponMods
    -- yorumu) -- carpan/delta SADECE bu silahin metadata'sinda saklanir;
    -- server/forensics.lua OnWeaponShotFired/ComputeMechanicalJamProbability
    -- bu alanlari okuyup uygular.
    local modMeta = {
        weapon_mod_name = modItem.name,
        full_auto       = modDef.full_auto or false,
        jam_coefficient_multiplier   = modDef.jam_coefficient_multiplier,
        trigger_weight_multiplier    = modDef.trigger_weight_multiplier,
        jam_threshold_percent_delta  = modDef.jam_threshold_percent_delta
    }
    Matrix.Inventory.MergeMetadata(inventoryId, weaponSlot, modMeta)

    Reply(src, ('%s silahiniza takildi.'):format(modDef.label))
    Matrix.Log('BLACKMARKET', '[MOD TAKILDI] src=%d silah=%s mod=%s', src, weaponItem.name, modItem.name)
end, false)


-- =====================================================================
-- TAKTİK DEBUG PANELİ
-- =====================================================================
RegisterCommand('karaborsagecmisi', function(src, args)
    local citizenid = args[1]
    if type(citizenid) ~= 'string' then Reply(src, 'Kullanim: /karaborsagecmisi [citizenid]'); return end


    local rows = MySQL.query.await(
        'SELECT item_type, item_ref, price_paid, created_at FROM matrix_blackmarket_purchases WHERE citizenid = ? ORDER BY id DESC LIMIT 20',
        { citizenid }
    ) or {}


    Reply(src, ('--- %s icin son %d karaborsa islemi ---'):format(citizenid, #rows))
    for _, row in ipairs(rows) do
        Reply(src, ('  [%s] %s | $%.0f | %s'):format(row.item_type, tostring(row.item_ref), row.price_paid, tostring(row.created_at)))
    end
end, false)


-- =====================================================================
-- EXPORTLAR
-- =====================================================================
-- ★ [SEC-4] NOT: bu export sunucu-içi güvenilir bir çağırandır (örn. bir
-- admin komutu/NPC etkileşimi) -- client handshake token'ından BAĞIMSIZ
-- olarak DoBuyVehicle çekirdeğini doğrudan çağırır. Eskiden bu export
-- TriggerEvent ile AYNI event handler'ı tetikliyordu; token zorunluluğu
-- eklendiğinde bu export kendi kendini kilitlerdi -- o yüzden çekirdek
-- mantık DoBuyVehicle'a çıkarıldı (bkz. yukarısı).
exports('BuyBlackMarketVehicle', function(src, catalogId)
    DoBuyVehicle(src, catalogId)
end)
exports('GenerateScratchedPlate', function(citizenid) return Matrix.BlackMarket.GenerateScratchedPlate(citizenid) end)
exports('GenerateWeaponSerial',  function(citizenid, weaponItem) return Matrix.BlackMarket.GenerateWeaponSerial(citizenid, weaponItem) end)