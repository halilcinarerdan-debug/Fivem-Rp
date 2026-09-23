-- =====================================================================
-- MATRIX TIM YAPAY ZEKA KOMUTASI / server/team_ai.lua
-- (MODUL 15: OpenAI Tabanli Stratejik Muhakeme + Otonom Tim Komutasi)
--
-- ★ Config.AI_Matrix_Brain (server/bureau.lua Matrix.Bureau.
-- RunAIAdvisoryPass ILE AYNI provider/apiKey/model) YENIDEN KULLANILIR --
-- ikinci bir "OpenAI anahtari" ICAT EDILMEZ. HTTP istegi PerformHttpRequest'
-- in KENDI async callback kanalinda yurutulur -- Config.Tick.IntervalMs
-- master ticker'i ASLA bloklamaz (Citizen.Await/senkron bekleme YOK).
--
-- ★ TIM MODELI: bu koddan ONCE hicbir "Tim Alfa/Bravo" kavrami yoktu --
-- additive bir alan (bot.state.team) ile /timata KOMUTUYLA kurulur.
-- Lider = o timdeki EN DUSUK id'li bot (RNG YOK, /timata Modul 10/11'in
-- "en dusuk id" desenini TEKRAR KULLANIR).
-- =====================================================================

Matrix.TeamAI = Matrix.TeamAI or {}
Matrix.TeamAI.Directives = Matrix.TeamAI.Directives or {} -- [team] = { sneak_mode, lspd_engagement, casualty_protocol, fallback_coords, updated_at }

local function Reply(src, msg)
    if type(src) == 'number' and src > 0 then
        TriggerClientEvent('chat:addMessage', src, { args = { '[TIM AI]', msg } })
    else
        print(('[MATRIX:TEAMAI:CONSOLE] %s'):format(msg))
    end
end

local function HasCommandAuthority(src)
    local pstate = Matrix.GetOrCreatePlayerState and Matrix.GetOrCreatePlayerState(src)
    local citizenid = pstate and pstate.citizenid
    return citizenid ~= nil
        and Matrix.Hierarchy ~= nil
        and type(Matrix.Hierarchy.HasCommandAuthority) == 'function'
        and Matrix.Hierarchy.HasCommandAuthority(citizenid) == true
end

-- =====================================================================
-- ★ [MODUL 16.2] CO-OP EMIR ROLESI: Tim Alfa/Bravo bolunmesi ve OpenAI
-- uzaktan sevk emirleri ARTIK yalnizca emri veren Baronun istemcisinde
-- yerel KALMAZ -- rutbede komuta yetkisi olan (Matrix.Hierarchy.
-- HasCommandAuthority) TUM baglı Co-Op ortaklarina net-event ile
-- YAYINLANIR. Ikinci bir "oyuncu listesi" taramasi ICAT EDILMEZ --
-- MEVCUT GetPlayers() + HasCommandAuthority deseni kullanilir.
-- =====================================================================
function Matrix.TeamAI.BroadcastToCommandAuthority(message, excludeSrc)
    for _, plyIdStr in ipairs(GetPlayers()) do
        local plySrc = tonumber(plyIdStr)
        if plySrc and plySrc ~= excludeSrc and HasCommandAuthority(plySrc) then
            TriggerClientEvent('chat:addMessage', plySrc, { args = { '[KARARGAH BULTENI]', message } })
        end
    end
end

--- ★ Salt-okunur getter: F6/K panelinin (client/hud.lua) Co-Op'ta TAM
--- senkronize gorebilmesi icin -- hangi tim, hangi OpenAI gorev kodunu
--- (sneak_mode/lspd_engagement/casualty_protocol) yurutuyor ve lideri
--- kim. Turnike/panik durumu (server/wound_system.lua Matrix.Wounds ile
--- AYNI alanlar) member_status icinde raporlanir -- ikinci bir "yara
--- durumu" tablosu ICAT EDILMEZ.
local function BuildTeamCommandReport()
    local report = {}
    for team in pairs(Config.TeamAI.ValidTeams) do
        local ids = GetTeamBotIds(team)
        if #ids > 0 then
            local members = {}
            for _, botId in ipairs(ids) do
                local bot = Matrix.Bots[botId]
                members[#members + 1] = {
                    bot_id     = botId,
                    name       = bot and bot.name or nil,
                    panicking  = (Matrix.Wounds and Matrix.Wounds.IsBotPanicking and Matrix.Wounds.IsBotPanicking(botId)) or false,
                    status     = bot and bot.status or nil
                }
            end
            report[team] = {
                leader_id = ids[1],
                directive = Matrix.TeamAI.Directives[team],
                members   = members
            }
        end
    end
    return report
