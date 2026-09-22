-- =====================================================================
-- ★★★ client/composer_intro.lua — BESTECİNİN İMZASI ★★★
-- YENİ dosya. Oyuncu spawn olduğunda (qbx_core/QBCore İKİ ÇERÇEVE İLE DE
-- UYUMLU — server/main.lua'nın 'qbx_core:server:onPlayerLoaded' +
-- 'QBCore:Server:PlayerLoaded' İLE AYNI çift-destek deseni), oyuncu
-- kontrolü eline almadan ÖNCE ekranı monokrom bir taktik bültenle kaplar;
-- bülten server/matrix_diagnostics.lua'nın GERÇEK son raporunu gösterir
-- (dekoratif "loading..." metni DEĞİL). Rapor sıfır hatayla mühürlenmişse
-- (sealed=true) ikinci bir ses katmanı (kontrpuan) devreye girer.
--
-- ★ ZAMAN GÜVENCESİ (kritik): giris/cikis SÜRESİ (introDurationMs) SABİT
-- bir Wait() zamanlayıcısıyla yönetilir — ASLA bir ses/ağ olayını (xsound
-- yüklü mü, dosya var mı, callback yanıt verdi mi) BEKLEMEZ. Bu yüzden
-- ses dosyası eksik/xsound kurulu değil/DB yavaş gibi HİÇBİR arıza,
-- oyuncuyu ekranda KİLİTLEYEMEZ — kontrol her koşulda introDurationMs
-- sonunda KOŞULSUZ geri verilir. SIFIR RNG: aynı rapor + aynı config HER
-- ZAMAN aynı bülten sırasını üretir.
-- =====================================================================

local introRunning   = false
local cachedReport   = nil

local COLOR_HEADER = { 235, 235, 235 }
local COLOR_OK     = { 110, 255, 140 }
local COLOR_FAIL   = { 255, 70, 70 }
local COLOR_DIM    = { 90, 140, 100 }

local function DrawMonoLine(x, y, text, r, g, b, scale, alpha)
    SetTextFont(4)
    SetTextProportional(1)
    SetTextScale(scale, scale)
    SetTextColour(r, g, b, alpha or 235)
    SetTextDropshadow(1, 0, 0, 0, 200)
    SetTextEdge(1, 0, 0, 0, 180)
    SetTextEntry('STRING')
    AddTextComponentString(text)
    DrawText(x, y)
end

