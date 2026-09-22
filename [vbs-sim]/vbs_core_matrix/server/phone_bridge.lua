-- =====================================================================
-- MATRIX DARKCHAT / QB-PHONE ENCRYPTED TELEMETRY KÖPRÜSÜ
-- server/phone_bridge.lua  (fxmanifest.lua server_scripts SONUNA eklenir)
--
-- ADDITIVE. Mevcut hiçbir dosya değiştirilmedi; yalnızca Matrix.CompleteDispatch
-- ve Matrix.DepositDealerCargoToTrapStash isim-uzayı SARMALANIR (monkey-patch),
-- Matrix.Bureau.GetEncryptedAgentTelemetry YENİ üye olarak bağlanır ve
-- matrix:server:phone:remoteWipe yeni net-event'i register edilir.
--
-- KATI ANAYASA:
--   - math.random YASAK. Tüm maske/parola üretimi SHA256-benzeri
--     checksum zinciri (KATMAN 8 bureau.lua _CryptoSha256Like deseniyle
--     BİREBİR aynı aile) ile deterministiktir.
--   - Tüm IO pcall + CreateThread ile asenkron; master ticker 0.00ms
--     bütçesinden tek kuruş çalınmaz.
-- =====================================================================

Matrix.PhoneBridge = Matrix.PhoneBridge or {}
Matrix.Bureau      = Matrix.Bureau      or {}

local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local math_max, math_floor                    = math.max, math.floor
local CreateThread                            = CreateThread
local RegisterNetEvent                       = RegisterNetEvent
local TriggerClientEvent                     = TriggerClientEvent
local TriggerEvent                            = TriggerEvent

-- =====================================================================
-- [0] DETERMİNİSTİK SHA256-BENZERİ HEX MOTORU (RNG YOK)
-- bureau.lua [KATMAN 8] _CryptoSha256Like ile AYNI aile; salt her zaman
-- kod içinde bir literal sabittir.
-- =====================================================================
local function _Sha256Like(input)
    input = tostring(input or '')
    local out = {}
    for i = 1, 16 do
        local raw = ('%s#%d#DC'):format(input, i)
        local sum = 0
        for j = 1, #raw do
            sum = (sum + (raw:byte(j) * (j + 131 + i))) % 0xFFFFFFF
        end
        out[i] = ('%04X'):format(sum % 0x10000)
    end
    return table.concat(out, '')
end

local function _MaskCoordinate(value, saltKey)
    local seed = ('COORD#%s#%.4f'):format(tostring(saltKey), tonumber(value) or 0.0)
    return '0x' .. _Sha256Like(seed):sub(1, 30)
end

local function _MaskBalance(value, saltKey)
    local seed = ('BAL#%s#%.4f'):format(tostring(saltKey), tonumber(value) or 0.0)
    return '0x' .. _Sha256Like(seed):sub(1, 30)
end

local function _GenerateMissionPassword(botDna, statusLabel, botId, epoch)
    local seed = ('%s#%s#%d#%d#FATURA'):format(
        tostring(botDna or 'UNK'), tostring(statusLabel), tonumber(botId) or 0, tonumber(epoch) or 0)
    return _Sha256Like(seed):sub(1, 16):upper()
end

