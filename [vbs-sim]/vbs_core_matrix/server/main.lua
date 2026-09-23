-- =====================================================================
-- MATRIX CORE / server/main.lua  (KATMAN 5 ULTIMATE — CO-OP & SIGINT/COMINT)
--
-- ★★★ YAMA 1 (BU SÜRÜM) — [D1-v2] ENVANTER KİLİDİ SERTLEŞTİRME ★★★
--   • CompleteDispatch IO bloğu çift katmanlı doğrulamaya geçti:
--       pcall_ok AND (result == true OR no-op)
--   • is_locked = false YALNIZCA tüm IO op'ları "settled" ise uygulanır.
--   • Boş cargo / birikmiş nakit yok / kanıt yok gibi "no-op" dönüşler
--     SUCCESS sayılır; gerçek AddItem/RemoveItem ret'i FAIL sayılır.
--   • FAIL varsa bot KİLİTLİ kalır — yeni komut /botkilitac ile manuel açılır.
--
-- ★★★ YAMA 4 (BU SÜRÜM) — RELAY + PORTARRIVAL RAM PURGE HOOK ★★★
--   • Matrix.RemoveBot içine additive purge eklendi:
--       Matrix.Logistics.__RelayCooldownByBotId[id] = nil
--       Matrix.Logistics.PortArrivalFlags[id] = nil
--     Bot silindiğinde relay RAM biriktiricileri kazınır.
-- =====================================================================

local pairs, ipairs, next       = pairs, ipairs, next
local type, tostring, tonumber  = type, tostring, tonumber
local table, string, math, os   = table, string, math, os
local setmetatable              = setmetatable
local tonumber, select          = tonumber, select
local math_floor, math_max      = math.floor, math.max
local math_min, math_huge       = math.min, math.huge
local math_rad, math_sin        = math.rad, math.sin
local math_cos, math_abs        = math.cos, math.abs
local math_sqrt                 = math.sqrt

local CreateThread              = CreateThread
local Wait                      = Wait
local CreatePed                 = CreatePed
local CreatePedInsideVehicle    = CreatePedInsideVehicle
local CreateVehicle             = CreateVehicle
local DoesEntityExist           = DoesEntityExist
local DeleteEntity              = DeleteEntity
local SetEntityOrphanMode       = SetEntityOrphanMode
local SetEntityCoords           = SetEntityCoords
local SetEntityCoordsNoOffset   = SetEntityCoordsNoOffset
local SetEntityRoutingBucket    = SetEntityRoutingBucket
local GetHashKey                = GetHashKey
local GetGameTimer              = GetGameTimer
local NetworkGetNetworkIdFromEntity = NetworkGetNetworkIdFromEntity
local NetworkGetEntityFromNetworkId = NetworkGetEntityFromNetworkId
local GetPlayerPed              = GetPlayerPed
local GetEntityCoords           = GetEntityCoords
local GetEntityHeading          = GetEntityHeading
local TaskVehicleDriveToCoord   = TaskVehicleDriveToCoord
local TaskFollowNavMeshToCoord  = TaskFollowNavMeshToCoord
local TriggerClientEvent        = TriggerClientEvent
local RegisterCommand           = RegisterCommand
local RegisterNetEvent          = RegisterNetEvent
local AddEventHandler           = AddEventHandler
local GetCurrentResourceName    = GetCurrentResourceName

Matrix       = Matrix       or {}
Matrix.Bots  = Matrix.Bots  or {}
Matrix.PlayerState = Matrix.PlayerState or {}
Matrix.Inventory   = Matrix.Inventory   or {}
Matrix.PlayerSourceIndex = Matrix.PlayerSourceIndex or {}
Matrix.NextBotId = Matrix.NextBotId or 1
Matrix.Dispatches = Matrix.Dispatches or {}

Matrix.QBX = exports.qbx_core

local PENDING_EVENTS_MAX = 64

local DEALER_PED_MODEL_NAME = 'g_m_y_famdnf_01'

local function ResolveRolePedModel(role)
    local modelName = (Config.BotPedConfiguration and Config.BotPedConfiguration[role])
        or (Config.RoleModels and Config.RoleModels[role])
        or Config.DefaultRoleModel
        or DEALER_PED_MODEL_NAME
    return GetHashKey(modelName), modelName
end

function Matrix.Log(tag, fmt, ...)
    if select('#', ...) > 0 then
        print(('[MATRIX:%s] %s'):format(tag, fmt:format(...)))
    else
        print(('[MATRIX:%s] %s'):format(tag, fmt))
    end
end

function Matrix.Clamp(value, minV, maxV)
    if type(value) ~= 'number' or value ~= value or value == math_huge or value == -math_huge then
        return minV
    end
    if value < minV then return minV end
    if value > maxV then return maxV end
    return value
end

function Matrix.Now() return os.time() end

--- ★ F6/DEBUG PANELİ MİLSİM METİN STANDARDI: çiğ Lua boolean'ı ("true"/
--- "false") hiçbir zaman doğrudan bir oyuncuya/konsola BASILMAZ. Bu tek
--- merkezi formatlayıcı üzerinden askeri-üslup bir durum metnine çevrilir.
--- trueText/falseText verilmezse jenerik "🚨 AKTİF" / "🟢 PASİF" kullanılır.
function Matrix.FormatMilSimStatus(value, trueText, falseText)
    if value then return trueText or '🚨 AKTİF' end
    return falseText or '🟢 PASİF'
end

function Matrix.Inventory.GetSlotMetadata(inventoryId, slot)
    if not inventoryId or not slot then return {} end
    local ok, item = pcall(exports['ox_inventory'].GetSlot, exports['ox_inventory'], inventoryId, slot)
    if not ok or not item or type(item) ~= 'table' then return {} end
    return item.metadata or {}
end

function Matrix.Inventory.MergeMetadata(inventoryId, slot, patch)
    local current = Matrix.Inventory.GetSlotMetadata(inventoryId, slot)
    if type(current) ~= 'table' then current = {} end
    if type(patch) ~= 'table' then return current end
    for key, value in pairs(patch) do current[key] = value end
    pcall(exports['ox_inventory'].SetMetadata, exports['ox_inventory'], inventoryId, slot, current)
    return current
end

Matrix.Radio = Matrix.Radio or {}

function Matrix.Radio.ApplyStatic(targetSrc, intensity, reason)
    if type(targetSrc) ~= 'number' or targetSrc <= 0 then return false end
    intensity = Matrix.Clamp(tonumber(intensity) or 1.0, 0.0, 1.0)

    pcall(function() exports['pma-voice']:SetRadioStatic(targetSrc, intensity) end)
    pcall(function() exports['qb-radio']:SetRadioNoise(targetSrc, intensity) end)

    TriggerClientEvent('matrix:client:applyRadioStatic', targetSrc, intensity, reason or 'unknown')
    return true
end

Matrix.Persistence = {
    dirtyBots        = {},
    lastBotFlush     = 0,
    botFlushMs       = Config.Persistence.BotFlushIntervalMs,
    botFlushMaxBatch = Config.Persistence.BotFlushMaxBatch
}
local P = Matrix.Persistence

function Matrix.MarkBotDirty(botId)
    if botId then P.dirtyBots[botId] = true end
end

local BOT_ROW_SQL = '(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NOW())'
local BOT_UPSERT_HEAD =
    'INSERT INTO matrix_bots (id, dna_id, name, role, status, handler_citizenid, ' ..
    'fear_factor, resilience, snitch_tendency, economic_pressure, cognitive_shifter, skill_chemistry, ' ..
    'skill_cyber, skill_logistics, loyalty_base, ' ..
    'fatigue_level, cortisol_level, withdrawal_index, addiction_level, base_cortisol_recovery_rate, ' ..
    'trap_house_id, updated_at) VALUES '
local BOT_UPSERT_TAIL =
    ' ON DUPLICATE KEY UPDATE ' ..
    'name=VALUES(name), role=VALUES(role), status=VALUES(status), handler_citizenid=VALUES(handler_citizenid), ' ..
    'fear_factor=VALUES(fear_factor), resilience=VALUES(resilience), ' ..
    'snitch_tendency=VALUES(snitch_tendency), economic_pressure=VALUES(economic_pressure), ' ..
    'cognitive_shifter=VALUES(cognitive_shifter), skill_chemistry=VALUES(skill_chemistry), ' ..
    'skill_cyber=VALUES(skill_cyber), skill_logistics=VALUES(skill_logistics), ' ..
    'loyalty_base=VALUES(loyalty_base), ' ..
    'fatigue_level=VALUES(fatigue_level), cortisol_level=VALUES(cortisol_level), ' ..
    'withdrawal_index=VALUES(withdrawal_index), addiction_level=VALUES(addiction_level), ' ..
    'base_cortisol_recovery_rate=VALUES(base_cortisol_recovery_rate), ' ..
    'trap_house_id=VALUES(trap_house_id), updated_at=NOW()'

local function BuildBotUpsert(botList)
    local n = #botList
    if n == 0 then return nil, nil end

    local rows = {}
    for i = 1, n do rows[i] = BOT_ROW_SQL end

    local params = {}
    local idx = 1
    for i = 1, n do
        local b = botList[i]
        params[idx] = b.id                                   ; idx = idx + 1
        params[idx] = b.dna_id                               ; idx = idx + 1
        params[idx] = b.name                                 ; idx = idx + 1
        params[idx] = b.role                                 ; idx = idx + 1
        params[idx] = b.status                               ; idx = idx + 1
        params[idx] = b.handler_citizenid                    ; idx = idx + 1
        params[idx] = b.psychology.fear_factor               ; idx = idx + 1
        params[idx] = b.psychology.resilience                ; idx = idx + 1
        params[idx] = b.psychology.snitch_tendency           ; idx = idx + 1
        params[idx] = b.psychology.economic_pressure         ; idx = idx + 1
        params[idx] = b.psychology.cognitive_shifter         ; idx = idx + 1
        params[idx] = b.psychology.skill_chemistry           ; idx = idx + 1
        params[idx] = b.psychology.skill_cyber               ; idx = idx + 1
        params[idx] = b.psychology.skill_logistics           ; idx = idx + 1
        params[idx] = b.psychology.loyalty_base              ; idx = idx + 1
        params[idx] = b.biology.fatigue_level                ; idx = idx + 1
        params[idx] = b.biology.cortisol_level               ; idx = idx + 1
        params[idx] = b.biology.withdrawal_index             ; idx = idx + 1
        params[idx] = b.biology.addiction_level              ; idx = idx + 1
        params[idx] = b.biology.base_cortisol_recovery_rate  ; idx = idx + 1
        params[idx] = b.state.trap_house_id                  ; idx = idx + 1
    end

    local query = BOT_UPSERT_HEAD .. table.concat(rows, ',') .. BOT_UPSERT_TAIL
    return query, params
end

function Matrix.FlushDirtyBots()
    local dirty = P.dirtyBots
    if not next(dirty) then return 0 end

    local batch, ids, count = {}, {}, 0
    for id in pairs(dirty) do
        local bot = Matrix.Bots[id]
        if bot then
            count = count + 1
            batch[count] = bot
            ids[count] = id
        else
            dirty[id] = nil
        end
        if count >= P.botFlushMaxBatch then break end
    end
    if count == 0 then return 0 end

    local query, params = BuildBotUpsert(batch)
    if not query then return 0 end

    local ok, result = pcall(function()
        return MySQL.transaction.await({ { query = query, values = params } })
    end)
    if ok and result ~= false then
        for i = 1, count do dirty[ids[i]] = nil end
    else
        Matrix.Log('CORE',
            '[HATA][KRITIK] FlushDirtyBots transaction basarisiz -- dirty bayraklar KORUNDU, tekrar denenecek: %s',
            tostring(result))
    end
    return count
end

local function PersistAllBotsSync()
    local batch, count = {}, 0
    for _, bot in pairs(Matrix.Bots) do
        count = count + 1
        batch[count] = bot
    end
    if count == 0 then return end
    local query, params = BuildBotUpsert(batch)
    if query then
        pcall(function() MySQL.query.await(query, params) end)
    end
end

function Matrix.PersistBot(bot)
    if bot and bot.id then P.dirtyBots[bot.id] = true end
end

function Matrix.CreateBotRecord(profile)
    profile = profile or {}
    local id = Matrix.NextBotId
    Matrix.NextBotId = id + 1

    local bot = {
        id     = id,
        dna_id = profile.dna_id or ('DNA-%08d'):format(id),
        name   = profile.name   or ('Operative-%d'):format(id),
        role   = profile.role   or 'runner',
        status = 'active',
        handler_citizenid = profile.handler_citizenid,
        psychology = {
            fear_factor       = Matrix.Clamp(profile.fear_factor or 0.0,       0.0, 1.0),
            resilience        = Matrix.Clamp(profile.resilience or 0.5,        0.0, 1.0),
            snitch_tendency   = Matrix.Clamp(profile.snitch_tendency or 0.0,   0.0, 1.0),
            economic_pressure = Matrix.Clamp(profile.economic_pressure or 0.0, 0.0, 1.0),
            cognitive_shifter = Matrix.Clamp(profile.cognitive_shifter or 0.5, 0.0, 1.0),
            skill_chemistry   = Matrix.Clamp(profile.skill_chemistry or 0.3,   0.0, 1.0),
            skill_cyber       = Matrix.Clamp(profile.skill_cyber or 0.0,       0.0, 1.0),
            skill_logistics   = Matrix.Clamp(profile.skill_logistics or 0.0,   0.0, 1.0),
            loyalty_base      = Matrix.Clamp(profile.loyalty_base or 0.5,      0.0, 1.0)
        },
        biology = {
            fatigue_level             = 0.0,
            cortisol_level            = 0.0,
            withdrawal_index          = 0.0,
            addiction_level           = Matrix.Clamp(profile.addiction_level or 0.0, 0.0, 100.0),
            base_cortisol_recovery_rate = Config.BaseCortisolRecoveryRate,
            fatigue_critical_since    = nil,
            burned_this_episode       = false
        },
        state = {
            activity        = profile.activity or 'idle',
            trap_house_id   = profile.trap_house_id,
            coords          = profile.coords,
            spawned         = false,
            net_id          = nil,
            elapsed_seconds = 0,
            is_locked       = false,
            weapon_wear_level = 1.0,
            interior_trap_house_id = nil
        }
    }

    Matrix.Bots[id] = bot
    Matrix.MarkBotDirty(id)
    Matrix.Log('CORE', 'Bot #%d matrise yazildi: %s (%s)', id, bot.name, bot.role)
    return bot
