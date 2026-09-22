-- =====================================================================
-- MATRIX RECRUITMENT / recruitment.lua
-- Batch UPDATE, async insert, sıfır await ticker.
-- =====================================================================


Matrix.Recruitment = Matrix.Recruitment or {}
Matrix.Candidates  = Matrix.Candidates  or {}
Matrix.Sessions    = Matrix.Sessions    or {}


local pairs, ipairs, type, tostring = pairs, ipairs, type, tostring
local tonumber, table               = tonumber, table
local math_max, math_floor          = math.max, math.floor


local nextCandidateId = 1
local nextSessionId   = 1


local BIO_FIELDS = {
    'fear_factor', 'resilience', 'snitch_tendency',
    'economic_pressure', 'cognitive_shifter', 'skill_chemistry'
}


-- =====================================================================
-- ASCII SES DALGASI (karanlık mülakat terminali)
-- =====================================================================
local function BuildAsciiWaveform(intensity)
    intensity = Matrix.Clamp(tonumber(intensity) or 0.0, 0.0, 1.0)
    local width = Config.Recruitment.WaveformWidth
    local filled = math_floor((intensity * width) + 0.5)
    return '[' .. ('|'):rep(filled) .. ('.'):rep(width - filled) .. ']'
end


-- =====================================================================
-- SORGU ÖZNESİ ÇÖZÜMLEMESİ: /sorgu hem havuzdan çekilmiş bir adayı (candidate)
-- hem de zaten işe alınmış bir botu (örn. yakalanma sonrası sadakat testi)
-- interrogate edebilsin diye tekilleştirilmiş bir görünüm sağlar. İkisi de
-- aynı psychology şemasını (fear_factor/resilience/...) paylaşır.
-- =====================================================================
local function ResolveInterrogationSubject(kind, id)
    if kind == 'bot' then
        local bot = Matrix.Bots[id]
        if not bot then return nil end
        return { kind = 'bot', id = id, name = bot.name, psychology = bot.psychology, ref_key = bot.dna_id }
    end


    local candidate = Matrix.Candidates[id]
    if not candidate then return nil end
    return { kind = 'candidate', id = id, name = candidate.name, psychology = candidate.psychology, ref_key = candidate.citizenid }
end


-- =====================================================================
-- TRAIT DERIVATION
--
-- FORMÜL: her trait, matrix_customer_pool'daki HAM DAVRANIŞSAL SAYAÇLARIN
-- (police_encounters_nearby, completed_deals, times_reported, ...) sabit
-- bir çarpanla ölçeklenip [0,1]'e clamp'lenmesidir - RNG YOK, aynı sayaç
-- girdisi HER ZAMAN aynı trait çıktısını üretir (deterministik, tekrar
-- edilebilir). resilience/cognitive_shifter'ın 0.30/0.20 taban değeri var
-- (deneyimsiz bir müşteri bile sıfır değil, gerçekçi bir alt sınırdan başlar).
-- KARMAŞIKLIK: O(1) per satır; ScanCustomerPool O(rows) ile bunu çağırır.
-- =====================================================================
local function DeriveTraitsFromCustomer(stats)
    if type(stats) ~= 'table' then stats = {} end
    return {
        fear_factor       = Matrix.Clamp((stats.police_encounters_nearby or 0) * 0.10, 0.0, 1.0),
        resilience        = Matrix.Clamp(0.30 + ((stats.completed_deals or 0) * 0.02), 0.0, 1.0),
        snitch_tendency   = Matrix.Clamp((stats.times_reported or 0) * 0.15, 0.0, 1.0),
        economic_pressure = Matrix.Clamp((stats.failed_payments or 0) * 0.12, 0.0, 1.0),
        cognitive_shifter = Matrix.Clamp(0.20 + ((stats.completed_deals or 0) * 0.015), 0.0, 1.0),
        skill_chemistry   = Matrix.Clamp((stats.chemistry_hints or 0) * 0.10, 0.0, 1.0)
    }
end


