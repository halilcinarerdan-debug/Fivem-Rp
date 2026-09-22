-- =====================================================================
-- MATRIX LOGISTICS / server/logistics.lua  (KATMAN 5 — MÜHÜRLÜ SÜRÜM)
--
-- ★ BU SÜRÜMDEKİ EK SERTLEŞTİRME:
--   [L1] QueueOrEmit FIFO-cap'li (PENDING_EVENTS_MAX=64).
--   [L2] DropHeat tablosu: bir drop 0.0 heat'e indiğinde girdi SİLİNİR.
--   [L3] ReleaseVehicleLock idempotent.
--   [L4] Tüm entity-temizleme yolları pcall + DoesEntityExist guard'lı.
--
-- ★★★ YAMA 4 (BU SÜRÜM) — SERVER-AUTHORITATIVE RELAY ★★★
--   • [HITSQUADDRIVEBY] CLIENT-SIDE cooldown TAMAMEN KALDIRILDI.
--   • Server artık PER-BOT (3sn) + PER-CLIENT (1sn) iki katmanlı rate-limit
--     uygular; NetOwner handoff veya NetID rotasyonu ile bypass imkansız.
--   • _RelayCooldownByBotId / _RelayCooldownByClient tabloları TTL-purge'lı;
--     bot silindiğinde Matrix.RemoveBot'un purge hook'u tarafından kazınır.
--   • /relaypurge operatör komutu elle temizlik sağlar.
-- =====================================================================


Matrix.Logistics = Matrix.Logistics or {}
Matrix.Fleet      = Matrix.Fleet      or {}
Matrix.Supplier   = Matrix.Supplier   or {}


local pairs, ipairs, type, tostring = pairs, ipairs, type, tostring
local tonumber, table, math         = tonumber, table, math
local math_max, math_min, math_huge = math.max, math.min, math.huge


local CreateThread                  = CreateThread
local Wait                          = Wait
local SetTimeout                    = SetTimeout
local GetPlayerPed                  = GetPlayerPed
local GetEntityCoords               = GetEntityCoords
local NetworkGetEntityFromNetworkId = NetworkGetEntityFromNetworkId
local DoesEntityExist               = DoesEntityExist
local SetEntityCoords               = SetEntityCoords
local TriggerClientEvent            = TriggerClientEvent
local RegisterCommand               = RegisterCommand
local RegisterNetEvent              = RegisterNetEvent


local PENDING_EVENTS_MAX = 64


-- =====================================================================
-- RUNTIME STATE
-- =====================================================================
local FleetVehicles         = {}
local PermanentVehicleByBot = {}
local ActiveVehicleLocks    = {}


local SupplierTrustCache    = {}
local ActiveDrops           = {}
local DropHeat              = {}


local dirtyFleet            = {}
local dirtySupplierTrust    = {}


local WARNED_MISSING_FLEET  = false
local WARNED_MISSING_TRUST  = false


-- =====================================================================
-- UTILITIES
-- =====================================================================
local function VectorDistance(a, b)
    if not a or not b then return math_huge end
    if type(a) ~= 'userdata' and type(a) ~= 'table' and type(a) ~= 'vector3' and type(a) ~= 'vector4' then return math_huge end
    if type(b) ~= 'userdata' and type(b) ~= 'table' and type(b) ~= 'vector3' and type(b) ~= 'vector4' then return math_huge end
    return #(a - b)
end


local function LerpCoords(a, b, t)
    t = Matrix.Clamp(t, 0.0, 1.0)
    return vector3(
        a.x + (b.x - a.x) * t,
        a.y + (b.y - a.y) * t,
        a.z + (b.z - a.z) * t
    )
end


local function IsValidCoords(c)
    if type(c) ~= 'table' and type(c) ~= 'userdata' and type(c) ~= 'vector3' and type(c) ~= 'vector4' then return false end
    return c.x ~= nil and c.y ~= nil and c.z ~= nil
end


local function GetVehicleProfile(vehicleType)
    return Config.Logistics.VehicleTypes[vehicleType]
        or Config.Logistics.VehicleTypes[Config.Logistics.DefaultVehicleType]
end


local function ValidateDestination(origin, destination)
    if destination == nil then return false, 'missing_vector' end
    if type(destination) ~= 'table' and type(destination) ~= 'userdata'
        and type(destination) ~= 'vector3' and type(destination) ~= 'vector4' then
        return false, 'corrupt_vector'
    end


    local x, y, z = destination.x, destination.y, destination.z
    if type(x) ~= 'number' or type(y) ~= 'number' or type(z) ~= 'number' then
        return false, 'corrupt_vector'
    end
    if x ~= x or y ~= y or z ~= z then return false, 'corrupt_vector' end
    if x == math_huge or x == -math_huge or y == math_huge or y == -math_huge
        or z == math_huge or z == -math_huge then
        return false, 'corrupt_vector'
    end


    if origin then
        local dist = VectorDistance(origin, destination)
        if dist > Config.Logistics.MaxDispatchRangeMeters then
            return false, 'out_of_range', dist
        end
        if dist < Config.Logistics.MinDispatchDistanceMeters then
            return false, 'too_close', dist
        end
    end
    return true
end


local function GetBotInventoryWeight(bot)
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
        local d = VectorDistance(coords, house.coords)
        if d < nearestDist then nearestId, nearestDist = id, d end
    end
    return nearestId, nearestDist
end


local function FindDeadZone(coords)
    for _, zone in ipairs(Config.Logistics.DeadZones) do
        if VectorDistance(coords, zone.coords) <= zone.radius then return zone end
    end
    return nil
end