end

function Matrix.GetBot(id) return Matrix.Bots[id] end

function Matrix.GetBotReadOnly(id, cellName)
    local bot = Matrix.Bots[id]
    if not bot then return nil end
    if not (Matrix.Diagnostics and Matrix.Diagnostics.WrapReadOnlyCell) then
        return bot
    end
    return Matrix.Diagnostics.WrapReadOnlyCell(bot, cellName or ('bot_cell_' .. tostring(id)), id)
end

function Matrix.GetBotDeepCopy(id)
    local bot = Matrix.Bots[id]
    if not bot then return nil end
    if not (Matrix.Diagnostics and Matrix.Diagnostics.DeepCopyCell) then
        return bot
    end
      return Matrix.Diagnostics.DeepCopyCell(bot)
end

function Matrix.RemoveBot(id, reason)
    local bot = Matrix.Bots[id]
    if not bot then return false end

    if Matrix.Dispatches[id] then
        Matrix.DespawnDispatchEntity(id, Matrix.Dispatches[id])
        Matrix.Dispatches[id] = nil
    end

    bot.status = reason or 'burned'
    local query, params = BuildBotUpsert({ bot })
    if query then MySQL.prepare(query, params) end

    -- ★ [OTONOM ALT HUCRE BOLUNMESI]
    if reason == 'deceased' and bot.role == 'Leader' and bot.state and bot.state.trap_house_id then
        local deadLeaderTrapHouseId = bot.state.trap_house_id
        local fragOk, fragErr = pcall(function()
            TriggerEvent('matrix:internal:gangLeaderDeceased', deadLeaderTrapHouseId, id)
        end)
        if not fragOk then
            Matrix.Log('CORE', '[HATA] gangLeaderDeceased yayini basarisiz (yutuldu): %s', tostring(fragErr))
        end
    end

    -- ★★★ [YAMA 4] RELAY + PORTARRIVAL RAM PURGE ★★★
    if Matrix.Logistics then
        if Matrix.Logistics.__RelayCooldownByBotId then
            Matrix.Logistics.__RelayCooldownByBotId[id] = nil
        end
        if Matrix.Logistics.PortArrivalFlags then
            Matrix.Logistics.PortArrivalFlags[id] = nil
        end
    end

    P.dirtyBots[id] = nil
    Matrix.Bots[id] = nil
    Matrix.Log('CORE', 'Bot #%d aktif matristen kaldirildi: %s', id, bot.status)
    return true
end

-- =====================================================================
-- ACTOR RESOLUTION
-- =====================================================================
function Matrix.ResolveActor(actorRef)
    if type(actorRef) ~= 'table' then return nil end
    if actorRef.kind == 'bot' and actorRef.id then
        return Matrix.Bots[actorRef.id]
    end
    if actorRef.kind == 'player' and type(actorRef.source) == 'number' then
        return Matrix.GetOrCreatePlayerState(actorRef.source)
    end
    return nil
end

function Matrix.GetOrCreatePlayerState(src)
    if type(src) ~= 'number' or src <= 0 then return nil end

    local ok, player = pcall(function() return Matrix.QBX:GetPlayer(src) end)
    if not ok or not player or not player.PlayerData then return nil end
    local citizenid = player.PlayerData.citizenid
    if not citizenid then return nil end

    local state = Matrix.PlayerState[citizenid]
    if state then
        Matrix.DecayPlayerCortisol(state)
        Matrix.PlayerSourceIndex[src] = citizenid
        return state
    end

    state = {
        id         = citizenid,
        citizenid  = citizenid,
        dna_id     = ('DNA-PLR-%s'):format(citizenid),
        psychology = { skill_chemistry = Config.Player.DefaultSkillChemistry },
        biology    = {
            fatigue_level             = 0.0,
            cortisol_level            = 0.0,
            resilience                = Config.Player.DefaultResilience,
            base_cortisol_recovery_rate = Config.BaseCortisolRecoveryRate,
            last_update               = Matrix.Now()
        },
        state = { activity = 'idle' }
    }

    Matrix.PlayerState[citizenid]       = state
    Matrix.PlayerSourceIndex[src]       = citizenid

    pcall(function()
        MySQL.prepare([[
            INSERT INTO matrix_player_state (citizenid, cortisol_level, fatigue_level, updated_at)
            VALUES (?, 0.0, 0.0, NOW())
            ON DUPLICATE KEY UPDATE citizenid = citizenid
        ]], { citizenid })
    end)

    return state
end

function Matrix.DecayPlayerCortisol(state)
    if not state or not state.biology then return end
    local now = Matrix.Now()
    local last = state.biology.last_update or now
    local elapsedMinutes = math_floor((now - last) / 60)
    if elapsedMinutes <= 0 then return end

    local recovery = state.biology.base_cortisol_recovery_rate
                     * state.biology.resilience
                     * elapsedMinutes
    state.biology.cortisol_level = Matrix.Clamp(state.biology.cortisol_level - recovery, 0.0, 1.0)
    state.biology.last_update    = last + (elapsedMinutes * 60)
end

AddEventHandler('qbx_core:server:onPlayerLoaded', function(payload)
    local src
    if type(payload) == 'table' then
        src = tonumber(payload.source or payload.src or payload[1])
    else
        src = tonumber(payload)
    end
    if not src or src <= 0 then return end
    Matrix.GetOrCreatePlayerState(src)
end)

AddEventHandler('QBCore:Server:PlayerLoaded', function(player)
    if type(player) ~= 'table' or not player.PlayerData then return end
    local src = tonumber(player.PlayerData.source)
    if src and src > 0 then Matrix.GetOrCreatePlayerState(src) end
end)