-- =====================================================================
-- SCAN CUSTOMER POOL (ticker → await YOK, batch)
-- =====================================================================
function Matrix.Recruitment.ScanCustomerPool()
    local rows = MySQL.query.await(
        'SELECT * FROM matrix_customer_pool WHERE promoted_to_candidate = 0 LIMIT 200',
        {}
    ) or {}
    if #rows == 0 then return 0 end


    local momentum  = Matrix.Bureau.GetPropagandaMomentum()
    local threshold = Config.Recruitment.BaseEligibilityThreshold / (1.0 + momentum)


    local promotedCids = {}
    local promotedCount = 0


    for _, row in ipairs(rows) do
        local traits = DeriveTraitsFromCustomer(row)
        local score  = traits.resilience + traits.cognitive_shifter + (1.0 - traits.snitch_tendency)


        -- Sokak Kulakları: siber yoğunluk (momentum) yükseldiğinde, ihbar
        -- geçmişi olan müşteriler potansiyel köstebek olarak fısıldanır.
        if momentum > Config.Recruitment.StreetWhisperMomentumThreshold and (row.times_reported or 0) > 0 then
            Matrix.Log('RECRUITMENT', '[SOKAK KULAKLARI] "%s" hakkında fısıltılar var: %d kez ihbar geçmiş.',
                row.name or row.citizenid, row.times_reported)
        end


        if score >= threshold then
            local cid = nextCandidateId
            nextCandidateId = cid + 1


            Matrix.Candidates[cid] = {
                id            = cid,
                citizenid     = row.citizenid,
                name          = row.name or ('Aday-%d'):format(cid),
                psychology    = traits,
                addiction_level = tonumber(row.addiction_level) or 0.0,
                revealed_fields = {}
            }
            promotedCids[#promotedCids + 1] = row.citizenid
            promotedCount = promotedCount + 1
            Matrix.Log('RECRUITMENT', 'Aday #%d havuzdan çekildi (skor %.2f / eşik %.2f)',
                cid, score, threshold)
        end
    end


    -- Batch UPDATE (tek sorgu, N satır)
    if #promotedCids > 0 then
        local placeholders = {}
        for i = 1, #promotedCids do placeholders[i] = '?' end
        local q = ('UPDATE matrix_customer_pool SET promoted_to_candidate = 1 WHERE citizenid IN (%s)')
                  :format(table.concat(placeholders, ','))
        MySQL.prepare(q, promotedCids)
    end


    return promotedCount
end


-- =====================================================================
-- INTERROGATION
-- =====================================================================
-- subjectRef: eski davranışla uyumlu düz bir candidateId (number) OLABİLİR,
-- ya da { kind = 'candidate'|'bot', id = ... } şeklinde açık bir referans.
function Matrix.Recruitment.BeginInterrogation(subjectRef, interrogatorSource)
    local kind, id
    if type(subjectRef) == 'table' then
        kind, id = subjectRef.kind, tonumber(subjectRef.id)
    else
        kind, id = 'candidate', tonumber(subjectRef)
    end
    if not id then return nil end


    local subject = ResolveInterrogationSubject(kind, id)
    if not subject then return nil end


    local sid = nextSessionId
    nextSessionId = sid + 1


    Matrix.Sessions[sid] = {
        id                  = sid,
        subject_kind        = subject.kind,
        subject_id          = subject.id,
        interrogator_source = interrogatorSource,
        cumulative_pressure = 0.0,
        lies_told           = 0,
        confessions         = 0,
        revealed            = {}
    }


    Matrix.Log('RECRUITMENT', 'Sorgu #%d başlatıldı -> %s #%s (%s)', sid, subject.kind, tostring(subject.id), subject.name)
    return sid
end


local function NextUnrevealedField(session)
    for _, field in ipairs(BIO_FIELDS) do
        if not session.revealed[field] then return field end
    end
    return nil
end


-- FORMÜL (karanlık mülakat panik endeksi):
--   panic = clamp(cumulative_pressure*fear_factor - resilience*ResilienceDamping, 0, 1)
-- Yorum: baskı ve korku ÇARPIMSAL etkileşir (yüksek fear_factor, aynı
-- baskıyı çok daha "yıkıcı" hale getirir); resilience ise SABİT bir
-- SÖNÜMLEME terimi olarak DOĞRUSAL çıkarılır (korkudan bağımsız bir
-- "iç kale"). panic üç bölgeye ayrılır (RNG YOK, sabit eşikler):
--   panic >= ConfessionThreshold(0.75) -> itiraf (gerçek trait açığa çıkar)
--   panic >= LieThreshold(0.35)        -> yalan (deterministik SAPMA formülü
--                                          ile üretilen SAHTE bir değer döner)
--   panic <  LieThreshold               -> sessizlik (hiçbir bilgi çıkmaz)
-- Yalan sapması: fakeValue = clamp(trueValue + (trueValue>=0.5 ? -0.4 : +0.4), 0,1)
-- yani gerçek değer HANGİ YARIDAYSA (üst/alt) karşı yarıya SIÇRAR - bu,
-- "gerçeğin tam tersini söyleme" davranışının deterministik matematik
-- karşılığıdır. KARMAŞIKLIK: O(1) + O(|BIO_FIELDS|)=O(6) (NextUnrevealedField).
function Matrix.Recruitment.ApplyPressure(sessionId, pressureAmount)
    sessionId = tonumber(sessionId)
    if not sessionId then return nil end
    local session = Matrix.Sessions[sessionId]
    if not session then return nil end


    local subject = ResolveInterrogationSubject(session.subject_kind, session.subject_id)
    if not subject then return nil end
    local psychology = subject.psychology


    pressureAmount = tonumber(pressureAmount) or 0.0
    if pressureAmount ~= pressureAmount or pressureAmount < 0.0 then pressureAmount = 0.0 end
    if pressureAmount > 100.0 then pressureAmount = 100.0 end


    session.cumulative_pressure = session.cumulative_pressure + pressureAmount


    local panic = Matrix.Clamp(
        (session.cumulative_pressure * psychology.fear_factor)
            - (psychology.resilience * Config.Recruitment.ResilienceDamping),
        0.0, 1.0
    )
    local waveform = BuildAsciiWaveform(panic)


    local field = NextUnrevealedField(session)
    if not field then
        Matrix.Log('RECRUITMENT', 'Sorgu #%d tükendi. Panik: %s', sessionId, waveform)
        return { panic_index = panic, outcome = 'exhausted', waveform = waveform }
    end


    if panic >= Config.Recruitment.ConfessionThreshold then
        session.revealed[field] = psychology[field]
        session.confessions = session.confessions + 1
        Matrix.Log('RECRUITMENT', '[İTİRAF] Sorgu #%d -> %s = %.2f | Panik: %s',
            sessionId, field, psychology[field], waveform)
        return { panic_index = panic, outcome = 'confession', field = field, value = psychology[field], waveform = waveform }
    elseif panic >= Config.Recruitment.LieThreshold then
        local trueValue = psychology[field]
        local fakeValue = Matrix.Clamp(trueValue + ((trueValue >= 0.5) and -0.4 or 0.4), 0.0, 1.0)
        session.lies_told = session.lies_told + 1


        -- Yalan söylerken telsiz ses frekans sapması: lies_told'a bağlı
        -- deterministik bozulma (RNG yok) - panikten daha "kısık/parazitli".
        local deviation = Matrix.Clamp(panic - (Config.Recruitment.LieWaveformDeviationPerLie * session.lies_told), 0.0, 1.0)
        local deviationWave = BuildAsciiWaveform(deviation)


        Matrix.Log('RECRUITMENT', '[YALAN TESPİTİ] Sorgu #%d -> %s alanında sapma tespit edildi.\n  SES  : %s\n  SAPMA: %s',
            sessionId, field, waveform, deviationWave)
        return { panic_index = panic, outcome = 'lie', field = field, value = fakeValue, waveform = waveform, deviation_waveform = deviationWave }
    else
        Matrix.Log('RECRUITMENT', '[SESSİZLİK] Sorgu #%d -> Aday baskıya direniyor. Panik: %s', sessionId, waveform)
        return { panic_index = panic, outcome = 'silence', waveform = waveform }
    end
end


-- =====================================================================
-- PROMOTE
-- =====================================================================
function Matrix.Recruitment.Promote(candidate)
    local bot = Matrix.CreateBotRecord({
        name              = candidate.name,
        role              = 'dealer',
        fear_factor       = candidate.psychology.fear_factor,
        resilience        = candidate.psychology.resilience,
        snitch_tendency   = candidate.psychology.snitch_tendency,
        economic_pressure = candidate.psychology.economic_pressure,
        cognitive_shifter = candidate.psychology.cognitive_shifter,
        skill_chemistry   = candidate.psychology.skill_chemistry,
        addiction_level   = candidate.addiction_level
    })


    Matrix.Log('RECRUITMENT', 'Aday #%d bot matrisine eklendi -> Bot #%d', candidate.id, bot.id)
    return bot
end


-- =====================================================================
-- ★ KATMAN 7 FAZ 2: PROPAGANDA -> DEVŞİRME KALİTE KÖPRÜSÜ
-- Sokakta canlı NPC "keş" satış döngüsü (server/market.lua Matrix.Market.
-- StreetDealing) bir NPC'nin bağımlılığını Config.Market.StreetDealing.
-- RecruitAddictionThreshold'a taşıdığında VE satıcı o NPC'ye Config.Market.
-- StreetDealing.RecruitDistance içindeyken çağrılır. YENİ bir psikoloji
-- formülü İCAT EDİLMEZ -- Matrix.CreateBotRecord (main.lua, TEK bot-yaratma
-- girdisi, DEĞİŞTİRİLMEDİ) yeniden kullanılır. Kalite, Matrix.Bureau.
-- GetPropagandaMomentum()'a (DEĞİŞTİRİLMEDİ) DOĞRUSAL bağlanır: kampanya ne
-- kadar "ısıtıyorsa" sokaktan gelen devşirme o kadar güvenilir (yüksek
-- resilience/düşük snitch_tendency) olur.
-- SIFIR RNG: aynı momentum + aynı taban değerler HER ZAMAN aynı psikolojiyi
-- üretir.
-- =====================================================================
-- ★ [MADDE 4] loyaltyBase (opsiyonel, varsayilan nil -> CreateBotRecord
-- kendi 0.5 tabanini kullanir): sokak satisi devsirme cagri yerleri
-- (server/market.lua net-event'i VE /sokakdevsir test komutu, asagida
-- AYNI DISIPLIN) 1.0 gecirir -- "Ox_Target ile devsirilen ajan MUTLAK
-- SADIK" talebi. Momentum/resilience/snitch formulu (yukarida, ESKI
-- davranis) HIC DEGISMEDI; loyalty_base bagimsiz bir ek alandir.
function Matrix.Recruitment.RecruitStreetNpc(npcLabel, trapHouseId, loyaltyBase)
    npcLabel = (type(npcLabel) == 'string' and npcLabel ~= '') and npcLabel or 'Sokak Ajani'
    trapHouseId = tonumber(trapHouseId)

    local momentum = (Matrix.Bureau and Matrix.Bureau.GetPropagandaMomentum and Matrix.Bureau.GetPropagandaMomentum()) or 0.0
    local qualityFactor = Matrix.Clamp(
        1.0 + (momentum / Config.Recruitment.MomentumQualityDivisor),
        1.0, Config.Recruitment.MomentumQualityCeiling
    )

    local resilience     = Matrix.Clamp(Config.Recruitment.BaseCandidateResilience * qualityFactor, 0.0, 1.0)
    local snitchTendency = Matrix.Clamp(Config.Recruitment.BaseCandidateSnitchTendency / qualityFactor, 0.0, 1.0)

    local bot = Matrix.CreateBotRecord({
        name              = npcLabel,
        role              = 'dealer',
        fear_factor       = 0.5,
        resilience        = resilience,
        snitch_tendency   = snitchTendency,
        economic_pressure = 0.5,
        cognitive_shifter = 0.2,
        skill_chemistry   = 0.1,
        trap_house_id     = trapHouseId,
        loyalty_base      = loyaltyBase
    })

    Matrix.Log('RECRUITMENT',
        '[SOKAK DEVSIRME] "%s" -> Bot #%d (momentum=%.2f, kaliteFaktoru=%.3f, resilience=%.3f, snitch=%.3f, loyalty=%.2f, trap=%s)',
        npcLabel, bot.id, momentum, qualityFactor, resilience, snitchTendency, bot.psychology.loyalty_base, tostring(trapHouseId))

    return bot
