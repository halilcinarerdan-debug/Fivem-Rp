-- =====================================================================
-- MATRIX DÜŞMAN ÇETE MAHALLELERİ / server/gang_hoods.lua (KATMAN 7)
-- Sıfır-Toplam Yağma Motoru + Balistik Suç Yükleme (Frame-Up)
--
-- ZERO-SUM PRENSİBİ: bir mahalle stash'i HİÇBİR ZAMAN yoktan var edilmez.
-- Açıldığı AN, en yakın (oyuncunun KENDİ hiyerarşisine ait OLMAYAN)
-- matrix_trap_stash_<id>'in GERÇEK içeriğinden (ZATEN VAR OLAN, otonom
-- lojistik botlarının fiilen stoklamış olduğu envanter) bir pay
-- MEVCUT ox_inventory'nin AddItem/RemoveItem çiftiyle TAŞINIR (kopyalanmaz)
-- -- kaynak trap house'un stash'i gerçekten azalır.
-- =====================================================================


Matrix.GangHoods = Matrix.GangHoods or {}


local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local math_min, math_max, math_floor          = math.min, math.max, math.floor
local math_huge                               = math.huge


local function Reply(src, msg)
    if type(src) == 'number' and src > 0 then
        TriggerClientEvent('chat:addMessage', src, { args = { '[DUSMAN MAHALLE]', msg } })
    else
        print(('[MATRIX:GANGHOODS:CONSOLE] %s'):format(msg))
    end
end