local function _ResolveSrcFromCitizenid(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' then return nil end
    for src, cid in pairs(Matrix.PlayerSourceIndex or {}) do
        if cid == citizenid then return src end
    end
    return nil
end

-- =====================================================================
-- [1] AJAN GÖREV SONU DARKCHAT TELEMETRİSİ
-- =====================================================================
function Matrix.PhoneBridge.TransmitMissionTelemetry(botSnapshot, statusLabel, dispatcherSrc)
    if type(botSnapshot) ~= 'table' then return false end

    if type(dispatcherSrc) ~= 'number' or dispatcherSrc <= 0 then
        dispatcherSrc = _ResolveSrcFromCitizenid(botSnapshot.handler_citizenid)
    end
    if type(dispatcherSrc) ~= 'number' or dispatcherSrc <= 0 then
        return false
    end

    local epoch    = os.time()
    local password = _GenerateMissionPassword(botSnapshot.dna_id, statusLabel, botSnapshot.id, epoch)

    local message = ('[AJAN #%d - %s]: Lojistik rota tamamlandı. Kar faturası mühürlendi. Parola: %s'):format(
        tonumber(botSnapshot.id) or 0, tostring(statusLabel), password)

    -- Asenkron fırlat — çağıran thread'i ASLA bloklamaz.
    CreateThread(function()
        -- qb-phone canonical
        pcall(function()
            TriggerEvent('qb-phone:server:sendNewMail', dispatcherSrc, {
                sender  = 'DARKCHAT // ENCRYPTED',
                subject = ('AJAN TELEMETRİSİ #%d'):format(tonumber(botSnapshot.id) or 0),
                message = message,
                button  = {}
            })
        end)
        -- qb-phone fork: direct export
        pcall(function()
            exports['qb-phone']:sendNewMail(dispatcherSrc, {
                sender  = 'DARKCHAT // ENCRYPTED',
                subject = ('AJAN TELEMETRİSİ #%d'):format(tonumber(botSnapshot.id) or 0),
                message = message
            })
        end)
        -- lb-phone fork
        pcall(function()
            exports['lb-phone']:SendMail(dispatcherSrc, {
                sender  = 'darkchat@matrix.local',
                subject = ('AJAN TELEMETRİSİ #%d'):format(tonumber(botSnapshot.id) or 0),
                message = message
            })
        end)
        -- darkchat alt-uygulama köprüsü (client tarafı)
        pcall(function()
            TriggerClientEvent('matrix:client:darkchat:telemetry', dispatcherSrc, {
                bot_id   = botSnapshot.id,
                bot_name = botSnapshot.name,
                status   = statusLabel,
                message  = message,
                parola   = password,
                epoch    = epoch
            })
        end)
    end)

    return true
end

-- =====================================================================
-- [1a] Matrix.CompleteDispatch SARMALAYICI (çift-sarma korumalı)
-- =====================================================================
if not Matrix.PhoneBridge._CompleteDispatchWrapped then
    Matrix.PhoneBridge._CompleteDispatchWrapped = true

    local _origCompleteDispatch = Matrix.CompleteDispatch

    function Matrix.CompleteDispatch(botId, reason)
        -- Orijinal çağrıdan ÖNCE dispatch ve bot snapshot'larını yakala
        -- (orijinal, Dispatches[botId]'yi nil'ler ve bot statüsünü
        -- değiştirebilir).
        local dispatch      = Matrix.Dispatches and Matrix.Dispatches[botId]
        local dispatcherSrc = dispatch and dispatch.dispatcher_src
        local botLive       = Matrix.Bots and Matrix.Bots[botId]

        local botSnapshot
        if botLive then
            botSnapshot = {
                id                = botLive.id,
                dna_id            = botLive.dna_id,
                name              = botLive.name,
                role              = botLive.role,
                handler_citizenid = botLive.handler_citizenid
            }
        end

        local result = _origCompleteDispatch(botId, reason)

        if result and botSnapshot and (reason == 'arrived' or reason == 'busted') then
            local statusLabel = (reason == 'arrived') and 'success'
                             or (reason == 'busted')  and 'busted'
                             or tostring(reason)
            -- Fire-and-forget; hata olsa dahi çağıran akış bozulmaz.
            pcall(function()
                Matrix.PhoneBridge.TransmitMissionTelemetry(botSnapshot, statusLabel, dispatcherSrc)
            end)
        end

        return result
    end
end

-- =====================================================================
-- [1b] Matrix.DepositDealerCargoToTrapStash SARMALAYICI
-- "Liman mal transfer döngüsünün sonu" — bu hook, kargo depoya
-- aktarıldıktan SONRA ikinci bir "fatura mühürlendi" telemetrisi yayar.
-- =====================================================================
if not Matrix.PhoneBridge._DepositCargoWrapped then
    Matrix.PhoneBridge._DepositCargoWrapped = true

    local _origDepositCargo = Matrix.DepositDealerCargoToTrapStash

    function Matrix.DepositDealerCargoToTrapStash(botId, trapHouseId)
        local result = _origDepositCargo(botId, trapHouseId)

        local bot = Matrix.Bots and Matrix.Bots[botId]
        if bot and result ~= nil then
            local snapshot = {
                id                = bot.id,
                dna_id            = bot.dna_id,
                name              = bot.name,
                handler_citizenid = bot.handler_citizenid
            }
            pcall(function()
                Matrix.PhoneBridge.TransmitMissionTelemetry(snapshot, 'deposit_sealed', nil)
            end)
        end

        return result
    end
end

-- =====================================================================
-- [2] AJAN BİLGİ SEVİYESİ VE KRİPTOLU REFS SÜZGECİ (INFORMATION LEVELS)
-- =====================================================================
local function _ResolvePlayerRankLevel(src)
    if not (Matrix.Hierarchy and Matrix.Hierarchy.GetRank) then return 0 end
    local state = Matrix.GetOrCreatePlayerState and Matrix.GetOrCreatePlayerState(src) or nil
    if not state or not state.citizenid then return 0 end
    local rank = Matrix.Hierarchy.GetRank(state.citizenid)
    if not rank then return 0 end
    local rankCfg = Config.Hierarchy and Config.Hierarchy.Ranks and Config.Hierarchy.Ranks[rank]
    return (rankCfg and tonumber(rankCfg.level)) or 0
end

function Matrix.Bureau.GetEncryptedAgentTelemetry(src, botId)
    if type(src) ~= 'number' or src <= 0 then return nil, 'bad_src' end
    botId = tonumber(botId)
    if not botId then return nil, 'bad_bot_id' end

    local bot = Matrix.Bots and Matrix.Bots[botId]
    if not bot then return nil, 'bot_missing' end

    -- ---- Görünürlük katsayıları -------------------------------------
    local rankLevel         = _ResolvePlayerRankLevel(src)
    local requiredRankLevel = (Config.Hierarchy and Config.Hierarchy.MinRankLevelForCommand) or 2

    local trapHouseId = bot.state and bot.state.trap_house_id
    local heat = 0.0
    if trapHouseId and Matrix.Bureau and Matrix.Bureau.GetHeat then
        local okHeat, h = pcall(Matrix.Bureau.GetHeat, trapHouseId)
        if okHeat and type(h) == 'number' and h == h then heat = h end
    end
    local maxHeat = (Config.Bureau and tonumber(Config.Bureau.CyberLeakMaxIntensity)) or 5.0
    if maxHeat <= 0.0 then maxHeat = 1.0 end
    local normalizedHeat = heat / maxHeat
    local heatThreshold  = (Config.Bureau and tonumber(Config.Bureau.LockdownEvidenceThreshold)) or 0.75

    local rankHigh   = rankLevel >= requiredRankLevel
    local heatClean  = normalizedHeat < heatThreshold
    -- Need-to-Know MilSim kuralı: SADECE rütbe yüksek VE ısı temizse
    -- açık veri gösterilir; aksi halde TÜM float verisi maskelenir.
    local maskOn     = not (rankHigh and heatClean)

    -- ---- Koordinat / bakiye ham çekim ------------------------------
    local coords = bot.state and bot.state.coords
    local cx, cy, cz = 0.0, 0.0, 0.0
    if coords and (type(coords) == 'vector3' or type(coords) == 'vector4') then
        cx = tonumber(coords.x) or 0.0
        cy = tonumber(coords.y) or 0.0
        cz = tonumber(coords.z) or 0.0
    end

    local balance = 0.0
    if bot.biology and bot.biology.crypto_balance then
        balance = tonumber(bot.biology.crypto_balance) or 0.0
    end

    local saltKey = ('BOT%d#%s'):format(botId, tostring(bot.dna_id or 'UNK'))

    if maskOn then
        return {
            bot_id         = botId,
            dna_id         = '0x' .. _Sha256Like('DNA#' .. tostring(bot.dna_id or 'UNK')):sub(1, 32),
            name           = '[REDACTED-AGENT]',
            role           = bot.role,
            status         = bot.status,
            coords_masked  = true,
            coords_x       = _MaskCoordinate(cx, saltKey .. '#X'),
            coords_y       = _MaskCoordinate(cy, saltKey .. '#Y'),
            coords_z       = _MaskCoordinate(cz, saltKey .. '#Z'),
            balance_masked = true,
            balance        = _MaskBalance(balance, saltKey .. '#BAL'),
            need_to_know   = true,
            heat_ratio     = normalizedHeat,
            rank_level     = rankLevel,
            mask_algorithm = 'SHA256-LIKE/CHECKSUM-V1'
        }
    end

    return {
        bot_id         = botId,
        dna_id         = bot.dna_id,
        name           = bot.name,
        role           = bot.role,
        status         = bot.status,
        coords_masked  = false,
        coords_x       = cx,
        coords_y       = cy,
        coords_z       = cz,
        balance_masked = false,
        balance        = balance,
        need_to_know   = false,
        heat_ratio     = normalizedHeat,
        rank_level     = rankLevel,
        mask_algorithm = nil
    }
end

-- =====================================================================
-- [2a] DARKCHAT ALT-UYGULAMA VERİ TALEP KANALI (client → server)
-- =====================================================================
RegisterNetEvent('matrix:server:phone:requestAgentTelemetry', function(botId)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end

    local data, err = Matrix.Bureau.GetEncryptedAgentTelemetry(src, botId)
    if not data then
        TriggerClientEvent('matrix:client:darkchat:telemetryResult', src, nil, err or 'unknown')
        return
    end
    TriggerClientEvent('matrix:client:darkchat:telemetryResult', src, data)
end)

-- =====================================================================
-- [3] DARKCHAT UZAKTAN İMHA (REMOTE WIPE PANIC BUTTON)
-- Oyuncu telefon arayüzünden panik butonunu tetiklediğinde çağrılır.
-- Matrix.Bureau.SabotagePhoneLine zaten ATOMİK SQL transaction uygular
-- (matrix_encrypted_messages + matrix_forensic_evidence/cyber, tek
-- transaction.await) — bu blok yalnızca güvenli çağrı köprüsüdür.
-- =====================================================================
RegisterNetEvent('matrix:server:phone:remoteWipe', function(dnaIdHint)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end

    -- DNA çözümleme: yalnızca çağıranın KENDİ dna_id'si hedeflenebilir.
    -- Client'tan gelen dnaIdHint, oyuncunun kendi dna_id'siyle birebir
    -- eşleşmediği sürece YOK SAYILIR (spoofing savunması).
    local state   = Matrix.GetOrCreatePlayerState and Matrix.GetOrCreatePlayerState(src) or nil
    local ownDna  = state and state.dna_id

    local targetDna
    if type(dnaIdHint) == 'string' and dnaIdHint ~= '' and dnaIdHint == ownDna then
        targetDna = dnaIdHint
    else
        targetDna = ownDna
    end

    if type(targetDna) ~= 'string' or targetDna == '' then
        TriggerClientEvent('matrix:client:actionNotify', src, false,
            'Uzaktan imha basarisiz: hat kimligi cozulemedi.')
        return
    end

    -- Asenkron atomik imha — master ticker'ı ASLA bloklamaz.
    CreateThread(function()
        local ok, result = pcall(Matrix.Bureau.SabotagePhoneLine, src, targetDna)

        if ok and result == true then
            TriggerClientEvent('matrix:client:actionNotify', src, true,
                '[ACİL İMHA] Şifreli mesajlar ve kesinleşmemiş siber deliller tek atomik transaction ile kazındı.')

            -- Onay bülteni: aynı telefon hattına deterministik bir "imha
            -- mührü" düşer (math.random YOK — epoch + dna_id sağlama
            -- toplamı).
            local seal = _Sha256Like(('WIPE#%s#%d'):format(targetDna, os.time())):sub(1, 16):upper()
            TriggerClientEvent('matrix:client:darkchat:telemetry', src, {
                bot_id   = 0,
                bot_name = 'DARKCHAT PANIC-WIPE',
                status   = 'remote_wipe',
                message  = ('[ACİL İMHA]: Hat mühürlendi. Tüm şifreli mesajlar buharlaştı. Mühür: %s'):format(seal),
                parola   = seal,
                epoch    = os.time()
            })
        else
            TriggerClientEvent('matrix:client:actionNotify', src, false,
                ('Uzaktan imha basarisiz: %s'):format(tostring(result)))
        end
    end)
end)