end


-- =====================================================================
-- EVALUATE OUTCOME
-- =====================================================================
function Matrix.Recruitment.EvaluateOutcome(sessionId)
    sessionId = tonumber(sessionId)
    if not sessionId then return nil end
    local session = Matrix.Sessions[sessionId]
    if not session then return nil end


    local subject = ResolveInterrogationSubject(session.subject_kind, session.subject_id)
    if not subject then return nil end
    local psychology = subject.psychology


    local outcome
    if session.lies_told > Config.Recruitment.MaxToleratedLies then
        outcome = 'burned'
    elseif session.confessions >= Config.Recruitment.MinConfessionsToPromote
        and psychology.snitch_tendency <= Config.Recruitment.SafeSnitchTendencyCeiling
        and psychology.resilience >= Config.Recruitment.MinOperationalResilience then
        -- Zaten bot olan bir özne için "recruited" anlamsız: sadakat testi geçti demektir.
        outcome = (subject.kind == 'candidate') and 'recruited' or 'released'
    else
        outcome = 'released'
    end


    -- Async insert: sunucuyu bloklamaz. Özne bir bot ise ref_key onun dna_id'sidir
    -- (candidate_citizenid kolonu her iki özne türü için de kimlik alanı olarak kullanılır).
    MySQL.prepare([[
        INSERT INTO matrix_recruitment_sessions (
            candidate_citizenid, fear_factor, resilience, lies_told, confessions, outcome, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, NOW())
    ]], {
        subject.ref_key, psychology.fear_factor, psychology.resilience,
        session.lies_told, session.confessions, outcome
    })


    if outcome == 'recruited' and subject.kind == 'candidate' then
        Matrix.Recruitment.Promote(Matrix.Candidates[subject.id])
    end


    if subject.kind == 'candidate' then
        Matrix.Candidates[subject.id] = nil
    end
    Matrix.Sessions[sessionId] = nil


    Matrix.Log('RECRUITMENT', 'Sorgu #%d (%s #%s) sonuçlandı: %s', sessionId, subject.kind, tostring(subject.id), outcome)
    return outcome
