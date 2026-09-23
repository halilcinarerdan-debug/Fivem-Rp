-- ★ [MODUL 16.1] EMNIYET ILKLENDIRMESI: bu dosyalarin hicbiri global Matrix
-- tablosunu calisma zamaninda okumaz (bkz. server-side yorumlar), ama
-- ileride bir referans eklenirse client-side VM'in erken/farkli sirada
-- yuklenmesi durumunda nil-index hatasi ASLA olusmasin diye zararsiz bir
-- guvenlik agi olarak eklenir.
Matrix = Matrix or {}
Matrix.Client = Matrix.Client or {}


-- =====================================================================
-- MATRIX HUD / client/hud.lua  (KATMAN 6 — RENDEZVOUS/TAHKİMAT EKİ)
-- Saf metin tabanlı, monokrom (yeşil/beyaz/kırmızı) Taktik Durum HUD'u.
--
-- ★ SERTLEŞTİRME (v1, korunuyor):
--   [S1] lib.inputDialog çıktıları, ExecuteCommand'a girmeden önce KATI
--        sanitizasyondan geçer: sayısal alanlar yalnızca tam sayı,
--        [1, Config.Hud.MaxBotIdInputValue]; plaka yalnızca [%w%-_%.] ve
--        Config.Hud.MaxPlateInputLength sınırında. Boşluk/quote/semicolon/
--        newline İÇEREN hiçbir girdi komuta ULAŞMAZ — ExecuteCommand
--        argüman-ayrıştırıcısına asla kirli string gitmez. Bu, sunucu
--        thread'inde mikrosaniyelik bile bir "parse + yetkisiz arg"
--        oluşmasını yapısal olarak engeller.
--   [S2] Gelen snapshot satırları `#lines <= Config.Hud.MaxHudLines` ile
--        sınırlandırılır (RAM-bomb savunması).
--   [S3] lib.notify varsa geçersiz girdi sessizce YUTULMAZ, kullanıcıya
--        görünür bir uyarı basılır (ama komut TETİKLENMEZ).
--
-- ★ KATMAN 5 EVRİM (korunuyor):
--   [E1] SIFIR SAYI STANDARDI, [E2] MULTI-WAYPOINT TAKTİK ROTA MOTORU.
--
-- ★ KATMAN 5 ULTIMATE (korunuyor):
--   [U1]-[U8]: /sevket kaldırıldı, Canlı Kadro tıklanabilir bot aksiyonları,
--   mekanik tutukluk tahliyesi, karaborsa/mali rapor alt menüleri, COMINT,
--   Acil Tahliye.
--
-- ★ KATMAN 6 (bu sürüm — yeni işler):
--   [K1] F10 -> "Mühimmat / Envanter Ameliyatı": Canlı Kadro'daki bir bota
--        tıklayınca açılan aksiyon menüsüne eklendi. Bot envanterini
--        (server/trap_house_interior.lua, lib.callback) listeler ve
--        oyuncunun kendi envanterindeki bir slotu bota elden teslim
--        etmesini sağlar (sayısal slot/miktar [S1] ile AYNI disiplinde
--        sanitize edilir).
--   [K2] F10 -> "Kapı Sürgü Tahkimatı": trap house ID + hedef seviye
--        (1-3) alır, server/door_reinforcement.lua'ya iletir. Trap House
--        ID ve seviye [S1] ile AYNI SanitizeNumericArg'dan geçer.
--   [K3] 'L' tuşu: Operasyon Not Defterini artık F10 menüsüne girmeden
--        doğrudan açar (mevcut OpenMatrixNotepad'e ek bir giriş noktası —
--        F10 içindeki eski giriş KALDIRILMADI).
--   [K4] 'matrix:client:rendezvousAssigned' event'i: server/rendezvous.lua
--        bir karaborsa silah/mühimmat buluşması ayarladığında GPS
--        waypoint'i otomatik ayarlar VE koordinatı Not Defterine ekler —
--        çiğ koordinat yalnızca oyuncunun KENDİ isteğiyle aldığı bir
--        teslimatın konumu olduğundan (server tarafından üretilip
--        gönderildiğinden) [S1] sanitizasyonuna tabi DEĞİLDİR (giden bir
--        ExecuteCommand argümanı değil, gelen güvenilir veridir).
--   Fiziksel dünya öğeleri (kapı blip'leri, satıcı/pusu ped'leri, tezgah/
--   paketleme prompt'ları, ambient dekor) client/trap_house_client.lua'da
--   AYRI bir dosyada tutulur — bu dosyanın kapsamı HUD + F10 menüsü olarak
--   kalır (mevcut dosya ayrımıyla tutarlı).
-- =====================================================================


local hudActive = false
local hudLines  = {}   -- { { text=..., header=true/false, danger=true/false }, ... }


local COLOR_HEADER = { 235, 235, 235 }
local COLOR_VALUE  = { 110, 255, 140 }
local COLOR_DIM    = { 90, 140, 100 }
local COLOR_DANGER = { 255, 70, 70 } -- ★ [U3][U5]: mekanik tutukluk / sinyal ucgenleme uyarilari


local MAX_HUD_LINES  = (Config.Hud and Config.Hud.MaxHudLines) or 64
local MAX_PLATE_LEN  = (Config.Hud and Config.Hud.MaxPlateInputLength) or 32
local MAX_BOT_ID     = (Config.Hud and Config.Hud.MaxBotIdInputValue) or 999999
local MAX_WAYPOINT_LEN = (Config.Hud and Config.Hud.MaxWaypointInputLength) or 64
local WEAPON_EVAC_MS = ((Config.Forensics and Config.Forensics.WeaponEvacuationSeconds) or 6) * 1000


local function DrawMonoLine(x, y, text, r, g, b, scale)
    SetTextFont(4)
    SetTextProportional(1)
    SetTextScale(scale, scale)
    SetTextColour(r, g, b, 235)
    SetTextDropshadow(1, 0, 0, 0, 200)
    SetTextEdge(1, 0, 0, 0, 180)
    SetTextEntry('STRING')
    AddTextComponentString(text)
    DrawText(x, y)
end


-- ★ [S1] Sanitizasyon yardımcıları -------------------------------------


--- Sayısal string arg: tam sayı, [minVal, maxVal] aralığında. Aksi halde nil.
--- NaN/inf/+/- boşluk/karakter — hepsi reddedilir.
local function SanitizeNumericArg(v, minVal, maxVal)
    if v == nil then return nil end
    local n = tonumber(v)
    if not n or n ~= n or n == math.huge or n == -math.huge then return nil end
    n = math.floor(n)
    if n < (minVal or 1) or n > (maxVal or MAX_BOT_ID) then return nil end
    return tostring(n)
end


--- Plaka arg: yalnızca [%w%-_%.] karakterleri, <= MAX_PLATE_LEN. Boş string
--- GEÇERLİDİR (kalıcı araç/foot anlamına gelir). Boşluk/quote/semicolon/nil
--- → nil (reddedilir).
local function SanitizePlateArg(v)
    if v == nil then return '' end
    local s = tostring(v)
    if #s > MAX_PLATE_LEN then return nil end
    if s == '' then return '' end
    -- Boşluk, quote, ; , |, newline, tab: hepsi YASAK (ExecuteCommand parser'ı
    -- boşluktan böler; enjeksiyon vektörünü kapatıyoruz).
    if s:find('[^%w%-_%.]') then return nil end
    return s
end


--- Rank arg: whitelist. Client, sunucudaki Config'i görmez ama bu üç değer
--- sabit — yine de ExecuteCommand'a SADECE bu üç string'den biri geçer.
local VALID_RANK_ARGS = {
    Leader = true, Logistics_Officer = true, Chemist = true
}


local function SanitizeRankArg(v)
    if v == nil then return nil end
    local s = tostring(v)
    if not VALID_RANK_ARGS[s] then return nil end
    return s
end


--- ★ KATMAN 7 [OPSEC] DEAD DROP ID TOKEN — "DD-1"/"DD-2"/"DD-3" gibi
--- Config.Supplier.DeadDrops.id'lerine deterministik olarak eşlenen bir
--- token'ı tanır. Rota motorunun "koordinat mı, trap house mu, dead drop mu"
--- ayrımı ZATEN sunucu tarafında yapılıyordu (bkz. SanitizeWaypointArg'ın
--- dosya-başı yorumu) — burada yalnızca BU ÜÇÜNCÜ formatın karakter kümesi
--- ve GERÇEKTEN var olan bir id'ye karşılık geldiği client tarafında
--- ÖN-DOĞRULANIR. Config.Supplier paylaşımlı (shared/config.lua) olduğundan
--- client bu listeyi zaten görür — yeni bir sunucu round-trip'i GEREKMEZ.
--- Token boşluk/virgül İÇERMEZ (tek bir kelimedir), bu yüzden ExecuteCommand'ın
--- tek-argüman disiplinini BOZMAZ.
local DEAD_DROP_TOKEN_PATTERN = '^[Dd][Dd]%-(%d+)$'


local function SanitizeDeadDropArg(s)
    local idStr = s:match(DEAD_DROP_TOKEN_PATTERN)
    if not idStr then return nil end
    local id = tonumber(idStr)
    if not id then return nil end
    if not (Config.Supplier and Config.Supplier.DeadDrops) then return nil end
    for _, drop in ipairs(Config.Supplier.DeadDrops) do
        if drop.id == id then
            return ('DD-%d'):format(id)
        end
    end
    return nil
end


--- ★ [E2] Waypoint arg: "x,y,z" / "x, y, z" / "x y z" (/coords çıktısı
--- boşlukla gelir) vektörü, salt tam sayı Trap House ID, YA DA (KATMAN 7
--- [OPSEC]) "DD-<sayı>" Dead Drop token'ı kabul eder. Vektör/Trap House
--- dalının kabul ettiği karakter kümesi yalnızca [rakam, nokta, virgül,
--- eksi, boşluk] olarak KALIR — harf/quote/semicolon İÇEREN hiçbir girdi
--- kabul edilmez; DD- token'ı bu genel kurala girmeden, kendi dar/whitelist
--- deseniyle AYRICA ve ÖNCE tanınır. ExecuteCommand tek bir argüman bekler
--- (boşluk argümanı BÖLER), bu yüzden kabul edilen boşluklar/virgüller
--- BURADA tek bir "," ayracına normalize edilir; döndürülen string ASLA
--- boşluk içermez. Format çözümlemesi (trap house mu, koordinat mı, dead
--- drop mu) sunucu tarafında yapılır; client yalnızca karakter kümesini,
--- uzunluğu ve normalize edilmiş biçimi doğrular.
local function SanitizeWaypointArg(v)
    if v == nil then return nil end
    local s = tostring(v)
    s = s:match('^%s*(.-)%s*$') -- baş/son boşlukları kırp
    if s == '' then return nil end
    if #s > MAX_WAYPOINT_LEN then return nil end


    -- ★ KATMAN 7 [OPSEC]: Dead Drop token'ı önce denenir (harf taşıdığı
    -- için aşağıdaki rakam-only filtreye ASLA girmez).
    local ddToken = SanitizeDeadDropArg(s)
    if ddToken then return ddToken end


    -- Yalnızca rakam/nokta/virgül/eksi/boşluk — başka HİÇBİR karakter kabul edilmez.
    if s:find('[^%d%.,%-%s]') then return nil end


    -- "x y z" / "x, y , z" gibi karışık ayraçları TEK "," ayracına indir.
    s = s:gsub('%s+', ','):gsub(',+', ',')
    s = s:match('^,*(.-),*$') -- baş/son ayraçları temizle


    if s == '' then return nil end
    if #s > MAX_WAYPOINT_LEN then return nil end
    return s