local function QueueOrEmit(dispatch, message)
    if dispatch.comms_lost then
        local events = dispatch.pending_events
        if #events >= PENDING_EVENTS_MAX then
            table.remove(events, 1)
        end
        events[#events + 1] = message
    else
        Matrix.Log('LOGISTICS', message)
    end
end


local function FlushPendingEvents(dispatch)
    if #dispatch.pending_events == 0 then return end
    Matrix.Log('LOGISTICS', '[GECİKMELİ VERİ AKIŞI] Bot #%d için %d olay toplu iletiliyor.',
        dispatch.bot_id, #dispatch.pending_events)
    for _, msg in ipairs(dispatch.pending_events) do
        Matrix.Log('LOGISTICS', '  -> %s', msg)
    end
    dispatch.pending_events = {}
end


-- =====================================================================
-- ILLEGAL FLEET: ASENKRON YÜKLEME
-- =====================================================================
function Matrix.Fleet.LoadFleet()
    local callOk, callErr = pcall(function()
        MySQL.query('SELECT * FROM matrix_fleet', {}, function(rows)
            local cbOk, cbErr = pcall(function()
                if type(rows) ~= 'table' then
                    if not WARNED_MISSING_FLEET then
                        WARNED_MISSING_FLEET = true
                        Matrix.Log('LOGISTICS',
                            '[HATA] Filo veri tabani tablosu (matrix_fleet) bulunamadi/okunamadi. Bellekteki yedek onbellek (RAM) devreye alindi; simulasyon kesintisiz suruyor.')
                    end
                    return
                end


                for _, row in ipairs(rows) do
                    if row and row.plate then
                        FleetVehicles[row.plate] = {
                            plate                   = row.plate,
                            vehicle_class           = row.vehicle_class or Config.Logistics.Fleet.DefaultVehicleClass,
                            vin_status              = row.vin_status or Config.Logistics.Fleet.DefaultVinStatus,
                            vehicle_wear            = tonumber(row.vehicle_wear) or 0.0,
                            registered_by_citizenid = row.registered_by_citizenid,
                            assigned_bot_id         = row.assigned_bot_id,
                            assignment_mode         = row.assignment_mode,
                            verified_stolen_plate   = (row.verified_stolen_plate == 1)
                        }
                        if row.assigned_bot_id and row.assignment_mode == 'permanent' then
                            PermanentVehicleByBot[row.assigned_bot_id] = row.plate
                        end
                    end
                end
                Matrix.Log('LOGISTICS', '%d illegal arac filoya yuklendi (async).', #rows)
            end)


            if not cbOk then
                Matrix.Log('LOGISTICS',
                    '[HATA] matrix_fleet callback isleme hatasi (simulasyon suruyor): %s',
                    tostring(cbErr))
            end
        end)
    end)


    if not callOk then
        if not WARNED_MISSING_FLEET then
            WARNED_MISSING_FLEET = true
            Matrix.Log('LOGISTICS',
                '[HATA] matrix_fleet sorgu cagrisi reddedildi; RAM onbellek devrede (simulasyon suruyor): %s',
                tostring(callErr))
        end
    end
end


CreateThread(function()
    Matrix.Fleet.LoadFleet()
end)


-- =====================================================================
-- ILLEGAL FLEET: ASENKRON PERSISTENCE
-- =====================================================================
local function MarkFleetDirty(plate)
    if plate then dirtyFleet[plate] = true end
end


local function FlushDirtyFleet()
    local pendingPlates = {}
    for plate in pairs(dirtyFleet) do
        pendingPlates[#pendingPlates + 1] = plate
    end
    if #pendingPlates == 0 then return end


    local queries = {}
    for _, plate in ipairs(pendingPlates) do
        local v = FleetVehicles[plate]
        if v then
            queries[#queries + 1] = {
                query = [[
                    INSERT INTO matrix_fleet
                        (plate, vehicle_class, vin_status, vehicle_wear, registered_by_citizenid,
                         assigned_bot_id, assignment_mode, verified_stolen_plate, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, NOW(), NOW())
                    ON DUPLICATE KEY UPDATE
                        vehicle_class           = VALUES(vehicle_class),
                        vin_status              = VALUES(vin_status),
                        vehicle_wear            = VALUES(vehicle_wear),
                        registered_by_citizenid = VALUES(registered_by_citizenid),
                        assigned_bot_id         = VALUES(assigned_bot_id),
                        assignment_mode         = VALUES(assignment_mode),
                        verified_stolen_plate   = VALUES(verified_stolen_plate),
                        updated_at              = NOW()
                ]],
                values = {
                    v.plate, v.vehicle_class, v.vin_status, v.vehicle_wear,
                    v.registered_by_citizenid, v.assigned_bot_id, v.assignment_mode,
                    v.verified_stolen_plate and 1 or 0
                }
            }
        end
    end


    if #queries == 0 then
        for _, plate in ipairs(pendingPlates) do dirtyFleet[plate] = nil end
        return
    end


    local ok, result = pcall(function() return MySQL.transaction.await(queries) end)
    if ok and result ~= false then
        for _, plate in ipairs(pendingPlates) do dirtyFleet[plate] = nil end
    else
        Matrix.Log('LOGISTICS',
            '[HATA][KRITIK] FlushDirtyFleet transaction basarisiz -- dirty bayraklar KORUNDU, tekrar denenecek: %s',
            tostring(result))
    end
end


-- =====================================================================
-- ILLEGAL FLEET: KAYIT / ATAMA
-- =====================================================================
function Matrix.Fleet.GetVehicle(plate)
    if type(plate) ~= 'string' then return nil end
    return FleetVehicles[plate]
end


local function VerifyStolenPlateAsync(plate)
    pcall(function()
        MySQL.query('SELECT citizenid FROM player_vehicles WHERE plate = ?', { plate }, function(rows)
            local cbOk = pcall(function()
                local v = FleetVehicles[plate]
                if not v then return end
                if type(rows) == 'table' and rows[1] then
                    v.verified_stolen_plate = true
                    MarkFleetDirty(plate)
                    Matrix.Log('LOGISTICS',
                        '[QB-CORE DOĞRULAMA] %s hakiki çalıntı olarak doğrulandı (sahip: %s).',
                        plate, tostring(rows[1].citizenid))
                end
            end)
            if not cbOk then
                Matrix.Log('LOGISTICS', '[HATA] stolen-plate callback hatasi (yutuldu): %s', plate)
            end
        end)
    end)
end


function Matrix.Fleet.RegisterVehicle(citizenid, plate, vehicleClass, vinStatus, vehicleWear)
    if type(plate) ~= 'string' or plate == '' or #plate > 32 then return false, 'bad_plate' end
    if FleetVehicles[plate] then return false, 'plate_exists' end


    vehicleClass = (vehicleClass == 'motorbike' or vehicleClass == 'car')
        and vehicleClass or Config.Logistics.Fleet.DefaultVehicleClass
    vinStatus = (vinStatus == 'factory' or vinStatus == 'scratched' or vinStatus == 'hot')
        and vinStatus or Config.Logistics.Fleet.DefaultVinStatus
    vehicleWear = Matrix.Clamp(tonumber(vehicleWear) or 0.0, 0.0, 1.0)


    FleetVehicles[plate] = {
        plate                   = plate,
        vehicle_class           = vehicleClass,
        vin_status              = vinStatus,
        vehicle_wear            = vehicleWear,
        registered_by_citizenid = citizenid,
        assigned_bot_id         = nil,
        assignment_mode         = nil,
        verified_stolen_plate   = false
    }
    MarkFleetDirty(plate)


    VerifyStolenPlateAsync(plate)


    Matrix.Log('LOGISTICS',
        'Illegal arac filoya kaydedildi (RAM + dirty-flag): %s [%s/%s] asinma=%.2f (sahip:%s)',
        plate, vehicleClass, vinStatus, vehicleWear, tostring(citizenid))


    return true
end


function Matrix.Fleet.AssignPermanent(plate, botId)
    local vehicle = FleetVehicles[plate]
    if not vehicle then return false, 'vehicle_not_found' end


    local bot = Matrix.Bots[botId]
    if not bot then return false, 'bot_missing' end


    if vehicle.assigned_bot_id and vehicle.assigned_bot_id ~= botId then
        return false, 'vehicle_assigned_elsewhere'
    end
    if PermanentVehicleByBot[botId] and PermanentVehicleByBot[botId] ~= plate then
        return false, 'bot_already_has_vehicle'
    end


    vehicle.assigned_bot_id = botId
    vehicle.assignment_mode = 'permanent'
    PermanentVehicleByBot[botId] = plate
    MarkFleetDirty(plate)


    Matrix.Log('LOGISTICS', 'Arac %s -> Bot #%d (%s) kalici olarak atandi.', plate, botId, bot.name)
    return true
end


function Matrix.Fleet.UnassignPermanent(plate)
    local vehicle = FleetVehicles[plate]
    if not vehicle or not vehicle.assigned_bot_id then return false end


    PermanentVehicleByBot[vehicle.assigned_bot_id] = nil
    vehicle.assigned_bot_id = nil
    vehicle.assignment_mode = nil
    MarkFleetDirty(plate)


    Matrix.Log('LOGISTICS', 'Arac %s serbest birakildi (kalici atama kaldirildi).', plate)
    return true
end


function Matrix.Fleet.GetVehicleByBot(botId)
    local plate = PermanentVehicleByBot[tonumber(botId)]
    if not plate then return nil end
    return FleetVehicles[plate]
end


function Matrix.Fleet.RecordAlprHit(plate, dnaId, organizationSignature, trapHouseId)
    MySQL.prepare([[
        INSERT INTO matrix_alpr_hits (plate, fingerprint_dna_id, organization_signature, trap_house_id, created_at)
        VALUES (?, ?, ?, ?, NOW())
    ]], { plate, dnaId or 'UNKNOWN', organizationSignature or 'UNKNOWN', trapHouseId })
end


function Matrix.Fleet.SeizeVehicle(plate, cause, dnaId, coords)
    local vehicle = FleetVehicles[plate]
    if not vehicle then return false end


    local certainty = Config.Logistics.Fleet.SeizureSealCertainty[vehicle.vin_status]
        or Config.Logistics.Fleet.SeizureSealCertainty[Config.Logistics.Fleet.DefaultVinStatus]


    if vehicle.verified_stolen_plate then
        certainty = Matrix.Clamp(certainty + 0.03, 0.0, 1.0)
    end


    local cx, cy, cz = 0.0, 0.0, 0.0
    if IsValidCoords(coords) then cx, cy, cz = coords.x, coords.y, coords.z end


    MySQL.prepare([[
        INSERT INTO matrix_vehicle_seizures (
            plate, vin_status, vehicle_wear, fingerprint_dna_id, organization_signature,
            seizure_cause, seal_certainty, coords_x, coords_y, coords_z, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NOW())
    ]], {
        plate, vehicle.vin_status, vehicle.vehicle_wear, dnaId or 'UNKNOWN',
        vehicle.registered_by_citizenid or 'UNKNOWN', cause or 'unknown', certainty, cx, cy, cz
    })


    if vehicle.assigned_bot_id then PermanentVehicleByBot[vehicle.assigned_bot_id] = nil end
    ActiveVehicleLocks[plate] = nil
    FleetVehicles[plate] = nil
    dirtyFleet[plate] = nil


    MySQL.prepare('DELETE FROM matrix_fleet WHERE plate = ?', { plate })


    Matrix.Log('LOGISTICS',
        '[FILO KAYIP: %s MUHURLENDI VE FILODAN SILINDI] Sebep:%s | VIN:%s | Muhur-Kesinlik:%.2f',
        plate, tostring(cause or 'unknown'), vehicle.vin_status, certainty)
    return true
end


function Matrix.Logistics.OnVehicleEncircled(plate, cause)
    local vehicle = Matrix.Fleet.GetVehicle(plate)
    if not vehicle then return false end


    local usingBotId = ActiveVehicleLocks[plate] or vehicle.assigned_bot_id
    local bot = usingBotId and Matrix.Bots[usingBotId]


    local dnaId, coords = 'UNKNOWN', nil
    if bot then
        dnaId = bot.dna_id
        coords = bot.state.coords
    end


    return Matrix.Fleet.SeizeVehicle(plate, cause or 'police_encirclement', dnaId, coords)
end


function Matrix.Logistics.ReleaseVehicleLock(plate)
    if plate and ActiveVehicleLocks[plate] then
        ActiveVehicleLocks[plate] = nil
    end
end


-- =====================================================================
-- TOPTANCI İLİŞKİ MATRİSİ & DEAD DROP LOJİSTİĞİ
-- =====================================================================
local function TrustKey(citizenid, supplierId)
    return tostring(citizenid) .. '#' .. tostring(supplierId)
end


local function GetDropConfig(dropId)
    for _, drop in ipairs(Config.Supplier.DeadDrops) do
        if drop.id == dropId then return drop end
    end
    return nil
end


local function FindActiveDeadDropAt(coords)
    for dropId, drop in pairs(ActiveDrops) do
        local cfg = GetDropConfig(dropId)
        if cfg and VectorDistance(coords, cfg.coords) <= cfg.radius then
            return dropId, drop, cfg
        end
    end
    return nil
end


function Matrix.Supplier.LoadTrust()
    local callOk, callErr = pcall(function()
        MySQL.query('SELECT * FROM matrix_supplier_trust', {}, function(rows)
            local cbOk, cbErr = pcall(function()
                if type(rows) ~= 'table' then
                    if not WARNED_MISSING_TRUST then
                        WARNED_MISSING_TRUST = true
                        Matrix.Log('LOGISTICS',
                            '[HATA] Toptanci guven tablosu (matrix_supplier_trust) bulunamadi/okunamadi. RAM onbellek devrede; varsayilan trust (0.5) uzerinden simulasyon suruyor.')
                    end
                    return
                end


                for _, row in ipairs(rows) do
                    if row and row.citizenid then
                        SupplierTrustCache[TrustKey(row.citizenid, row.supplier_id)] = {
                            citizenid       = row.citizenid,
                            supplier_id     = row.supplier_id,
                            trust           = tonumber(row.trust) or Config.Supplier.DefaultTrust,
                            late_payments   = row.late_payments or 0,
                            forensic_leaks  = row.forensic_leaks or 0,
                            last_touched    = Matrix.Now()
                        }
                    end
                end
                Matrix.Log('LOGISTICS', '%d toptanci guven iliskisi yuklendi (async).', #rows)
            end)


            if not cbOk then
                Matrix.Log('LOGISTICS',
                    '[HATA] matrix_supplier_trust callback hatasi (simulasyon suruyor): %s',
                    tostring(cbErr))
            end
        end)
    end)


    if not callOk then
        if not WARNED_MISSING_TRUST then
            WARNED_MISSING_TRUST = true
            Matrix.Log('LOGISTICS',
                '[HATA] matrix_supplier_trust sorgu cagrisi reddedildi; RAM onbellek devrede: %s',
                tostring(callErr))
        end
    end
end


CreateThread(function()
    Matrix.Supplier.LoadTrust()
end)


local function ApplyPassiveTrustDrift(rec)
    local now = Matrix.Now()
    local elapsedDays = (now - (rec.last_touched or now)) / 86400.0
    rec.last_touched = now
    if elapsedDays <= 0.0 then return end


    local target = Config.Supplier.PassiveTrustRecoveryTarget
    local closedFraction = 1.0 - ((1.0 - Config.Supplier.PassiveTrustRecoveryPerRealDay) ^ elapsedDays)
    rec.trust = Matrix.Clamp(rec.trust + ((target - rec.trust) * closedFraction), 0.0, 1.0)
end


function Matrix.Supplier.GetTrustRecord(citizenid, supplierId)
    local key = TrustKey(citizenid, supplierId)
    local rec = SupplierTrustCache[key]
    if not rec then
        rec = {
            citizenid = citizenid, supplier_id = supplierId,
            trust = Config.Supplier.DefaultTrust,
            late_payments = 0, forensic_leaks = 0,
            last_touched = Matrix.Now()
        }
        SupplierTrustCache[key] = rec
    else
        ApplyPassiveTrustDrift(rec)
    end
    return rec
end


function Matrix.Supplier.GetTrust(citizenid, supplierId)
    return Matrix.Supplier.GetTrustRecord(citizenid, supplierId).trust
end


local function MarkSupplierTrustDirty(citizenid, supplierId)
    dirtySupplierTrust[TrustKey(citizenid, supplierId)] = true
end


local function FlushDirtySupplierTrust()
    local pendingKeys = {}
    for key in pairs(dirtySupplierTrust) do
        pendingKeys[#pendingKeys + 1] = key
    end
    if #pendingKeys == 0 then return end


    local queries = {}
    for _, key in ipairs(pendingKeys) do
        local rec = SupplierTrustCache[key]
        if rec then
            queries[#queries + 1] = {
                query = [[
                    INSERT INTO matrix_supplier_trust
                        (citizenid, supplier_id, trust, late_payments, forensic_leaks, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, NOW(), NOW())
                    ON DUPLICATE KEY UPDATE
                        trust          = VALUES(trust),
                        late_payments  = VALUES(late_payments),
                        forensic_leaks = VALUES(forensic_leaks),
                        updated_at     = NOW()
                ]],
                values = { rec.citizenid, rec.supplier_id, rec.trust, rec.late_payments, rec.forensic_leaks }
            }
        end
    end


    if #queries == 0 then
        for _, key in ipairs(pendingKeys) do dirtySupplierTrust[key] = nil end
        return
    end


    local ok, result = pcall(function() return MySQL.transaction.await(queries) end)
    if ok and result ~= false then
        for _, key in ipairs(pendingKeys) do dirtySupplierTrust[key] = nil end
    else
        Matrix.Log('LOGISTICS',
            '[HATA][KRITIK] FlushDirtySupplierTrust transaction basarisiz -- dirty bayraklar KORUNDU, tekrar denenecek: %s',
            tostring(result))
    end
end


function Matrix.Supplier.GetPriceMultiplier(citizenid, supplierId)
    local trust = Matrix.Supplier.GetTrust(citizenid, supplierId)
    local mult = 1.0 + ((1.0 - trust) * Config.Supplier.PriceMultiplierGain)
    return Matrix.Clamp(mult, Config.Supplier.PriceMultiplierFloor, Config.Supplier.PriceMultiplierCeiling)
end


function Matrix.Supplier.TriggerBetrayal(citizenid, supplierId)
    local targetId = nil
    for id in pairs(Matrix.TrapHouses or {}) do
        if not targetId or id < targetId then targetId = id end
    end
    if targetId then
        Matrix.Bureau.ReceiveSnitchLeak(targetId)
    end


    Matrix.Log('LOGISTICS',
        '[IHANET] Toptanci #%d guven esiginin altina dustu: %s desifre edildi / infaz mangasi yolda.',
        supplierId, tostring(citizenid))
    TriggerClientEvent('matrix:client:executeHitSquad', -1, citizenid, supplierId)
end


function Matrix.Supplier.ReportLatePayment(citizenid, supplierId)
    local rec = Matrix.Supplier.GetTrustRecord(citizenid, supplierId)
    rec.late_payments = rec.late_payments + 1
    rec.trust = Matrix.Clamp(rec.trust - Config.Supplier.TrustLatePaymentPenalty, 0.0, 1.0)
    MarkSupplierTrustDirty(citizenid, supplierId)


    Matrix.Log('LOGISTICS', 'Toptanci #%d guveni dustu (gecikmis odeme): %s -> %.2f',
        supplierId, tostring(citizenid), rec.trust)


    if rec.trust < Config.Supplier.BetrayalTrustThreshold then
        Matrix.Supplier.TriggerBetrayal(citizenid, supplierId)
    end
    return rec.trust
end


function Matrix.Supplier.ApplyBureauIntelLeak(citizenid, supplierId, penalty, dropId)
    local rec = Matrix.Supplier.GetTrustRecord(citizenid, supplierId)
    rec.trust = Matrix.Clamp(rec.trust - (tonumber(penalty) or 0.0), 0.0, 1.0)
    rec.forensic_leaks = rec.forensic_leaks + 1
    MarkSupplierTrustDirty(citizenid, supplierId)


    Matrix.Log('LOGISTICS',
        '[BÜRO SIZINTISI] Drop #%s üzerinden toptancı #%d güveni düştü: %s -> %.3f',
        tostring(dropId), supplierId, tostring(citizenid), rec.trust)


    if rec.trust < Config.Supplier.BetrayalTrustThreshold then
        Matrix.Supplier.TriggerBetrayal(citizenid, supplierId)
    end


    return rec.trust
end


function Matrix.Supplier.RequestDrop(citizenid, dropId)
    local dropCfg = GetDropConfig(dropId)
    if not dropCfg then return false, 'bad_drop' end
    if ActiveDrops[dropId] then return false, 'already_active' end


    local rec = Matrix.Supplier.GetTrustRecord(citizenid, dropCfg.supplier_id)
    if rec.trust < Config.Supplier.SupplyCutTrustThreshold then
        return false, 'supply_cut'
    end


    ActiveDrops[dropId] = {
        supplier_id  = dropCfg.supplier_id,
        citizenid    = citizenid,
        requested_at = Matrix.Now(),
        expires_at   = Matrix.Now() + Config.Supplier.PickupWindowSeconds
    }


    local priceMultiplier = Matrix.Supplier.GetPriceMultiplier(citizenid, dropCfg.supplier_id)


    Matrix.Log('LOGISTICS',
        'Dead drop #%d (%s) acildi: toptanci #%d, guven=%.2f, fiyat-carpani=x%.2f, pencere=%ds',
        dropId, dropCfg.label, dropCfg.supplier_id, rec.trust, priceMultiplier, Config.Supplier.PickupWindowSeconds)


    return true, {
        price_multiplier = priceMultiplier,
        expires_in       = Config.Supplier.PickupWindowSeconds,
        coords           = dropCfg.coords
    }
end


function Matrix.Supplier.OnPickup(actorRef, dropId, creditCitizenid)
    local drop = ActiveDrops[dropId]
    if not drop then return false, 'no_active_drop' end
    if Matrix.Now() > drop.expires_at then
        ActiveDrops[dropId] = nil
        return false, 'window_expired'
    end


    local dropCfg = GetDropConfig(dropId)
    if not dropCfg then return false, 'bad_drop' end


    local actor = Matrix.ResolveActor(actorRef)
    local fingerprintQuality = actor and Matrix.Forensics.ComputeFingerprintQuality(actor) or 1.0
    local forensicTraceLeft = fingerprintQuality < Config.Supplier.ForensicTraceQualityThreshold
    local heat = DropHeat[dropId] or 0.0


    local citizenid = creditCitizenid or drop.citizenid
    local rec = Matrix.Supplier.GetTrustRecord(citizenid, drop.supplier_id)


    if forensicTraceLeft or heat > 0.0 then
        local penalty = Config.Supplier.TrustForensicLeakPenalty * (1.0 + (heat * Config.Supplier.TrustHeatmapPenaltyFactor))
        rec.trust = Matrix.Clamp(rec.trust - penalty, 0.0, 1.0)
        if forensicTraceLeft then rec.forensic_leaks = rec.forensic_leaks + 1 end
    else
        rec.trust = Matrix.Clamp(rec.trust + Config.Supplier.TrustRecoveryPerCleanPickup, 0.0, 1.0)
    end
    MarkSupplierTrustDirty(citizenid, drop.supplier_id)


    DropHeat[dropId] = math_min(heat + Config.Supplier.DropHeatGrowthPerUse, 10.0)
    ActiveDrops[dropId] = nil


    MySQL.prepare([[
        INSERT INTO matrix_dead_drop_events (drop_id, supplier_id, citizenid, heat_at_pickup, forensic_trace_left, created_at)
        VALUES (?, ?, ?, ?, ?, NOW())
    ]], { dropId, drop.supplier_id, citizenid, heat, forensicTraceLeft and 1 or 0 })


    Matrix.Log('LOGISTICS', 'Dead drop #%d (%s) teslim alindi: %s | heat=%.2f | iz=%s | guven=%.2f',
        dropId, dropCfg.label, tostring(citizenid), heat, tostring(forensicTraceLeft), rec.trust)


    if rec.trust < Config.Supplier.BetrayalTrustThreshold then
        Matrix.Supplier.TriggerBetrayal(citizenid, drop.supplier_id)
    end


    return true, { heat = heat, forensic_trace_left = forensicTraceLeft, trust = rec.trust }
end


CreateThread(function()
    while true do
        Wait(60000)
        for dropId, heat in pairs(DropHeat) do
            local newHeat = math_max(heat - Config.Supplier.DropHeatDecayPerMinute, 0.0)
            if newHeat <= 0.0 then
                DropHeat[dropId] = nil
            else
                DropHeat[dropId] = newHeat
            end
        end


        local now = Matrix.Now()
        for dropId, drop in pairs(ActiveDrops) do
            if now > drop.expires_at then
                ActiveDrops[dropId] = nil
                Matrix.Log('LOGISTICS', 'Dead drop #%d penceresi suresi doldu, teslim alinmadi.', dropId)
            end
        end
    end
end)


CreateThread(function()
    while true do
        Wait(20000)
        FlushDirtyFleet()
        FlushDirtySupplierTrust()
    end
end)


-- =====================================================================
-- KALICI ÖLÜM (PERMADEATH & HARD-DELETE)
-- =====================================================================
function Matrix.Logistics.OnDealerEliminated(botId, cause)
    local bot = Matrix.Bots[botId]
    if not bot then return false end


    if Matrix.Dispatches and Matrix.Dispatches[botId] then
        local dispatch = Matrix.Dispatches[botId]
        local plate = dispatch.plate
        if plate then Matrix.Logistics.ReleaseVehicleLock(plate) end
        if Matrix.DespawnDispatchEntity then Matrix.DespawnDispatchEntity(botId, dispatch) end
        Matrix.Dispatches[botId] = nil
    end


    local plateToSeize = PermanentVehicleByBot[botId]
    local lastCoords = bot.state.coords
    local dnaId = bot.dna_id


    if bot.state.spawned then
        Matrix.DespawnBot(botId)
    end


    MySQL.prepare('DELETE FROM matrix_bots WHERE id = ?', { botId })


    Matrix.Persistence.dirtyBots[botId] = nil
    Matrix.Bots[botId] = nil


    Matrix.Log('LOGISTICS',
        '[LOJISTIK KAYIP: DEALER_ID %d KALICI OLARAK DE-REGISTRE EDILDI] Sebep:%s',
        botId, tostring(cause or 'unknown'))


    if plateToSeize then
        Matrix.Fleet.SeizeVehicle(plateToSeize, cause, dnaId, lastCoords)
    end


    return true
end


-- =====================================================================
-- ÇATIŞMA DİRENCİ
-- =====================================================================
function Matrix.Logistics.ApplyCombatDamage(botId, rawDamage)
    local bot = Matrix.Bots[botId]
    if not bot then return false end


    rawDamage = tonumber(rawDamage) or 1.0
    if rawDamage ~= rawDamage or rawDamage < 0.0 then rawDamage = 0.0 end


    local dispatch = Matrix.Dispatches and Matrix.Dispatches[botId]
    local profile = GetVehicleProfile(dispatch and dispatch.vehicle_type or Config.Logistics.DefaultVehicleType)
    local effectiveDamage = rawDamage * (1.0 - profile.CombatResistance)


    if dispatch then
        dispatch.combat_damage = (dispatch.combat_damage or 0.0) + effectiveDamage
        Matrix.Log('LOGISTICS', 'Bot #%d catisma hasari: ham=%.2f direnc=%.2f etkin=%.2f birikim=%.2f/%.2f',
            botId, rawDamage, profile.CombatResistance, effectiveDamage,
            dispatch.combat_damage, Config.Logistics.CombatEliminationThreshold)


        if dispatch.combat_damage >= Config.Logistics.CombatEliminationThreshold then
            Matrix.Logistics.OnDealerEliminated(botId, 'combat')
        end
    elseif effectiveDamage >= Config.Logistics.CombatEliminationThreshold then
        Matrix.Logistics.OnDealerEliminated(botId, 'combat')
    end


    return true
end


function Matrix.Logistics.OnPoliceCollision(botId)
    return Matrix.Logistics.OnDealerEliminated(botId, 'police_collision')
end


-- =====================================================================
-- DEALER SEVK PLANLAYICI
-- =====================================================================
function Matrix.Logistics.DispatchDealer(botId, destination, vehicleRef, dispatcherSrc)
    botId = tonumber(botId)
    if not botId then return false, 'bad_bot_id' end


    local bot = Matrix.Bots[botId]
    if not bot then return false, 'bot_missing' end
    if bot.role ~= 'dealer' then return false, 'not_a_dealer' end


    if Matrix.Dispatches and Matrix.Dispatches[botId] then
        return false, 'already_dispatched'
    end


    if Matrix.RadioSilence and Matrix.RadioSilence.GuardBotDispatch then
        local silOk, silReason = Matrix.RadioSilence.GuardBotDispatch(dispatcherSrc)
        if not silOk then return false, silReason end
    end


    local origin = bot.state.coords
    if not IsValidCoords(origin) then
        local fallbackHouse = bot.state.trap_house_id and Matrix.TrapHouses and Matrix.TrapHouses[bot.state.trap_house_id]


        if not fallbackHouse and Matrix.TrapHouses then
            local lowestId = nil
            for id in pairs(Matrix.TrapHouses) do
                if not lowestId or id < lowestId then lowestId = id end
            end
            fallbackHouse = lowestId and Matrix.TrapHouses[lowestId]
        end


        if fallbackHouse then
            origin = fallbackHouse.coords
            Matrix.Log('LOGISTICS',
                '[ORIJIN VARSAYILANI] Bot #%d hic konumlanmamisti; trap house #%d (%s) baslangic olarak kullanildi.',
                botId, fallbackHouse.id, fallbackHouse.label)
        elseif type(dispatcherSrc) == 'number' and dispatcherSrc > 0 then
            local ped = GetPlayerPed(dispatcherSrc)
            if ped and ped ~= 0 then
                local c = GetEntityCoords(ped)
                origin = vector3(c.x, c.y + 200.0, c.z)
                Matrix.Log('LOGISTICS',
                    '[ORIJIN VARSAYILANI] Bot #%d hic konumlanmamisti ve matriste trap house yok; dispatcher src=%d konumu +200m ofsetle kullanildi.',
                    botId, dispatcherSrc)
            end
        end


        if not IsValidCoords(origin) then return false, 'no_origin' end
    end


    local destOk, destReason, destExtra = ValidateDestination(origin, destination)
    if not destOk then
        Matrix.Log('LOGISTICS',
            '[LOJISTIK HATA: GECERSIZ HEDEF VEKTORU] Bot #%d sevk reddedildi. Sebep:%s',
            botId, destReason)
        return false, destReason
    end


    local plate, vehicle, vehicleType, assignmentMode = nil, nil, nil, nil


    if vehicleRef == nil or vehicleRef == '' then
        plate = PermanentVehicleByBot[botId]
    elseif vehicleRef ~= 'foot' then
        plate = vehicleRef
    end


    if plate then
        vehicle = Matrix.Fleet.GetVehicle(plate)
        if not vehicle then return false, 'vehicle_not_found' end
        if vehicle.assigned_bot_id and vehicle.assigned_bot_id ~= botId then
            return false, 'vehicle_assigned_elsewhere'
        end
        if ActiveVehicleLocks[plate] and ActiveVehicleLocks[plate] ~= botId then
            return false, 'vehicle_in_use'
        end


        vehicleType    = vehicle.vehicle_class
        assignmentMode = (vehicle.assigned_bot_id == botId) and 'permanent' or 'temporary'
        ActiveVehicleLocks[plate] = botId
    else
        vehicleType = 'foot'
    end


    local profile = GetVehicleProfile(vehicleType)
    local wearBonus = vehicle and (1.0 + (vehicle.vehicle_wear * Config.Logistics.Fleet.WearFrictionBonus)) or 1.0
    local effectiveFriction = profile.FrictionMultiplier * wearBonus


    local distance    = VectorDistance(origin, destination)
    local weightTotal = GetBotInventoryWeight(bot)
    local baseSpeed   = Config.Logistics.BaseSpeedUnitsPerSecond


    local frictionDivisor = 1.0 + (weightTotal * Config.Logistics.WeightFrictionCoefficient * effectiveFriction)


    local etaSeconds = (distance / (baseSpeed * profile.SpeedCoefficient)) * frictionDivisor
    etaSeconds = Matrix.Clamp(etaSeconds, 0.0, math_huge)


    Matrix.Log('LOGISTICS',
        'Sevkiyat plani: Bot #%d [%s]%s Mesafe:%.1fm Agirlik:%.1fg Surtunme:x%.2f ETA:%.1fsn',
        botId, bot.name,
        plate and (' Plaka:%s VIN:%s Asinma:%.2f'):format(plate, vehicle.vin_status, vehicle.vehicle_wear)
              or (' Arac:%s'):format(vehicleType),
        distance, weightTotal, frictionDivisor, etaSeconds)


    if Matrix.BeginPhysicalDispatch then
        local ok, reason = Matrix.BeginPhysicalDispatch(
            botId, origin, destination, plate, vehicleType, etaSeconds, dispatcherSrc, frictionDivisor
        )
        if not ok then
            if plate then ActiveVehicleLocks[plate] = nil end
            Matrix.Log('LOGISTICS', '[SEVK BASLATILAMADI] Bot #%d Sebep:%s', botId, tostring(reason))
            return false, reason or 'dispatch_failed'
        end
    else
        Matrix.Log('LOGISTICS',
            '[UYARI] BeginPhysicalDispatch exportu tanimli degil; sevk yalnizca plan olarak kayitli.')
    end


    return true, etaSeconds
end


Matrix.SevkBot = Matrix.Logistics.DispatchDealer


-- =====================================================================
-- ★ KATMAN 7 [T2]: MÜHİMMAT DAĞITIM GÖREVİ
-- =====================================================================
function Matrix.Logistics.DispatchAmmoRun(sourceBotId, targetBotId, dispatcherSrc)
    sourceBotId = tonumber(sourceBotId)
    targetBotId = tonumber(targetBotId)
    if not sourceBotId or not targetBotId then return false, 'bad_bot_id' end
    if sourceBotId == targetBotId then return false, 'same_bot' end

    local sourceBot = Matrix.Bots[sourceBotId]
    if not sourceBot then return false, 'bot_missing' end
    if sourceBot.role ~= 'runner' then return false, 'not_logistics' end
    if sourceBot.state.is_locked or (Matrix.Dispatches and Matrix.Dispatches[sourceBotId]) then
        return false, 'already_dispatched'
    end

    local targetBot = Matrix.Bots[targetBotId]
    if not targetBot then return false, 'target_missing' end
    if not IsValidCoords(targetBot.state.coords) then return false, 'target_no_coords' end

    local trapHouseId = sourceBot.state.trap_house_id
    local house = trapHouseId and Matrix.TrapHouses and Matrix.TrapHouses[trapHouseId]
    if not house then return false, 'no_trap_house' end

    if Matrix.RadioSilence and Matrix.RadioSilence.GuardBotDispatch then
        local silOk, silReason = Matrix.RadioSilence.GuardBotDispatch(dispatcherSrc)
        if not silOk then return false, silReason end
    end

    local stashId     = ('matrix_trap_stash_%d'):format(trapHouseId)
    local inventoryId = ('dealer_%d'):format(sourceBotId)
    pcall(function()
        exports['ox_inventory']:RegisterStash(stashId, (house.label or ('Trap #' .. trapHouseId)) .. ' Deposu', 100, 200000)
    end)

    local pulled = {}
    for _, entry in ipairs(Config.Logistics.AmmoRunManifest) do
        local removeOk, removed = pcall(function()
            return exports['ox_inventory']:RemoveItem(stashId, entry.item, entry.count)
        end)
        if removeOk and removed == true then
            local addOk, added = pcall(function()
                return exports['ox_inventory']:AddItem(inventoryId, entry.item, entry.count)
            end)
            if addOk and added == true then
                pulled[#pulled + 1] = ('%sx%d'):format(entry.item, entry.count)
            else
                local restoreOk, restored = pcall(function()
                    return exports['ox_inventory']:AddItem(stashId, entry.item, entry.count)
                end)
                if not (restoreOk and restored == true) then
                    Matrix.Log('LOGISTICS',
                        '[KRITIK] DispatchAmmoRun: %s x%d AddItem+telafi ikisi de basarisiz -- olasi kayip.',
                        entry.item, entry.count)
                end
            end
        end
    end

    if #pulled == 0 then return false, 'stash_empty' end

    if Matrix.TrapHouseInterior and Matrix.TrapHouseInterior.MarkBotForStashRun then
        Matrix.TrapHouseInterior.MarkBotForStashRun(sourceBotId, trapHouseId)
    elseif Matrix.SetBotInteriorTrapHouse then
        Matrix.SetBotInteriorTrapHouse(sourceBotId, trapHouseId)
    end

    local plate = PermanentVehicleByBot[sourceBotId]
    local vehicle = plate and Matrix.Fleet.GetVehicle(plate)
    local vehicleType = vehicle and vehicle.vehicle_class or 'car'
    if plate and (not vehicle or (ActiveVehicleLocks[plate] and ActiveVehicleLocks[plate] ~= sourceBotId)) then
        plate, vehicleType = nil, 'car'
    end
    if plate then ActiveVehicleLocks[plate] = sourceBotId end

    local distance    = VectorDistance(house.coords, targetBot.state.coords)
    local profile      = GetVehicleProfile(vehicleType)
    local etaSeconds   = Matrix.Clamp(distance / (Config.Logistics.BaseSpeedUnitsPerSecond * profile.SpeedCoefficient), 0.0, math_huge)

    local ok, reason = Matrix.BeginPhysicalDispatch(
        sourceBotId, house.coords, targetBot.state.coords, plate, vehicleType, etaSeconds, dispatcherSrc, 1.0
    )
    if not ok then
        if plate then ActiveVehicleLocks[plate] = nil end
        sourceBot.state.interior_trap_house_id = nil
        return false, reason or 'dispatch_failed'
    end

    Matrix.Dispatches[sourceBotId].ammo_run_target_bot_id = targetBotId

    Matrix.Log('LOGISTICS',
        '[MUHIMMAT DAGITIM GOREVI] Lojistik Bot #%d -> Tetikci Bot #%d icin depodan yuklenip yola cikti. Yuk: %s',
        sourceBotId, targetBotId, table.concat(pulled, ', '))

    return true, etaSeconds
end


function Matrix.Logistics.OnAmmoRunArrived(sourceBotId, targetBotId, arrivalCoords)
    local sourceBot = Matrix.Bots[sourceBotId]
    local targetBot = Matrix.Bots[targetBotId]
    if not sourceBot or not targetBot then return false end

    local fromInv = ('dealer_%d'):format(sourceBotId)
    local toInv    = ('dealer_%d'):format(targetBotId)

    local invOk, inv = pcall(exports['ox_inventory'].GetInventory, exports['ox_inventory'], fromInv)
    local movedAny = false
    if invOk and type(inv) == 'table' and type(inv.items) == 'table' then
        for slot, item in pairs(inv.items) do
            if type(item) == 'table' and type(item.name) == 'string' and (tonumber(item.count) or 0) > 0 then
                local addOk = pcall(function()
                    return exports['ox_inventory']:AddItem(toInv, item.name, item.count, item.metadata)
                end)
                if addOk then
                    pcall(function() exports['ox_inventory']:RemoveItem(fromInv, item.name, item.count, item.metadata, slot) end)
                    movedAny = true
                end
            end
        end
    end

    Matrix.Log('LOGISTICS',
        '[MUHIMMAT TESLIMI] Lojistik Bot #%d -> Tetikci Bot #%d elden teslimat %s.',
        sourceBotId, targetBotId, movedAny and 'tamamlandi' or 'BOS ENVANTER (atlandi)')

    local trapHouseId = sourceBot.state.trap_house_id
    local house = trapHouseId and Matrix.TrapHouses and Matrix.TrapHouses[trapHouseId]
    if house and Matrix.BeginPhysicalDispatch then
        SetTimeout(100, function()
            if sourceBot.state.is_locked or (Matrix.Dispatches and Matrix.Dispatches[sourceBotId]) then return end
            local plate = PermanentVehicleByBot[sourceBotId]
            local vehicle = plate and Matrix.Fleet.GetVehicle(plate)
            local vehicleType = vehicle and vehicle.vehicle_class or 'car'
            if plate and not vehicle then plate = nil end
            if plate then ActiveVehicleLocks[plate] = sourceBotId end
            local ok = Matrix.BeginPhysicalDispatch(
                sourceBotId, arrivalCoords, house.coords, plate, vehicleType, 0.0, nil, 1.0
            )
            if not ok and plate then ActiveVehicleLocks[plate] = nil end
        end)
    end

    return movedAny
end


-- =====================================================================
-- KATMAN 5: CO-OP KOMUTA YETKİSİ GUARD'I
-- =====================================================================
local function HasCommandAuthority(src)
    if not (Matrix.Hierarchy and Matrix.Hierarchy.HasCommandAuthority) then return true end


    local state = Matrix.GetOrCreatePlayerState(src)
    if not state or not state.citizenid then return false end
    return Matrix.Hierarchy.HasCommandAuthority(state.citizenid)
end


-- =====================================================================
-- KOMUTLAR
-- =====================================================================
local function Reply(src, msg)
    if type(src) == 'number' and src > 0 then
        TriggerClientEvent('chat:addMessage', src, { args = { '[LOJİSTİK]', msg } })
    else
        print(('[MATRIX:LOGISTICS:CONSOLE] %s'):format(msg))
    end
end


function Matrix.Logistics.LoadTrunkFromStash(botId, itemName, count)
    botId = tonumber(botId)
    count = tonumber(count)
    if not botId or type(itemName) ~= 'string' or itemName == '' or not count or count <= 0 then
        return false, 'bad_args'
    end


    local bot = Matrix.Bots[botId]
    if not bot then return false, 'bot_missing' end


    local trapHouseId = bot.state.trap_house_id
    if not trapHouseId then return false, 'no_trap_house' end


    local vehicle = Matrix.Fleet.GetVehicleByBot(botId)
    if not vehicle then return false, 'no_assigned_vehicle' end


    local stashId = ('matrix_trap_stash_%d'):format(trapHouseId)
    local trunkId = Config.Logistics.TrunkOps.StashPrefix .. vehicle.plate


    pcall(function()
        exports['ox_inventory']:RegisterStash(trunkId, ('%s Bagaji'):format(vehicle.plate),
            Config.Logistics.TrunkOps.Slots, Config.Logistics.TrunkOps.MaxWeight)
    end)


    local haveOk, have = pcall(function() return exports['ox_inventory']:Search(stashId, 'count', itemName) end)
    have = (haveOk and tonumber(have)) or 0
    if have < count then return false, 'insufficient_stash' end


    local removeOk = pcall(function() return exports['ox_inventory']:RemoveItem(stashId, itemName, count) end)
    if not removeOk then return false, 'remove_failed' end


    local addOk = pcall(function() return exports['ox_inventory']:AddItem(trunkId, itemName, count) end)
    if not addOk then
        pcall(function() exports['ox_inventory']:AddItem(stashId, itemName, count) end)
        return false, 'add_failed'
    end


    Matrix.Log('LOGISTICS', '[BAGAJ AMELIYATI] Bot #%d: %dx %s trap #%d deposundan %s bagajina tasindi.',
        botId, count, itemName, trapHouseId, vehicle.plate)
    return true
end


local DISPATCH_FAILURE_MESSAGES = {
    bad_bot_id                 = 'Geçersiz bot ID.',
    bot_missing                = 'Bot matriste bulunamadı.',
    not_a_dealer                = 'Bu bot bir dealer değil.',
    already_dispatched          = 'Bot zaten sevk halinde.',
    bot_locked                 = 'Bot kilitli (onceki IO muhrunu bekliyor).',
    no_origin                  = 'Bot için bilinen bir konum yok.',
    missing_vector              = 'Hedef koordinatı eksik.',
    corrupt_vector              = 'Hedef koordinatı bozuk/geçersiz.',
    out_of_range                = 'Hedef menzil dışında.',
    too_close                   = 'Hedef mesafesi çok yakın (min. 5m); sevk iptal edildi.',
    vehicle_not_found            = 'Belirtilen plaka filoda kayıtlı değil.',
    vehicle_assigned_elsewhere  = 'Araç başka bir bota kalıcı olarak atanmış.',
    vehicle_in_use              = 'Araç şu anda başka bir sevkiyatta kullanılıyor.',
    dispatch_failed             = 'Fiziksel sevk başlatılamadı.',
    task_assignment_failed      = 'Görev atama basarisiz (fiziksel sevk iptal edildi).',
    radio_silence_active        = 'Telsiz sessizliği aktif -- bu süre boyunca yeni sevk/rota komutları engellidir.'
}


local AMMO_RUN_FAILURE_MESSAGES = {
    bad_bot_id            = 'Geçersiz bot ID.',
    same_bot               = 'Kaynak ve hedef bot aynı olamaz.',
    bot_missing            = 'Lojistik bot matriste bulunamadı.',
    not_logistics          = 'Bu bot Lojistik (runner) rütbesinde değil.',
    already_dispatched      = 'Lojistik bot zaten sevk halinde.',
    target_missing          = 'Hedef Tetikçi bot matriste bulunamadı.',
    target_no_coords        = 'Hedef Tetikçi botun bilinen bir konumu yok.',
    no_trap_house           = 'Lojistik bota atanmış bir trap house yok.',
    radio_silence_active    = 'Telsiz sessizliği aktif -- bu süre boyunca yeni görev verilemez.',
    stash_empty             = 'Trap house deposunda dağıtılacak mühimmat yok.',
    dispatch_failed         = 'Fiziksel sevk başlatılamadı.',
    task_assignment_failed  = 'Görev atama basarisiz (fiziksel sevk iptal edildi).'
}


local FLEET_FAILURE_MESSAGES = {
    bad_plate                  = 'Geçersiz plaka.',
    plate_exists                = 'Bu plaka zaten filoda kayıtlı.',
    vehicle_not_found            = 'Plaka filoda bulunamadı.',
    bot_missing                = 'Bot matriste bulunamadı.',
    vehicle_assigned_elsewhere  = 'Araç başka bir bota atanmış.',
    bot_already_has_vehicle    = 'Bu bota zaten kalıcı bir araç atanmış.'
}


RegisterCommand('sevket', function(src, args)
    if not HasCommandAuthority(src) then
        Reply(src, 'Bu emri vermek için yeterli rütbeniz yok (Logistics_Officer veya Leader gerekir).'); return
    end


    local botId = tonumber(args[1])
    local vehicleRef = args[2]


    if not botId then
        Reply(src, 'Kullanim: /sevket [botId] [plaka|foot]'); return
    end


    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then
        Reply(src, 'Meet-point için geçerli bir ped gerekli.'); return
    end
    local destination = GetEntityCoords(ped)


    local ok, etaOrReason = Matrix.Logistics.DispatchDealer(botId, destination, vehicleRef, src)
    if ok then
        Reply(src, ('Bot #%d fiziksel sevke alindi. Tahmini varis: %.1f sn'):format(botId, etaOrReason))
    else
        Reply(src, DISPATCH_FAILURE_MESSAGES[etaOrReason] or ('Sevk basarisiz: %s'):format(tostring(etaOrReason)))
    end
end, false)


RegisterCommand('muhimmatsevk', function(src, args)
    if not HasCommandAuthority(src) then
        Reply(src, 'Bu gorevi vermek icin yeterli rutbeniz yok (Logistics_Officer veya Leader gerekir).'); return
    end


    local sourceBotId = tonumber(args[1])
    local targetBotId = tonumber(args[2])
    if not sourceBotId or not targetBotId then
        Reply(src, 'Kullanim: /muhimmatsevk [lojistikBotId] [tetikciBotId]'); return
    end


    local ok, etaOrReason = Matrix.Logistics.DispatchAmmoRun(sourceBotId, targetBotId, src)
    if ok then
        Reply(src, ('Bot #%d muhimmat dagitim gorevine cikti (hedef: Tetikci Bot #%d). Tahmini varis: %.1f sn'):format(
            sourceBotId, targetBotId, etaOrReason))
    else
        Reply(src, AMMO_RUN_FAILURE_MESSAGES[etaOrReason] or ('Gorev baslatilamadi: %s'):format(tostring(etaOrReason)))
    end
end, false)


RegisterCommand('filokaydet', function(src, args)
    local plate         = args[1]
    local vehicleClass  = args[2]
    local vinStatus     = args[3]
    local vehicleWear   = tonumber(args[4])


    local citizenid = nil
    local state = Matrix.GetOrCreatePlayerState(src)
    if state then citizenid = state.citizenid end


    local ok, reason = Matrix.Fleet.RegisterVehicle(citizenid, plate, vehicleClass, vinStatus, vehicleWear)
    if ok then
        Reply(src, ('Araç filoya kaydedildi: %s (RAM + async persist)'):format(plate))
    else
        Reply(src, FLEET_FAILURE_MESSAGES[reason] or ('Kayıt başarısız: %s'):format(tostring(reason)))
    end
end, false)


RegisterCommand('filoata', function(src, args)
    if not HasCommandAuthority(src) then
        Reply(src, 'Bu atamayı yapmak için yeterli rütbeniz yok (Logistics_Officer veya Leader gerekir).'); return
    end


    local plate = args[1]
    local botId = tonumber(args[2])
    if type(plate) ~= 'string' or not botId then
        Reply(src, 'Kullanim: /filoata [plaka] [botId]'); return
    end


    local ok, reason = Matrix.Fleet.AssignPermanent(plate, botId)
    if ok then
        Reply(src, ('Araç %s -> Bot #%d kalıcı olarak atandı.'):format(plate, botId))
    else
        Reply(src, FLEET_FAILURE_MESSAGES[reason] or ('Atama başarısız: %s'):format(tostring(reason)))
    end
end, false)


RegisterCommand('filobirak', function(src, args)
    if not HasCommandAuthority(src) then
        Reply(src, 'Bu işlemi yapmak için yeterli rütbeniz yok (Logistics_Officer veya Leader gerekir).'); return
    end


    local plate = args[1]
    if type(plate) ~= 'string' then Reply(src, 'Kullanim: /filobirak [plaka]'); return end


    local ok = Matrix.Fleet.UnassignPermanent(plate)
    Reply(src, ok and ('Araç %s serbest bırakıldı.'):format(plate) or 'Araç bulunamadı veya kalıcı atanmamış.')
end, false)


local TRUNK_OPS_FAILURE_MESSAGES = {
    bad_args            = 'Gecersiz parametre.',
    bot_missing         = 'Bot matriste bulunamadi.',
    no_trap_house       = 'Bu bot su an bir trap house eslesmesine sahip degil.',
    no_assigned_vehicle = 'Bu bota kalici atanmis bir arac yok (once /filoata kullanin).',
    insufficient_stash  = 'Trap house deposunda yeterli miktar yok.',
    remove_failed       = 'Depodan cekme basarisiz.',
    add_failed          = 'Bagaja yukleme basarisiz (bagaj dolu olabilir).'
}


RegisterCommand('bagajyukle', function(src, args)
    if not HasCommandAuthority(src) then
        Reply(src, 'Bu islemi yapmak icin yeterli rutbeniz yok (Logistics_Officer veya Leader gerekir).'); return
    end


    local botId = tonumber(args[1])
    local itemName = args[2]
    local count = tonumber(args[3])
    if not botId or type(itemName) ~= 'string' or not count then
        Reply(src, 'Kullanim: /bagajyukle [botId] [item] [miktar]'); return
    end


    local ok, reason = Matrix.Logistics.LoadTrunkFromStash(botId, itemName, count)
    if ok then
        Reply(src, ('Bot #%d bagajina %dx %s yuklendi.'):format(botId, count, itemName))
    else
        Reply(src, TRUNK_OPS_FAILURE_MESSAGES[reason] or ('Bagaj yukleme basarisiz: %s'):format(tostring(reason)))
    end
end, false)


local SUPPLIER_FAILURE_MESSAGES = {
    bad_drop         = 'Geçersiz drop.',
    already_active    = 'Bu drop zaten açık, önce teslim alın.',
    supply_cut        = 'Toptancı güveniniz çok düşük, tedarik kesildi.',
    no_active_drop    = 'Bu drop şu anda aktif değil.',
    window_expired    = 'Teslim alma penceresi doldu.'
}


RegisterCommand('dropiste', function(src, args)
    local dropId = tonumber(args[1])
    if not dropId then Reply(src, 'Kullanim: /dropiste [dropId]'); return end


    local state = Matrix.GetOrCreatePlayerState(src)
    local citizenid = state and state.citizenid
    if not citizenid then Reply(src, 'Profil çözülemedi.'); return end


    local ok, info = Matrix.Supplier.RequestDrop(citizenid, dropId)
    if ok then
        Reply(src, ('Drop #%d açıldı. Fiyat çarpanı x%.2f, %ds içinde teslim al.'):format(
            dropId, info.price_multiplier, info.expires_in))
    else
        Reply(src, SUPPLIER_FAILURE_MESSAGES[info] or ('Drop açılamadı: %s'):format(tostring(info)))
    end
end, false)


RegisterCommand('dropcek', function(src, args)
    local dropId = tonumber(args[1])
    if not dropId then Reply(src, 'Kullanim: /dropcek [dropId]'); return end


    local dropCfg = GetDropConfig(dropId)
    if not dropCfg then Reply(src, 'Geçersiz drop ID.'); return end


    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then Reply(src, 'Ped bulunamadı.'); return end


    local playerCoords = GetEntityCoords(ped)
    if VectorDistance(playerCoords, dropCfg.coords) > dropCfg.radius then
        Reply(src, 'Drop noktasına yeterince yakın değilsiniz.'); return
    end


    local state = Matrix.GetOrCreatePlayerState(src)
    local ok, result = Matrix.Supplier.OnPickup({ kind = 'player', source = src }, dropId, state and state.citizenid)
    if ok then
        Reply(src, ('Teslim alındı. Heat:%.2f İz:%s Güven:%.2f'):format(
            result.heat, tostring(result.forensic_trace_left), result.trust))
    else
        Reply(src, SUPPLIER_FAILURE_MESSAGES[result] or ('Teslim alınamadı: %s'):format(tostring(result)))
    end
end, false)


-- =====================================================================
-- EVENT BRIDGE
-- =====================================================================
RegisterNetEvent('matrix:server:reportDealerEliminated', function(botId, cause)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    botId = tonumber(botId)
    if not botId then return end
    Matrix.Logistics.OnDealerEliminated(botId, type(cause) == 'string' and cause or 'unknown')
end)


RegisterNetEvent('matrix:server:reportDealerPoliceCollision', function(botId)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    botId = tonumber(botId)
    if not botId then return end
    Matrix.Logistics.OnPoliceCollision(botId)
end)


RegisterNetEvent('matrix:server:reportDealerCombatDamage', function(botId, rawDamage)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    botId = tonumber(botId)
    if not botId then return end
    Matrix.Logistics.ApplyCombatDamage(botId, rawDamage)
end)


RegisterNetEvent('matrix:server:registerFleetVehicle', function(plate, vehicleClass, vinStatus, vehicleWear)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    local state = Matrix.GetOrCreatePlayerState(src)
    Matrix.Fleet.RegisterVehicle(state and state.citizenid, plate, vehicleClass, vinStatus, vehicleWear)
end)


RegisterNetEvent('matrix:server:assignFleetVehicle', function(plate, botId)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    botId = tonumber(botId)
    if type(plate) ~= 'string' or not botId then return end
    Matrix.Fleet.AssignPermanent(plate, botId)
end)


RegisterNetEvent('matrix:server:unassignFleetVehicle', function(plate)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    if type(plate) ~= 'string' then return end
    Matrix.Fleet.UnassignPermanent(plate)
end)


RegisterNetEvent('matrix:server:reportVehicleEncircled', function(plate, cause)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    if type(plate) ~= 'string' then return end
    Matrix.Logistics.OnVehicleEncircled(plate, type(cause) == 'string' and cause or 'police_encirclement')
end)


RegisterNetEvent('matrix:server:requestDeadDrop', function(dropId)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    dropId = tonumber(dropId)
    if not dropId then return end
    local state = Matrix.GetOrCreatePlayerState(src)
    if state then Matrix.Supplier.RequestDrop(state.citizenid, dropId) end
end)


RegisterNetEvent('matrix:server:reportLatePayment', function(supplierId)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    supplierId = tonumber(supplierId)
    if not supplierId then return end
    local state = Matrix.GetOrCreatePlayerState(src)
    if state then Matrix.Supplier.ReportLatePayment(state.citizenid, supplierId) end
end)


-- =====================================================================
-- EXPORTLAR
-- =====================================================================
exports('DispatchDealer', function(botId, dest, vehicleRef, dispatcherSrc)
    return Matrix.Logistics.DispatchDealer(botId, dest, vehicleRef, dispatcherSrc)
end)
exports('DispatchAmmoRun', function(sourceBotId, targetBotId, dispatcherSrc)
    return Matrix.Logistics.DispatchAmmoRun(sourceBotId, targetBotId, dispatcherSrc)
end)
exports('ApplyCombatDamageToDealer', function(botId, dmg)
    return Matrix.Logistics.ApplyCombatDamage(botId, dmg)
end)
exports('EliminateDealer', function(botId, cause)
    return Matrix.Logistics.OnDealerEliminated(botId, cause)
end)
exports('ReportDealerPoliceCollision', function(botId)
    return Matrix.Logistics.OnPoliceCollision(botId)
end)


exports('RegisterFleetVehicle', function(citizenid, plate, vehicleClass, vinStatus, vehicleWear)
    return Matrix.Fleet.RegisterVehicle(citizenid, plate, vehicleClass, vinStatus, vehicleWear)
end)
exports('AssignFleetVehicle', function(plate, botId)
    return Matrix.Fleet.AssignPermanent(plate, botId)
end)
exports('UnassignFleetVehicle', function(plate)
    return Matrix.Fleet.UnassignPermanent(plate)
end)
exports('GetFleetVehicle', function(plate)
    return Matrix.Fleet.GetVehicle(plate)
end)
exports('GetVehicleByBot', function(botId)
    return Matrix.Fleet.GetVehicleByBot(botId)
end)
exports('LoadTrunkFromStash', function(botId, itemName, count)
    return Matrix.Logistics.LoadTrunkFromStash(botId, itemName, count)
end)
exports('SeizeFleetVehicle', function(plate, cause)
    return Matrix.Logistics.OnVehicleEncircled(plate, cause)
end)


exports('GetSupplierTrust', function(citizenid, supplierId)
    return Matrix.Supplier.GetTrust(citizenid, supplierId)
end)
exports('GetSupplierPriceMultiplier', function(citizenid, supplierId)
    return Matrix.Supplier.GetPriceMultiplier(citizenid, supplierId)
end)
exports('ReportSupplierLatePayment', function(citizenid, supplierId)
    return Matrix.Supplier.ReportLatePayment(citizenid, supplierId)
end)
exports('RequestDeadDrop', function(citizenid, dropId)
    return Matrix.Supplier.RequestDrop(citizenid, dropId)
end)
exports('PickupDeadDrop', function(actorRef, dropId, creditCitizenid)
    return Matrix.Supplier.OnPickup(actorRef, dropId, creditCitizenid)
end)


-- =====================================================================
-- TAKTİK DEBUG PANELİ
-- =====================================================================
RegisterCommand('aracsizdurumu', function(src, args)
    local plate = args[1]
    local vehicle = plate and Matrix.Fleet.GetVehicle(plate)
    if not vehicle then Reply(src, 'Kullanim: /aracsizdurumu [plaka]'); return end


    Reply(src, ('%s [%s/%s] Asinma:%.3f Sahip:%s Atama:%s->%s Dogrulanmis-Calinti:%s'):format(
        vehicle.plate, vehicle.vehicle_class, vehicle.vin_status, vehicle.vehicle_wear,
        tostring(vehicle.registered_by_citizenid), tostring(vehicle.assignment_mode),
        tostring(vehicle.assigned_bot_id), tostring(vehicle.verified_stolen_plate)))
end, false)


RegisterCommand('aracele', function(src, args)
    local plate = args[1]
    local cause = args[2] or 'debug'
    if type(plate) ~= 'string' then Reply(src, 'Kullanim: /aracele [plaka] [sebep]'); return end


    local ok = Matrix.Logistics.OnVehicleEncircled(plate, cause)
    Reply(src, ok and ('%s ele gecirildi ve muhurlendi.'):format(plate) or 'Arac bulunamadi.')
end, false)


RegisterCommand('hasarver', function(src, args)
    local botId = tonumber(args[1])
    local amount = tonumber(args[2]) or 1.0
    if not botId or not Matrix.Bots[botId] then Reply(src, 'Kullanim: /hasarver [botId] [miktar]'); return end


    Matrix.Logistics.ApplyCombatDamage(botId, amount)
    local stillAlive = Matrix.Bots[botId] ~= nil
    Reply(src, ('Bot #%d hasar aldi. Hayatta:%s'):format(botId, tostring(stillAlive)))
end, false)


RegisterCommand('oldur', function(src, args)
    local botId = tonumber(args[1])
    local cause = args[2] or 'debug'
    if not botId or not Matrix.Bots[botId] then Reply(src, 'Kullanim: /oldur [botId] [sebep]'); return end


    Matrix.Logistics.OnDealerEliminated(botId, cause)
    Reply(src, ('Bot #%d kalici olarak elendi.'):format(botId))
end, false)


RegisterCommand('guvengoster', function(src, args)
    local citizenid = args[1]
    local supplierId = tonumber(args[2])
    if type(citizenid) ~= 'string' or not supplierId then
        Reply(src, 'Kullanim: /guvengoster [citizenid] [supplierId]'); return
    end


    local trust = Matrix.Supplier.GetTrust(citizenid, supplierId)
    local mult = Matrix.Supplier.GetPriceMultiplier(citizenid, supplierId)
    Reply(src, ('%s <-> Toptanci #%d | Guven:%.3f | Fiyat-Carpani:x%.2f | Tedarik-Kesik:%s'):format(
        citizenid, supplierId, trust, mult, tostring(trust < Config.Supplier.SupplyCutTrustThreshold)))
end, false)


RegisterCommand('gecodeme', function(src, args)
    local citizenid = args[1]
    local supplierId = tonumber(args[2])
    if type(citizenid) ~= 'string' or not supplierId then
        Reply(src, 'Kullanim: /gecodeme [citizenid] [supplierId]'); return
    end


    local newTrust = Matrix.Supplier.ReportLatePayment(citizenid, supplierId)
    Reply(src, ('Gecikmis odeme islendi. Yeni guven:%.3f'):format(newTrust))
end, false)


RegisterCommand('dropdurum', function(src)
    local count = 0
    local now = Matrix.Now()
    for dropId, drop in pairs(ActiveDrops) do
        count = count + 1
        local cfg = GetDropConfig(dropId)
        Reply(src, ('Drop #%d (%s) | Sahip:%s | Kalan-Pencere:%ds | Heat:%.3f'):format(
            dropId, cfg and cfg.label or '?', tostring(drop.citizenid),
            math_max(drop.expires_at - now, 0), DropHeat[dropId] or 0.0))
    end
    Reply(src, ('--- Toplam %d acik drop ---'):format(count))
end, false)


local function ParseCoordNumber(s)
    return tonumber((tostring(s or ''):gsub(',', '')))
end


RegisterCommand('korbolgetest', function(src, args)
    local x, y, z = ParseCoordNumber(args[1]), ParseCoordNumber(args[2]), ParseCoordNumber(args[3])
    if not x or not y or not z then
        Reply(src, 'Kullanim: /korbolgetest [x] [y] [z]  (boslukla ayirin, virgul KULLANMAYIN)'); return
    end


    local zone = FindDeadZone(vector3(x, y, z))
    Reply(src, zone and ('Bu koordinat "%s" kor bolgesinin ICINDE.'):format(zone.label)
              or 'Bu koordinat hicbir kor bolgenin icinde degil.')
end, false)


RegisterCommand('cachedebug', function(src)
    local fleetN, dirtyFN = 0, 0
    for _ in pairs(FleetVehicles) do fleetN = fleetN + 1 end
    for _ in pairs(dirtyFleet) do dirtyFN = dirtyFN + 1 end


    local trustN, dirtyTN = 0, 0
    for _ in pairs(SupplierTrustCache) do trustN = trustN + 1 end
    for _ in pairs(dirtySupplierTrust) do dirtyTN = dirtyTN + 1 end


    local dropsN, heatN = 0, 0
    for _ in pairs(ActiveDrops) do dropsN = dropsN + 1 end
    for _ in pairs(DropHeat) do heatN = heatN + 1 end


    Reply(src, ('Fleet RAM: %d kayit | dirty kuyruk: %d | eksik-tablo uyarisi:%s'):format(
        fleetN, dirtyFN, tostring(WARNED_MISSING_FLEET)))
    Reply(src, ('Trust RAM: %d kayit | dirty kuyruk: %d | eksik-tablo uyarisi:%s'):format(
        trustN, dirtyTN, tostring(WARNED_MISSING_TRUST)))
    Reply(src, ('ActiveDrops: %d | DropHeat: %d'):format(dropsN, heatN))
end, false)


-- =====================================================================
-- ★★★ KATMAN 8 — CEPHE A: LİMAN KAÇAKÇILIK AĞLARI (YAMA 4 ENTEGRE) ★★★
-- Bot liman gümrük rampasına girince matrix_bureau_intensity x2 katlanır
-- ve SERVER-AUTHORITATIVE rate-limit altında NetOwner istemciye driveby
-- isteği push edilir. SIFIR RNG.
-- =====================================================================

Matrix.Logistics.PortConfig = Matrix.Logistics.PortConfig or {
    RampCoords        = vector3(-50.0, -2400.0, 5.0),
    RampRadius        = 15.0,
    IntensitySpike    = 2.0,
    DrivebyRange      = 60.0,
    DrivebyAccuracy   = 75,
    FiringPattern     = 'FIRING_PATTERN_FULL_AUTO',
}

Matrix.Logistics.PortArrivalFlags = Matrix.Logistics.PortArrivalFlags or {}

-- ★ [YAMA 4] SERVER-AUTHORITATIVE RELAY COOLDOWN TABLOLARI
Matrix.Logistics.__RelayCooldownByBotId  = Matrix.Logistics.__RelayCooldownByBotId  or {}
Matrix.Logistics.__RelayCooldownByClient  = Matrix.Logistics.__RelayCooldownByClient  or {}
Matrix.Logistics.__RelayCooldownTTLMs     = 300000   -- 5 dk purge TTL
Matrix.Logistics.__RelayCooldownPerBotMs  = 3000     -- per-bot 3sn
Matrix.Logistics.__RelayCooldownPerClientMs = 1000   -- per-client 1sn


local function _PortChecksum(raw, salt)
    local sum = 0
    for i = 1, #raw do
        sum = (sum + (raw:byte(i) * (i + salt))) % 0xFFFFFFF
    end
    return sum
end


--- ★ [YAMA 4] Oportunistik TTL purge — her push çağrısında tek pass.
--- Wait(0) yok, sabit iş (O(n) en kötü durumda, pratikte nadiren büyür).
local function _PurgeRelayCooldowns(nowTs)
    local ttl = Matrix.Logistics.__RelayCooldownTTLMs
    for botId, ts in pairs(Matrix.Logistics.__RelayCooldownByBotId) do
        if (nowTs - ts) > ttl then Matrix.Logistics.__RelayCooldownByBotId[botId] = nil end
    end
    for src, ts in pairs(Matrix.Logistics.__RelayCooldownByClient) do
        if (nowTs - ts) > ttl then Matrix.Logistics.__RelayCooldownByClient[src] = nil end
    end
end


--- ★ [YAMA 4] SERVER-AUTHORITATIVE rate-limit + NetOwner push.
--- NetOwner handoff veya NetID rotasyonu ile bypass edilemez; çünkü
--- rate-limit SUNUCU tabloları üzerinden uygulanır (botId ve src bazlı).
--- @return boolean pushed
local function _RelayHitsquadDrivebyServerAuthoritative(dispatch, pedNetId)
    if not dispatch or type(pedNetId) ~= 'number' or pedNetId == 0 then return false end
    local botId = dispatch.bot_id
    if not botId then return false end

    local nowTs = GetGameTimer()

    -- Fırsatçı TTL purge (her çağrıda tek pass, ucuz).
    _PurgeRelayCooldowns(nowTs)

    -- Per-bot rate-limit: aynı bot için 3sn'de bir push.
    local lastBot = Matrix.Logistics.__RelayCooldownByBotId[botId] or 0
    if (nowTs - lastBot) < Matrix.Logistics.__RelayCooldownPerBotMs then
        return false
    end

    -- Ped entity çözümü ve NetOwner hedeflemesi.
    local targetPed = NetworkGetEntityFromNetworkId(pedNetId)
    if not targetPed or targetPed == 0 or not DoesEntityExist(targetPed) then
        return false
    end

    local ownerOk, ownerSrc = pcall(NetworkGetEntityOwner, targetPed)
    if not ownerOk or type(ownerSrc) ~= 'number' or ownerSrc <= 0 then
        return false
    end

    -- Per-client rate-limit: aynı client'a 1sn'de bir push (spam savunması).
    local lastClient = Matrix.Logistics.__RelayCooldownByClient[ownerSrc] or 0
    if (nowTs - lastClient) < Matrix.Logistics.__RelayCooldownPerClientMs then
        return false
    end

    -- Payload: server TARAFINDAN sanitize edilmiş değerler.
    local cfg = Matrix.Logistics.PortConfig
    local weaponHash = GetHashKey(Config.HitSquad and Config.HitSquad.Weapon or 'WEAPON_MICROSMG')
    local payload = {
        ped_net_id     = pedNetId,
        vehicle_net_id = dispatch.vehicle_net_id,
        weapon_hash    = weaponHash,
        firing_pattern = cfg.FiringPattern,
        accuracy       = math.min(math.max(tonumber(cfg.DrivebyAccuracy) or 75, 0), 100),
        range          = math.min(math.max(tonumber(cfg.DrivebyRange) or 60.0, 1.0), 200.0),
        port_checksum  = _PortChecksum(('%d#%d'):format(botId, nowTs), 61),
    }

    TriggerClientEvent('matrix:client:hitsquadDriveby', ownerSrc, payload)

    Matrix.Logistics.__RelayCooldownByBotId[botId]     = nowTs
    Matrix.Logistics.__RelayCooldownByClient[ownerSrc] = nowTs
    return true
end


--- Bot liman rampasına girdiği AN çağrılır. Bir bot için TEK SEFERLİK
--- tetiklenir (flag bayrağı rampa terk edilene kadar korunur).
function Matrix.Logistics.CheckPortArrival(dispatch, coords)
    if not dispatch or not coords then return false end
    local botId = dispatch.bot_id
    if not botId then return false end

    local cfg = Matrix.Logistics.PortConfig
    local dx = coords.x - cfg.RampCoords.x
    local dy = coords.y - cfg.RampCoords.y
    local dz = coords.z - cfg.RampCoords.z
    local dist = math.sqrt((dx * dx) + (dy * dy) + (dz * dz))

    if dist > cfg.RampRadius then
        Matrix.Logistics.PortArrivalFlags[botId] = nil
        return false
    end
    if Matrix.Logistics.PortArrivalFlags[botId] then return true end
    Matrix.Logistics.PortArrivalFlags[botId] = true

    local before = GetConvarFloat('matrix_bureau_intensity', 1.0)
    if type(before) ~= 'number' or before ~= before or before <= 0.0 then before = 1.0 end
    local after = before * cfg.IntensitySpike
    SetConvar('matrix_bureau_intensity', tostring(after))

    -- ★ [YAMA 4] SERVER-AUTHORITATIVE rate-limit altında driveby push.
    local drivebyPushed = 0
    local pedNetId = dispatch.entity_net_id
    if pedNetId and _RelayHitsquadDrivebyServerAuthoritative(dispatch, pedNetId) then
        drivebyPushed = 1
    end

    MySQL.insert([[
        INSERT INTO matrix_port_smuggling_events
            (bot_id, port_zone, intensity_before, intensity_after, dispatch_plate, driveby_pushed, created_at)
        VALUES (?, 'port_ramp', ?, ?, ?, ?, NOW())
    ]], { botId, before, after, dispatch.plate, drivebyPushed })

    Matrix.Log('LOGISTICS',
        '[LIMAN GUMRUK] Bot #%d rampa bolgesine girdi (mesafe=%.1fm) -- matrix_bureau_intensity %.2f -> %.2f (x%.1f) driveby_pushed=%d.',
        botId, dist, before, after, cfg.IntensitySpike, drivebyPushed)

    return true
end


-- =====================================================================
-- ★ [YAMA 4] OPERATÖR KOMUTU: /relaypurge — elle RAM temizliği.
-- Bot silindiğinde Matrix.RemoveBot'un purge hook'u otomatik çağırır;
-- bu komut manuel doğrulama/emergency temizlik içindir.
-- =====================================================================
RegisterCommand('relaypurge', function(src)
    if Matrix.Hierarchy and Matrix.Hierarchy.HasCommandAuthority then
        local st = Matrix.GetOrCreatePlayerState(src)
        if not st or not st.citizenid or not Matrix.Hierarchy.HasCommandAuthority(st.citizenid) then
            Reply(src, 'Yetkisiz.'); return
        end
    end
    local nBot, nCli, nPort = 0, 0, 0
    for _ in pairs(Matrix.Logistics.__RelayCooldownByBotId) do nBot = nBot + 1 end
    for _ in pairs(Matrix.Logistics.__RelayCooldownByClient) do nCli = nCli + 1 end
    for _ in pairs(Matrix.Logistics.PortArrivalFlags) do nPort = nPort + 1 end
    Matrix.Logistics.__RelayCooldownByBotId = {}
    Matrix.Logistics.__RelayCooldownByClient = {}
    Matrix.Logistics.PortArrivalFlags       = {}
    Reply(src, ('[RELAY PURGE] %d bot, %d client, %d port-flag kaydi kazindi.'):format(nBot, nCli, nPort))
end, false)

-- =====================================================================
-- ★★★ [YAMA 5][STALE MEMORY DRIFT TAMIRI] SERVER-AUTHORITATIVE
-- PLAYERDROPPED PURGE ★★★
-- __RelayCooldownByBotId, Matrix.RemoveBot icinde bot silindiginde
-- zaten temizleniyordu (main.lua). __RelayCooldownByClient'in ise
-- (src bazli) hicbir playerDropped kancasi yoktu -- temizligi tamamen
-- _PurgeRelayCooldowns'un firsatci TTL taramasina birakiyordu, o da
-- yalnizca bir bot liman rampasina girince calisiyordu. FiveM src
-- id'leri disconnect sonrasi yeni oyunculara RECYCLE edildigi icin,
-- bu pencere icinde reconnect eden yeni bir oyuncu ayrilanin eski
-- cooldown timestamp'ini miras alabiliyordu. Artik oyuncu ayrilir
-- ayrilmaz kendi src kaydi kazinir -- iki tablo da simdi ayni
-- server-authoritative temizlik garantisine sahip.
-- =====================================================================
AddEventHandler('playerDropped', function()
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    if Matrix.Logistics.__RelayCooldownByClient then
        Matrix.Logistics.__RelayCooldownByClient[src] = nil
    end
end)