-- =====================================================================
-- [3a] EXPORT KÖPRÜLERİ (client/hud.lua ve dış kaynaklar için)
-- =====================================================================
exports('GetEncryptedAgentTelemetry', function(src, botId)
    return Matrix.Bureau.GetEncryptedAgentTelemetry(src, botId)
end)

exports('TransmitMissionTelemetry', function(botId, statusLabel, dispatcherSrc)
    local bot = Matrix.Bots and Matrix.Bots[tonumber(botId) or botId]
    if not bot then return false end
    return Matrix.PhoneBridge.TransmitMissionTelemetry({
        id                = bot.id,
        dna_id            = bot.dna_id,
        name              = bot.name,
        handler_citizenid = bot.handler_citizenid
    }, statusLabel or 'manual', dispatcherSrc)
end)

exports('RemoteWipePhoneLine', function(src, dnaId)
    return Matrix.Bureau.SabotagePhoneLine(src, dnaId)
end)

-- =====================================================================
-- [4] DETERMINISM PROBE — diagnostics için (matrix_diagnostics.lua
-- AddCheck('PhoneBridge: Determinizm ...') testini besler). Salt-okunur
-- bir yardımcıdır; production akışına dokunmaz.
-- =====================================================================
Matrix.PhoneBridge.__DeterminismProbe = _Sha256Like