local function LoadBotsFromDatabase()
    local rows = MySQL.query.await('SELECT * FROM matrix_bots WHERE status = ?', { 'active' }) or {}
    for _, row in ipairs(rows) do
        Matrix.Bots[row.id] = {
            id = row.id, dna_id = row.dna_id, name = row.name,
            role = row.role, status = row.status,
            handler_citizenid = row.handler_citizenid,
            psychology = {
                fear_factor       = row.fear_factor       or 0.0,
                resilience        = row.resilience        or 0.5,
                snitch_tendency   = row.snitch_tendency   or 0.0,
                economic_pressure = row.economic_pressure or 0.0,
                cognitive_shifter = row.cognitive_shifter or 0.5,
                skill_chemistry   = row.skill_chemistry   or 0.3,
                skill_cyber       = row.skill_cyber       or 0.0,
                skill_logistics   = row.skill_logistics   or 0.0,
                loyalty_base      = row.loyalty_base      or 0.5
            },
            biology = {
                fatigue_level             = row.fatigue_level              or 0.0,
                cortisol_level            = row.cortisol_level             or 0.0,
                withdrawal_index          = row.withdrawal_index           or 0.0,
                addiction_level           = row.addiction_level            or 0.0,
                base_cortisol_recovery_rate = row.base_cortisol_recovery_rate or Config.BaseCortisolRecoveryRate,
                fatigue_critical_since    = nil,
                burned_this_episode       = false
            },
            state = {
                activity        = 'idle',
                trap_house_id   = row.trap_house_id,
                coords          = nil,
                spawned         = false,
                net_id          = nil,
                elapsed_seconds = 0,
                is_locked       = false,
                weapon_wear_level = 1.0,
                interior_trap_house_id = nil
            }
        }
        if row.id >= Matrix.NextBotId then Matrix.NextBotId = row.id + 1 end
    end
    Matrix.Log('CORE', '%d bot matristen belleğe yüklendi.', #rows)
end

local MATRIX_PED_INJECTION_MAX_TICKS   = 50
local MATRIX_PED_INJECTION_POLL_MS     = 10

local function AwaitEntityCreation(entity, maxTicks)
    local ticks = 0
    maxTicks = maxTicks or MATRIX_PED_INJECTION_MAX_TICKS
    while not DoesEntityExist(entity) and ticks < maxTicks do
        Wait(MATRIX_PED_INJECTION_POLL_MS)
        ticks = ticks + 1
    end
    return DoesEntityExist(entity)
end
Matrix.AwaitEntityCreation = AwaitEntityCreation

local function SafeDeleteEntity(handle)
    if not handle or handle == 0 then return end
    local ok = pcall(function()
        if DoesEntityExist(handle) then
            DeleteEntity(handle)
        end
    end)
    return ok
end

function Matrix.SpawnBot(id, coords)
    local bot = Matrix.Bots[id]
    if not bot then return false, 'bot_missing' end
    if bot.state.spawned then return false, 'already_spawned' end
    if type(coords) ~= 'vector4' and type(coords) ~= 'vector3' then
        return false, 'bad_coords'
    end

    local modelHash, modelName = ResolveRolePedModel(bot.role)
    local x, y, z   = coords.x, coords.y, coords.z
    local heading   = coords.w or 0.0

    local ped = CreatePed(0, modelHash, x, y, z, heading, true, true)
    if not AwaitEntityCreation(ped) then
        SafeDeleteEntity(ped)
        Matrix.Log('CORE', '[HATA] Bot #%d OneSync ped doğrulaması zaman aşımı.', id)
        return false, 'timeout'
    end

    pcall(SetEntityOrphanMode, ped, 2)
    local netId = NetworkGetNetworkIdFromEntity(ped)

    bot.state.spawned = true
    bot.state.net_id  = netId
    bot.state.coords  = vector3(x, y, z)

    TriggerClientEvent('matrix:client:injectBot', -1, id, bot.role, coords, bot.dna_id, netId)
    Matrix.Log('CORE', 'Bot #%d enjekte edildi [%s / %s] NetID:%d', id, bot.role, modelName, netId)
    return true, netId
end

function Matrix.DespawnBot(id)
    local bot = Matrix.Bots[id]
    if not bot then return false end
    if not bot.state.spawned then return false end

    if bot.state.net_id then
        local ped = NetworkGetEntityFromNetworkId(bot.state.net_id)
        if ped and ped ~= 0 and DoesEntityExist(ped) then SafeDeleteEntity(ped) end
    end

    TriggerClientEvent('matrix:client:extractBot', -1, id)
    bot.state.spawned = false
    bot.state.net_id  = nil
    Matrix.Log('CORE', 'Bot #%d dünyadan çekildi.', id)
    return true
end

local DISPATCH_VEHICLE_MODELS = {
    car       = 'sultan',
    motorbike = 'bati',
}

local DISPATCH_ARRIVAL_RADIUS_M       = 6.0
local DISPATCH_POLICE_PROXIMITY_M     = 60.0
local DISPATCH_POLICE_DECRYPT_TICK    = 0.015
local DISPATCH_BUSTED_PROXIMITY_M     = 8.0
local DISPATCH_BUSTED_DWELL_TICKS     = 8
local DISPATCH_ALPR_RADIUS_M          = 250.0
local DISPATCH_TASK_REISSUE_TICKS     = 25

local NAVMESH_TASK_TIMEOUT            = -1
local NAVMESH_STOPPING_RANGE_M        = 0.0
local NAVMESH_PERSIST_FOLLOWING       = false

local DISPATCH_BASE_FOOT_SPEED_MS     = 1.4
local DISPATCH_BASE_VEHICLE_SPEED_MS  = 15.0
local DISPATCH_MIN_SPEED_FRACTION     = 0.25

local PANIC_EVAC_VEHICLE_SPEED_MS     = 25.0
local PANIC_EVAC_FOOT_SPEED_MS        = 4.0
local PANIC_REISSUE_TICKS             = 5

local PoliceSources       = {}
local policeFailCount     = 0
local policeDisabledUntil = 0

local function RefreshPoliceCache()
    if Matrix.Now() < policeDisabledUntil then return end

    local ok, players = pcall(function() return Matrix.QBX:GetQBPlayers() end)
    if not ok or type(players) ~= 'table' then
        policeFailCount = policeFailCount + 1
        if policeFailCount >= 5 then
            policeDisabledUntil = Matrix.Now() + 60
            policeFailCount = 0
            Matrix.Log('CORE', '[UYARI] GetQBPlayers 5 kez ust uste basarisiz oldu; 60sn devre disi birakildi.')
        end
        return
    end
    policeFailCount = 0

    local fresh = {}
    for src, player in pairs(players) do
        if player and player.PlayerData and player.PlayerData.job then
            local job = player.PlayerData.job
            if job.onduty and (job.name == 'police' or job.name == 'sheriff' or job.type == 'leo') then
                fresh[src] = true
            end
        end
    end
    PoliceSources = fresh
end

--- ★ [SEC] Tek doğruluk kaynağı: bir src'in GÖREVDE polis/şerif/LEO olup
--- olmadığını CANLI (cache'e bağımlı olmadan) sorgular -- bureau.lua'nın
--- polis-gated komutları (davaac/davasorgula/polisgenetigi) bunu kullanır.
--- PoliceSources RAM önbelleği yalnızca performans-kritik dispatch tarama
--- döngüsü içindir (5sn TTL) -- yetki kararları için CANLI veri tercih edilir.
function Matrix.IsOnDutyPolice(src)
    if type(src) ~= 'number' or src <= 0 then return false end
    local ok, player = pcall(function() return Matrix.QBX:GetPlayer(src) end)
    if not ok or not player or not player.PlayerData or not player.PlayerData.job then return false end
    local job = player.PlayerData.job
    return job.onduty and (job.name == 'police' or job.name == 'sheriff' or job.type == 'leo') or false
end

CreateThread(function()
    while true do
        Wait(5000)
        RefreshPoliceCache()
    end
end)

local function LocalGetVehicleProfile(vehicleType)
    return Config.Logistics.VehicleTypes[vehicleType]
        or Config.Logistics.VehicleTypes[Config.Logistics.DefaultVehicleType]
end

local function LocalGetBotInventoryWeight(bot)
    local inventoryId = ('dealer_%d'):format(bot.id)
    local ok, inv = pcall(exports['ox_inventory'].GetInventory, exports['ox_inventory'], inventoryId)
    if not ok or type(inv) ~= 'table' or type(inv.items) ~= 'table' then return 0.0 end
    local total = 0.0
    for _, item in pairs(inv.items) do
        if type(item) == 'table' then
            total = total + ((tonumber(item.weight) or 0.0) * (tonumber(item.count) or 0.0))
        end
    end
    return total
end

local function FindNearestTrapHouse(coords)
    local nearestId, nearestDist = nil, math_huge
    for id, house in pairs(Matrix.TrapHouses or {}) do
        local d = #(coords - house.coords)
        if d < nearestDist then nearestId, nearestDist = id, d end
    end
    return nearestId, nearestDist
end

local function FindDeadZone(coords)
    for _, zone in ipairs(Config.Logistics.DeadZones) do
        if #(coords - zone.coords) <= zone.radius then return zone end
    end
    return nil
end

local function FindActiveDeadDropAt(destination)
    for _, drop in ipairs(Config.Supplier.DeadDrops) do
        if #(destination - drop.coords) <= drop.radius then return drop end
    end
    return nil
end

local function _SafeVec(v)
    return v and v.x == v.x and v.y == v.y and v.z == v.z
           and v.x ~= math_huge and v.x ~= -math_huge
           and v.y ~= math_huge and v.y ~= -math_huge
           and v.z ~= math_huge and v.z ~= -math_huge
end

local function _ToVec3(v)
    if type(v) == 'vector4' then return vector3(v.x, v.y, v.z) end
    return v
end

local function SpawnDispatchActors(bot, origin, vehicleType, cruiseSpeed, firstDestination)
    local pedHash = ResolveRolePedModel(bot.role)
    local isFoot  = (vehicleType == 'foot')

    local ped, vehicle
    local vehicleNetId = nil

    if isFoot then
        ped = CreatePed(0, pedHash, origin.x, origin.y, origin.z, 0.0, true, true)
        if not AwaitEntityCreation(ped) then
            SafeDeleteEntity(ped)
            return nil, nil, nil, nil, 'ped_spawn_timeout'
        end
        pcall(SetEntityOrphanMode, ped, 2)
        pcall(SetEntityRoutingBucket, ped, 0)
        SetEntityCoords(ped, origin.x, origin.y, origin.z, false, false, false, false)

        local taskOk = pcall(TaskFollowNavMeshToCoord,
            ped,
            firstDestination.x, firstDestination.y, firstDestination.z,
            cruiseSpeed, NAVMESH_TASK_TIMEOUT, NAVMESH_STOPPING_RANGE_M,
            NAVMESH_PERSIST_FOLLOWING, 0.0
        )
        if not taskOk then
            SafeDeleteEntity(ped)
            return nil, nil, nil, nil, 'task_assignment_failed'
        end
    else
        local vehModelName = DISPATCH_VEHICLE_MODELS[vehicleType] or DISPATCH_VEHICLE_MODELS.car
        local vehHash      = GetHashKey(vehModelName)

        vehicle = CreateVehicle(vehHash, origin.x, origin.y, origin.z, 0.0, true, true)
        if not AwaitEntityCreation(vehicle) then
            SafeDeleteEntity(vehicle)
            return nil, nil, nil, nil, 'vehicle_spawn_timeout'
        end
        pcall(SetEntityOrphanMode, vehicle, 2)
        pcall(SetEntityRoutingBucket, vehicle, 0)

        ped = CreatePedInsideVehicle(vehicle, 0, pedHash, -1, true, true)
        if not AwaitEntityCreation(ped) then
            SafeDeleteEntity(ped)
            SafeDeleteEntity(vehicle)
            return nil, nil, nil, nil, 'ped_in_vehicle_timeout'
        end
        pcall(SetEntityOrphanMode, ped, 2)
        pcall(SetEntityRoutingBucket, ped, 0)

        local taskOk = pcall(TaskVehicleDriveToCoord,
            ped,
            vehicle,
            firstDestination.x, firstDestination.y, firstDestination.z,
            cruiseSpeed,
            0,
            vehHash,
            16777216,
            5.0,
            1
        )
        if not taskOk then
            SafeDeleteEntity(ped)
            SafeDeleteEntity(vehicle)
            return nil, nil, nil, nil, 'task_assignment_failed'
        end

        vehicleNetId = NetworkGetNetworkIdFromEntity(vehicle)
    end

    local pedNetId = NetworkGetNetworkIdFromEntity(ped)
    return ped, vehicle, pedNetId, vehicleNetId, nil
end

local function ResolveExteriorBridgeOrigin(bot, requestedOrigin)
    local interiorTrapId = bot.state.interior_trap_house_id
    if not interiorTrapId then
        return requestedOrigin, false
    end

    bot.state.interior_trap_house_id = nil
    if Matrix.TrapHouseInterior and Matrix.TrapHouseInterior.ClearStashRunMark then
        Matrix.TrapHouseInterior.ClearStashRunMark(bot.id)
    end

    local house = Matrix.TrapHouses and Matrix.TrapHouses[interiorTrapId]
    if not house or not _SafeVec(house.coords) then
        Matrix.Log('CORE',
            '[UYARI] Bot #%d interior köprüsü için trap house #%s bulunamadı; orijinal origin kullanıldı.',
            bot.id, tostring(interiorTrapId))
        return requestedOrigin, false
    end

    Matrix.Log('CORE',
        '[CIKIS KOPRUSU] Bot #%d GTA Online interior hücresinden (trap #%d) harita yüzeyindeki fiziki kapı koordinatına çıkartıldı: (%.1f,%.1f,%.1f)',
        bot.id, interiorTrapId, house.coords.x, house.coords.y, house.coords.z)

    return house.coords, true
end

function Matrix.SetBotInteriorTrapHouse(botId, trapHouseId)
    local bot = Matrix.Bots[botId]
    if not bot then return false end
    bot.state.interior_trap_house_id = trapHouseId
    return true
end

function Matrix.BeginPhysicalDispatch(botId, origin, destination, plate, vehicleType, etaSeconds, dispatcherSrc, frictionDivisor)
    botId = tonumber(botId)
    if not botId then return false, 'bad_bot_id' end

    frictionDivisor = Matrix.Clamp(tonumber(frictionDivisor) or 1.0, 1.0, 1.0 / DISPATCH_MIN_SPEED_FRACTION)

    local bot = Matrix.Bots[botId]
    if not bot then return false, 'bot_missing' end
    if bot.state.is_locked then return false, 'bot_locked' end
    if Matrix.Dispatches[botId] then return false, 'already_dispatched' end
    if type(origin) ~= 'vector3' and type(origin) ~= 'vector4' then return false, 'bad_origin' end
    if type(destination) ~= 'vector3' and type(destination) ~= 'vector4' then return false, 'bad_destination' end

    origin      = _ToVec3(origin)
    destination = _ToVec3(destination)

    local bridged
    origin, bridged = ResolveExteriorBridgeOrigin(bot, origin)

    if not _SafeVec(origin) or not _SafeVec(destination) then
        return false, 'corrupt_vector'
    end

    if not bridged and #(origin - destination) < Config.Logistics.MinDispatchDistanceMeters then
        return false, 'too_close'
    end

    if bot.state.spawned then
        Matrix.DespawnBot(botId)
        Wait(50)
    end

    local isFoot      = (vehicleType == 'foot')
    local baseSpeed    = isFoot and DISPATCH_BASE_FOOT_SPEED_MS or DISPATCH_BASE_VEHICLE_SPEED_MS
    local cruiseSpeed  = math_max(baseSpeed / frictionDivisor, baseSpeed * DISPATCH_MIN_SPEED_FRACTION)

    local ped, vehicle, pedNetId, vehicleNetId, spawnErr =
        SpawnDispatchActors(bot, origin, vehicleType, cruiseSpeed, destination)
    if spawnErr then return false, spawnErr end

    bot.state.spawned    = true
    bot.state.net_id     = pedNetId
    bot.state.is_locked  = true

    Matrix.Dispatches[botId] = {
        bot_id            = botId,
        entity_net_id     = pedNetId,
        vehicle_net_id    = vehicleNetId,
        plate             = plate,
        vehicle_type      = vehicleType,
        profile           = LocalGetVehicleProfile(vehicleType),
        origin            = origin,
        destination       = destination,
        route_queue       = nil,
        route_index       = nil,
        eta_estimate      = etaSeconds or 0.0,
        cruise_speed      = cruiseSpeed,
        elapsed           = 0.0,
        last_coords       = origin,
        weight_total      = LocalGetBotInventoryWeight(bot),
        dispatcher_src    = dispatcherSrc,
        comms_lost        = false,
        pending_events    = {},
        alpr_logged_traps = {},
        combat_damage     = 0.0,
        police_dwell      = 0,
        task_retry_ticks  = 0,
        started_at        = Matrix.Now()
    }

    bot.state.activity = 'distribution'

    TriggerClientEvent('matrix:client:injectBot', -1, botId, bot.role, origin, bot.dna_id, pedNetId)

    Matrix.Log('CORE',
        'Fiziksel sevk başlatıldı: Bot #%d [%s] Origin=(%.1f,%.1f,%.1f) → Hedef=(%.1f,%.1f,%.1f)',
        botId, vehicleType, origin.x, origin.y, origin.z, destination.x, destination.y, destination.z)

    return true
end

function Matrix.BeginRouteDispatch(botId, origin, waypointRefs, finalRef, plate, vehicleType, dispatcherSrc, frictionDivisor)
    botId = tonumber(botId)
    if not botId then return false, 'bad_bot_id' end

    frictionDivisor = Matrix.Clamp(tonumber(frictionDivisor) or 1.0, 1.0, 1.0 / DISPATCH_MIN_SPEED_FRACTION)

    local bot = Matrix.Bots[botId]
    if not bot then return false, 'bot_missing' end
    if bot.state.is_locked then return false, 'bot_locked' end
    if Matrix.Dispatches[botId] then return false, 'already_dispatched' end
    if type(origin) ~= 'vector3' and type(origin) ~= 'vector4' then return false, 'bad_origin' end
    if type(waypointRefs) ~= 'table' then return false, 'bad_waypoints' end
    if type(finalRef) ~= 'vector3' and type(finalRef) ~= 'vector4' then return false, 'bad_destination' end

    origin   = _ToVec3(origin)
    finalRef = _ToVec3(finalRef)
    for i = 1, #waypointRefs do
        waypointRefs[i] = _ToVec3(waypointRefs[i])
    end

    local bridged
    origin, bridged = ResolveExteriorBridgeOrigin(bot, origin)

    if not _SafeVec(origin) or not _SafeVec(finalRef) then return false, 'corrupt_vector' end
    for i = 1, #waypointRefs do
        if not _SafeVec(waypointRefs[i]) then return false, 'corrupt_vector' end
    end

    local routeQueue = {}
    for i = 1, #waypointRefs do routeQueue[i] = waypointRefs[i] end
    routeQueue[#routeQueue + 1] = finalRef

    local legOrigin = origin
    for i = 1, #routeQueue do
        local legDest = routeQueue[i]
        local legDist = #(legOrigin - legDest)
        if not (bridged and i == 1) and legDist < Config.Logistics.MinDispatchDistanceMeters then
            return false, 'too_close', i, legDist
        end
        legOrigin = legDest
    end

    if bot.state.spawned then
        Matrix.DespawnBot(botId)
        Wait(50)
    end

    local isFoot      = (vehicleType == 'foot')
    local baseSpeed    = isFoot and DISPATCH_BASE_FOOT_SPEED_MS or DISPATCH_BASE_VEHICLE_SPEED_MS
    local cruiseSpeed  = math_max(baseSpeed / frictionDivisor, baseSpeed * DISPATCH_MIN_SPEED_FRACTION)

    local ped, vehicle, pedNetId, vehicleNetId, spawnErr =
        SpawnDispatchActors(bot, origin, vehicleType, cruiseSpeed, routeQueue[1])
    if spawnErr then return false, spawnErr end

    bot.state.spawned    = true
    bot.state.net_id     = pedNetId
    bot.state.is_locked  = true

    Matrix.Dispatches[botId] = {
        bot_id            = botId,
        entity_net_id     = pedNetId,
        vehicle_net_id    = vehicleNetId,
        plate             = plate,
        vehicle_type      = vehicleType,
        profile           = LocalGetVehicleProfile(vehicleType),
        origin            = origin,
        destination       = routeQueue[1],
        route_queue       = routeQueue,
        route_index       = 1,
        eta_estimate      = 0.0,
        cruise_speed      = cruiseSpeed,
        elapsed           = 0.0,
        last_coords       = origin,
        weight_total      = LocalGetBotInventoryWeight(bot),
        dispatcher_src    = dispatcherSrc,
        comms_lost        = false,
        pending_events    = {},
        alpr_logged_traps = {},
        combat_damage     = 0.0,
        police_dwell      = 0,
        task_retry_ticks  = 0,
        started_at        = Matrix.Now()
    }

    bot.state.activity = 'distribution'

    TriggerClientEvent('matrix:client:injectBot', -1, botId, bot.role, origin, bot.dna_id, pedNetId)

    Matrix.Log('CORE',
        'Multi-Waypoint rota başlatıldı: Bot #%d [%s] %d ara nokta + final hedef.',
        botId, vehicleType, #waypointRefs)

    return true
end

function Matrix.DepositDealerCargoToTrapStash(botId, trapHouseId)
    local inventoryId = ('dealer_%d'):format(botId)
    local stashId      = ('matrix_trap_stash_%d'):format(trapHouseId)

    local invOk, inv = pcall(exports['ox_inventory'].GetInventory, exports['ox_inventory'], inventoryId)
    if not invOk or type(inv) ~= 'table' or type(inv.items) ~= 'table' then return false end

    local house = Matrix.TrapHouses and Matrix.TrapHouses[trapHouseId]
    local stashLabel = (house and house.label and ('%s Deposu'):format(house.label))
        or ('Trap House #%d Deposu'):format(trapHouseId)

    pcall(function()
        exports['ox_inventory']:RegisterStash(stashId, stashLabel, 100, 200000)
    end)

    local movedAny        = false
    -- ★ [D1-v2] IO MÜHRÜ: bu bayrak yalnızca "hiç eşya yoktu" (no-op) ile
    -- "bir eşya gerçekten kayboldu" (remove basarili + add basarisiz + telafi
    -- de basarisiz, YA DA RemoveItem pcall'ı patladı) durumlarını AYIRT ETMEK
    -- içindir. movedAny=false HER ZAMAN "güvenli" değildir -- bu yüzden
    -- CompleteDispatch artık movedAny'ye değil, bu ikinci değere bakarak
    -- is_locked=false kilidini açar.
    local ioIntegrityIntact = true
    for slot, item in pairs(inv.items) do
        if type(item) == 'table' and type(item.name) == 'string' and (tonumber(item.count) or 0) > 0 then
            local itemName, itemCount, itemMeta = item.name, item.count, item.metadata

            local removeOk, removed = pcall(function()
                return exports['ox_inventory']:RemoveItem(inventoryId, itemName, itemCount, itemMeta, slot)
            end)

            if not removeOk then
                ioIntegrityIntact = false
                Matrix.Log('CORE',
                    '[KRITIK] DepositDealerCargoToTrapStash: Bot #%d, esya (%s x%s) RemoveItem pcall hatasi: %s',
                    botId, tostring(itemName), tostring(itemCount), tostring(removed))
            elseif removed == true then
                local addOk, added = pcall(function()
                    return exports['ox_inventory']:AddItem(stashId, itemName, itemCount, itemMeta)
                end)

                if addOk and added == true then
                    movedAny = true
                else
                    local restoreOk, restored = pcall(function()
                        return exports['ox_inventory']:AddItem(inventoryId, itemName, itemCount, itemMeta)
                    end)
                    if not (restoreOk and restored == true) then
                        ioIntegrityIntact = false
                        Matrix.Log('CORE',
                            '[KRITIK] DepositDealerCargoToTrapStash: Bot #%d, esya (%s x%s) AddItem+telafi ikisi de basarisiz -- olasi kayip.',
                            botId, tostring(itemName), tostring(itemCount))
                    end
                end
            end
            -- removeOk==true and removed~=true: esya zaten kaynakta yok/RemoveItem
            -- reddetti -- hicbir sey degismedi, bu bir IO basarisizligi DEGILDIR.
        end
    end

    if movedAny then
        Matrix.Log('CORE',
            '[OTOMATIK TESLIMAT] Bot #%d yuku Trap House #%d deposuna (%s) aktarildi, kutle hafifledi.',
            botId, trapHouseId, stashId)
    end
    -- ★ Boş kargo (pairs döngüsü hiç çalışmadı) → movedAny=false AMA
    -- ioIntegrityIntact=true kalır: bu, mühürü aldatan sahte bir "true" değil,
    -- gerçek bir no-op'un dürüst yansımasıdır. Çağıran (CompleteDispatch)
    -- ikinci değeri kullanarak is_locked=false kararını SADECE fiili IO
    -- tescili tamlığına bağlar.
    return movedAny, ioIntegrityIntact
end

-- =====================================================================
-- ★★★ [YAMA 1] CompleteDispatch — [D1-v2] IO SEAL ★★★
-- =====================================================================
function Matrix.CompleteDispatch(botId, reason)
    local dispatch = Matrix.Dispatches[botId]
    if not dispatch then return false end

    local pedNetId     = dispatch.entity_net_id
    local vehicleNetId = dispatch.vehicle_net_id
    local plate        = dispatch.plate
    local destination  = dispatch.destination
    local lastCoords   = dispatch.last_coords
    local ammoRunTargetBotId = dispatch.ammo_run_target_bot_id

    Matrix.Dispatches[botId] = nil

    local inventoryOpsTotal   = 0
    local inventoryOpsFailed  = 0

    local function _TrackIO(noOpIsSuccess, fn)
        inventoryOpsTotal = inventoryOpsTotal + 1
        local ok, result = pcall(fn)
        if not ok then
            inventoryOpsFailed = inventoryOpsFailed + 1
            Matrix.Log('CORE',
                '[D1-v2] IO op FAIL (pcall): %s', tostring(result))
            return false
        end
        if noOpIsSuccess then
            if result == true or result == false then
                return true
            end
            inventoryOpsFailed = inventoryOpsFailed + 1
            Matrix.Log('CORE',
                '[D1-v2] IO op FAIL (unexpected return type=%s)', type(result))
            return false
        else
            if result == true then return true end
            inventoryOpsFailed = inventoryOpsFailed + 1
            return false
        end
    end

    local bot = Matrix.Bots[botId]
    if bot then
        if reason == 'arrived' then
            bot.state.activity = 'idle'
            bot.state.coords   = destination

            local drop = FindActiveDeadDropAt(destination)
            if drop and Matrix.Supplier and Matrix.Supplier.OnPickup then
                pcall(Matrix.Supplier.OnPickup, { kind = 'bot', id = botId }, drop.id, nil)
            end

            if ammoRunTargetBotId and Matrix.Logistics and Matrix.Logistics.OnAmmoRunArrived then
                local ammoOk, ammoErr = pcall(Matrix.Logistics.OnAmmoRunArrived, botId, ammoRunTargetBotId, destination)
                if not ammoOk then
                    Matrix.Log('CORE', '[HATA] OnAmmoRunArrived basarisiz (yutuldu): %s', tostring(ammoErr))
                end
            end

            local nearestTrapId, nearestTrapDist = FindNearestTrapHouse(destination)
            if nearestTrapId and nearestTrapDist <= Config.Logistics.TrapHouseArrivalStashRadius then
                -- ★ [D1-v2] _TrackIO(true, fn) tek dönüş değerine bakar ve
                -- movedAny==false'u (boş kargo no-op) HER ZAMAN "başarılı"
                -- sayardı -- bu, mühürü aldatan boşluktu. Burada ikinci
                -- dönüş değerini (ioIntegrityIntact) DOĞRUDAN sayaca işleyip
                -- gerçek bir kayıp/pcall hatasını IO FAIL olarak isaretliyoruz.
                inventoryOpsTotal = inventoryOpsTotal + 1
                local trackOk, _movedAny, ioIntegrityIntact = pcall(
                    Matrix.DepositDealerCargoToTrapStash, botId, nearestTrapId)
                if not trackOk or ioIntegrityIntact == false then
                    inventoryOpsFailed = inventoryOpsFailed + 1
                    Matrix.Log('CORE',
                        '[D1-v2] IO op FAIL (trap-stash deposit): %s',
                        tostring(not trackOk and _movedAny or 'esya kalici kayip -- ioIntegrityIntact=false'))
                end

                if Matrix.Market and Matrix.Market.FlushBotStreetCash then
                    _TrackIO(true, function()
                        return Matrix.Market.FlushBotStreetCash(botId, nearestTrapId)
                    end)
                end
            end
        elseif reason == 'busted' then
            local nearestId = FindNearestTrapHouse(lastCoords or destination)
            if nearestId then
                if Matrix.Kitchen and Matrix.Kitchen.OnCaptured then
                    pcall(Matrix.Kitchen.OnCaptured, botId, nearestId)
                end
            end

            if Matrix.Forensics and Matrix.Forensics.InspectBustedBot then
                _TrackIO(true, function()
                    return Matrix.Forensics.InspectBustedBot(botId, nearestId, plate)
                end)
            end

            if Matrix.Market and Matrix.Market.SeizeBotStreetCash then
                _TrackIO(true, function()
                    return Matrix.Market.SeizeBotStreetCash(botId)
                end)
            end

            if Matrix.Logistics and Matrix.Logistics.OnDealerEliminated then
                pcall(Matrix.Logistics.OnDealerEliminated, botId, 'police_busted')
            end
        end
    end

    local inventoryOpsSettled = (inventoryOpsFailed == 0)
    if not inventoryOpsSettled then
        Matrix.Log('CORE',
            '[D1-v2][IO MÜHRÜ] Bot #%d: %d/%d IO op BASARISIZ -- is_locked KİLİTLİ KALDI. /botkilitac ile manuel acilabilir.',
            botId, inventoryOpsFailed, inventoryOpsTotal)
    end

    if plate and Matrix.Logistics and Matrix.Logistics.ReleaseVehicleLock then
        pcall(Matrix.Logistics.ReleaseVehicleLock, plate)
    end

    if pedNetId then
        local ped = NetworkGetEntityFromNetworkId(pedNetId)
        if ped and ped ~= 0 and DoesEntityExist(ped) then SafeDeleteEntity(ped) end
    end
    if vehicleNetId then
        local veh = NetworkGetEntityFromNetworkId(vehicleNetId)
        if veh and veh ~= 0 and DoesEntityExist(veh) then SafeDeleteEntity(veh) end
    end

    if bot then
        bot.state.spawned   = false
        bot.state.net_id    = nil
        if inventoryOpsSettled then
            bot.state.is_locked = false
        else
            bot.state.is_locked = true
        end
    end

    TriggerClientEvent('matrix:client:extractBot', -1, botId)
    Matrix.Log('CORE', '[SEVK SONLANDI] Bot #%d Sebep:%s', botId, tostring(reason or 'unknown'))
    return true
end

function Matrix.TriggerPanicEvacuation(botId, dispatcherSrc)
    botId = tonumber(botId)
    if not botId then return false, 'bad_bot_id' end

    local bot = Matrix.Bots[botId]
    if not bot then return false, 'bot_missing' end

    local dispatch = Matrix.Dispatches[botId]
    if not dispatch then return false, 'not_dispatched' end

    if type(dispatcherSrc) ~= 'number' or dispatcherSrc <= 0 then return false, 'bad_dispatcher' end
    local dispatcherPed = GetPlayerPed(dispatcherSrc)
    if not dispatcherPed or dispatcherPed == 0 then return false, 'dispatcher_ped_missing' end

    do
        local dState = Matrix.GetOrCreatePlayerState(dispatcherSrc)
        if dState and dState.citizenid and Matrix.RadioSilence
            and Matrix.RadioSilence.IsActive and Matrix.RadioSilence.IsActive(dState.citizenid)
            and Matrix.RadioSilence.BreakForRedirect then
            pcall(Matrix.RadioSilence.BreakForRedirect, dState.citizenid, botId, bot.state.trap_house_id)
        end
    end

    local ped = NetworkGetEntityFromNetworkId(dispatch.entity_net_id)
    if not ped or ped == 0 or not DoesEntityExist(ped) then return false, 'entity_missing' end

    local veh = nil
    if dispatch.vehicle_net_id then
        veh = NetworkGetEntityFromNetworkId(dispatch.vehicle_net_id)
        if not veh or veh == 0 or not DoesEntityExist(veh) then
            return false, 'vehicle_missing'
        end
    end

    local dRaw = GetEntityCoords(dispatcherPed)
    local targetCoords = vector3(dRaw.x, dRaw.y, dRaw.z)
    if not _SafeVec(targetCoords) then return false, 'bad_dispatcher_coords' end

    local speed = veh and PANIC_EVAC_VEHICLE_SPEED_MS or PANIC_EVAC_FOOT_SPEED_MS
    local taskOk
    if veh then
        taskOk = pcall(TaskVehicleDriveToCoord,
            ped, veh,
            targetCoords.x, targetCoords.y, targetCoords.z,
            speed, 0, 0, 16777216, 5.0, 1
        )
    else
        taskOk = pcall(TaskFollowNavMeshToCoord,
            ped,
            targetCoords.x, targetCoords.y, targetCoords.z,
            speed, NAVMESH_TASK_TIMEOUT, NAVMESH_STOPPING_RANGE_M,
            NAVMESH_PERSIST_FOLLOWING, 0.0
        )
    end
    if not taskOk then return false, 'task_assignment_failed' end

    bot.state.is_locked = false

    dispatch.route_queue          = nil
    dispatch.route_index          = nil
    dispatch.destination          = targetCoords
    dispatch.panic_evacuation     = true
    dispatch.panic_dispatcher_src = dispatcherSrc
    dispatch.task_retry_ticks     = 0
    dispatch.police_dwell         = 0
    dispatch.comms_lost           = false
    dispatch.cruise_speed         = speed

    bot.state.is_locked = true
    bot.state.activity   = 'panic_evacuation'

    Matrix.Log('CORE',
        '[ACIL TAHLIYE] Bot #%d gorevi terk etti; dispatcher src=%d konumuna (%.1f,%.1f,%.1f) dogru son hizla yola cikti.',
        botId, dispatcherSrc, targetCoords.x, targetCoords.y, targetCoords.z)

    return true
end

function Matrix.DespawnDispatchEntity(botId, dispatch)
    dispatch = dispatch or Matrix.Dispatches[botId]
    local bot = Matrix.Bots[botId]

    local pedNetId = dispatch and dispatch.entity_net_id or (bot and bot.state.net_id)

    if pedNetId then
        local ped = NetworkGetEntityFromNetworkId(pedNetId)
        if ped and ped ~= 0 and DoesEntityExist(ped) then SafeDeleteEntity(ped) end
    end

    if dispatch and dispatch.vehicle_net_id then
        local veh = NetworkGetEntityFromNetworkId(dispatch.vehicle_net_id)
        if veh and veh ~= 0 and DoesEntityExist(veh) then SafeDeleteEntity(veh) end
    end

    if bot then
        bot.state.spawned   = false
        bot.state.net_id    = nil
        bot.state.is_locked = false
    end

    TriggerClientEvent('matrix:client:extractBot', -1, botId)
end

local function FlushPendingEvents(dispatch)
    if #dispatch.pending_events == 0 then return end
    Matrix.Log('CORE', '[GECİKMELİ VERİ AKIŞI] Bot #%d için %d olay toplu iletiliyor.',
        dispatch.bot_id, #dispatch.pending_events)
    for _, msg in ipairs(dispatch.pending_events) do
        Matrix.Log('CORE', '  -> %s', msg)
    end
    dispatch.pending_events = {}
end

local function QueueOrEmit(dispatch, message)
    if dispatch.comms_lost then
        local events = dispatch.pending_events
        if #events >= PENDING_EVENTS_MAX then
            table.remove(events, 1)
        end
        events[#events + 1] = message
    else
        Matrix.Log('CORE', message)
    end
end

local function AdvanceRouteWaypoint(ped, dispatch, botId)
    dispatch.route_index      = dispatch.route_index + 1
    dispatch.destination      = dispatch.route_queue[dispatch.route_index]
    dispatch.task_retry_ticks = 0

    local reissueSpeed = dispatch.cruise_speed or DISPATCH_BASE_VEHICLE_SPEED_MS
    if dispatch.vehicle_net_id then
        local veh = NetworkGetEntityFromNetworkId(dispatch.vehicle_net_id)
        if veh and veh ~= 0 and DoesEntityExist(veh) then
            pcall(TaskVehicleDriveToCoord,
                ped, veh,
                dispatch.destination.x, dispatch.destination.y, dispatch.destination.z,
                reissueSpeed, 0, 0, 16777216, 5.0, 1
            )
        end
    else
        pcall(TaskFollowNavMeshToCoord,
            ped,
            dispatch.destination.x, dispatch.destination.y, dispatch.destination.z,
            reissueSpeed, NAVMESH_TASK_TIMEOUT, NAVMESH_STOPPING_RANGE_M,
            NAVMESH_PERSIST_FOLLOWING, 0.0
        )
    end

    QueueOrEmit(dispatch, ('[ROTA ZİNCİRİ] Bot #%d %d/%d. uğrağa ulaştı — %d. noktaya anında yönlendirildi.'):format(
        botId, dispatch.route_index - 1, #dispatch.route_queue, dispatch.route_index))
end

function Matrix.TickPhysicalDispatches()
    local toComplete = {}

    for botId, dispatch in pairs(Matrix.Dispatches) do
        local bot = Matrix.Bots[botId]
        if not bot then
            toComplete[botId] = 'failed'
        else
            dispatch.elapsed = dispatch.elapsed + 1.0
            dispatch.task_retry_ticks = dispatch.task_retry_ticks + 1

            local ped = NetworkGetEntityFromNetworkId(dispatch.entity_net_id)
            if not ped or ped == 0 or not DoesEntityExist(ped) then
                Matrix.Log('CORE', '[SEVK KAYIP] Bot #%d fiziksel varlık bulunamadı, iptal.', botId)
                toComplete[botId] = 'failed'
            else
                local coordsRaw = GetEntityCoords(ped)
                local coords    = vector3(coordsRaw.x, coordsRaw.y, coordsRaw.z)
                dispatch.last_coords = coords
                bot.state.coords     = coords

                if Matrix.Logistics and Matrix.Logistics.CheckPortArrival then
                    local portOk, portErr = pcall(Matrix.Logistics.CheckPortArrival, dispatch, coords)
                    if not portOk then
                        Matrix.Log('CORE', '[HATA] CheckPortArrival basarisiz (yutuldu): %s', tostring(portErr))
                    end
                end

                local distToDest = #(coords - dispatch.destination)
                if distToDest <= DISPATCH_ARRIVAL_RADIUS_M then
                    if dispatch.route_queue and dispatch.route_index < #dispatch.route_queue then
                        AdvanceRouteWaypoint(ped, dispatch, botId)
                    else
                        toComplete[botId] = 'arrived'
                    end
                else
                    local zone = FindDeadZone(coords)
                    if zone and not dispatch.comms_lost then
                        dispatch.comms_lost = true
                        Matrix.Log('CORE', '[BAĞLANTI KESİLDİ] Bot #%d (%s) kör bölgede: %s',
                            botId, bot.name, zone.label)
                        if type(dispatch.dispatcher_src) == 'number' and dispatch.dispatcher_src > 0 then
                            Matrix.Radio.ApplyStatic(dispatch.dispatcher_src, 1.0, 'dead_zone')
                        end
                    elseif (not zone) and dispatch.comms_lost then
                        dispatch.comms_lost = false
                        Matrix.Log('CORE', '[SİNYAL YENİDEN ALINDI] Bot #%d kör bölgeden çıktı.', botId)
                        SetTimeout(Config.Logistics.DeadZoneLogFlushDelayMs, function()
                            if Matrix.Dispatches[botId] == dispatch then
                                FlushPendingEvents(dispatch)
                            end
                        end)
                    end

                    local policeNearby = false
                    local veryClose    = false
                    for src in pairs(PoliceSources) do
                        local policePed = GetPlayerPed(src)
                        if policePed and policePed ~= 0 then
                            local pd = GetEntityCoords(policePed)
                            local d  = #(vector3(pd.x, pd.y, pd.z) - coords)
                            if d <= DISPATCH_POLICE_PROXIMITY_M then
                                policeNearby = true
                                if d <= DISPATCH_BUSTED_PROXIMITY_M then
                                    veryClose = true
                                end
                            end
                        end
                    end

                    if policeNearby then
                        local nearestId, nearestDist = FindNearestTrapHouse(coords)
                        if nearestId and nearestDist <= Config.Bureau.BaseSearchRadius then
                            Matrix.Bureau.AdvanceDecryption(
                                nearestId,
                                DISPATCH_POLICE_DECRYPT_TICK * (dispatch.profile.PoliceDecryptionMultiplier or 1.0)
                            )
                        end
                    end

                    if veryClose then
                        dispatch.police_dwell = dispatch.police_dwell + 1
                    else
                        dispatch.police_dwell = math_max(0, dispatch.police_dwell - 1)
                    end

                    if dispatch.police_dwell >= DISPATCH_BUSTED_DWELL_TICKS then
                        Matrix.Log('CORE', '[PUSU] Bot #%d polis tarafından kuşatıldı.', botId)
                        toComplete[botId] = 'busted'
                    else
                        if dispatch.plate then
                            for trapId, trapHouse in pairs(Matrix.TrapHouses or {}) do
                                if not dispatch.alpr_logged_traps[trapId] then
                                    if #(coords - trapHouse.coords) <= DISPATCH_ALPR_RADIUS_M then
                                        dispatch.alpr_logged_traps[trapId] = true
                                        local veh = Matrix.Fleet and Matrix.Fleet.GetVehicle and Matrix.Fleet.GetVehicle(dispatch.plate)
                                        if veh then
                                            pcall(Matrix.Fleet.RecordAlprHit, dispatch.plate, bot.dna_id,
                                                veh.registered_by_citizenid, trapId)

                                            local vinMult = Config.Logistics.Fleet.VinDecryptionMultiplier[veh.vin_status] or 1.0
                                            Matrix.Bureau.AdvanceDecryption(
                                                trapId,
                                                DISPATCH_POLICE_DECRYPT_TICK
                                                    * (dispatch.profile.PoliceDecryptionMultiplier or 1.0)
                                                    * vinMult
                                            )
                                            QueueOrEmit(dispatch, ('[ALPR EŞLEŞMESİ] Plaka %s -> DNA %s -> Trap #%d'):format(
                                                dispatch.plate, bot.dna_id, trapId))
                                        end
                                    end
                                end
                            end
                        end

                        local reissueThreshold = dispatch.panic_evacuation
                            and PANIC_REISSUE_TICKS or DISPATCH_TASK_REISSUE_TICKS

                        if dispatch.task_retry_ticks >= reissueThreshold then
                            dispatch.task_retry_ticks = 0

                            if dispatch.panic_evacuation and dispatch.panic_dispatcher_src then
                                local dispatcherPed = GetPlayerPed(dispatch.panic_dispatcher_src)
                                if dispatcherPed and dispatcherPed ~= 0 then
                                    local dRaw = GetEntityCoords(dispatcherPed)
                                    local liveTarget = vector3(dRaw.x, dRaw.y, dRaw.z)
                                    if _SafeVec(liveTarget) then
                                        dispatch.destination = liveTarget
                                    end
                                end
                            end

                            local reissueSpeed = dispatch.cruise_speed or DISPATCH_BASE_VEHICLE_SPEED_MS
                            if dispatch.vehicle_net_id then
                                local veh = NetworkGetEntityFromNetworkId(dispatch.vehicle_net_id)
                                if veh and veh ~= 0 and DoesEntityExist(veh) then
                                    pcall(TaskVehicleDriveToCoord,
                                        ped, veh,
                                        dispatch.destination.x, dispatch.destination.y, dispatch.destination.z,
                                        reissueSpeed, 0, 0, 16777216, 5.0, 1
                                    )
                                end
                            else
                                pcall(TaskFollowNavMeshToCoord,
                                    ped,
                                    dispatch.destination.x, dispatch.destination.y, dispatch.destination.z,
                                    reissueSpeed, NAVMESH_TASK_TIMEOUT, NAVMESH_STOPPING_RANGE_M,
                                    NAVMESH_PERSIST_FOLLOWING, 0.0
                                )
                            end
                        end

                        QueueOrEmit(dispatch, ('Bot #%d konum güncellendi: (%.1f, %.1f, %.1f) | Kalan mesafe:%.1fm'):format(
                            botId, coords.x, coords.y, coords.z, distToDest))
                    end
                end
            end
        end
    end

    for botId, reason in pairs(toComplete) do
        local ok, err = pcall(Matrix.CompleteDispatch, botId, reason)
        if not ok then
            Matrix.Log('CORE', '[HATA] CompleteDispatch (%s) basarisiz: %s', tostring(botId), tostring(err))
        end
        if Matrix.Dispatches[botId] then
            Matrix.Dispatches[botId] = nil
        end
    end
end

lib.callback.register('matrix:callback:getRosterReport', function(src)
    local entries = {}

    for id, bot in pairs(Matrix.Bots) do
        if #entries >= 100 then break end
        if bot.status == 'active' then
            local durum = bot.state.is_locked and 'MESGUL / INTIKALDE' or 'STABIL / BEKLEMEDE'
            local roleLabel = (bot.role == 'Inspector') and 'BOLGE DENETLEYICISI' or 'STREET DEALER'
            local moleFlagged = (Matrix.Inspector and Matrix.Inspector.IsMoleFlagged and Matrix.Inspector.IsMoleFlagged(id)) or false

            local text = ('[BOT-ID: %d] - %s | Rol: %s | Durum: %s'):format(id, bot.name, roleLabel, durum)
            if moleFlagged then
                text = text .. ' | [SIGINT ANOMALISI: KOSTEBEK / MUHBIR DOGRULANDI!]'
            end

            entries[#entries + 1] = {
                kind         = 'bot',
                id           = id,
                role         = bot.role,
                mole_flagged = moleFlagged,
                text         = text
            }
        end
    end

    local ok, players = pcall(function() return Matrix.QBX:GetQBPlayers() end)
    if ok and type(players) == 'table' then
        for playerSrc, player in pairs(players) do
            if #entries >= 100 then break end
            if player and player.PlayerData then
                local citizenid = player.PlayerData.citizenid
                local rank      = citizenid and Matrix.Hierarchy.GetRank(citizenid)
                local rankDef   = rank and Config.Hierarchy.Ranks[rank]
                local rankLabel = rankDef and rankDef.label or 'Rutbesiz'
                local ROSTER_AUTHORITY_LABELS = {
                    Leader            = 'MUTLAK',
                    Logistics_Officer = 'YETKILI',
                    Chemist           = 'KISITLI'
                }
                local yetki     = (rank and ROSTER_AUTHORITY_LABELS[rank]) or 'KISITLI'

                local charinfo = player.PlayerData.charinfo
                local name = (charinfo and charinfo.firstname and charinfo.lastname)
                    and ('%s %s'):format(charinfo.firstname, charinfo.lastname)
                    or ('Oyuncu-%d'):format(playerSrc)

                entries[#entries + 1] = {
                    kind = 'player',
                    id   = playerSrc,
                    text = ('[PLR-ID: %d] - %s | Rutbe: %s | Yetki: %s'):format(playerSrc, name, rankLabel, yetki)
                }
            end
        end
    end

    return entries
end)

local bureauAccumulator = 0

CreateThread(function()
    LoadBotsFromDatabase()

    local interval       = Config.Tick.IntervalMs
    local secPerMin      = Config.Tick.SecondsPerMinute
    local secPerHour     = Config.Tick.SecondsPerHour
    local bureauInterval = Config.Bureau.AnalysisIntervalSeconds

    while true do
        Wait(interval)
        bureauAccumulator = bureauAccumulator + 1

        for _, bot in pairs(Matrix.Bots) do
            if bot.status == 'active' then
                local s = bot.state.elapsed_seconds + 1
                bot.state.elapsed_seconds = s

                if s % secPerMin == 0 then
                    local ok, err = pcall(Matrix.Kitchen.ProcessMinuteCycle, bot)
                    if not ok then Matrix.Log('CORE', '[HATA] ProcessMinuteCycle (Bot #%d) basarisiz: %s', bot.id, tostring(err)) end
                end
                if s % secPerHour == 0 then
                    local ok, err = pcall(Matrix.Kitchen.ProcessHourCycle, bot)
                    if not ok then Matrix.Log('CORE', '[HATA] ProcessHourCycle (Bot #%d) basarisiz: %s', bot.id, tostring(err)) end
                end
            end
        end

        for src, citizenid in pairs(Matrix.PlayerSourceIndex) do
            local state = Matrix.PlayerState[citizenid]
            if state and state.biology then
                Matrix.DecayPlayerCortisol(state)
                if state.biology.cortisol_level > Config.Kitchen.CortisolDeviationThreshold then
                    Matrix.Radio.ApplyStatic(src, state.biology.cortisol_level, 'panic')
                end
            end
        end

        local ok3, err3 = pcall(Matrix.TickPhysicalDispatches)
        if not ok3 then Matrix.Log('CORE', '[HATA] TickPhysicalDispatches basarisiz (yutuldu): %s', tostring(err3)) end

        if bureauAccumulator >= bureauInterval then
            bureauAccumulator = 0
            local ok4, err4 = pcall(Matrix.Bureau.Tick)
            if not ok4 then Matrix.Log('CORE', '[HATA] Bureau.Tick basarisiz (yutuldu): %s', tostring(err4)) end
            CreateThread(function()
                local okS, errS = pcall(Matrix.Recruitment.ScanCustomerPool)
                if not okS then Matrix.Log('CORE', '[HATA] ScanCustomerPool basarisiz (yutuldu): %s', tostring(errS)) end
            end)
        end

        if Matrix.Hud and Matrix.Hud.PushSnapshots then
            local ok5, err5 = pcall(Matrix.Hud.PushSnapshots)
            if not ok5 then Matrix.Log('CORE', '[HATA] Hud.PushSnapshots basarisiz (yutuldu): %s', tostring(err5)) end
        end
    end
end)

CreateThread(function()
    while true do
        Wait(Matrix.Persistence.botFlushMs)
        Matrix.FlushDirtyBots()
    end
end)

AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end

    PersistAllBotsSync()

    for citizenid, state in pairs(Matrix.PlayerState) do
        pcall(function()
            MySQL.query.await([[
                INSERT INTO matrix_player_state (citizenid, cortisol_level, fatigue_level, updated_at)
                VALUES (?, ?, ?, NOW())
                ON DUPLICATE KEY UPDATE cortisol_level = VALUES(cortisol_level),
                    fatigue_level = VALUES(fatigue_level), updated_at = NOW()
            ]], { citizenid, state.biology.cortisol_level, state.biology.fatigue_level })
        end)
    end

    Matrix.Log('CORE', 'Tüm veri kalıcı depoya yazıldı. Kapanış tamamlandı.')
end)

AddEventHandler('playerDropped', function()
    local src = source
    local citizenid = Matrix.PlayerSourceIndex[src]

    if citizenid then
        local state = Matrix.PlayerState[citizenid]
        if state then
            MySQL.prepare([[
                INSERT INTO matrix_player_state (citizenid, cortisol_level, fatigue_level, updated_at)
                VALUES (?, ?, ?, NOW())
                ON DUPLICATE KEY UPDATE cortisol_level = VALUES(cortisol_level),
                    fatigue_level = VALUES(fatigue_level), updated_at = NOW()
            ]], { citizenid, state.biology.cortisol_level, state.biology.fatigue_level })

            Matrix.PlayerState[citizenid] = nil
        end
    end
    Matrix.PlayerSourceIndex[src] = nil

    for _, dispatch in pairs(Matrix.Dispatches) do
        if dispatch.dispatcher_src == src then
            dispatch.dispatcher_src = nil
            dispatch.comms_lost = true
        end
    end
end)

local function Reply(src, msg)
    if type(src) == 'number' and src > 0 then
        TriggerClientEvent('chat:addMessage', src, { args = { '[MATRIX]', msg } })
    else
        print(('[MATRIX:CONSOLE] %s'):format(msg))
    end
end

local function NotifyResult(src, ok, msg)
    Reply(src, msg)
    if type(src) == 'number' and src > 0 then
        TriggerClientEvent('matrix:client:actionNotify', src, ok, msg)
    end
end


-- =====================================================================
-- ★★★ [SANDBOX ACE HARDENING] Matrix.Security ★★★
-- Sivil oyuncuların KENDİ oyun mantığı/RP döngüleri için kullandığı
-- komutlar (ör. /telefonuyoket, /opsecparola) ile yalnızca sunucu
-- yöneticilerinin debug/test/simülasyon süreçlerinde kullanması gereken
-- komutlar (ör. /botyarat, /burokilitzorla, /radyoparazit, /rotaciz) ARASINDAKİ
-- ayrımı TEK bir merkezi kapıdan geçirir. Her tehlikeli/debug RegisterCommand
-- artık DOĞRUDAN değil, Matrix.Security.RegisterGatedCommand ÜZERİNDEN
-- tanımlanır -- bu hem native restricted=true (FXServer'ın kendi
-- 'command.<isim>' ACE kontrolü, Lua'ya HİÇ ULAŞMADAN reddeder) hem de
-- Lua-seviyesi bağımsız bir ikinci katman (group.admin VEYA özel
-- command.matrix_supervisor principal'ı) UYGULAR -- server.cfg'de
-- per-command ACE tanımlamayan küçük sunucular için de çalışır (bkz.
-- README.md "Sandbox Komutları" bölümü).
-- =====================================================================
Matrix.Security = Matrix.Security or {}

local IsPlayerAceAllowed = IsPlayerAceAllowed

-- name -> true: RegisterGatedCommand ÜZERİNDEN gerçekten kayıt edilmiş
-- komutlar. matrix_diagnostics.lua'nın 'Sandbox: ACE Privilege Verification'
-- kontrolü, DangerousCommands listesindeki HER isim burada da var mı diye
-- doğrular -- biri eksikse ("hayalet debug komutu") sunucu açılışını durdurur.
Matrix.Security.GatedCommands = {}

-- ★ CANONICAL TEHLİKELİ/DEBUG KOMUT LİSTESİ. Yeni bir debug/test komutu
-- eklerken buraya da eklenmezse, matrix_diagnostics.lua bunu bir "hayalet
-- komut" olarak işaretleyip sunucu açılışını AbortResourceOnSimulationFailure
-- ile durdurur (bkz. server/matrix_diagnostics.lua).
-- ★ SINIFLANDIRMA NOTU: bazı komutlar (ör. /botkilitac, /operatiftasfiye,
-- /panikiptal, /cetelideriata, /relaypurge) BU LİSTEYE BİLİNÇLİ OLARAK
-- ALINMADI -- zaten Matrix.Hierarchy.HasCommandAuthority (org-içi rütbe:
-- Leader/Logistics_Officer) ile doğru şekilde kilitli, MEŞRU oyun-içi
-- kartel operasyon komutlarıdır; onları group.admin'e kilitlemek çalışan
-- bir özelliği KIRARDI. /rotaciz de aynı şekilde ÇEKİRDEK oyun döngüsüdür
-- (F10 menüsünden tetiklenir) -- admin-only YAPILMADI, bunun yerine
-- eksik olan AYNI org-rütbe kapısı eklendi (bkz. RegisterCommand('rotaciz',
-- ...) -- artık /sevket ve /panikiptal ile AYNI HasCommandAuthority
-- disiplinine tabi). Buradaki liste yalnızca GERÇEKTEN ungated, in-fiction
-- karşılığı olmayan (test/debug isimli VEYA hiçbir yetki kontrolü
-- taşımayan) komutları kapsar.
Matrix.Security.DangerousCommands = {
    -- server/main.lua
    'botyarat', 'botspawn', 'botdespawn', 'balistiktest', 'botbalistik',
    'kortizoltetikle', 'botskill', 'botbio', 'botmekanik',
    'radyoparazit', 'matrixdump', 'fizikselsevk',
    -- server/bureau.lua
    'burokilitzorla', 'traphouseekle', 'desifreekle', 'propagandatetikle',
    'baskinzorla', 'baskinsonuclandir', 'dropsizintiekle', 'dropsizintisifirla',
    'yayinbaslat', 'yayinbitir', 'polisgenetigi', 'dropsizintidurum',
    -- server/logistics.lua
    'aracele', 'hasarver', 'oldur', 'guvengoster', 'gecodeme', 'dropdurum',
    -- server/market.lua
    'piyasasifirla', 'nakityatir', 'nakitakla', 'gizliajandurum',
    'denetleyicidurum', 'bolgeselrapor', 'sokaksatisrapor',
    -- server/forensics.lua
    'kovantopla', 'mobesehackle', 'cctvkaydet', 'kanitsabotaj',
    'forensicdump', 'forensicrapor', 'asinmaayarla',
    -- server/recruitment.lua (dosyanin kendi basligi: "herkese acik test grubu")
    'sorgu', 'musterikaydet', 'havuztara', 'adaygoster', 'baskiuygula',
    'sorgubitir', 'sokakdevsir',
    -- server/kitchen.lua
    'mutfaktest', 'dakikadongusu', 'saatdongusu', 'yakalatest',
    'kortizolsicramasi', 'katmandurum', 'katmantemizle',
    -- server/trap_house_interior.lua
    'interiordurum',
    -- server/district_hubs.lua
    'hubata', 'hublistele',
    -- server/blackmarket.lua
    'karaborsagecmisi',
    -- server/rendezvous.lua
    'rendezvousdurum',
    -- server/matrix_diagnostics.lua
    'matrix_run_diagnostics', 'matrix_diag_detay'
}

-- ★ Bu listede OLMAYAN, ama AYRI bir mekanizma ile ayni sekilde
-- kapatilmis kritik acikllar (matrix_diagnostics.lua'nin ACE kontrolu
-- bunlari DENETLEMEZ -- farkli bir yetki modeli kullanirlar, admin/
-- supervisor DEGIL, 'org-ici Leader' veya 'gorevde polis' otoritesi):
--   • rutbeata         (server/market.lua)  -> Matrix.Hierarchy.CanAssignRank
--                        (yalnizca mevcut Leader/supervisor VEYA ilk-Leader
--                        bootstrap'i rutbe atayabilir -- ONCEDEN SIFIR
--                        kontrol vardi, herkes kendini Leader yapabiliyordu).
--   • rotaciz          (server/main.lua)    -> Matrix.Hierarchy.HasCommandAuthority
--                        (org-ici, /sevket ile AYNI kapı -- CEKIRDEK oyun
--                        donguisu, admin-only YAPILMADI).
--   • telefonuyoket    (server/bureau.lua)  -> artik SADECE cagiranin
--                        KENDI dna_id'sine kilitli (parametre enjeksiyonu
--                        kapatildi, args[1] TAMAMEN yok sayilir).
--   • davaac/davasorgula (server/bureau.lua),
--     kanityukle       (server/gang_hoods.lua) -> Matrix.IsOnDutyPolice
--                        (bu ucu de dogrudan Matrix.Bureau.ExecuteVerdict
--                        zincirine baglaniyordu, hicbir kontrol yoktu).

--- group.admin VEYA özel command.matrix_supervisor ACE principal'ına sahip
--- olan her kaynak "supervisor" sayılır. Konsol (src==0) HER ZAMAN otorite
--- sahibidir -- ayrı bir çağrı yolu ile ele alınır (bkz. RegisterGatedCommand).
function Matrix.Security.IsSupervisor(src)
    if type(src) ~= 'number' or src <= 0 then return false end
    local ok1, allowed1 = pcall(IsPlayerAceAllowed, src, 'group.admin')
    if ok1 and allowed1 then return true end
    local ok2, allowed2 = pcall(IsPlayerAceAllowed, src, 'command.matrix_supervisor')
    if ok2 and allowed2 then return true end
    return false
end

--- Yetkisiz bir tetikleme, adli kayıt politikasına uygun şekilde kalıcı bir
--- tabloya (matrix_command_tamper_log) işlenir -- mevcut matrix_opsec_
--- tamper_log İLE KARIŞTIRILMAZ (o tablo trap_house_id NOT NULL + FK ile
--- YALNIZCA yanlış OPSEC parolası denemelerine özeldir, bkz. bureau.lua
--- SEC-7; genel bir komut-tamper tablosu için şeması UYGUN DEĞİLDİR).
function Matrix.Security.LogTamperAttempt(src, commandName, argsRaw)
    local state = Matrix.GetOrCreatePlayerState and Matrix.GetOrCreatePlayerState(src)
    local citizenid = state and state.citizenid

    local argsOk, argsJson = pcall(json.encode, argsRaw or {})
    if not argsOk then argsJson = '[]' end

    local ok = pcall(function()
        MySQL.insert([[
            INSERT INTO matrix_command_tamper_log
                (src, citizenid, command_name, raw_args, created_at)
            VALUES (?, ?, ?, ?, NOW())
        ]], { src, citizenid, commandName, argsJson })
    end)
    if not ok then
        Matrix.Log('SECURITY', '[HATA] LogTamperAttempt INSERT basarisiz (yutuldu).')
    end

    Matrix.Log('SECURITY',
        '[OPSEC TAMPER][HILECI ENJEKSIYONU] src=%d citizenid=%s komut=/%s -- YETKISIZ tetikleme REDDEDILDI ve islendi.',
        src, tostring(citizenid), commandName)
end

--- Tüm tehlikeli/debug komutlar BUNUN ÜZERİNDEN kayıt edilir. `handler`
--- normal bir RegisterCommand callback'idir (src, args, raw).
function Matrix.Security.RegisterGatedCommand(name, handler)
    Matrix.Security.GatedCommands[name] = true

    RegisterCommand(name, function(src, args, raw)
        -- Konsoldan (src==0) çalıştırma: konsol ZATEN sunucu otoritesidir,
        -- ayrıca bir ACE kontrolüne TABİ DEĞİLDİR (FXServer'ın kendi
        -- davranışıyla tutarlı).
        if type(src) ~= 'number' or src <= 0 then
            return handler(src, args, raw)
        end

        if not Matrix.Security.IsSupervisor(src) then
            Matrix.Security.LogTamperAttempt(src, name, args)
            NotifyResult(src, false, 'Yetkisiz. Bu komut yalnizca sunucu supervisorlerine acik (group.admin / command.matrix_supervisor).')
            return
        end

        return handler(src, args, raw)
    end, true) -- ★ restricted=true: FXServer'ın kendi 'command.<isim>' ACE kapısı da AYRICA devrede.
end

local function SafeForwardCoords(src, distance)
    if type(src) ~= 'number' or src <= 0 then return nil end
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    local c  = GetEntityCoords(ped)
    local hd = GetEntityHeading(ped)
    local rad = math_rad(hd)
    return vector4(
        c.x - (math_sin(rad) * distance),
        c.y + (math_cos(rad) * distance),
        c.z,
        (hd + 180.0) % 360.0
    )
end

local function ResolveBotOrigin(bot, dispatcherSrc)
    if not bot then return nil end
    if bot.state.coords then return bot.state.coords end

    local trapHouseId = bot.state.trap_house_id
    local house = trapHouseId and Matrix.TrapHouses and Matrix.TrapHouses[trapHouseId]
    if house and house.coords then return house.coords end

    if Matrix.TrapHouses then
        local lowestId = nil
        for id in pairs(Matrix.TrapHouses) do
            if not lowestId or id < lowestId then lowestId = id end
        end
        if lowestId and Matrix.TrapHouses[lowestId].coords then
            return Matrix.TrapHouses[lowestId].coords
        end
    end

    if type(dispatcherSrc) == 'number' and dispatcherSrc > 0 then
        local ped = GetPlayerPed(dispatcherSrc)
        if ped and ped ~= 0 then
            local c = GetEntityCoords(ped)
            return vector3(c.x, c.y + 200.0, c.z)
        end
    end

    return nil
end

RegisterCommand('coords', function(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then Reply(src, 'Ped bulunamadi.'); return end
    local c  = GetEntityCoords(ped)
    local hd = GetEntityHeading(ped)
    Reply(src, ('KOMUTLAR ICIN (boslukla): %.3f %.3f %.3f  |Heading:%.1f'):format(c.x, c.y, c.z, hd))
    Reply(src, ('CONFIG ICIN (virgullu):  vector3(%.3f, %.3f, %.3f)'):format(c.x, c.y, c.z))
end, false)

Matrix.Security.RegisterGatedCommand('botyarat', function(src, args)
    local name = args[1]
    local role = args[2] or 'runner'
    if type(name) ~= 'string' or name == '' then
        Reply(src, 'Kullanim: /botyarat [isim] [rol]'); return
    end
    if not Config.RoleModels[role] and role ~= Config.DefaultRoleModel then
        role = 'runner'
    end

    local bot = Matrix.CreateBotRecord({ name = name, role = role })
    Reply(src, ('Bot #%d matrise yazıldı: %s (%s)'):format(bot.id, bot.name, bot.role))
end)

Matrix.Security.RegisterGatedCommand('botspawn', function(src, args)
    local botId = tonumber(args[1])
    if not botId then Reply(src, 'Kullanim: /botspawn [id]'); return end
    local coords = SafeForwardCoords(src, 2.0)
    if not coords then Reply(src, 'Spawn için geçerli bir ped gerekli.'); return end
    local ok = Matrix.SpawnBot(botId, coords)
    Reply(src, ok and ('Bot #%d enjekte edildi.'):format(botId)
              or  ('Bot #%d enjekte edilemedi.'):format(botId))
end)

Matrix.Security.RegisterGatedCommand('botdespawn', function(src, args)
    local botId = tonumber(args[1])
    if not botId then Reply(src, 'Kullanim: /botdespawn [id]'); return end
    local ok = Matrix.DespawnBot(botId)
    Reply(src, ok and ('Bot #%d hafıza matrisine geri çekildi.'):format(botId)
              or  ('Bot #%d geri çekilemedi.'):format(botId))
end)

-- =====================================================================
-- ★ [YAMA 1] /botkilitac — D1-v2 IO FAIL sonrası manuel kilit açma.
-- =====================================================================
RegisterCommand('botkilitac', function(src, args)
    local botId = tonumber(args[1])
    if not botId then NotifyResult(src, false, 'Kullanim: /botkilitac [botId]'); return end
    if Matrix.Hierarchy and Matrix.Hierarchy.HasCommandAuthority then
        local st = Matrix.GetOrCreatePlayerState(src)
        if not st or not st.citizenid or not Matrix.Hierarchy.HasCommandAuthority(st.citizenid) then
            NotifyResult(src, false, 'Yetkisiz.'); return
        end
    end
    local bot = Matrix.Bots[botId]
    if not bot then NotifyResult(src, false, 'Bot yok.'); return end
    if not bot.state.is_locked then
        NotifyResult(src, false, 'Bot zaten kilitli degil.'); return
    end
    bot.state.is_locked = false
    NotifyResult(src, true, ('[KILIT ACILDI] Bot #%d is_locked=false (manuel override).'):format(botId))
    Matrix.Log('CORE', '[MANUEL KILIT ACILDI] Bot #%d operatör override.', botId)
end, false)

RegisterCommand('operatiftasfiye', function(src, args)
    local botId = tonumber(args[1])
    if not botId then NotifyResult(src, false, 'Kullanim: /operatiftasfiye [botId]'); return end

    if Matrix.Hierarchy and Matrix.Hierarchy.HasCommandAuthority then
        local assignerState = Matrix.GetOrCreatePlayerState(src)
        if not assignerState or not assignerState.citizenid or not Matrix.Hierarchy.HasCommandAuthority(assignerState.citizenid) then
            NotifyResult(src, false, 'Bu emri vermek icin yeterli rutbeniz yok (Logistics_Officer veya Leader gerekir).'); return
        end
    end

    if not Matrix.Bots[botId] then
        NotifyResult(src, false, ('Bot #%d matriste bulunamadi.'):format(botId)); return
    end

    local ok
    if Matrix.Logistics and Matrix.Logistics.OnDealerEliminated then
        ok = Matrix.Logistics.OnDealerEliminated(botId, 'command_purge')
    else
        ok = Matrix.RemoveBot(botId, 'command_purge')
    end

    if ok then
        NotifyResult(src, true, ('[TASFIYE TAMAMLANDI] Bot #%d matristen ve RAM onbellekten kalici olarak silindi (Hard-Delete).'):format(botId))
    else
        NotifyResult(src, false, ('Bot #%d tasfiye edilemedi.'):format(botId))
    end
end, false)

RegisterCommand('cetelideriata', function(src, args)
    local botId       = tonumber(args[1])
    local trapHouseId = tonumber(args[2])
    if not botId or not trapHouseId or not Matrix.Bots[botId] or not Matrix.TrapHouses[trapHouseId] then
        Reply(src, 'Kullanim: /cetelideriata [botId] [trapHouseId (gecerli olmali)]'); return
    end

    if Matrix.Hierarchy and Matrix.Hierarchy.HasCommandAuthority then
        local assignerState = Matrix.GetOrCreatePlayerState(src)
        if not assignerState or not assignerState.citizenid or not Matrix.Hierarchy.HasCommandAuthority(assignerState.citizenid) then
            Reply(src, 'Bu atamayi yapmak icin yeterli rutbeniz yok (Logistics_Officer veya Leader gerekir).'); return
        end
    end

    local bot = Matrix.Bots[botId]
    bot.role = 'Leader'
    bot.state.trap_house_id = trapHouseId
    local assignerState = Matrix.GetOrCreatePlayerState(src)
    bot.handler_citizenid = assignerState and assignerState.citizenid
    Matrix.MarkBotDirty(botId)

    Reply(src, ('Bot #%d, Trap #%d icin otonom cete lideri ("Leader") olarak atandi.'):format(botId, trapHouseId))
    Matrix.Log('CORE', '[CETE LIDERI ATANDI] Bot #%d -> Trap #%d', botId, trapHouseId)
end, false)

local PANIC_EVAC_FAILURE_MESSAGES = {
    bad_bot_id              = 'Gecersiz bot ID.',
    bot_missing              = 'Bot matriste bulunamadi.',
    not_dispatched           = 'Bot su anda aktif bir sevkiyatta degil (sahada degil), acil tahliye tetiklenemez.',
    bad_dispatcher           = 'Komutu tetikleyen oyuncu cozulemedi.',
    dispatcher_ped_missing   = 'Ped\'iniz bulunamadi.',
    entity_missing           = 'Botun fiziksel varligi (ped) dunyada bulunamadi.',
    vehicle_missing          = 'Botun aracı dunyada bulunamadi.',
    bad_dispatcher_coords    = 'Konumunuz cozulemedi.',
    task_assignment_failed   = 'Gorev atamasi basarisiz oldu.'
}

RegisterCommand('panikiptal', function(src, args)
    local botId = tonumber(args[1])
    if not botId then NotifyResult(src, false, 'Kullanim: /panikiptal [botId]'); return end

    if Matrix.Hierarchy and Matrix.Hierarchy.HasCommandAuthority then
        local callerState = Matrix.GetOrCreatePlayerState(src)
        if not callerState or not callerState.citizenid or not Matrix.Hierarchy.HasCommandAuthority(callerState.citizenid) then
            NotifyResult(src, false, 'Bu emri vermek icin yeterli rutbeniz yok (Logistics_Officer veya Leader gerekir).'); return
        end
    end

    local ok, reason = Matrix.TriggerPanicEvacuation(botId, src)
    if ok then
        NotifyResult(src, true, ('[ACIL TAHLIYE TETIKLENDI] Bot #%d gorevini terk etti, son hizla sana dogru geliyor.'):format(botId))
    else
        NotifyResult(src, false, PANIC_EVAC_FAILURE_MESSAGES[reason] or ('Acil tahliye tetiklenemedi: %s'):format(tostring(reason)))
    end
end, false)

local WAYPOINT_INTEGER_PATTERN  = '^%d+$'
local WAYPOINT_COORD_PATTERN    = '^%-?%d+%.?%d*,%-?%d+%.?%d*,%-?%d+%.?%d*$'
local WAYPOINT_DEAD_DROP_PATTERN = '^[Dd][Dd]%-(%d+)$'

local function ResolveWaypointRef(refString)
    if type(refString) ~= 'string' or refString == '' then return nil, 'empty_waypoint' end

    local deadDropIdStr = refString:match(WAYPOINT_DEAD_DROP_PATTERN)
    if deadDropIdStr then
        local dropId = tonumber(deadDropIdStr)
        local dropCfg
        for _, d in ipairs(Config.Supplier.DeadDrops) do
            if d.id == dropId then dropCfg = d break end
        end
        if not dropCfg or not dropCfg.coords then return nil, 'dead_drop_not_found' end
        return dropCfg.coords
    end

    if refString:match(WAYPOINT_INTEGER_PATTERN) then
        local houseId = tonumber(refString)
        local house = Matrix.TrapHouses and Matrix.TrapHouses[houseId]
        if not house or not house.coords then return nil, 'trap_house_not_found' end
        return house.coords
    end

    if refString:match(WAYPOINT_COORD_PATTERN) then
        local xs, ys, zs = refString:match('^(%-?%d+%.?%d*),(%-?%d+%.?%d*),(%-?%d+%.?%d*)$')
        local x, y, z = tonumber(xs), tonumber(ys), tonumber(zs)
        if not x or not y or not z then return nil, 'bad_coord_numbers' end
        if x ~= x or y ~= y or z ~= z then return nil, 'nan_coord' end
        return vector3(x, y, z)
    end

    return nil, 'unrecognized_waypoint_format'
end

-- ★ [SEC-5][EKSIK YETKI KAPISI DUZELTMESI] /rotaciz, server/logistics.lua
-- /sevket'in ("Multi-Waypoint" cok-uğraklı benzeri) HasCommandAuthority
-- kapisindan YOKSUNDU -- bu, org rutbesi olmayan HERHANGI bir baglantili
-- oyuncunun HERHANGI bir botu istedigi rotaya sevk edebilmesi anlamina
-- geliyordu. Bu KOMUT admin-only YAPILMADI (F10 menusunden calisan
-- CEKIRDEK oyun donguisudur) -- yalnizca /sevket ve /panikiptal ile AYNI
-- org-rutbe kontrolu eklendi.
RegisterCommand('rotaciz', function(src, args)
    if Matrix.Hierarchy and Matrix.Hierarchy.HasCommandAuthority then
        local callerState = Matrix.GetOrCreatePlayerState(src)
        if not callerState or not callerState.citizenid or not Matrix.Hierarchy.HasCommandAuthority(callerState.citizenid) then
            Reply(src, 'Bu emri vermek icin yeterli rutbeniz yok (Logistics_Officer veya Leader gerekir).'); return
        end
    end

    local botId = tonumber(args[1])
    local bot   = botId and Matrix.Bots[botId]
    if not bot then
        Reply(src, 'Kullanim: /rotaciz [botId] [wp1|nil] [wp2|nil] [wp3|nil] [finalHedef] [plaka] [aracTipi] (wp1-3 bos/"nil" olabilir)')
        return
    end

    local waypoints = {}
    for i, rawIdx in ipairs({ 2, 3, 4 }) do
        local raw = args[rawIdx]
        if raw ~= nil and raw ~= '' and raw ~= 'nil' then
            local coords, err = ResolveWaypointRef(raw)
            if not coords then
                Reply(src, ('Ugrak #%d cozumlenemedi: %s'):format(i, tostring(err)))
                return
            end
            waypoints[#waypoints + 1] = coords
        end
    end

    local finalCoords, finalErr = ResolveWaypointRef(args[5])
    if not finalCoords then
        Reply(src, ('Final hedef cozumlenemedi: %s'):format(tostring(finalErr)))
        return
    end

    local plate = args[6]
    if plate == nil or plate == '' or plate == 'nil' then plate = nil end

    local vehicleType = args[7]
    if not vehicleType or not Config.Logistics.VehicleTypes[vehicleType] then
        vehicleType = Config.Logistics.DefaultVehicleType
    end

    local origin = ResolveBotOrigin(bot, src)
    if not origin then
        Reply(src, ('Bot #%d icin gecerli bir baslangic konumu bulunamadi (trap house yok, dispatcher ped cozulemedi).'):format(botId))
        return
    end

    local ok, err, legIndex, legDist = Matrix.BeginRouteDispatch(botId, origin, waypoints, finalCoords, plate, vehicleType, src)
    if ok then
        Reply(src, ('[ROTA CIZILDI] Bot #%d icin %d ugraklik taktik kacis rotasi baslatildi.'):format(botId, #waypoints + 1))
    elseif err == 'too_close' and legIndex then
        local totalLegs = #waypoints + 1
        local fromLabel = (legIndex == 1) and 'Bot Konumu' or ('Ugrak #%d'):format(legIndex - 1)
        local toLabel   = (legIndex == totalLegs) and 'Final Hedef' or ('Ugrak #%d'):format(legIndex)
        Reply(src, ('Rota baslatilamadi: %s -> %s arasi cok yakin (%.1fm < %.1fm gerekli). Isinlanma korumasi engelledi.'):format(
            fromLabel, toLabel, legDist or 0.0, Config.Logistics.MinDispatchDistanceMeters))
    else
        Reply(src, ('Rota baslatilamadi: %s'):format(tostring(err)))
    end
end, false)

Matrix.Security.RegisterGatedCommand('balistiktest', function(src, args)
    local weaponSerial = tostring(args[1] or 'TEST-SERIAL-0001')
    local weaponWear   = Matrix.Clamp(tonumber(args[2]) or 0.0, 0.0, 1.0)

    local result = Matrix.Forensics.SimulateWeaponFire({ kind = 'player', source = src }, weaponSerial, weaponWear, 'test_fire')
    if not result then Reply(src, 'Test başarısız: oyuncu profili çözülemedi.'); return end

    Reply(src, ('BalistikID:%s | Q_kovan:%.3f | Parmak izi:%.3f | Eşleşme:%.3f | Mühür:%s'):format(
        result.ballistic_id, result.striation_quality, result.fingerprint_quality,
        result.match_certainty, tostring(result.sealed)))
end)

Matrix.Security.RegisterGatedCommand('botbalistik', function(src, args)
    local botId = tonumber(args[1])
    if not botId or not Matrix.Bots[botId] then
        Reply(src, 'Kullanim: /botbalistik [id] [seri] [asinma 0-1]'); return
    end
    local weaponSerial = tostring(args[2] or ('TEST-SERIAL-BOT-%d'):format(botId))
    local weaponWear   = Matrix.Clamp(tonumber(args[3]) or 0.0, 0.0, 1.0)

    local result = Matrix.Forensics.SimulateWeaponFire({ kind = 'bot', id = botId }, weaponSerial, weaponWear, 'test_fire')
    if not result then Reply(src, 'Test başarısız.'); return end

    Reply(src, ('Bot #%d | BalistikID:%s | Q_kovan:%.3f | Eşleşme:%.3f | Mühür:%s'):format(
        botId, result.ballistic_id, result.striation_quality,
        result.match_certainty, tostring(result.sealed)))
end)

RegisterCommand('kortizolum', function(src)
    local state = Matrix.GetOrCreatePlayerState(src)
    if not state then Reply(src, 'Profil çözülemedi.'); return end
    Reply(src, ('Kortizol:%.2f | Yorgunluk:%.2f | Direnç:%.2f | Toparlanma:%.4f'):format(
        state.biology.cortisol_level, state.biology.fatigue_level,
        state.biology.resilience, state.biology.base_cortisol_recovery_rate))
end, false)

Matrix.Security.RegisterGatedCommand('kortizoltetikle', function(src, args)
    local spikeType = args[1] or 'gunshot'
    if spikeType ~= 'gunshot' and spikeType ~= 'bureau_vehicle' then
        Reply(src, 'Kullanim: /kortizoltetikle [gunshot|bureau_vehicle]'); return
    end
    Matrix.Kitchen.AdjustCortisol({ kind = 'player', source = src }, spikeType)
    local state = Matrix.GetOrCreatePlayerState(src)
    if state then
        Reply(src, ('Kortizol sıçraması (%s). Yeni seviye: %.2f'):format(spikeType, state.biology.cortisol_level))
    end
end)

RegisterCommand('botdurum', function(src, args)
    local botId = tonumber(args[1])
    local bot = botId and Matrix.Bots[botId]
    if not bot then Reply(src, 'Kullanim: /botdurum [id]'); return end
    Reply(src, ('Bot #%d [%s] Kortizol:%.2f Yorgunluk:%.2f Yoksunluk:%.2f Direnç:%.2f'):format(
        bot.id, bot.name, bot.biology.cortisol_level, bot.biology.fatigue_level,
        bot.biology.withdrawal_index, bot.psychology.resilience))
end, false)

exports('CreateBot',   function(p) return Matrix.CreateBotRecord(p) end)
exports('SpawnBot',    function(id, c) return Matrix.SpawnBot(id, c) end)
exports('DespawnBot',  function(id) return Matrix.DespawnBot(id) end)
exports('RemoveBot',   function(id, r) return Matrix.RemoveBot(id, r) end)
exports('GetBot',      function(id) return Matrix.GetBot(id) end)
exports('GetBotReadOnly', function(id, cellName) return Matrix.GetBotReadOnly(id, cellName) end)
exports('GetBotDeepCopy', function(id) return Matrix.GetBotDeepCopy(id) end)
exports('SetBotInteriorTrapHouse', function(id, trapHouseId)
    return Matrix.SetBotInteriorTrapHouse(id, trapHouseId)
end)

exports('BeginPhysicalDispatch', function(botId, origin, destination, plate, vehicleType, eta, src, frictionDivisor)
    return Matrix.BeginPhysicalDispatch(botId, origin, destination, plate, vehicleType, eta, src, frictionDivisor)
end)
exports('BeginRouteDispatch', function(botId, origin, waypoints, finalDest, plate, vehicleType, src, frictionDivisor)
    return Matrix.BeginRouteDispatch(botId, origin, waypoints, finalDest, plate, vehicleType, src, frictionDivisor)
end)
exports('CompleteDispatch', function(botId, reason)
    return Matrix.CompleteDispatch(botId, reason)
end)
exports('GetActiveDispatches', function()
    return Matrix.Dispatches
end)
exports('DepositDealerCargoToTrapStash', function(botId, trapHouseId)
    return Matrix.DepositDealerCargoToTrapStash(botId, trapHouseId)
end)
exports('TriggerPanicEvacuation', function(botId, dispatcherSrc)
    return Matrix.TriggerPanicEvacuation(botId, dispatcherSrc)
end)

exports('ReportWeaponDischarge', function(actorRef, weaponSerial, invId, slot)
    return Matrix.Forensics.OnWeaponFired(actorRef, weaponSerial, invId, slot)
end)
exports('SimulateWeaponFire', function(actorRef, weaponSerial, wear, evType, durability)
    return Matrix.Forensics.SimulateWeaponFire(actorRef, weaponSerial, wear, evType, durability)
end)
exports('StampTouch',     function(actorRef, invId, slot) return Matrix.Forensics.StampTouch(actorRef, invId, slot) end)
exports('AnalyzeEvidence',function(evId) return Matrix.Forensics.AnalyzeEvidence(evId) end)

exports('ProcessCook',  function(a, t, rw, rp, aw) return Matrix.Kitchen.ProcessCook(a, t, rw, rp, aw) end)
exports('AdjustCortisol',function(a, s) return Matrix.Kitchen.AdjustCortisol(a, s) end)
exports('OnBotCaptured', function(b, t) return Matrix.Kitchen.OnCaptured(b, t) end)

exports('TriggerPropaganda',     function(t) return Matrix.Bureau.TriggerPropaganda(t) end)
exports('ReportUnencryptedComms',function(a, c) return Matrix.Bureau.OnUnencryptedComms(a, c) end)
exports('ReportLogisticsRun',    function(t) return Matrix.Bureau.LogPatternEvent(t) end)

exports('ScanCustomerPool',       function() return Matrix.Recruitment.ScanCustomerPool() end)
exports('BeginInterrogation',     function(c, s) return Matrix.Recruitment.BeginInterrogation(c, s) end)
exports('ApplyInterrogationPressure', function(s, a) return Matrix.Recruitment.ApplyPressure(s, a) end)
exports('EvaluateInterrogation',  function(s) return Matrix.Recruitment.EvaluateOutcome(s) end)

local VALID_PSYCHOLOGY_FIELDS = {
    fear_factor = true, resilience = true, snitch_tendency = true,
    economic_pressure = true, cognitive_shifter = true,
    skill_chemistry = true, skill_cyber = true, skill_logistics = true,
    loyalty_base = true
}
local VALID_BIOLOGY_FIELDS = {
    fatigue_level = true, cortisol_level = true, withdrawal_index = true,
    addiction_level = true, base_cortisol_recovery_rate = true
}

Matrix.Security.RegisterGatedCommand('botskill', function(src, args)
    local botId = tonumber(args[1])
    local field = args[2]
    local value = tonumber(args[3])
    local bot = botId and Matrix.Bots[botId]
    if not bot or not VALID_PSYCHOLOGY_FIELDS[field] or not value then
        Reply(src, 'Kullanim: /botskill [id] [fear_factor|resilience|snitch_tendency|economic_pressure|cognitive_shifter|skill_chemistry|skill_cyber|skill_logistics|loyalty_base] [0.0-1.0]')
        return
    end
    bot.psychology[field] = Matrix.Clamp(value, 0.0, 1.0)
    Matrix.MarkBotDirty(botId)
    Reply(src, ('Bot #%d %s = %.3f olarak ayarlandı.'):format(botId, field, bot.psychology[field]))
end)

Matrix.Security.RegisterGatedCommand('botbio', function(src, args)
    local botId = tonumber(args[1])
    local field = args[2]
    local value = tonumber(args[3])
    local bot = botId and Matrix.Bots[botId]
    if not bot or not VALID_BIOLOGY_FIELDS[field] or not value then
        Reply(src, 'Kullanim: /botbio [id] [fatigue_level|cortisol_level|withdrawal_index|addiction_level|base_cortisol_recovery_rate] [deger]')
        return
    end
    local maxV = (field == 'addiction_level') and 100.0 or 1.0
    bot.biology[field] = Matrix.Clamp(value, 0.0, maxV)
    Matrix.MarkBotDirty(botId)
    Reply(src, ('Bot #%d %s = %.3f olarak ayarlandı.'):format(botId, field, bot.biology[field]))
end)

Matrix.Security.RegisterGatedCommand('botmekanik', function(src, args)
    local botId = tonumber(args[1])
    local value = tonumber(args[2])
    local bot = botId and Matrix.Bots[botId]
    if not bot or not value then
        Reply(src, 'Kullanim: /botmekanik [id] [asinma 0.0-1.0] (1.0=kusursuz, 0.0=eriimis)')
        return
    end
    bot.state.weapon_wear_level = Matrix.Clamp(value, 0.0, 1.0)
    Reply(src, ('Bot #%d silah asinmasi (ham) = %.3f olarak ayarlandi.'):format(botId, bot.state.weapon_wear_level))
end)

Matrix.Security.RegisterGatedCommand('radyoparazit', function(src, args)
    local targetSrc = tonumber(args[1]) or src
    local intensity = tonumber(args[2]) or 1.0
    Matrix.Radio.ApplyStatic(targetSrc, intensity, 'debug')
    Reply(src, ('Telsiz statiği src=%d yoğunluk=%.2f olarak tetiklendi.'):format(targetSrc, intensity))
end)

Matrix.Security.RegisterGatedCommand('matrixdump', function(src)
    local count = 0
    for id, bot in pairs(Matrix.Bots) do
        count = count + 1
        Reply(src, ('#%d [%s|%s|%s] Fat:%.2f Cort:%.2f With:%.2f | Chem:%.2f Cyber:%.2f Log:%.2f | Res:%.2f Snitch:%.2f Loyal:%.2f | Mekanik:%.2f'):format(
            id, bot.name, bot.role, bot.status,
            bot.biology.fatigue_level, bot.biology.cortisol_level, bot.biology.withdrawal_index,
            bot.psychology.skill_chemistry, bot.psychology.skill_cyber, bot.psychology.skill_logistics,
            bot.psychology.resilience, bot.psychology.snitch_tendency, bot.psychology.loyalty_base or 0.5,
            bot.state.weapon_wear_level or 1.0))
    end
    Reply(src, ('--- Toplam %d bot ---'):format(count))
end)

Matrix.Security.RegisterGatedCommand('fizikselsevk', function(src, args)
    local count = 0
    for botId, d in pairs(Matrix.Dispatches) do
        count = count + 1
        local lc = d.last_coords or d.origin
        local routeInfo = d.route_queue and (' Rota:%d/%d'):format(d.route_index, #d.route_queue) or ''
        Reply(src, ('Bot #%d [%s] Plaka:%s Konum:(%.1f,%.1f,%.1f) Hedef-Mesafe:%.1fm Hiz:%.2fm/s Sinyal:%s Polis-Dwell:%d Bekleyen:%d%s'):format(
            botId, d.vehicle_type, tostring(d.plate),
            lc.x, lc.y, lc.z,
            #(lc - d.destination),
            d.cruise_speed or 0.0,
            d.comms_lost and 'KESİK' or 'VAR',
            d.police_dwell,
            #d.pending_events,
            routeInfo))
    end
    Reply(src, ('--- Toplam %d fiziksel dispatch ---'):format(count))
end)