end


-- =====================================================================
-- EVENT BRIDGE (guard'lı)
-- =====================================================================
RegisterNetEvent('matrix:server:beginInterrogation', function(candidateId)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    candidateId = tonumber(candidateId)
    if not candidateId then return end
    Matrix.Recruitment.BeginInterrogation(candidateId, src)
end)


RegisterNetEvent('matrix:server:applyInterrogationPressure', function(sessionId, pressureAmount)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    sessionId = tonumber(sessionId)
    if not sessionId then return end
    Matrix.Recruitment.ApplyPressure(sessionId, pressureAmount)
end)


RegisterNetEvent('matrix:server:evaluateInterrogation', function(sessionId)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    sessionId = tonumber(sessionId)
    if not sessionId then return end
    Matrix.Recruitment.EvaluateOutcome(sessionId)
end)


-- =====================================================================
-- KOMUT: /sorgu [id] [aday|bot] - ASCII ses-dalgalı karanlık mülakat terminali
-- =====================================================================
local function Reply(src, msg)
    if type(src) == 'number' and src > 0 then
        TriggerClientEvent('chat:addMessage', src, { args = { '[SORGU]', msg } })
    else
        print(('[MATRIX:RECRUITMENT:CONSOLE] %s'):format(msg))
    end
end


RegisterCommand('sorgu', function(src, args)
    local id = tonumber(args[1])
    local kind = (args[2] == 'bot') and 'bot' or 'candidate'


    if not id then
        Reply(src, 'Kullanim: /sorgu [id] [aday|bot]'); return
    end


    local sid = Matrix.Recruitment.BeginInterrogation({ kind = kind, id = id }, src)
    if not sid then
        Reply(src, ('%s #%d bulunamadı.'):format(kind, id)); return
    end


    local result = Matrix.Recruitment.ApplyPressure(sid, 25.0)
    if result then
        Reply(src, ('Sorgu #%d | Panik: %s | Sonuç: %s'):format(sid, result.waveform, result.outcome))
    end
end, false)


-- =====================================================================
-- MONOKROM TAKTİK DEBUG PANELİ (herkese açık test grubu, restricted=false)
-- ScanCustomerPool normalde Bureau.AnalysisIntervalSeconds'ta (300s) bir,
-- kendi coroutine'inde (main.lua ticker'ını bloklamadan) çalışır. Bu
-- komutlar o beklemeyi atlayıp DeriveTraitsFromCustomer/panic formüllerini
-- anlık test etmeyi sağlar.
-- =====================================================================