-- =====================================================================
-- ★ [FAZ 1] NEED-TO-KNOW MASKELİ TELEMETRİ SÜZGECİ
-- Oyuncu rütbesi YÜKSEK VE siber-ısı düşükse → açık veri.
-- Aksi halde → SHA256-benzeri hex maskeleme (koordinat + bakiye).
-- =====================================================================

local function _ResolvePlayerRankLevel(src)
    if not (Matrix.Hierarchy and Matrix.Hierarchy.GetRank) then return 0 end
    local state = Matrix.GetOrCreatePlayerState and Matrix.GetOrCreatePlayerState(src) or nil
    if not state or not state.citizenid then return 0 end
    local rank = Matrix.Hierarchy.GetRank(state.citizenid)
    if not rank then return 0 end
    local rankCfg = Config.Hierarchy and Config.Hierarchy.Ranks and Config.Hierarchy.Ranks[rank]
    return (rankCfg and tonumber(rankCfg.level)) or 0
end

function Matrix.Bureau.GetEncryptedAgentTelemetry(src, botId)
    if type(src) ~= 'number' or src <= 0 then return nil, 'bad_src' end
    botId = tonumber(botId)
    if not botId then return nil, 'bad_bot_id' end

    local bot = Matrix.Bots and Matrix.Bots[botId]
    if not bot then return nil, 'bot_missing' end

    -- Görünürlük katsayıları
    local rankLevel         = _ResolvePlayerRankLevel(src)
    local requiredRankLevel = (Config.Hierarchy and Config.Hierarchy.MinRankLevelForCommand) or 2

    local trapHouseId = bot.state and bot.state.trap_house_id
    local heat = 0.0
    if trapHouseId and Matrix.Bureau and Matrix.Bureau.GetHeat then
        local okHeat, h = pcall(Matrix.Bureau.GetHeat, trapHouseId)
        if okHeat and type(h) == 'number' and h == h then heat = h end
    end
    local maxHeat = (Config.Bureau and tonumber(Config.Bureau.CyberLeakMaxIntensity)) or 5.0
    if maxHeat <= 0.0 then maxHeat = 1.0 end
    local normalizedHeat = heat / maxHeat
    local heatThreshold  = (Config.Bureau and tonumber(Config.Bureau.LockdownEvidenceThreshold)) or 0.75

    local rankHigh   = rankLevel >= requiredRankLevel
    local heatClean  = normalizedHeat < heatThreshold
    local maskOn     = not (rankHigh and heatClean)

    -- Koordinat / bakiye ham veri
    local coords = bot.state and bot.state.coords
    local cx, cy, cz = 0.0, 0.0, 0.0
    if coords and (type(coords) == 'vector3' or type(coords) == 'vector4') then
        cx, cy, cz = tonumber(coords.x) or 0.0, tonumber(coords.y) or 0.0, tonumber(coords.z) or 0.0
    end

    local balance = 0.0
    if bot.biology and bot.biology.crypto_balance then
        balance = tonumber(bot.biology.crypto_balance) or 0.0
    end

    local saltKey = ('BOT%d#%s'):format(botId, tostring(bot.dna_id or 'UNK'))

    local function _Mask(v, prefix)
        local seed = ('%s#%.4f'):format(prefix, tonumber(v) or 0.0)
        return '0x' .. _Sha256Like(seed):sub(1, 30)
    end

    if maskOn then
        return {
            bot_id         = botId,
            dna_id         = '0x' .. _Sha256Like('DNA#' .. tostring(bot.dna_id or 'UNK')):sub(1, 32),
            name           = '[REDACTED-AGENT]',
            role           = bot.role,
            status         = bot.status,
            coords_masked  = true,
            coords_x       = _Mask(cx, saltKey .. '#X'),
            coords_y       = _Mask(cy, saltKey .. '#Y'),
            coords_z       = _Mask(cz, saltKey .. '#Z'),
            balance_masked = true,
            balance        = _Mask(balance, saltKey .. '#BAL'),
            need_to_know   = true,
            heat_ratio     = normalizedHeat,
            rank_level     = rankLevel,
            mask_algorithm = 'SHA256-LIKE/CHECKSUM-V1'
        }
    end

    return {
        bot_id         = botId,
        dna_id         = bot.dna_id,
        name           = bot.name,
        role           = bot.role,
        status         = bot.status,
        coords_masked  = false,
        coords_x       = cx,
        coords_y       = cy,
        coords_z       = cz,
        balance_masked = false,
        balance        = balance,
        need_to_know   = false,
        heat_ratio     = normalizedHeat,
        rank_level     = rankLevel
    }