-- ★ xsound gercek bir sunucu-taraf/istemci-taraf kaynagi olarak kurulu
-- OLMAYABILIR (fxmanifest.lua dependencies'e eklendi ama bu, resource'un
-- fiilen indirilip 'start xsound' ile calistirildigi anlamina gelmez) --
-- ve ses dosyalari (Config.ComposerSignature.guideVoiceFile/counterpoint
-- VoiceFile) bu repoda YOK (bkz. shared/config.lua yorumu -- gercek bir
-- Bach kaydi/render'i telif/lisans geregi buraya konulamadi). Bu yuzden
-- HER cagri pcall ile sarilir: xsound yoksa veya dosya 404 donerse ses
-- SESSIZCE calmaz, script/dizi ETKILENMEDEN devam eder.
local function TryPlayVoice(soundId, relativeFile, volume)
    if not relativeFile or relativeFile == '' then return end
    local url = ('https://cfx-nui-%s/%s'):format(GetCurrentResourceName(), relativeFile)
    pcall(function()
        exports.xsound:PlayUrl(soundId, url, volume or 0.5, false)
    end)
end

local function TryStopVoice(soundId)
    pcall(function() exports.xsound:Destroy(soundId) end)
end

local function BuildBulletinLines(report)
    local lines = {}
    lines[#lines + 1] = { text = '=== MATRIX TAKTİK İSTİHBARAT BÜLTENİ ===', color = COLOR_HEADER }

    if not report or not report.checks then
        lines[#lines + 1] = { text = 'Tanı raporu alınamadı -- sunucu henüz ilk taramayı tamamlamamış olabilir.', color = COLOR_FAIL }
        return lines
    end

    lines[#lines + 1] = { text = ('Tarama: %d/%d kontrol başarılı (%dms, deep=%s)'):format(
        report.passed or 0, report.total or 0, report.duration_ms or 0, tostring(report.deep)), color = COLOR_DIM }

    for _, c in ipairs(report.checks) do
        local marker = c.passed and '[OK]' or '[HATA]'
        lines[#lines + 1] = { text = ('%s %s'):format(marker, c.name), color = c.passed and COLOR_OK or COLOR_FAIL }
    end

    lines[#lines + 1] = { text = report.sealed and 'SONUÇ: SİSTEM MÜHÜRLENDİ -- 0 HATA' or 'SONUÇ: AÇIK BULGU VAR -- personel bilgilendirilsin', color = report.sealed and COLOR_OK or COLOR_FAIL }
    return lines
end

local function RunComposerIntro()
    if introRunning then return end
    introRunning = true

    local ped = PlayerPedId()
    pcall(function() SetPlayerControl(PlayerId(), false, 0) end)
    pcall(function() FreezeEntityPosition(ped, true) end)
    pcall(function() DisplayRadar(false) end)

    -- ★ Guncel raporu iste (broadcast'e GUVENME -- bu client, resource
    -- ilk actiginda henuz baglanmamis olabilir; callback her zaman
    -- GUNCEL degeri doner). lib.callback.await zaten ana pattern (bkz.
    -- diger F10 raporlari) -- YENI bir cagri sekli ICAT EDILMEZ.
    local ok, report = pcall(function()
        return lib.callback.await('matrix:callback:getDiagnosticsReport', false)
    end)
    cachedReport = ok and report or cachedReport

    local cfg = Config.ComposerSignature or {}
    local lines = BuildBulletinLines(cachedReport)
    local lineIntervalMs = cfg.bulletinLineIntervalMs or 220
    local introDurationMs = cfg.introDurationMs or 8000
    local counterpointLeadMs = cfg.counterpointLeadMs or 2500
    local fadeOutMs = math.min(cfg.fadeOutMs or 600, introDurationMs)

    local startedAt = GetGameTimer()
    local visibleLines = 0
    local guideStarted, counterpointStarted = false, false

    if cfg.playAudioOnLoad then
        TryPlayVoice('matrix_composer_guide', cfg.guideVoiceFile, cfg.volume)
        guideStarted = true
    end

    CreateThread(function()
        while true do
            local elapsed = GetGameTimer() - startedAt
            if elapsed >= introDurationMs then break end

            -- Bulten satirlari deterministik olarak zamanla acilir.
            local shouldShow = math.floor(elapsed / lineIntervalMs) + 1
            if shouldShow > visibleLines then visibleLines = math.min(shouldShow, #lines) end

            -- Kontrpuan: SADECE rapor sealed ise VE son pencereye girildiyse.
            if cfg.playAudioOnLoad and not counterpointStarted
                and cachedReport and cachedReport.sealed
                and elapsed >= (introDurationMs - counterpointLeadMs) then
                TryPlayVoice('matrix_composer_counterpoint', cfg.counterpointVoiceFile, cfg.volume)
                counterpointStarted = true
            end

            -- ★ Pürüzsüz kapanış: son fadeOutMs içinde alfa 235'ten 0'a
            -- lineer iner -- ani kesilme YOK, "sönsün" talebi buradan
            -- karşılanıyor. remainingMs negatif olamaz (introDurationMs
            -- kontrolü döngü başında zaten yapıldı).
            local remainingMs = introDurationMs - elapsed
            local alpha = 235
            if remainingMs < fadeOutMs then
                alpha = math.floor(235 * (remainingMs / fadeOutMs))
            end

            -- Tam ekran monokrom yikama -- HTML/CSS YOK, saf native DrawRect.
            DrawRect(0.5, 0.5, 1.0, 1.0, 4, 8, 4, alpha)

            local y = 0.12
            for i = 1, visibleLines do
                local line = lines[i]
                DrawMonoLine(0.06, y, line.text, line.color[1], line.color[2], line.color[3], 0.32, alpha)
                y = y + 0.022
            end

            Wait(0) -- DrawRect/DrawText per-frame gerektirir (mevcut HUD'un kendi disiplini)
        end

        pcall(function() SetPlayerControl(PlayerId(), true, 0) end)
        pcall(function() FreezeEntityPosition(PlayerPedId(), false) end)
        pcall(function() DisplayRadar(true) end)
        if guideStarted then TryStopVoice('matrix_composer_guide') end
        if counterpointStarted then TryStopVoice('matrix_composer_counterpoint') end
        introRunning = false
    end)
end

RegisterNetEvent('qbx_core:client:onPlayerLoaded', RunComposerIntro)
RegisterNetEvent('QBCore:Client:OnPlayerLoaded', RunComposerIntro)

-- Bir yönetici oturumdayken '/matrix_run_diagnostics' çalıştırırsa en
-- güncel raporu önbelleğe alır (bir sonraki spawn/callback için) -- introyu
-- KESMEZ, yalnızca sessizce günceller.
RegisterNetEvent('matrix:client:diagnosticsSealed', function(report)
    cachedReport = report
end)