-- /musterikaydet [citizenid] [isim] [polisEncounter] [tamamlananIs] [ihbar]
-- [odemeBasarisiz] [kimyaIpucu] [bagimlilik] - matrix_customer_pool'a
-- gerçek oynanış beklemeden bir satır yazar; ardından /havuztara ile
-- DeriveTraitsFromCustomer formülünün ürettiği trait'ler gözlemlenebilir.
RegisterCommand('musterikaydet', function(src, args)
    local citizenid = args[1]
    local name       = args[2] or citizenid
    if type(citizenid) ~= 'string' then
        Reply(src, 'Kullanim: /musterikaydet [citizenid] [isim] [polisEncounter] [tamamlananIs] [ihbar] [odemeBasarisiz] [kimyaIpucu] [bagimlilik]')
        return
    end


    MySQL.prepare([[
        INSERT INTO matrix_customer_pool (
            citizenid, name, police_encounters_nearby, completed_deals, times_reported,
            failed_payments, chemistry_hints, addiction_level, promoted_to_candidate, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, NOW())
        ON DUPLICATE KEY UPDATE
            name = VALUES(name), police_encounters_nearby = VALUES(police_encounters_nearby),
            completed_deals = VALUES(completed_deals), times_reported = VALUES(times_reported),
            failed_payments = VALUES(failed_payments), chemistry_hints = VALUES(chemistry_hints),
            addiction_level = VALUES(addiction_level)
    ]], {
        citizenid, name,
        tonumber(args[3]) or 0, tonumber(args[4]) or 0, tonumber(args[5]) or 0,
        tonumber(args[6]) or 0, tonumber(args[7]) or 0, tonumber(args[8]) or 0.0
    })


    Reply(src, ('Müşteri havuzu satırı yazıldı: %s (%s)'):format(citizenid, name))
end, false)