end

lib.callback.register('matrix:callback:getTeamCommandReport', function(src)
    if not HasCommandAuthority(src) then return {} end
    return BuildTeamCommandReport()
end)

--- ★ Salt-okunur getter: bir timdeki TUM bot id'lerini KUCUKTEN BUYUGE
--- siralanmis dondurur -- ids[1] HER ZAMAN o timin lideridir.
local function GetTeamBotIds(team)
    local ids = {}
    for id, bot in pairs(Matrix.Bots) do
        if bot.state and bot.state.team == team then ids[#ids + 1] = id end
    end
    table.sort(ids)
    return ids
end

function Matrix.TeamAI.GetTeamLeaderId(team)
    return GetTeamBotIds(team)[1]
end

-- =====================================================================
-- ★ /timata [botId] [alfa|bravo] -- rutbeli subaylarin (Config.Hierarchy.
-- MinRankLevelForCommand, MEVCUT Matrix.Hierarchy.HasCommandAuthority ile
-- AYNI yetki) bir botu bir tim etiketine ATAMASINI saglar. Additive alan
-- (bot.state.team) -- ikinci bir "bot kaydi" ICAT EDILMEZ.
-- =====================================================================
RegisterCommand('timata', function(src, args)
    if not HasCommandAuthority(src) then
        Reply(src, 'Bu komutu vermek icin yeterli rutbeniz yok.')
        return
    end

    local botId = tonumber(args[1])
    local team  = args[2] and tostring(args[2]):lower() or nil
    if not botId or not team or not Config.TeamAI.ValidTeams[team] then
        Reply(src, 'Kullanim: /timata [botId] [alfa|bravo]')
        return
    end

    local bot = Matrix.Bots[botId]
    if not bot then
        Reply(src, 'Bot bulunamadi.')
        return
    end

    bot.state = bot.state or {}
    bot.state.team = team
    if Matrix.MarkBotDirty then Matrix.MarkBotDirty(botId) end

    Reply(src, ('Bot #%d Tim %s icin atandi.'):format(botId, team:upper()))
end, false)

-- =====================================================================
-- ★ DOGRULAMA: AI ciktisi HICBIR ZAMAN kor guvenilmez -- her alan
-- whitelist/clamp'ten gecer, gecersiz/eksik ise Config.TeamAI.
-- DefaultDirective'e DUSER (RNG YOK, "tahmin" edilmez).
-- =====================================================================
local VALID_ENGAGEMENT = { flee = true, attack = true, sabotage = true }
local VALID_CASUALTY   = { carry = true, purge_evidence = true }

local function SanitizeDirective(decoded)
    decoded = type(decoded) == 'table' and decoded or {}
    local d = Config.TeamAI.DefaultDirective

    local sneak = decoded.sneak_mode
    if type(sneak) ~= 'boolean' then sneak = d.sneak_mode end

    local engagement = decoded.lspd_engagement
    if type(engagement) ~= 'string' or not VALID_ENGAGEMENT[engagement] then engagement = d.lspd_engagement end

    local casualty = decoded.casualty_protocol
    if type(casualty) ~= 'string' or not VALID_CASUALTY[casualty] then casualty = d.casualty_protocol end

    local fallback = nil
    local fc = decoded.fallback_coords_if_leader_down
    if type(fc) == 'table' then
        local x = tonumber(fc.x or fc[1])
        local y = tonumber(fc.y or fc[2])
        local z = tonumber(fc.z or fc[3])
        if x and y and z and math.abs(x) <= 20000.0 and math.abs(y) <= 20000.0 and math.abs(z) <= 2000.0 then
            fallback = vector3(x, y, z)
        end
    end

    return {
        sneak_mode        = sneak,
        lspd_engagement   = engagement,
        casualty_protocol = casualty,
        fallback_coords   = fallback,
        updated_at        = Matrix.Now()
    }
end

-- =====================================================================
-- ★ /timeemir [alfa|bravo] [serbest metin] -- OpenAI (Config.AI_Matrix_
-- Brain.provider=='openai') serbest metni KATI operasyonel JSON'a parse
-- eder; sonuc SanitizeDirective'ten GECER ve ilgili timin AKTIF sevk
-- kayitlarina (Matrix.Dispatches[botId].ai_fsm_matrix) enjekte edilir --
-- ikinci bir "tim durumu" tablosu ICAT EDILMEZ.
-- =====================================================================
RegisterCommand('timeemir', function(src, args)
    if not HasCommandAuthority(src) then
        Reply(src, 'Bu komutu vermek icin yeterli rutbeniz yok.')
        return
    end

    local team = args[1] and tostring(args[1]):lower() or nil
    if not team or not Config.TeamAI.ValidTeams[team] then
        Reply(src, "Kullanim: /timeemir [alfa|bravo] [serbest metin talimati]")
        return
    end

    local freeText = table.concat(args, ' ', 2)
    if not freeText or freeText:gsub('%s', '') == '' then
        Reply(src, 'Bos talimat gonderilemez.')
        return
    end

    if Config.AI_Matrix_Brain.provider ~= 'openai'
        or not Config.AI_Matrix_Brain.apiKey
        or Config.AI_Matrix_Brain.apiKey == 'sk-...' then
        Reply(src, '[BZZZT] -- ...sinyal-yok... OpenAI anahtari yapilandirilmamis, komuta koprusu KAPALI.')
        return
    end

    local teamIds = GetTeamBotIds(team)
    if #teamIds == 0 then
        Reply(src, ('Tim %s icinde atanmis bot yok (/timata ile atayin).'):format(team:upper()))
        return
    end

    local body = json.encode({
        model = Config.TeamAI.Model or 'gpt-4o-mini',
        messages = {
            {
                role = 'system',
                content = 'You are a deterministic military-operations order parser for a GTA roleplay crime-team simulation. '
                    .. 'Convert the operator\'s free-text order into STRICT JSON only, matching EXACTLY this schema: '
                    .. '{"sneak_mode": boolean, "lspd_engagement": "flee"|"attack"|"sabotage", '
                    .. '"casualty_protocol": "carry"|"purge_evidence", '
                    .. '"fallback_coords_if_leader_down": {"x": number, "y": number, "z": number} or null}. '
                    .. 'Never invent extra fields, never include prose or markdown, respond with the JSON object only.'
            },
            { role = 'user', content = freeText }
        }
    })

    PerformHttpRequest('https://api.openai.com/v1/chat/completions', function(statusCode, response)
        if statusCode ~= 200 then
            Reply(src, ('[BZZZT] -- ...bag-lan-ti kes-ildi... OpenAI istegi basarisiz (HTTP %s), deterministik varsayilan korunuyor.'):format(tostring(statusCode)))
            return
        end

        local ok, decoded = pcall(json.decode, response)
        local content = ok and decoded and decoded.choices and decoded.choices[1]
            and decoded.choices[1].message and decoded.choices[1].message.content or nil

        local parsedOk, parsed = false, nil
        if content then
            parsedOk, parsed = pcall(json.decode, content)
        end
        if not parsedOk then
            Matrix.Log('TEAMAI', '[HATA] OpenAI yaniti cozumlenemedi, deterministik varsayilana dusuluyor.')
        end

        local directive = SanitizeDirective(parsedOk and parsed or nil)
        Matrix.TeamAI.Directives[team] = directive

        for _, botId in ipairs(teamIds) do
            local d = Matrix.Dispatches and Matrix.Dispatches[botId]
            if d then d.ai_fsm_matrix = directive end
        end

        local engagementLabel = (directive.lspd_engagement == 'flee') and 'geri cekilme kilitlendi'
            or (directive.lspd_engagement == 'attack') and 'temasta yaylim atesi angajmani'
            or 'sabotaj protokolu'
        local fallbackLabel = directive.fallback_coords and 'guvenli koordinata donuyoruz' or 'en yakin sigina donuyoruz'

        local bulletin = ('[BZZZT] -- Baronum, talimat alindi. %s Lideri konusuyor: Sizma modu %s, LEO temasinda %s, lider duserse %s, muhurlendi!'):format(
            team:upper(),
            directive.sneak_mode and 'aktif' or 'pasif',
            engagementLabel,
            fallbackLabel)

        -- ★ [MODUL 16.2] emri veren Baronun kendi ekranina DOGRUDAN, diger
        -- TUM komuta yetkili Co-Op ortaklarina ise net-event yayiniyla
        -- ULASIR -- yerel kalmaz.
        Reply(src, bulletin)
        Matrix.TeamAI.BroadcastToCommandAuthority(bulletin, src)
    end, 'POST', body, {
        ['Content-Type']  = 'application/json',
        ['Authorization'] = 'Bearer ' .. Config.AI_Matrix_Brain.apiKey
    })
end, false)

-- =====================================================================
-- ★ LEADER DOWN PROTOCOL: OnDealerEliminated'i (server/logistics.lua)
-- SARMALAR (monkeypatch) -- ikinci bir "olum kancasi" ICAT EDILMEZ,
-- MEVCUT permadeath yoluna binilir. Silinmeden ONCE calisir (bot verisi
-- HALA erisilebilir).
-- =====================================================================
function Matrix.TeamAI.HandleLeaderDown(botId)
    local bot = Matrix.Bots[botId]
    if not bot or not bot.state or not bot.state.team then return end
    local team = bot.state.team

    if Matrix.TeamAI.GetTeamLeaderId(team) ~= botId then return end -- lider degildi

    local survivors = {}
    for _, id in ipairs(GetTeamBotIds(team)) do
        if id ~= botId then survivors[#survivors + 1] = id end
    end
    if #survivors == 0 then return end

    local newLeaderId = survivors[1] -- YENI lider = kalanlar arasinda EN DUSUK id (RNG YOK)
    Matrix.Log('TEAMAI', '[LIDER DUSTU] Tim %s -- Bot #%d elendi, Bot #%d yeni tim lideri.', team:upper(), botId, newLeaderId)

    local directive = Matrix.TeamAI.Directives[team]
    local fallback  = directive and directive.fallback_coords
    if not fallback then return end

    for _, id in ipairs(survivors) do
        local survivorBot = Matrix.Bots[id]
        local netId = survivorBot and survivorBot.state and survivorBot.state.net_id
        local ped = (type(netId) == 'number' and netId > 0) and NetworkGetEntityFromNetworkId(netId) or nil
        if ped and ped ~= 0 and DoesEntityExist(ped) then
            pcall(TaskGoToCoordAnyMeans, ped, fallback.x, fallback.y, fallback.z, 2.0, 0, false, 786603, 0xbf800000)
        end
    end
    Matrix.Log('TEAMAI', '[LIDER DUSTU] Tim %s -- %d hayatta kalan AI fallback koordinatina otonom cekiliyor.', team:upper(), #survivors)
end

CreateThread(function()
    Wait(0) -- server/logistics.lua ONCE yuklenmis olmali (fxmanifest sirasi)
    local originalOnDealerEliminated = Matrix.Logistics and Matrix.Logistics.OnDealerEliminated
    if type(originalOnDealerEliminated) ~= 'function' then
        Matrix.Log('TEAMAI', '[HATA] Matrix.Logistics.OnDealerEliminated bulunamadi, Leader Down Protocol devre disi.')
        return
    end

    function Matrix.Logistics.OnDealerEliminated(botId, cause)
        local ok, err = pcall(Matrix.TeamAI.HandleLeaderDown, botId)
        if not ok then
            Matrix.Log('TEAMAI', '[HATA] HandleLeaderDown basarisiz (yutuldu): %s', tostring(err))
        end
        return originalOnDealerEliminated(botId, cause)
    end
end)

exports('GetTeamLeaderId',  function(team) return Matrix.TeamAI.GetTeamLeaderId(team) end)
exports('GetTeamDirective', function(team) return Matrix.TeamAI.Directives[team] end)