end


--- ★ [E3] DİNAMİK WAYPOINT ESNEKLİĞİ: ara uğrak alanları (1-3) artık
--- ZORUNLU DEĞİL. Boş bırakılan bir alan GEÇERLİDİR — sabit bir "atla"
--- placeholder'ı (ROUTE_WAYPOINT_SKIP) döner; ExecuteCommand tek argüman
--- beklediği için boş string GÖNDERİLEMEZ (pozisyonel argümanları kaydırır),
--- bu yüzden boş bırakma her zaman bu sabit, boşluksuz token ile temsil
--- edilir. DOLU bir alan yine [S1] ile aynı katı SanitizeWaypointArg
--- kontrolünden geçer — geçersizse (harf/quote/vb.) nil döner (komut iptal).
local ROUTE_WAYPOINT_SKIP = 'nil'


local function SanitizeOptionalWaypointArg(v)
    if v == nil then return ROUTE_WAYPOINT_SKIP end
    local trimmed = tostring(v):match('^%s*(.-)%s*$')
    if trimmed == '' then return ROUTE_WAYPOINT_SKIP end
    return SanitizeWaypointArg(trimmed)
end


--- ★ [E2] Araç tipi arg: whitelist Config.Logistics.VehicleTypes anahtarlarından
--- türetilir (paylaşımlı Config, client'ta da görünür) — sabit metin dışında
--- hiçbir şey ExecuteCommand'a geçmez.
local function SanitizeVehicleTypeArg(v)
    if v == nil then return nil end
    local s = tostring(v)
    if not (Config.Logistics and Config.Logistics.VehicleTypes and Config.Logistics.VehicleTypes[s]) then
        return nil
    end
    return s
end


local function BuildVehicleTypeOptions()
    local options = {}
    for vtype in pairs(Config.Logistics and Config.Logistics.VehicleTypes or {}) do
        options[#options + 1] = { value = vtype, label = vtype }
    end
    table.sort(options, function(a, b) return a.value < b.value end)
    return options
end

local function NotifyInvalidInput(reason)
    if lib and lib.notify then
        lib.notify({
            title       = '[GECERSIZ GIRD]',
            description = reason or 'Komut icin gecersiz parametre.',
            type        = 'error'
        })
    else
        print(('[MATRIX:HUD] Gecersiz girdi: %s'):format(tostring(reason)))
    end
end


-- =====================================================================
-- ★ [E1] SIFIR SAYI STANDARDI — Bültene Çeviri Motoru
-- =====================================================================
local BULLETIN_CORTISOL   = (Config.Hud and Config.Hud.Bulletins and Config.Hud.Bulletins.Cortisol)
    or { CalmMax = 0.20, AnxietyMax = 0.60 }
local BULLETIN_FATIGUE    = (Config.Hud and Config.Hud.Bulletins and Config.Hud.Bulletins.Fatigue)
    or { FreshMax = 0.30, ChronicMax = 0.80 }
local BULLETIN_MECHANICAL = (Config.Hud and Config.Hud.Bulletins and Config.Hud.Bulletins.Mechanical)
    or { PristineMin = 0.80, WornMin = 0.40 }


local function FormatCortisolBulletin(value)
    value = tonumber(value)
    if not value then return nil end
    if value < BULLETIN_CORTISOL.CalmMax then
        return '[NABIZ: SOĞUKKANLI SUBAY]'
    elseif value <= BULLETIN_CORTISOL.AnxietyMax then
        return '[NABIZ: ANKSİYETE BAŞLANGICI — TETİKTE]'
    else
        return '[NABIZ: AKUT PANİK ATAK KRİZİ — ELLERİN TİTRİYOR]'
    end
end


local function FormatFatigueBulletin(value)
    value = tonumber(value)
    if not value then return nil end
    if value < BULLETIN_FATIGUE.FreshMax then
        return '[KONDİSYON: DİNÇ]'
    elseif value <= BULLETIN_FATIGUE.ChronicMax then
        return '[KONDİSYON: KRONİK BİTKİNLİK — REFLEKSLER YAVAŞ]'
    else
        return '[KONDİSYON: NÖRON HASARI SINIRI — BEYİN SAKATLIĞI RİSKİ]'
    end
end


local function FormatMechanicalBulletin(value)
    value = tonumber(value)
    if not value then return nil end
    if value > BULLETIN_MECHANICAL.PristineMin then
        return '[MEKANİK: KUSURSUZ CONDITION]'
    elseif value >= BULLETIN_MECHANICAL.WornMin then
        return '[MEKANİK: YİV-SET AŞINMASI — BALİSTİK MUTASYON AKTİF]'
    else
        return '[MEKANİK: KRİTİK YİV ERİMESİ — TUTUKLUK VE PERMADEATH RİSKİ]'
    end
end


--- Sunucudan gelen tek bir snapshot satırını (ham metrik veya düz metin)
--- nihai ekran metnine çevirir. Bilinmeyen/geçersiz metrik → nil (satır
--- ekrana hiç basılmaz; çiğ sayı asla sızmaz).
local function FormatBulletinLine(metric, value, label)
    label = label or ''
    if metric == 'cortisol_level' then
        local text = FormatCortisolBulletin(value)
        return text and (label .. text) or nil
    elseif metric == 'fatigue_level' then
        local text = FormatFatigueBulletin(value)
        return text and (label .. text) or nil
    elseif metric == 'durability' or metric == 'wear_level' then
        local text = FormatMechanicalBulletin(value)
        return text and (label .. text) or nil
    end
    return nil
end


-- =====================================================================
-- Toggle / snapshot
-- =====================================================================
local function ToggleHud(forceState)
    local newState = (forceState ~= nil) and forceState or (not hudActive)
    if newState == hudActive then return end


    hudActive = newState
    if not hudActive then
        hudLines = {}
    end
    TriggerServerEvent('matrix:server:hudToggled', hudActive)
end


-- ★ [U5] danger alanı da taşınır: sunucu (server/market.lua BuildSnapshot)
-- COMINT üçgenleme uyarısı gibi satırları `danger=true` ile işaretler,
-- render thread bunu kırmızı çizer (bkz. aşağıdaki RENDER THREAD).
RegisterNetEvent('matrix:client:hudSnapshot', function(lines)
    if not hudActive then return end
    if type(lines) ~= 'table' then return end
    -- ★ [S2] RAM-bomb savunması: sunucu kontrollü de olsa, üst sınır koy.
    if #lines > MAX_HUD_LINES then return end


    -- ★ [E1] Dönüşüm TEK SEFERDE burada yapılır (per-frame değil) — 0 Resmon
    -- bütçesi korunur. Render thread'i yalnızca hazır metni çizer.
    local converted = {}
    for i = 1, #lines do
        local line = lines[i]
        if type(line) == 'table' then
            if line.metric ~= nil then
                local text = FormatBulletinLine(line.metric, line.value, line.label)
                if text then
                    converted[#converted + 1] = { text = text, header = line.header and true or false, danger = line.danger and true or false }
                end
            elseif type(line.text) == 'string' then
                converted[#converted + 1] = { text = line.text, header = line.header and true or false, danger = line.danger and true or false }
            end
        end
    end
    hudLines = converted
end)


RegisterCommand('hud', function()
    ToggleHud()
end, false)


RegisterKeyMapping('hud', 'Taktik HUD ac/kapat', 'keyboard', Config.Hud and Config.Hud.ToggleKey or 'F6')


-- ★ [U5] COMINT: aynı HUD'u açan/kapatan ikinci bir tuş bağı. Ayrı bir
-- panel/render thread AÇILMAZ — [COMINT ISTIHBARAT PROFILI] bloğu zaten
-- ana snapshot'ın bir parçasıdır (bkz. server/market.lua BuildSnapshot).
RegisterCommand('comintpanel', function()
    ToggleHud()
end, false)
RegisterKeyMapping('comintpanel', 'COMINT Istihbarat Profili (Taktik HUD) ac/kapat', 'keyboard', (Config.Comint and Config.Comint.ToggleKey) or 'K')


AddEventHandler('onClientResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    hudActive = false
    hudLines  = {}
end)

-- =====================================================================
-- ★ [FIX] TAKTIK HUD RENDER DONGUSU -- BU DOSYADA DAHA ONCE HICBIR YERDE
-- YOKTU: hudActive/hudLines dogru sekilde tutuluyor (ToggleHud, hudSnapshot
-- event'i), ama onlari EKRANA CIZEN bir CreateThread dongusu hic
-- YAZILMAMISTI -- DrawMonoLine bu dosyada yalnizca [U3] mekanik tutukluk
-- uyarisi icin cagriliyordu. F6/K basildiginda hudActive dogru sekilde
-- toggle oluyor VE sunucudan snapshot geliyordu, ama HICBIR SEY EKRANA
-- BASILMIYORDU -- "HUD bulten cercevesi ekrana gelmiyor" sikayetinin
-- KOK NEDENI budur (bir race/yaris kosulu veya ag kesintisi DEGIL).
--
-- hudActive=false iken dongu Wait(250) ile HAFIF bekler (0 Resmon
-- disiplini); hudActive=true iken her frame (Wait(0)) sabit basliktan
-- itibaren hudLines dizisini SIRAYLA cizer -- header/danger/normal
-- satirlar COLOR_HEADER/COLOR_DANGER/COLOR_VALUE ile ayirt edilir.
-- =====================================================================
local HUD_ORIGIN_X     = 0.015
local HUD_ORIGIN_Y     = 0.04
local HUD_LINE_HEIGHT  = 0.021
local HUD_TEXT_SCALE   = 0.32

CreateThread(function()
    while true do
        if hudActive then
            local y = HUD_ORIGIN_Y
            DrawMonoLine(HUD_ORIGIN_X, y, '=== TAKTIK HUD (MATRIX) ===', COLOR_HEADER[1], COLOR_HEADER[2], COLOR_HEADER[3], HUD_TEXT_SCALE)
            y = y + HUD_LINE_HEIGHT

            if #hudLines == 0 then
                -- ★ [FIX] sunucudan HENUZ ilk snapshot gelmediyse (agir
                -- gecikme/ag kesintisi) bulten cercevesi BOS BEKLEMEZ --
                -- senkronize ediliyor bulteni ANINDA cizilir, bos bir
                -- ekran ASLA gorulmez.
                DrawMonoLine(HUD_ORIGIN_X, y, '[SENKRONIZE EDILIYOR...]', COLOR_DIM[1], COLOR_DIM[2], COLOR_DIM[3], HUD_TEXT_SCALE)
            else
                for i = 1, #hudLines do
                    local line = hudLines[i]
                    local r, g, b = COLOR_VALUE[1], COLOR_VALUE[2], COLOR_VALUE[3]
                    if line.danger then
                        r, g, b = COLOR_DANGER[1], COLOR_DANGER[2], COLOR_DANGER[3]
                    elseif line.header then
                        r, g, b = COLOR_HEADER[1], COLOR_HEADER[2], COLOR_HEADER[3]
                    end
                    DrawMonoLine(HUD_ORIGIN_X, y, line.text, r, g, b, HUD_TEXT_SCALE)
                    y = y + HUD_LINE_HEIGHT
                end
            end

            Wait(0)
        else
            Wait(250)
        end
    end
end)

-- =====================================================================
-- ★ KATMAN 5 ULTIMATE [U3]: MEKANİK TUTUKLUK TESPİTİ & TAHLİYE
--
-- Mermi-sayısı-azalma (ammo-delta) tespiti kullanılır — IsPedShooting'in
-- tam/otomatik ateş serilerinde kaçırabileceği ardışık atışları KAÇIRMAZ
-- (bir frame'de birden fazla mermi azalmışsa o kadar shot event tetiklenir).
-- Silah kimliği/slotu SUNUCUYA GÜVENİLMEDEN, ox_inventory'nin kendi
-- GetCurrentWeapon export'undan okunur; sunucu ayrıca o slot'un weapon_serial
-- metadata'sını kendi okuyarak doğrular (bkz. server/forensics.lua).
-- =====================================================================
local weaponJamActive = false
local weaponJamSlot    = nil


RegisterNetEvent('matrix:client:weaponJamStateChanged', function(slot, jammed)
    weaponJamActive = jammed and true or false
    weaponJamSlot    = jammed and slot or nil
end)

-- =====================================================================
-- ★ DÜZELTME: KOMUT SONUÇ BİLDİRİMİ (silent-failure önleme)
-- F10 menüsünden tetiklenen komutlar (/operatiftasfiye, /panikiptal, vb.)
-- şimdiye kadar YALNIZCA chat:addMessage ile cevap veriyordu — oyuncunun
-- chat penceresi kapalıysa (FiveM'de varsayılan, T'ye basılana kadar) bir
-- rütbe reddi veya hata SESSİZCE kayboluyor, "tıkladım ama hiçbir şey
-- olmuyor" izlenimi veriyordu. Artık bu komutlar SONUCU (başarılı/
-- başarısız, sebebiyle) AYRICA bu event üzerinden de gönderir; burada
-- lib.notify ile EKRANDA gösterilir — chat açık olsun olmasın görülür.
-- =====================================================================
RegisterNetEvent('matrix:client:actionNotify', function(ok, message)
    if lib and lib.notify then
        lib.notify({
            title       = ok and '[ISLEM BASARILI]' or '[ISLEM BASARISIZ]',
            description = tostring(message or ''),
            type        = ok and 'success' or 'error',
            duration    = 6000
        })
    end
end)

-- =====================================================================
-- ★★★ DARKCHAT TELEMETRİ KÖPRÜSÜ (server/phone_bridge.lua) ★★★
-- Ajan görev sonu bülteni + Need-to-Know maskeli telemetri cevabı.
-- Chat penceresi kapalı olsa bile ekranda görünür (lib.notify).
-- Bu iki blok ADDITIVE'tir; mevcut akışa dokunmaz.
-- =====================================================================
RegisterNetEvent('matrix:client:darkchat:telemetry', function(payload)
    if type(payload) ~= 'table' then return end
    if lib and lib.notify then
        lib.notify({
            title       = ('[DARKCHAT // #%d]'):format(tonumber(payload.bot_id) or 0),
            description = tostring(payload.message or ''),
            type        = 'inform',
            duration    = 9000
        })
    end
end)

RegisterNetEvent('matrix:client:darkchat:telemetryResult', function(data, err)
    if lib and lib.notify then
        if not data then
            lib.notify({
                title       = '[DARKCHAT]',
                description = tostring(err or 'veri yok'),
                type        = 'error'
            })
            return
        end
        local body = data.coords_masked
            and ('[NEED-TO-KNOW] Ajan #%d maskeli: %s | %s'):format(
                data.bot_id, tostring(data.coords_x), tostring(data.balance))
            or  ('Ajan #%d konum: %.1f,%.1f,%.1f | Bakiye: %.2f'):format(
                data.bot_id, data.coords_x, data.coords_y, data.coords_z, data.balance)
        lib.notify({
            title       = '[DARKCHAT TELEMETRI]',
            description = body,
            type        = 'inform',
            duration    = 8000
        })
    end
end)
-- ★★★ DARKCHAT BLOK SONU ★★★

local lastWeaponHash = nil
local lastAmmoInClip = nil
-- ★ [DÜZELTME]: FiveM'in backtick hash-literal uzantısı (`WEAPON_UNARMED`)
-- standart Lua sözdizimi DEĞİLDİR — vanilla luac ile syntax-check
-- edilemez. GetHashKey ile ayni joaat hash'i üretir, davranış AYNI kalır.
local WEAPON_UNARMED_HASH = GetHashKey('WEAPON_UNARMED')

CreateThread(function()
    while true do
        local ped = PlayerPedId()
        local weaponHash = GetSelectedPedWeapon(ped)


        if weaponHash and weaponHash ~= 0 and weaponHash ~= WEAPON_UNARMED_HASH then
            local ammo = GetAmmoInPedWeapon(ped, weaponHash)


            if weaponHash ~= lastWeaponHash then
                -- Silah degisti (kusanma/sokma) - taban cizgisini sifirdan kur,
                -- bu geciste "atis" tetiklenmez.
                lastWeaponHash = weaponHash
                lastAmmoInClip = ammo
            elseif type(lastAmmoInClip) == 'number' and type(ammo) == 'number' and ammo < lastAmmoInClip then
                local shotsFired = lastAmmoInClip - ammo
                local ok, current = pcall(function() return exports['ox_inventory']:GetCurrentWeapon() end)
                if ok and type(current) == 'table' and current.weapon and current.slot then
                    for _ = 1, shotsFired do
                        TriggerServerEvent('matrix:server:reportWeaponShotFired', current.weapon, current.slot)
                    end
                end
                lastAmmoInClip = ammo
            elseif type(lastAmmoInClip) ~= 'number' or (type(ammo) == 'number' and ammo > lastAmmoInClip) then
                -- Ilk okuma veya sarjor doldurma/degistirme - taban cizgisi guncellenir.
                lastAmmoInClip = ammo
            end
        else
            lastWeaponHash = nil
            lastAmmoInClip = nil
        end


        -- Tutukluk aktifken DisablePlayerFiring'in her frame calismasi
        -- gerektigi icin bu thread de Wait(0)'a siki tutunur; aksi halde
        -- hafif bir 100ms poll yeterlidir (mermi degisimi tek frame'lik
        -- gecici bir olay degildir, bir sonraki atisa kadar kalici kalir).
        Wait(weaponJamActive and 0 or 100)
    end
end)


CreateThread(function()
    while true do
        if weaponJamActive then
            DisablePlayerFiring(PlayerId(), true)
            DrawMonoLine(0.36, 0.90, '[MEKANIK: SILAH TUTUKLUK YAPTI]', COLOR_DANGER[1], COLOR_DANGER[2], COLOR_DANGER[3], 0.45)
            Wait(0)
        else
            Wait(250)
        end
    end
end)


local function BeginWeaponJamEvacuation()
    if not weaponJamActive or not weaponJamSlot then
        NotifyInvalidInput('Su an tutuklu bir silahiniz yok.')
        return
    end


    local slot = weaponJamSlot
    local completed = lib.progressCircle({
        duration     = WEAPON_EVAC_MS,
        position     = 'bottom',
        label        = 'Silah Kurma Kolu Cekiliyor / Sikisan Kovan Tahliye Ediliyor...',
        useWhileDead = false,
        canCancel    = true,
        disable      = { move = true, car = true, combat = true }
    })


    if completed then
        TriggerServerEvent('matrix:server:clearWeaponJam', slot)
    end
end


RegisterCommand('silahtahliye', function()
    BeginWeaponJamEvacuation()
end, false)
RegisterKeyMapping('silahtahliye', 'Sikisan Silahi Tahliye Et (Tutukluk Giderme)', 'keyboard', 'X')


-- =====================================================================
-- ★ [MODUL 14.2] ISTEMCI TARAFLI ADLI PAKET TAMPONU (Delayed Buffer Sync)
-- Ag kilitlenmeleri/timeout riski sirasinda sunucuya giden hasar/bayiltma
-- event'lerinin (matrix:server:reportPlayerWounded) havada dusup adli iz
-- birakmadan kaybolmasini ONLER. server/matrix_diagnostics.lua'nin
-- yayinladigi 'matrix:client:networkHeartbeat' zaman damgasi izlenir --
-- bu sure Config.NetworkGuard.HeartbeatTimeoutMs'i asarsa ag hatti
-- "riskli/tikanik" sayilir ve event KORLEMESINE gonderilmez, bunun
-- yerine LocalAdliBuffer'a (FIFO, Config.NetworkGuard.LocalBufferMaxEntries
-- tavanli -- RAM-bomb korumali, en eski kayit sessizce dusurulur)
-- muhurlenir. Ag hatti normale doner donmez tampon TEK bir toplu paket
-- (Delayed Batch Sync) halinde 'matrix:server:reportPlayerWoundedBatch'
-- ile sunucuya gonderilir.
-- =====================================================================
local LocalAdliBuffer   = {}
local LastHeartbeatAt   = GetGameTimer()
local WasNetworkHealthy = true

RegisterNetEvent('matrix:client:networkHeartbeat', function()
    LastHeartbeatAt = GetGameTimer()
end)

local function IsNetworkHealthy()
    local timeoutMs = (Config.NetworkGuard and Config.NetworkGuard.HeartbeatTimeoutMs) or 12000
    return (GetGameTimer() - LastHeartbeatAt) <= timeoutMs
end

local function PushToLocalAdliBuffer(record)
    local maxEntries = (Config.NetworkGuard and Config.NetworkGuard.LocalBufferMaxEntries) or 32
    LocalAdliBuffer[#LocalAdliBuffer + 1] = record
    -- ★ RAM-bomb korumasi: tavan asilirsa EN ESKI kayit (FIFO basi)
    -- sessizce dusurulur -- tampon sinirsiz BUYUMEZ.
    while #LocalAdliBuffer > maxEntries do
        table.remove(LocalAdliBuffer, 1)
    end
end

local function FlushLocalAdliBuffer()
    if #LocalAdliBuffer == 0 then return end
    TriggerServerEvent('matrix:server:reportPlayerWoundedBatch', LocalAdliBuffer)
    LocalAdliBuffer = {}
end

--- ★ Guvenli sarmalayici: ag hatti SAGLIKLIYSA DOGRUDAN gonderir (mevcut
--- davranis DEGISMEZ); DEGILSE korlemesine firlatmak yerine yerel
--- tampona muhurler. Sagliga DONUS aninda tampon TOPLU olarak bosaltilir.
local function ReportWoundedSafe(attackerServerId, weaponHashStr)
    local healthy = IsNetworkHealthy()

    if healthy and not WasNetworkHealthy then
        FlushLocalAdliBuffer()
    end
    WasNetworkHealthy = healthy

    if healthy then
        TriggerServerEvent('matrix:server:reportPlayerWounded', attackerServerId, weaponHashStr)
    else
        local ped = PlayerPedId()
        local coords = ped and ped ~= 0 and GetEntityCoords(ped) or nil
        PushToLocalAdliBuffer({
            attacker_server_id = attackerServerId,
            weapon_hash         = weaponHashStr,
            coords_x            = coords and coords.x or 0.0,
            coords_y            = coords and coords.y or 0.0,
            coords_z            = coords and coords.z or 0.0,
            ts                  = os.time()
        })
    end
end

-- ★ Ag hatti saglikliyken de periyodik olarak kontrol eder -- sadece
-- yeni bir hasar event'i geldiginde degil, sagliga DONUS anini da
-- YAKALAR (ornegin oyuncu o sure icinde hic hasar almadiysa bile tampon
-- bir sonraki saglikli tick'te bosaltilir).
CreateThread(function()
    while true do
        Wait(2000)
        local healthy = IsNetworkHealthy()
        if healthy and not WasNetworkHealthy then
            FlushLocalAdliBuffer()
        end
        WasNetworkHealthy = healthy
    end
end)

-- =====================================================================
-- ★ YERALTI GENISLETMESI KATMAN 2: OYUNCU-HASAR TESPITI
-- Vanilla 'CEventNetworkEntityDamage' gameEventTriggered'i, yerel oyuncu
-- kurbanken YALNIZCA sunucuya bir bildirim gonderir -- server/wound_
-- system.lua bunu, o saldirganin EN SON ates ettigi silahin (ZATEN VAR
-- OLAN reportWeaponShotFired onbellegi) balistik imzasiyla eslestirir.
-- =====================================================================
AddEventHandler('gameEventTriggered', function(eventName, args)
    if eventName ~= 'CEventNetworkEntityDamage' then return end

    -- CEventNetworkEntityDamage args: [1]=victim [2]=attacker [3]=weaponDamage(bool)
    -- [4]=victimDied(bool) [5]=weaponType(bool) [6]=weaponHash [7]=baseDamage
    -- -- yalnizca YEREL oyuncu kurbanken ve gercek bir silah hasari varken islenir.
    local victim, attacker, weaponDamage, weaponHash = args[1], args[2], args[3], args[6]
    if victim ~= PlayerPedId() or not weaponDamage then return end

    local attackerServerId = nil
    if attacker and attacker ~= 0 and NetworkGetEntityIsNetworked(attacker) then
        if IsPedAPlayer(attacker) then
            attackerServerId = GetPlayerServerId(NetworkGetPlayerIndexFromPed(attacker))
        end
    end

    local weaponHashStr = weaponHash and tostring(weaponHash) or nil
    ReportWoundedSafe(attackerServerId, weaponHashStr)
end)


--- ★ [U3] F10 -> "/namludegistir": elde tutulan silahin slotunu ox_inventory
--- GetCurrentWeapon export'undan cozup sunucu komutuna [S1] disiplinindeki
--- gibi yalnizca temiz bir tam sayi olarak iletir.
local function OpenNamluDegistirAction()
    local ok, current = pcall(function() return exports['ox_inventory']:GetCurrentWeapon() end)
    if not ok or type(current) ~= 'table' or not current.slot then
        NotifyInvalidInput('Elinizde degistirilebilir bir silah yok.')
        return
    end
    ExecuteCommand(('namludegistir %d'):format(current.slot))
end


--- ★ KATMAN 6 [K1]: F10 -> Tezgahta Tamir. Aynı GetCurrentWeapon deseniyle
--- silah slotunu çözer, ancak /namludegistir'in AKSİNE nakit yerine
--- server/workbench.lua'nın bileşen kontrolünden geçer (para YOK).
local function OpenWorkbenchRepairAction()
    local ok, current = pcall(function() return exports['ox_inventory']:GetCurrentWeapon() end)
    if not ok or type(current) ~= 'table' or not current.slot then
        NotifyInvalidInput('Elinizde tamir edilebilir bir silah yok.')
        return
    end
    TriggerServerEvent('matrix:server:workbench:repairWeapon', current.slot)
end


--- ★ Herhangi bir telefon kaynağının çağrı başlangıcı/bitişinde
--- çağırması beklenen client-side köprü. Üretimde telefon kaynağının
--- kendi event'lerine (qb-phone/lb-phone/vb. — bu dosya hangisinin kurulu
--- olduğunu varsaymaz) bağlanıp bunu tetiklemesi gerekir.
exports('ReportPhoneCallState', function(active, isBurner)
    TriggerServerEvent('matrix:server:reportPhoneCallState', active, isBurner)
end)


-- =====================================================================
-- TAKTİK KOMUTA MENÜSÜ (ox_lib Context Menu, F10) — MÜHÜRLÜ + EVRİM
-- =====================================================================
local function OpenTrapHouseDurumDialog()
    local input = lib.inputDialog('/traphousedurum - Trap House Sorgusu', {
        { type = 'number', label = 'Trap House ID', required = true, min = 1, max = 2147483646 }
    })
    if not input then return end


    local houseId = SanitizeNumericArg(input[1], 1, 2147483646)
    if not houseId then NotifyInvalidInput('Trap House ID gecersiz.'); return end


    ExecuteCommand(('traphousedurum %s'):format(houseId))
end


--- ★ KATMAN 6: "Trap House'a Git" — client/trap_house_client.lua'nın kapı
--- blip'lerini beslemek için zaten kullandığı AYNI
--- 'matrix:callback:getTrapHouseLocations' callback'i (server/
--- trap_house_interior.lua) burada da okunur; yeni bir sunucu-tarafı
--- endpoint icat EDİLMEZ. server/rendezvous.lua'nın otomatik waypoint
--- deseniyle (bkz. dosya başı [K4] notu) AYNI native — SetNewWaypoint —
--- kullanılır; ekstra bir kaynak/bağımlılık GEREKMEZ.
local function OpenTrapHouseWaypointDialog()
    local list = lib.callback.await('matrix:callback:getTrapHouseLocations', false)
    if type(list) ~= 'table' or #list == 0 then
        if lib and lib.notify then
            lib.notify({ title = '[TRAP HOUSE]', description = 'Henuz kayitli bir trap house yok.', type = 'inform' })
        end
        return
    end


    local options = {}
    for i = 1, #list do
        local entry = list[i]
        if type(entry) == 'table' and type(entry.id) == 'number' and type(entry.coords) == 'vector3' then
            options[#options + 1] = { value = tostring(entry.id), label = ('#%d — %s'):format(entry.id, entry.label or 'Trap House') }
        end
    end
    if #options == 0 then return end


    local input = lib.inputDialog('Trap House\'a Git (Waypoint)', {
        { type = 'select', label = 'Trap House', required = true, options = options }
    })
    if not input then return end


    local chosenId = tonumber(input[1])
    local target
    for i = 1, #list do
        if list[i].id == chosenId then target = list[i]; break end
    end
    if not target then return end


    SetNewWaypoint(target.coords.x, target.coords.y)
    if lib and lib.notify then
        lib.notify({ title = '[TRAP HOUSE]', description = ('Waypoint ayarlandi: #%d %s'):format(target.id, target.label or ''), type = 'inform' })
    end
end


local function OpenRutbeAtaDialog()
    local input = lib.inputDialog('/rutbeata - Hiyerarsi Rutbe Atamasi', {
        { type = 'number', label = 'Hedef Server ID', required = true, min = 1, max = 65535 },
        { type = 'select', label = 'Rutbe', required = true, options = {
            { value = 'Leader',            label = 'Leader (Baron)' },
            { value = 'Logistics_Officer', label = 'Logistics_Officer (Lojistik Subayi)' },
            { value = 'Chemist',           label = 'Chemist (Kimyager)' }
        } }
    })
    if not input then return end


    local targetSrc = SanitizeNumericArg(input[1], 1, 65535)
    if not targetSrc then NotifyInvalidInput('Hedef Server ID gecersiz.'); return end


    local rank = SanitizeRankArg(input[2])
    if not rank then NotifyInvalidInput('Rutbe secimi gecersiz.'); return end


    ExecuteCommand(('rutbeata %s %s'):format(targetSrc, rank))
end


--- ★ [E2][E3] "Rota Çiz" — Multi-Waypoint Taktik Rota Motoru diyaloğu.
--- 0-3 ara uğrak (ARTIK ZORUNLU DEĞİL, boş bırakılabilir) + 1 ZORUNLU final
--- hedef toplanır; her alan ya "x,y,z" vektörü ya da bir Trap House ID'sidir.
--- Dolu alanlar [S1] ile aynı sıkılıkta sanitize edilir; boş bırakılan ara
--- uğraklar ROUTE_WAYPOINT_SKIP placeholder'ı ile gönderilip sunucu
--- tarafında (server/main.lua: /rotaciz) rota zincirinden drop edilir.
--- Format çözümlemesi (koordinat mı, trap house mu) ve fiziksel güvenlik
--- guard'ları (ışınlanma koruması, Co-Op Mutex) da sunucu tarafında yürütülür.
--- ★ [U1] Bota bindirip intikali BAŞLATMA işlemi EKSTRA bir /sevket
--- komutuna GEREK DUYMAZ — Matrix.BeginRouteDispatch (server/main.lua)
--- bu dialog onaylandığı AN asenkron olarak tetiklenir ve bot kendiliğinden
--- arabaya binip yola çıkar; varışta kargo otomatik Trap House deposuna
--- aktarılır (bkz. server/main.lua Matrix.DepositDealerCargoToTrapStash).
local function OpenRotaCizDialog()
    local input = lib.inputDialog('/rotaciz - Multi-Waypoint Taktik Rota (Otomatik Intikal)', {
        {
            type = 'number', label = 'Bot ID',
            description = 'Rota cizilecek dealer botunun ID numarasi',
            required = true, min = 1, max = MAX_BOT_ID
        },
        {
            type = 'input', label = '1. Ugrak Noktasi (opsiyonel)',
            description = '"x,y,z" veya "x y z" veya Trap House ID veya "DD-1/2/3" (Dead Drop) — BOS BIRAKILABILIR',
            required = false, max = MAX_WAYPOINT_LEN
        },
        {
            type = 'input', label = '2. Ugrak Noktasi (opsiyonel)',
            description = '"x,y,z" veya "x y z" veya Trap House ID veya "DD-1/2/3" (Dead Drop) — BOS BIRAKILABILIR',
            required = false, max = MAX_WAYPOINT_LEN
        },
        {
            type = 'input', label = '3. Ugrak Noktasi (opsiyonel)',
            description = '"x,y,z" veya "x y z" veya Trap House ID veya "DD-1/2/3" (Dead Drop) — BOS BIRAKILABILIR',
            required = false, max = MAX_WAYPOINT_LEN
        },
        {
            type = 'input', label = 'Final Hedef (Ana Us / Trap House) — ZORUNLU',
            description = '"x,y,z" veya "x y z" veya Trap House ID veya "DD-1/2/3" (Dead Drop) — varista kargo otomatik depoya aktarilir',
            required = true, max = MAX_WAYPOINT_LEN
        },
        {
            type = 'input', label = 'Plaka (bos = kalici arac/foot)',
            required = false, max = MAX_PLATE_LEN
        },
        {
            type = 'select', label = 'Arac Tipi', required = true,
            options = BuildVehicleTypeOptions()
        }
    })
    if not input then return end


    local botId = SanitizeNumericArg(input[1], 1, MAX_BOT_ID)
    if not botId then NotifyInvalidInput('Bot ID gecersiz.'); return end


    -- ★ [E3] Ara uğraklar (1-3): boş bırakma GEÇERLİDİR (atlanır); DOLU
    -- olup da karakter kümesini ihlal eden bir girdi yine REDDEDİLİR.
    local waypointArgs = {}
    for i = 2, 4 do
        local wp = SanitizeOptionalWaypointArg(input[i])
        if not wp then
            NotifyInvalidInput(('Uğrak #%d geçersiz (boş bırakabilirsiniz; doluysa yalnızca rakam, ".", ",", "-", boşluk).'):format(i - 1))
            return
        end
        waypointArgs[#waypointArgs + 1] = wp
    end


    -- Final hedef HALA ZORUNLU — boş bırakılamaz.
    local finalWp = SanitizeWaypointArg(input[5])
    if not finalWp then
        NotifyInvalidInput('Final Hedef geçersiz veya boş bırakılamaz (yalnızca rakam, ".", ",", "-", boşluk).')
        return
    end


    local plate = SanitizePlateArg(input[6])
    if plate == nil then
        NotifyInvalidInput('Plaka yalnizca harf/rakam/-/_/. icerebilir (max ' .. MAX_PLATE_LEN .. ').')
        return
    end


    local vehicleType = SanitizeVehicleTypeArg(input[7])
    if not vehicleType then NotifyInvalidInput('Arac tipi gecersiz.'); return end


    ExecuteCommand(('rotaciz %s %s %s %s %s %s %s'):format(
        botId, waypointArgs[1], waypointArgs[2], waypointArgs[3], finalWp, plate, vehicleType))
end


--- ★ KATMAN 6 [K2]: "Kapı Sürgü Tahkimatı". Trap House ID + hedef seviye
--- (1-3, sıralı yükseltme) [S1] ile AYNI SanitizeNumericArg disiplininden
--- geçer; server/door_reinforcement.lua fiyat/yetki/sıra kontrolünü ayrıca
--- kendi tarafında da yapar (client sanitizasyonu bir GÜVEN kaynağı DEĞİL,
--- yalnızca ExecuteCommand/enjeksiyon yüzeyini kapatan bir ön filtredir).
local function OpenDoorReinforcementDialog()
    local input = lib.inputDialog('Kapı Sürgü Tahkimatı', {
        {
            type = 'number', label = 'Trap House ID',
            required = true, min = 1, max = 2147483646
        },
        {
            type = 'select', label = 'Hedef Seviye (sıralı yükseltilmelidir)', required = true, options = {
                { value = '1', label = 'Seviye 1 — Takviyeli Ahşap Sürgü' },
                { value = '2', label = 'Seviye 2 — Çelik Sürgü Barikatı' },
                { value = '3', label = 'Seviye 3 — Çift Katlı Çelik Barikat (Maks)' }
            }
        }
    })
    if not input then return end


    local houseId = SanitizeNumericArg(input[1], 1, 2147483646)
    if not houseId then NotifyInvalidInput('Trap House ID gecersiz.'); return end


    local level = SanitizeNumericArg(input[2], 1, 3)
    if not level then NotifyInvalidInput('Seviye secimi gecersiz.'); return end


    TriggerServerEvent('matrix:server:doorReinforcement:install', tonumber(houseId), tonumber(level))
end


local function OpenMatrixDump()
    ExecuteCommand('matrixdump')
end


-- =====================================================================
-- ★ KATMAN 5 ULTIMATE [U2]: BOT AKSİYON MENÜSÜ (Tasfiye / Denetleyici Ata)
-- Canlı Kadro raporundaki bir BOT satırına tıklandığında açılır.
-- ★ KATMAN 6 [K1]: "Mühimmat / Envanter Ameliyatı" eklendi.
-- =====================================================================
local OpenAssignInspectorDialog -- ileri bildirim (OpenBotActionsMenu tarafından kullanilir)
local OpenBotInventoryOpsMenu   -- ★ KATMAN 6: ileri bildirim
local OpenGiveItemToBotDialog   -- ★ KATMAN 6: ileri bildirim
local OpenAmmoRunDialog         -- ★ KATMAN 7 [T2]: ileri bildirim

-- [FAZ 1] Darkchat parola sonucu
RegisterNetEvent('matrix:client:darkchat:passphraseResult', function(ok, reason, trapHouseId)
    if lib and lib.notify then
        lib.notify({
            title       = ok and '[SEC-7 ONAY]' or '[SEC-7 RED]',
            description = ok and 'Parola kabul edildi.' or ('Parola reddedildi: ' .. tostring(reason)),
            type        = ok and 'success' or 'error',
            duration    = 5000
        })
    end
end)

-- [FAZ 1] Need-to-Know maskeli telemetri cevabı
RegisterNetEvent('matrix:client:darkchat:telemetryResult', function(data, err)
    if lib and lib.notify then
        if not data then
            lib.notify({
                title       = '[DARKCHAT]',
                description = tostring(err or 'veri yok'),
                type        = 'error'
            })
            return
        end
        local body = data.coords_masked
            and ('[NEED-TO-KNOW] Ajan #%d maskeli | Bakiye: %s'):format(data.bot_id, tostring(data.balance))
            or  ('Ajan #%d konum: %.1f,%.1f,%.1f | Bakiye: %.2f'):format(
                data.bot_id, data.coords_x, data.coords_y, data.coords_z, data.balance)
        lib.notify({
            title       = '[DARKCHAT TELEMETRI]',
            description = body,
            type        = 'inform',
            duration    = 8000
        })
    end
end)

-- [FAZ 4] Panik butonu tetikleyici (herhangi bir client tetikleyicisi:
-- örn. telefon UI'nin bir butonu bu event'i çağırır):
-- TriggerServerEvent('matrix:server:phone:remoteWipe', nil) -- nil = kendi dna_id