-- /havuztara - ScanCustomerPool'u 300sn beklemeden anlık çalıştırır.
RegisterCommand('havuztara', function(src)
    local count = Matrix.Recruitment.ScanCustomerPool()
    Reply(src, ('Havuz tarandı: %d aday terfi etti.'):format(count or 0))
end, false)


-- /adaygoster [candidateId] - bir adayın anlık psychology/addiction durumunu döker.
RegisterCommand('adaygoster', function(src, args)
    local id = tonumber(args[1])
    local candidate = id and Matrix.Candidates[id]
    if not candidate then Reply(src, 'Kullanim: /adaygoster [candidateId]'); return end


    local p = candidate.psychology
    Reply(src, ('Aday #%d %s | Fear:%.2f Res:%.2f Snitch:%.2f Econ:%.2f Cog:%.2f Chem:%.2f | Bağımlılık:%.1f'):format(
        id, candidate.name, p.fear_factor, p.resilience, p.snitch_tendency, p.economic_pressure,
        p.cognitive_shifter, p.skill_chemistry, candidate.addiction_level))
end, false)


-- /baskiuygula [sessionId] [miktar] - ApplyPressure'ı /sorgu'nun sabit 25.0
-- değeri dışında serbest bir miktarla test etmek için.
RegisterCommand('baskiuygula', function(src, args)
    local sid = tonumber(args[1])
    local amount = tonumber(args[2])
    if not sid or not amount then Reply(src, 'Kullanim: /baskiuygula [sessionId] [miktar]'); return end


    local result = Matrix.Recruitment.ApplyPressure(sid, amount)
    if not result then Reply(src, 'Sorgu bulunamadı.'); return end


    Reply(src, ('Panik: %s (%.3f) | Sonuç: %s'):format(result.waveform, result.panic_index, result.outcome))
end, false)


-- /sorgubitir [sessionId] - EvaluateOutcome wrapper'ı.
RegisterCommand('sorgubitir', function(src, args)
    local sid = tonumber(args[1])
    if not sid then Reply(src, 'Kullanim: /sorgubitir [sessionId]'); return end


    local outcome = Matrix.Recruitment.EvaluateOutcome(sid)
    Reply(src, outcome and ('Sonuç: %s'):format(outcome) or 'Sorgu bulunamadı.')
end, false)


-- /sokakdevsir [trapHouseId] [isim] - RecruitStreetNpc'yi market.lua'nın
-- bağımlılık eşiğini beklemeden test etmek için (bkz. /havuztara İLE AYNI
-- disiplin/kapsam: gerçek tetikleyici server/market.lua'dadır). loyalty_base
-- 1.0 sabit -- test yolu, gerçek Ox_Target tetiğiyle AYNI sonucu üretmeli.
RegisterCommand('sokakdevsir', function(src, args)
    local trapHouseId = tonumber(args[1])
    local label = args[2] or 'Test-Ajan'
    local bot = Matrix.Recruitment.RecruitStreetNpc(label, trapHouseId, 1.0)
    Reply(src, ('"%s" devsirildi -> Bot #%d (loyalty_base=%.2f).'):format(label, bot.id, bot.psychology.loyalty_base))
end, false)


exports('RecruitStreetNpc', function(npcLabel, trapHouseId, loyaltyBase) return Matrix.Recruitment.RecruitStreetNpc(npcLabel, trapHouseId, loyaltyBase) end)