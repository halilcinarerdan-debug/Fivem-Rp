-- =====================================================================
-- MATRIX TRAP HOUSE INTERIOR / server/trap_house_interior.lua (KATMAN 6 — YENİ)
--
-- Sanal Mahalle Evi (Interior Instance): trap house'lar haritada açıkta
-- durmaz. Oyuncu haritadaki gerçek trap house koordinatına (Matrix.
-- TrapHouses[id].coords — Katman 2'den beri var olan alan, DEĞİŞTİRİLMEDİ)
-- yaklaşıp kapıyı açtığında, SetPlayerRoutingBucket ile o trap house'a
-- BİRİCİK bir bucket'a (Config.TrapHouseInterior.BucketBase + trapHouseId)
-- geçirilir ve TEK BİR paylaşımlı vanilla döküntü iç mekan kabuğuna
-- (Config.TrapHouseInterior.Shell) ışınlanır. Routing bucket, aynı fiziksel
-- koordinatları paylaşan farklı trap house'ların birbirini GÖRMEMESİNİ/
-- ETKİLEMEMESİNİ garanti eder — FiveM'in yerleşik "interior olmadan
-- interior" tekniği.
--
-- ★ ÜYELİK KAPISI: girişe yalnızca Matrix.Hierarchy'de (server/market.lua,
-- DEĞİŞTİRİLMEDİ) bir rütbesi olan oyuncular izin verilir — "Kartel'in
-- parçası olmayan biri döküntü eve giremez" mantığı.
--
-- ★ BOT ROUTING (main.lua doğrulandıktan SONRAKİ düzeltme): main.lua'nın
-- gerçek kaynağı incelendi — botlar STABİL/BEKLEMEDE durumundayken (yani
-- bir dispatch'in DIŞINDA) DÜNYADA HİÇ SPAWN EDİLMİŞ bir ped'e sahip
-- DEĞİLDİR (bot.state.spawned=false, net_id=nil). Bir sevkiyat 'arrived'
-- ile kapandığında (Matrix.CompleteDispatch, main.lua) ped zaten AYNI
-- fonksiyon içinde SafeDeleteEntity ile dünyadan silinir — yani "varışta
-- bota ait canlı bir ped handle'ı yakalayıp bucket'a taşı" diye bir
-- entegrasyon noktası main.lua'nın gerçek mimarisinde YOKTUR (daha önceki
-- sürümdeki yorum bunu main.lua'yı görmeden yanlış varsaymıştı — düzeltildi).
-- Matrix.TrapHouseInterior.RouteBotIntoInterior(botId, trapHouseId, ped)
-- yine de DIŞA AÇIK bırakıldı: yalnızca ped/araç spawn eden bir dispatch
-- AKTİFKEN (Matrix.Dispatches[botId] doluyken, ped dispatch.entity_net_id
-- üzerinden çözülebilirken) anlamlıdır — sunucu operatörü ileride "bot
-- rotasının SON bacağı trap house kapısındaysa, ped silinmeden ÖNCE onu
-- bucket'a al" gibi bir davranış eklemek isterse main.lua'ya TEK SATIRLIK
-- bir çağrı (CompleteDispatch'in entity silme adımından ÖNCE) ile
-- bağlanabilir.
--
-- ★ KATMAN 7 [T1/T2]: yukarıdaki analiz tam olarak doğrulandı — "bot ped'i
-- OLMADAN mantıken içeride sayılma" ihtiyacı gerçekten doğdu (Mühimmat
-- Dağıtım Görevi: bir Lojistik bot dünyada hiç doğmadan trap house
-- deposundan mühimmat çeker). Bkz. MarkBotForStashRun (aşağıda) — bu, RAM'de
-- yalnızca bir bayrak (bot.state.interior_trap_house_id, server/main.lua'da
-- tanımlı) set eder; main.lua'nın Çıkış Köprüsü (ResolveExteriorBridgeOrigin)
-- bir sonraki fiziksel sevk başladığında bu bayrağı tüketip botu haritanın
-- gerçek yüzeyine (bu trap house'un fiziki kapı koordinatına) çıkarır ve
-- SetEntityRoutingBucket(entity, 0) ile dış dünyaya bağlar — RouteBotIntoInterior
-- (yukarıdaki, canlı bir ped GEREKTİREN) ile ÇAKIŞMAZ, tamamlayıcıdır.
-- =====================================================================


Matrix.TrapHouseInterior = Matrix.TrapHouseInterior or {}


local pairs, ipairs, type, tostring = pairs, ipairs, type, tostring
local tonumber                       = tonumber
local math_huge                      = math.huge
local GetPlayerPed                   = GetPlayerPed
local GetEntityCoords                = GetEntityCoords
local TriggerClientEvent             = TriggerClientEvent
local SetPlayerRoutingBucket         = SetPlayerRoutingBucket
local SetEntityRoutingBucket         = SetEntityRoutingBucket


--- ★ DÜZELTME: eskiden burası 'chat:addMessage' ile arcade tarzı sohbet
--- bildirimi gönderiyordu (chat penceresi kapalıyken SESSİZCE kayboluyordu).
--- Artık server/main.lua'nın client/hud.lua'da (lib.notify ile) işlenen
--- MEVCUT 'matrix:client:actionNotify' kancasını kullanır -- chat açık
--- olsun olmasın ekranda görülür, ve arcade UI'siz monokrom bildirim.
local function Reply(src, msg, ok)
    if type(src) == 'number' and src > 0 then
        TriggerClientEvent('matrix:client:actionNotify', src, ok or false, msg)
    else
        Matrix.Log('TRAPHOUSE', '[KONSOL] %s', tostring(msg))
    end
end


--- ★ TEŞHİS: giriş mesafesi eskiden TEK bir 3D uzaklıkla (X,Y,Z birlikte)
--- ölçülüyordu. Trap house koordinatı /coords ile yer seviyesinde
--- kaydedilmiş olsa bile oyuncu bir kaldırım/basamak/eşikte durduğunda Z
--- birkaç metre farklı olabilir — bu da "haritada tam üzerindeyim" derken
--- 3D mesafenin eşiği aşıp SESSİZCE reddedilmesine yol açar. Yatay (X,Y)
--- ve dikey (Z) mesafe artık AYRI ölçülür; dikeyde çok daha toleranslıdır.
local function HorizontalDistance(a, b)
    if not a or not b then return math_huge end
    local dx, dy = (a.x - b.x), (a.y - b.y)
    return math.sqrt((dx * dx) + (dy * dy))
end


-- src -> trapHouseId (oyuncu şu an hangi trap house instance'ının içinde)
local PlayerInteriorState = {}
-- trapHouseId -> { [src] = true }  (barikat/last-stand yayını için occupant listesi)
local Occupants = {}


function Matrix.TrapHouseInterior.GetBucket(trapHouseId)
    return (Config.TrapHouseInterior.BucketBase or 20000) + tonumber(trapHouseId)
end


--- door_reinforcement.lua'nın "Last Stand" yayınının hedef kitlesini
--- bulması için — yalnızca o trap house'un içindeki oyuncuları döner.
function Matrix.TrapHouseInterior.GetOccupants(trapHouseId)
    local list = {}
    for src in pairs(Occupants[trapHouseId] or {}) do
        list[#list + 1] = src
    end
    return list
end


--- server/workbench.lua'nın tezgah/paketleme odası konum kontrolü için:
--- oyuncu şu an hangi trap house instance'ının içinde (yoksa nil).
function Matrix.TrapHouseInterior.GetPlayerTrapHouse(src)
    return PlayerInteriorState[src]
end


--- ★ DÜZELTME: eskiden burası rastgele model/kıyafetli KOZMETİK "ambient"
--- NPC'ler (gerçek oyun durumuyla hiç bağlantısı olmayan yabancılar)
--- üretiyordu. Artık YALNIZCA bu trap house'a GERÇEKTEN atanmış
--- (bot.state.trap_house_id eşleşen, status='active') Matrix.Bots
--- kayıtları döner — atanmış bot yoksa liste boş döner ve içeride HİÇ
--- kimse görünmez ("sadece bizim ajanlarımız olsun" talebi).
local function GetResidentBots(trapHouseId)
    local list = {}
    for id, bot in pairs(Matrix.Bots or {}) do
        if bot.status == 'active' and bot.state and bot.state.trap_house_id == trapHouseId then
            list[#list + 1] = { id = id, name = bot.name, role = bot.role }
            if #list >= 20 then break end
        end
    end
    return list
end


local function HasMembership(citizenid)
    if not citizenid then return false end
    if Matrix.Hierarchy and Matrix.Hierarchy.GetRank then
        return Matrix.Hierarchy.GetRank(citizenid) ~= nil
    end
    -- Matrix.Hierarchy yüklü değilse (savunmacı geri düşüş) herkese izin
    -- ver — bu modülü main.lua/market.lua olmadan test edebilmek için.
    return true
end


-- =====================================================================
-- GİRİŞ
-- =====================================================================
RegisterNetEvent('matrix:server:trapHouseInterior:enter', function(trapHouseId)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    trapHouseId = tonumber(trapHouseId)
    local house = trapHouseId and Matrix.TrapHouses[trapHouseId]
    if not house then Reply(src, 'Trap house bulunamadı.'); return end


    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return end
    local coords = GetEntityCoords(ped)


    local horizDist   = HorizontalDistance(coords, house.coords)
    local vertDist    = math.abs(coords.z - house.coords.z)
    local horizRadius = (Config.TrapHouseInterior.EntryRadius or 1.5) + 3.0
    local vertRadius  = Config.TrapHouseInterior.EntryZTolerance or 8.0


    if horizDist > horizRadius or vertDist > vertRadius then
        Reply(src, 'Kapıya yeterince yakın değilsiniz.')
        Matrix.Log('TRAPHOUSE',
            '[GIRIS RED] src=%d trap=%d -> mesafe yetersiz (yatay:%.1fm/limit:%.1fm, dikey:%.1fm/limit:%.1fm)',
            src, trapHouseId, horizDist, horizRadius, vertDist, vertRadius)
        return
    end


    local state = Matrix.GetOrCreatePlayerState(src)
    local citizenid = state and state.citizenid


    -- ★ TEŞHİS: iki farklı red nedenini (profil çözülemedi / gerçekten
    -- rütbesiz) birbirinden ayırıp konsola basar — ikisi de oyuncuya AYNI
    -- "kilitli" mesajını gösterse de (bilgi sızdırmamak için), server
    -- konsolunda TAM sebep görülür.
    if not citizenid then
        Reply(src, 'Bu kapı size kilitli — örgüt hiyerarşisinde kayıtlı değilsiniz.')
        Matrix.Log('TRAPHOUSE', '[GIRIS RED] src=%d -> citizenid cozulemedi (QBX player state yok).', src)
        return
    end


    if not HasMembership(citizenid) then
        local rank = Matrix.Hierarchy and Matrix.Hierarchy.GetRank and Matrix.Hierarchy.GetRank(citizenid)
        Reply(src, 'Bu kapı size kilitli — örgüt hiyerarşisinde kayıtlı değilsiniz.')
        Matrix.Log('TRAPHOUSE', '[GIRIS RED] src=%d citizenid=%s -> Matrix.Hierarchy.GetRank sonucu: %s',
            src, citizenid, tostring(rank))
        return
    end


    local bucket = Matrix.TrapHouseInterior.GetBucket(trapHouseId)
    SetPlayerRoutingBucket(src, bucket)
    PlayerInteriorState[src] = trapHouseId
    Occupants[trapHouseId] = Occupants[trapHouseId] or {}
    Occupants[trapHouseId][src] = true


    local shell = Config.TrapHouseInterior.Shell
    TriggerClientEvent('matrix:client:trapHouseInterior:teleportIn', src, {
        trap_house_id = trapHouseId,
        bucket        = bucket,
        enter_coords  = shell.EnterCoords,
        workbench_pos = shell.WorkbenchPos,
        packaging_pos = shell.PackagingPos,
        exit_coords   = shell.ExitCoords,
        resident_bots = GetResidentBots(trapHouseId),
        ambient_scenarios = Config.TrapHouseInterior.AmbientScenarios
    })


    Matrix.Log('TRAPHOUSE', 'src=%d trap house #%d içine girdi (bucket:%d).', src, trapHouseId, bucket)
end)


-- =====================================================================
-- ÇIKIŞ
-- =====================================================================
RegisterNetEvent('matrix:server:trapHouseInterior:exit', function()
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end


    local trapHouseId = PlayerInteriorState[src]
    if not trapHouseId then return end


    local house = Matrix.TrapHouses[trapHouseId]
    SetPlayerRoutingBucket(src, 0)
    PlayerInteriorState[src] = nil
    if Occupants[trapHouseId] then Occupants[trapHouseId][src] = nil end


    TriggerClientEvent('matrix:client:trapHouseInterior:teleportOut', src, {
        exit_world_coords = house and house.coords or nil
    })


    Matrix.Log('TRAPHOUSE', 'src=%d trap house #%d dışına çıktı.', src, trapHouseId)
end)


AddEventHandler('playerDropped', function()
    local src = source
    local trapHouseId = PlayerInteriorState[src]
    if trapHouseId and Occupants[trapHouseId] then Occupants[trapHouseId][src] = nil end
    PlayerInteriorState[src] = nil
end)


--- ★ Bkz. dosya başı "BOT ROUTING" notu — main.lua'nın varış tespiti
--- bota ait ped entity handle'ını bulduğunda bunu çağırmalıdır.
function Matrix.TrapHouseInterior.RouteBotIntoInterior(botId, trapHouseId, botPedEntity)
    if not botPedEntity or botPedEntity == 0 then return false end
    local bucket = Matrix.TrapHouseInterior.GetBucket(trapHouseId)
    local ok = pcall(SetEntityRoutingBucket, botPedEntity, bucket)
    if ok then
        Matrix.Log('TRAPHOUSE', 'Bot #%d trap house #%d ic mekanina yonlendirildi (bucket:%d).', botId, trapHouseId, bucket)
    end
    return ok
end


-- botId -> trapHouseId, yalnızca /interiordurum debug paneli için (bkz.
-- aşağıda) — gerçek yönlendirme kararı DAİMA bot.state.interior_trap_house_id
-- (server/main.lua) üzerinden verilir, bu tablo salt bir yansımadır.
local BotsMarkedForStashRun = {}


--- ★ KATMAN 7 [T1/T2]: bir Lojistik botu, dünyada bir ped'i HİÇ doğmadan
--- (stash/depo işlemi anında bir canlı ped'e ihtiyaç yok — bkz. dosya başı
--- yorumu) mantıken bu trap house'un interior hücresinin içinde işaretler.
--- Gerçek bayrağı server/main.lua'daki Matrix.SetBotInteriorTrapHouse set
--- eder (main.lua bu dosyadan ÖNCE yüklenir, bkz. fxmanifest.lua) — burası
--- yalnızca o çağrıyı bu modülün kendi isimlendirme/log/debug disipliniyle
--- sarmalar. server/logistics.lua Matrix.Logistics.DispatchAmmoRun bunu
--- (yüklüyse) tercih eder; yüklü değilse doğrudan Matrix.SetBotInteriorTrapHouse'a
--- düşer (defansif, opsiyonel-modül deseni — bu dosyanın geri kalanıyla AYNI).
function Matrix.TrapHouseInterior.MarkBotForStashRun(botId, trapHouseId)
    botId = tonumber(botId)
    trapHouseId = tonumber(trapHouseId)
    if not botId or not trapHouseId or not Matrix.TrapHouses[trapHouseId] then return false end
    if not Matrix.SetBotInteriorTrapHouse then return false end

    local ok = Matrix.SetBotInteriorTrapHouse(botId, trapHouseId)
    if ok then
        BotsMarkedForStashRun[botId] = trapHouseId
        Matrix.Log('TRAPHOUSE',
            'Bot #%d trap house #%d deposu icin ic mekana isaretlendi (ped YOK -- bkz. Cikis Koprusu, server/main.lua).',
            botId, trapHouseId)
    end
    return ok
end


--- Çıkış Köprüsü tüketildiğinde (bot fiilen sahaya çıktığında) bu yansıma
--- tablosundan da temizlenir — yalnızca /interiordurum debug paneli doğru
--- kalsın diye (gerçek durum HER ZAMAN bot.state.interior_trap_house_id'dir).
function Matrix.TrapHouseInterior.ClearStashRunMark(botId)
    BotsMarkedForStashRun[tonumber(botId) or botId] = nil
end


-- =====================================================================
-- ★ KATMAN 6: "MÜHİMMAT / ENVANTER AMELİYATI" — F10 Canlı Kadro bot
-- aksiyon menüsüne eklenir (bkz. client/hud.lua OpenBotActionsMenu).
-- =====================================================================
local function GetBotInventoryId(botId)
    return ('dealer_%d'):format(botId)
end


--- ★ client/trap_house_client.lua'nın kapı blip'lerini/E-tetiklerini
--- çizebilmesi için trap house dünya konumlarını (id+coords+label) döner.
--- Adli/ekonomik hiçbir hassas veri taşımaz — yalnızca zaten haritada
--- bilinmesi gereken kapı konumlarıdır.
lib.callback.register('matrix:callback:getTrapHouseLocations', function(src)
    local list = {}
    for id, house in pairs(Matrix.TrapHouses or {}) do
        list[#list + 1] = { id = id, coords = house.coords, label = house.label }
    end
    return list
end)


lib.callback.register('matrix:callback:getBotInventoryItems', function(src, botId)
    botId = tonumber(botId)
    if not botId or not Matrix.Bots[botId] then return {} end


    local ok, inv = pcall(function()
        return exports['ox_inventory']:GetInventory(GetBotInventoryId(botId))
    end)
    if not ok or type(inv) ~= 'table' or type(inv.items) ~= 'table' then return {} end


    local list = {}
    for _, item in pairs(inv.items) do
        if type(item) == 'table' and item.name then
            list[#list + 1] = {
                slot  = item.slot,
                name  = item.name,
                label = item.label or item.name,
                count = item.count or 1
            }
        end
    end
    table.sort(list, function(a, b) return (a.slot or 0) < (b.slot or 0) end)
    return list
end)


--- Oyuncunun kendi envanterindeki [playerSlot] öğesini bota elden teslim eder.
RegisterNetEvent('matrix:server:trapHouseInterior:giveItemToBot', function(botId, playerSlot, count)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    botId = tonumber(botId)
    playerSlot = tonumber(playerSlot)
    count = tonumber(count) or 1
    if not botId or not Matrix.Bots[botId] or not playerSlot or count < 1 then
        Reply(src, 'Gecersiz teslimat parametreleri.')
        return
    end

    -- ★ [DUZELTME] server/main.lua'nin Matrix.EnsureBotInventoryRegistered'i
    -- normalde bot olusturulurken/yuklenirken zaten cagirir -- burada
    -- TEKRAR cagirmak zararsizdir (idempotent, trap house stash'in HER
    -- teslimat oncesi yeniden kaydedilmesiyle AYNI savunma deseni) ve
    -- bu fix'ten ONCE olusturulmus botlar icin de kalici bir kurtarma saglar.
    if Matrix.EnsureBotInventoryRegistered then
        Matrix.EnsureBotInventoryRegistered(botId, Matrix.Bots[botId].name)
    end

    local okSlot, slotData = pcall(function()
        return exports['ox_inventory']:GetSlot(src, playerSlot)
    end)
    if not okSlot or type(slotData) ~= 'table' or not slotData.name then
        Reply(src, 'Belirtilen slotta bir esya yok.')
        return
    end


    local transferCount = math.min(count, tonumber(slotData.count) or 1)


    -- ★ [DUZELTME] pcall(fn) ilk deger olarak "hata firlatilmadi mi"
    -- dondurur, ox_inventory'nin KENDI true/false sonucunu DEGIL. Onceki
    -- kod yalnizca pcall'in basarisini kontrol ediyordu -- RemoveItem/
    -- AddItem sessizce `false` donduğunde (hata FIRLATMADAN reddettiğinde,
    -- ör. envanter agirlik limiti/slot uyumsuzlugu) bu HIC fark edilmiyor,
    -- "basarili" sanilip devam ediliyordu. Sonuc: esya oyuncudan cekilip
    -- bota HICBIR ZAMAN eklenmiyordu -- sessiz kayip (oyuncunun bildirdigi
    -- "envanter bos gozukuyor ama esya envanterimden gidiyor" TAM OLARAK
    -- budur). Artik HER IKI deger de (pcall basarisi + ox_inventory'nin
    -- kendi donus degeri) ayri ayri kontrol edilir.
    local removeOk, removed = pcall(function()
        return exports['ox_inventory']:RemoveItem(src, slotData.name, transferCount, slotData.metadata, playerSlot)
    end)
    if not (removeOk and removed == true) then
        Reply(src, 'Esya envanterinizden cikarilamadi.')
        return
    end


    local addOk, added = pcall(function()
        return exports['ox_inventory']:AddItem(GetBotInventoryId(botId), slotData.name, transferCount, slotData.metadata)
    end)
    if not (addOk and added == true) then
        -- Bota teslim edilemedi (bot envanteri dolu/kayitli degil olabilir)
        -- -- esyayi oyuncuya iade et. Iade de basarisiz olursa (cift
        -- basarisizlik) esya kalici olarak kaybolabilir -- bu KRITIK
        -- durum ayrica loglanir (D1-v2 IO muhuru ile AYNI disiplin).
        local restoreOk, restored = pcall(function()
            return exports['ox_inventory']:AddItem(src, slotData.name, transferCount, slotData.metadata)
        end)
        if not (restoreOk and restored == true) then
            Matrix.Log('TRAPHOUSE',
                '[KRITIK] giveItemToBot: src=%d esya (%s x%d) AddItem+telafi ikisi de basarisiz -- olasi kayip.',
                src, tostring(slotData.name), transferCount)
        end
        Reply(src, 'Bot envanteri dolu, teslimat iptal edildi ve esya size iade edildi.')
        return
    end


    Reply(src, ('%s (x%d) Bot #%d envanterine teslim edildi.'):format(slotData.label or slotData.name, transferCount, botId), true)
    Matrix.Log('TRAPHOUSE', 'src=%d -> Bot #%d envanter teslimi: %s x%d', src, botId, slotData.name, transferCount)
end)


--- Lojistik/Inspector botu, depo botunun (fromBotId) envanterindeki bir
--- kalemi sokaktaki kurye botuna (toBotId) asenkron olarak taşır.
RegisterNetEvent('matrix:server:trapHouseInterior:transferBotToBot', function(fromBotId, toBotId, itemName, count)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    fromBotId = tonumber(fromBotId)
    toBotId   = tonumber(toBotId)
    count     = tonumber(count) or 1
    if not fromBotId or not Matrix.Bots[fromBotId] or not toBotId or not Matrix.Bots[toBotId]
        or type(itemName) ~= 'string' or count < 1 then
        Reply(src, 'Gecersiz aktarim parametreleri.')
        return
    end

    if Matrix.EnsureBotInventoryRegistered then
        Matrix.EnsureBotInventoryRegistered(fromBotId, Matrix.Bots[fromBotId].name)
        Matrix.EnsureBotInventoryRegistered(toBotId, Matrix.Bots[toBotId].name)
    end


    -- ★ [DUZELTME] giveItemToBot ILE AYNI hata: pcall'in kendi basari
    -- bayragi, ox_inventory'nin sessizce dondurdugu false'u MASKELIYORDU.
    local removeOk, removed = pcall(function()
        return exports['ox_inventory']:RemoveItem(GetBotInventoryId(fromBotId), itemName, count)
    end)
    if not (removeOk and removed == true) then
        Reply(src, ('Bot #%d envanterinde yeterli %s yok.'):format(fromBotId, itemName))
        return
    end


    local addOk, added = pcall(function()
        return exports['ox_inventory']:AddItem(GetBotInventoryId(toBotId), itemName, count)
    end)
    if not (addOk and added == true) then
        local restoreOk, restored = pcall(function()
            return exports['ox_inventory']:AddItem(GetBotInventoryId(fromBotId), itemName, count)
        end)
        if not (restoreOk and restored == true) then
            Matrix.Log('TRAPHOUSE',
                '[KRITIK] transferBotToBot: Bot #%d -> Bot #%d esya (%s x%d) AddItem+telafi ikisi de basarisiz -- olasi kayip.',
                fromBotId, toBotId, tostring(itemName), count)
        end
        Reply(src, ('Bot #%d envanteri dolu, aktarim iptal edildi.'):format(toBotId))
        return
    end


    Reply(src, ('Bot #%d -> Bot #%d: %s x%d aktarildi.'):format(fromBotId, toBotId, itemName, count), true)
    Matrix.Log('TRAPHOUSE', 'Bot #%d -> Bot #%d envanter aktarimi (src=%d): %s x%d', fromBotId, toBotId, src, itemName, count)
end)


-- =====================================================================
-- TAKTİK DEBUG PANELİ
-- =====================================================================
Matrix.Security.RegisterGatedCommand('interiordurum', function(src)
    local count = 0
    for trapHouseId, set in pairs(Occupants) do
        local n = 0
        for _ in pairs(set) do n = n + 1 end
        if n > 0 then
            count = count + n
            Reply(src, ('Trap #%d icinde %d kisi (bucket:%d)'):format(
                trapHouseId, n, Matrix.TrapHouseInterior.GetBucket(trapHouseId)), true)
        end
    end
    Reply(src, ('--- Toplam %d oyuncu bir trap house icinde ---'):format(count), true)


    -- ★ KATMAN 7: ped'i olmadan mantiken icerideki (stash isi yapan) botlar.
    local stashCount = 0
    for botId, trapHouseId in pairs(BotsMarkedForStashRun) do
        stashCount = stashCount + 1
        Reply(src, ('Bot #%d trap house #%d deposunda (Cikis Koprusu bekliyor, ped yok)'):format(botId, trapHouseId), true)
    end
    Reply(src, ('--- Toplam %d bot depo isleminde ---'):format(stashCount), true)
end)


exports('GetTrapHouseBucket', function(trapHouseId) return Matrix.TrapHouseInterior.GetBucket(trapHouseId) end)
exports('GetTrapHouseOccupants', function(trapHouseId) return Matrix.TrapHouseInterior.GetOccupants(trapHouseId) end)
exports('GetPlayerTrapHouse', function(src) return Matrix.TrapHouseInterior.GetPlayerTrapHouse(src) end)
exports('RouteBotIntoInterior', function(botId, trapHouseId, botPedEntity)
    return Matrix.TrapHouseInterior.RouteBotIntoInterior(botId, trapHouseId, botPedEntity)
end)
exports('MarkBotForStashRun', function(botId, trapHouseId)
    return Matrix.TrapHouseInterior.MarkBotForStashRun(botId, trapHouseId)
end)
exports('ClearStashRunMark', function(botId)
    return Matrix.TrapHouseInterior.ClearStashRunMark(botId)
end)