end

-- Telefon → server telemetri talebi
RegisterNetEvent('matrix:server:phone:requestAgentTelemetry', function(botId)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    local data, err = Matrix.Bureau.GetEncryptedAgentTelemetry(src, botId)
    if not data then
        TriggerClientEvent('matrix:client:darkchat:telemetryResult', src, nil, err or 'unknown')
        return
    end
    TriggerClientEvent('matrix:client:darkchat:telemetryResult', src, data)
end)

exports('GetEncryptedAgentTelemetry', function(src, botId)
    return Matrix.Bureau.GetEncryptedAgentTelemetry(src, botId)
end)

-- =====================================================================
-- ★ [FAZ 4] DARKCHAT UZAKTAN İMHA (REMOTE WIPE) PANİK BUTONU
-- Matrix.Bureau.SabotagePhoneLine zaten atomik SQL transaction uygular;
-- bu blok yalnızca güvenli çağrı köprüsüdür + cooldown + deterministik
-- imha mührü (RNG YOK — epoch + dna_id checksum).
-- =====================================================================

local RemoteWipeCooldown = {}  -- [src] = sonraki izinli zaman (Unix saniye)

RegisterNetEvent('matrix:server:phone:remoteWipe', function(dnaIdHint)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end

    -- Cooldown (30 sn spam koruması)
    local nowTs = os.time()
    if RemoteWipeCooldown[src] and nowTs < RemoteWipeCooldown[src] then
        TriggerClientEvent('matrix:client:actionNotify', src, false,
            'Uzaktan imha bekleme süresinde.')
        return
    end
    RemoteWipeCooldown[src] = nowTs + math.floor((Config.Bureau.RemoteWipeCooldownMs or 30000) / 1000)

    -- DNA çözümleme: yalnızca çağıranın KENDİ dna_id'si hedeflenebilir.
    -- dnaIdHint spoofing koruması: hediye ile gelen hint kendi dna_id ile
    -- birebir eşleşmiyorsa YOK SAYILIR.
    local state  = Matrix.GetOrCreatePlayerState and Matrix.GetOrCreatePlayerState(src) or nil
    local ownDna = state and state.dna_id

    local targetDna
    if type(dnaIdHint) == 'string' and dnaIdHint ~= '' and dnaIdHint == ownDna then
        targetDna = dnaIdHint
    else
        targetDna = ownDna
    end

    if type(targetDna) ~= 'string' or targetDna == '' then
        TriggerClientEvent('matrix:client:actionNotify', src, false,
            'Uzaktan imha başarısız: hat kimliği çözülemedi.')
        return
    end

    -- Asenkron atomik imha — master ticker'ı ASLA bloklamaz.
    CreateThread(function()
        local ok, result = pcall(Matrix.Bureau.SabotagePhoneLine, src, targetDna)

        if ok and result == true then
            TriggerClientEvent('matrix:client:actionNotify', src, true,
                '[ACİL İMHA] Şifreli mesajlar ve kesinleşmemiş siber deliller tek atomik transaction ile kazındı.')

            -- İmha mührü: deterministik hash, math.random YOK.
            local seal = _Sha256Like(('WIPE#%s#%d'):format(targetDna, os.time())):sub(1, 16):upper()

            TriggerClientEvent('matrix:client:darkchat:telemetry', src, {
                bot_id   = 0,
                bot_name = 'DARKCHAT PANIC-WIPE',
                status   = 'remote_wipe',
                message  = ('[ACİL İMHA]: Hat mühürlendi. Tüm şifreli mesajlar buharlaştı. Mühür: %s'):format(seal),
                parola   = seal,
                epoch    = os.time()
            })
        else
            TriggerClientEvent('matrix:client:actionNotify', src, false,
                ('Uzaktan imha başarısız: %s'):format(tostring(result)))
        end
    end)
end)

exports('RemoteWipePhoneLine', function(src, dnaId)
    return Matrix.Bureau.SabotagePhoneLine(src, dnaId)
end)