local function VectorDistance(a, b)
    if not a or not b then return math_huge end
    local dx, dy, dz = a.x - b.x, a.y - b.y, (a.z or 0.0) - (b.z or 0.0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end


local function FindNearestTrapHouse(coords)
    local nearestId, nearestDist = nil, math_huge
    for id, house in pairs(Matrix.TrapHouses or {}) do
        local d = VectorDistance(coords, house.coords)
        if d < nearestDist then nearestId, nearestDist = id, d end
    end
    return nearestId, nearestDist
end


Matrix.GangHoods.Hoods = {} -- [id] = { coords, control_ratio, stash_id, nearest_trap_house_id, loot_opened_at, loot_compound_ticks }


CreateThread(function()
    local count = MySQL.scalar.await('SELECT COUNT(*) FROM matrix_gang_hoods') or 0
    if tonumber(count) == 0 then
        for i, hood in ipairs(Config.GangHoods.Hoods) do
            local stashId = ('matrix_gang_hood_stash_%d'):format(i)
            MySQL.insert([[
                INSERT INTO matrix_gang_hoods (hood_label, control_ratio, stash_id, coord_x, coord_y, coord_z)
                VALUES (?, 1.0, ?, ?, ?, ?)
            ]], { hood.label, stashId, hood.coords.x, hood.coords.y, hood.coords.z })
        end
        Matrix.Log('GANGHOODS', '%d dusman cete mahallesi ilk kez kaydedildi.', #Config.GangHoods.Hoods)
    end

    local rows = MySQL.query.await('SELECT * FROM matrix_gang_hoods') or {}
    for _, row in ipairs(rows) do
        local coords = vector3(row.coord_x or 0.0, row.coord_y or 0.0, row.coord_z or 0.0)
        Matrix.GangHoods.Hoods[row.id] = {
            hood_label             = row.hood_label,
            control_ratio           = tonumber(row.control_ratio) or 1.0,
            stash_id                = row.stash_id,
            coords                   = coords,
            nearest_trap_house_id    = row.nearest_trap_house_id,
            loot_opened_at           = nil,
            loot_compound_ticks      = 0
        }
        pcall(function()
            exports['ox_inventory']:RegisterStash(row.stash_id, row.hood_label or ('Dusman Mahalle #' .. row.id), 40, 100000)
        end)
    end
    Matrix.Log('GANGHOODS', 'Dusman mahalleleri yuklendi (%d mahalle).', #rows)
end)


-- =====================================================================
-- SIFIR-TOPLAM SENKRONİZASYON — açılış anında en yakın (oyuncunun kendi
-- ele geçirdiği hiyerarşiye AİT OLMAYAN) trap house stash'inden
-- control_ratio ile ölçeklenmiş bir pay taşınır.
-- =====================================================================
local TagLootedWeaponMetadata -- ileri bildirim (asagida tanimlanir, SyncHoodStashFromNearestTrapHouse tarafindan kullanilir)


local function SyncHoodStashFromNearestTrapHouse(hoodId, hood)
    local trapId = FindNearestTrapHouse(hood.coords)
    if not trapId then return end
    hood.nearest_trap_house_id = trapId

    local sourceStash = ('matrix_trap_stash_%d'):format(trapId)
    local invOk, inv = pcall(exports['ox_inventory'].GetInventory, exports['ox_inventory'], sourceStash)
    if not invOk or not inv or not inv.items then return end

    for _, item in pairs(inv.items) do
        if item and item.name and (item.count or 0) > 0 then
            local moveCount = math_max(1, math_floor((item.count or 0) * Matrix.Clamp(hood.control_ratio or 1.0, 0.0, 1.0)))
            local removeOk = pcall(function() return exports['ox_inventory']:RemoveItem(sourceStash, item.name, moveCount, item.metadata) end)
            if removeOk then
                local taggedMeta = TagLootedWeaponMetadata and TagLootedWeaponMetadata(hood.stash_id, item.name, moveCount, item.metadata) or item.metadata
                pcall(function() exports['ox_inventory']:AddItem(hood.stash_id, item.name, moveCount, taggedMeta) end)
            end
        end
    end

    MySQL.prepare('UPDATE matrix_gang_hoods SET nearest_trap_house_id = ? WHERE id = ?', { trapId, hoodId })
end


-- =====================================================================
-- LOOT PENCERESİ — açıldığında 120 saniyelik kesin bir pencere başlar;
-- her 10 saniyede ALPR devriye yoğunluğu (matrix_alpr_hits'in
-- OKUDUĞU/kaynaklandığı MEVCUT kavram) o bölgede +%25 bileşik büyür.
-- Yeni bir ALPR motoru İCAT EDİLMEZ -- yalnızca bu tek bölgeye özgü bir
-- çarpan (RAM, restart'ta sıfırlanır) tutulur.
-- =====================================================================
local PatrolMultiplier = {} -- [hoodId] = mevcut carpan


RegisterNetEvent('matrix:server:gangHood:openStash', function(hoodId)
    local src = source
    hoodId = tonumber(hoodId)
    local hood = hoodId and Matrix.GangHoods.Hoods[hoodId]
    if not hood then return end

    local ped = GetPlayerPed(src)
    local coords = ped and ped ~= 0 and GetEntityCoords(ped) or nil
    if not coords or VectorDistance(coords, hood.coords) > 10.0 then
        TriggerClientEvent('matrix:client:actionNotify', src, false, 'Mahalle stash konumunda degilsiniz.')
        return
    end

    if not hood.loot_opened_at then
        SyncHoodStashFromNearestTrapHouse(hoodId, hood)
        hood.loot_opened_at      = Matrix.Now()
        hood.loot_compound_ticks = 0
        PatrolMultiplier[hoodId] = 1.0
        MySQL.prepare('UPDATE matrix_gang_hoods SET loot_opened_at = NOW(), loot_compound_ticks = 0 WHERE id = ?', { hoodId })
        Matrix.Log('GANGHOODS', '[YAGMA PENCERESI ACILDI] Mahalle #%d, src=%d -- %ds pencere basladi.',
            hoodId, src, Config.GangHoods.LootWindowSeconds or 120)
    end

    TriggerClientEvent('matrix:client:actionNotify', src, true, 'Stash acildi -- 120 saniyelik yagma penceresi baslatildi.')
end)


local function ProcessLootWindows()
    local now = Matrix.Now()
    for hoodId, hood in pairs(Matrix.GangHoods.Hoods) do
        if hood.loot_opened_at then
            local elapsed = now - hood.loot_opened_at
            local expectedTicks = math_floor(elapsed / (Config.GangHoods.PatrolCompoundTickSeconds or 10))
            if expectedTicks > hood.loot_compound_ticks then
                for _ = hood.loot_compound_ticks + 1, expectedTicks do
                    PatrolMultiplier[hoodId] = (PatrolMultiplier[hoodId] or 1.0) * (Config.GangHoods.PatrolCompoundFactor or 1.25)
                end
                hood.loot_compound_ticks = expectedTicks
                Matrix.Log('GANGHOODS', '[ALPR DEVRIYE YOGUNLASTI] Mahalle #%d carpan=%.3f (%ds gecti).',
                    hoodId, PatrolMultiplier[hoodId], elapsed)
            end

            if elapsed >= (Config.GangHoods.LootWindowSeconds or 120) then
                hood.loot_opened_at      = nil
                hood.loot_compound_ticks = 0
                PatrolMultiplier[hoodId] = nil
                MySQL.prepare('UPDATE matrix_gang_hoods SET loot_opened_at = NULL, loot_compound_ticks = 0 WHERE id = ?', { hoodId })
                Matrix.Log('GANGHOODS', '[YAGMA PENCERESI KAPANDI] Mahalle #%d sure doldu.', hoodId)
            end
        end
    end
end


CreateThread(function()
    while true do
        Wait(2000)
        local ok, err = pcall(ProcessLootWindows)
        if not ok then Matrix.Log('GANGHOODS', '[HATA] ProcessLootWindows basarisiz (yutuldu): %s', tostring(err)) end
    end
end)


function Matrix.GangHoods.GetPatrolMultiplier(hoodId)
    return PatrolMultiplier[hoodId] or 1.0
end


-- =====================================================================
-- /depoyuyak — kalan yağmayı kalıcı olarak yok et ve sahneden TÜM adli
-- kanıtı (matrix_forensic_evidence) sil -- front company'i audit-wipe
-- riskinden korur (ZATEN VAR OLAN /namludegistir'in "kanıt asla silinmez"
-- politikasının KASITLI, İKİNCİ istisnası, o dosyanın yorumuyla AYNI
-- disiplinde).
-- =====================================================================
RegisterCommand(Config.GangHoods.DestroyLootCommand, function(src, args)
    local hoodId = tonumber(args[1])
    local hood = hoodId and Matrix.GangHoods.Hoods[hoodId]
    if not hood then
        Reply(src, ('Kullanim: /%s [mahalleId]'):format(Config.GangHoods.DestroyLootCommand))
        return
    end

    local ped = GetPlayerPed(src)
    local coords = ped and ped ~= 0 and GetEntityCoords(ped) or nil
    if not coords or VectorDistance(coords, hood.coords) > 10.0 then
        Reply(src, 'Mahalle stash konumunda degilsiniz.')
        return
    end

    local invOk, inv = pcall(exports['ox_inventory'].GetInventory, exports['ox_inventory'], hood.stash_id)
    if invOk and inv and inv.items then
        for _, item in pairs(inv.items) do
            if item and item.name and (item.count or 0) > 0 then
                pcall(function() exports['ox_inventory']:RemoveItem(hood.stash_id, item.name, item.count, item.metadata) end)
            end
        end
    end

    hood.loot_opened_at      = nil
    hood.loot_compound_ticks = 0
    PatrolMultiplier[hoodId] = nil
    MySQL.prepare('UPDATE matrix_gang_hoods SET loot_opened_at = NULL, loot_compound_ticks = 0 WHERE id = ?', { hoodId })

    -- Sahne temizligi: bu mahalleye en yakin trap house cevresindeki (100m)
    -- son adli kanit satirlarini sil.
    if hood.nearest_trap_house_id then
        local house = Matrix.TrapHouses[hood.nearest_trap_house_id]
        if house then
            MySQL.query.await([[
                DELETE FROM matrix_forensic_evidence
                WHERE SQRT(POW(coords_x - ?, 2) + POW(coords_y - ?, 2) + POW(coords_z - ?, 2)) <= 100.0
            ]], { house.coords.x, house.coords.y, house.coords.z })
        end
    end

    Reply(src, '[DEPO YAKILDI] Kalan yagma yok edildi ve sahnedeki adli kanit temizlendi.')
end, false)


-- =====================================================================
-- BALİSTİK SUÇ YÜKLEME (FRAME-UP) — düşman çetenin 'unknown suspect' ile
-- arşivlenmiş silahları yağmalanırken bu meta-etiketi ALIR (AddItem
-- sırasında SetMetadata ile). /kanityukle [suspectSrc] [slot] MEVCUT
-- Frisk (Config.Forensics.Frisk) yakınlık disipliniyle AYNI mantıkla,
-- bir memurun sahada tuttugu üst-arama sonucunu işler: silah hâlâ etiketi
-- taşıyorsa (yani /namludegistir ile KOŞULMADAN yakalandıysa) taşıyıcının
-- AÇIK davasına (MEVCUT /davaac -> matrix_trial_records) o silahın
-- işlenmemiş cinayetleri hard-evidence olarak eklenir -> %100 Mahkumiyet
-- Skoru -> Matrix.Bureau.ExecuteVerdict (Karakter Wipe).
-- =====================================================================
TagLootedWeaponMetadata = function(stashId, itemName, count, meta)
    if type(meta) ~= 'table' then return meta end
    if not meta.weapon_serial then return meta end

    local hasEvidence = MySQL.scalar.await(
        'SELECT COUNT(*) FROM matrix_forensic_evidence WHERE ballistic_id IN (SELECT ballistic_id FROM matrix_ballistic_weapons WHERE weapon_serial = ?)',
        { meta.weapon_serial }) or 0

    if tonumber(hasEvidence) and tonumber(hasEvidence) > 0 then
        meta.origin_tag = Config.GangHoods.FrameUpMetadataTag
    end
    return meta
end


RegisterCommand('kanityukle', function(src, args)
    local suspectSrc = tonumber(args[1])
    local slot        = tonumber(args[2])
    if not suspectSrc or not slot then
        Reply(src, 'Kullanim: /kanityukle [supheliSrc] [silahSlotu]')
        return
    end

    local ped = GetPlayerPed(src)
    local suspectPed = GetPlayerPed(suspectSrc)
    if ped and ped ~= 0 and suspectPed and suspectPed ~= 0 then
        local d = VectorDistance(GetEntityCoords(ped), GetEntityCoords(suspectPed))
        if d > (Config.Forensics.Frisk.Radius or 8.0) then
            Reply(src, 'Supheli Ust Arama menzilinin disinda.')
            return
        end
    end

    local meta = Matrix.Inventory.GetSlotMetadata(tostring(suspectSrc), slot)
    if type(meta) ~= 'table' or meta.origin_tag ~= Config.GangHoods.FrameUpMetadataTag then
        Reply(src, 'Bu silahta bir suc yukleme (frame-up) etiketi bulunamadi.')
        return
    end

    local suspectState = Matrix.GetOrCreatePlayerState(suspectSrc)
    if not suspectState or not suspectState.citizenid then return end

    -- Aktif bir dava yoksa MEVCUT OpenTrial ile bu bulguya dayali sifirdan
    -- bir dava acilir; ardindan dogrudan %100'e cekilir (islenmemis
    -- cinayetlerin hard-evidence olarak yuklenmesi).
    Matrix.Bureau.OpenTrial(src, suspectSrc, suspectState.dna_id)
    Matrix.Bureau.RecordTrialResponse(src, suspectSrc, 'yalan')
    MySQL.prepare([[
        UPDATE matrix_trial_records
        SET conviction_weight = 1.0
        WHERE defendant_citizenid = ? AND verdict = 'pending'
        ORDER BY opened_at DESC LIMIT 1
    ]], { suspectState.citizenid })

    pcall(Matrix.Bureau.ExecuteVerdict, src, {
        defendant_citizenid = suspectState.citizenid,
        defendant_src         = suspectSrc,
        lie_count              = 1
    })

    Reply(src, ('[SUC YUKLEME DOGRULANDI] %s uzerinde islenmemis cinayetler hard-evidence olarak baglandi -- %%100 Mahkumiyet Skoru.'):format(
        suspectState.citizenid))
end, false)

-- Yağma sırasında elde edilen silahlar için etiketleme yalnızca ilk
-- sisteme giriş anında (SyncHoodStashFromNearestTrapHouse içindeki
-- RemoveItem/AddItem çifti) uygulanır -- oyuncu daha sonra hood stash'inden
-- kendi envanterine çektiğinde (ox_inventory'nin KENDİ stash->player
-- transfer akışı) taşınan metadata AYNEN korunur, ikinci bir etiketleme
-- noktasına GEREK YOKTUR.
