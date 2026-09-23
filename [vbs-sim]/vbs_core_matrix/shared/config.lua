Config = {}


Config.Tick = {
    IntervalMs       = 1000,
    SecondsPerMinute = 60,
    SecondsPerHour   = 3600
}


-- Persistence / write-behind
Config.Persistence = {
    BotFlushIntervalMs      = 15000,
    BotFlushMaxBatch        = 250,
    TrapHouseFlushIntervalMs= 20000,
    AsyncRetryBackoffMs     = 5000
}


-- Katman 1: Balistik / adli sabitler
Config.BaseCortisolRecoveryRate   = 0.05
Config.BallisticStriationPrecision= 0.85


Config.Forensics = {
    MatchCertaintyThreshold        = 0.75,
    FingerprintQualityCortisolWeight = 0.4,
    CasingWearWeight               = 0.3,
    CasingCortisolWeight           = 0.2
}


Config.Recruitment = {
    BaseEligibilityThreshold   = 1.2,
    ResilienceDamping          = 0.35,
    LieThreshold               = 0.35,
    ConfessionThreshold        = 0.75,
    MinConfessionsToPromote    = 3,
    MaxToleratedLies           = 4,
    SafeSnitchTendencyCeiling  = 0.6,
    MinOperationalResilience   = 0.25,


    -- ASCII ses-dalgası sorgu terminali
    WaveformWidth              = 20,
    LieWaveformDeviationPerLie = 0.15,


    -- Sokak Kulakları: bu momentum eşiğinin üstünde köstebek fısıltıları basılır.
    StreetWhisperMomentumThreshold = 0.5
}


Config.Bureau = {
    CellTowers = {
        { id = 1, coords = vector3(-100.0, -800.0, 30.0) },
        { id = 2, coords = vector3(400.0, -1200.0, 30.0) },
        { id = 3, coords = vector3(150.0, -2200.0, 30.0) },
        { id = 4, coords = vector3(-600.0, -1400.0, 30.0) },
        { id = 5, coords = vector3(900.0, -300.0, 60.0) },
        { id = 6, coords = vector3(-1100.0, -400.0, 35.0) }
    },
    TowerRange                 = 1200.0,
    BaseSearchRadius           = 2500.0,


    -- Triangulation AKTİF bir oyuncu hatasının (şifresiz telsiz kullanımı)
    -- ANLIK bedelidir - zamana yayılan pasif bir oran değildir, bu yüzden
    -- "Yarılanma Ömrü" türetmesine girmez. Doğrudan bir sabit olarak kalır,
    -- ama "ilk 1 saat çöküşü" riskini azaltmak için 0.04'ten 0.025'e
    -- yumuşatıldı (yaklaşık %37 daha az sert; hâlâ hatanın gerçek bir
    -- bedeli var, sadece anlık ölüm değil).
    TriangulationDecryptionGain= 0.025,


    RaidDecryptionThreshold    = 0.90,
    AnalysisIntervalSeconds    = 300,
    PropagandaGeometricFactor  = 1.15,
    PropagandaMomentumIncrement= 0.10,
    PropagandaMaxMomentum      = 6.0,
    CyberLeakGeometricFactor   = 1.20,
    CyberLeakIncrement         = 0.05,
    CyberLeakMaxIntensity      = 5.0,
    PostRaidHeatmapDecay       = 0.5,
    PostRaidDecryptionReset    = 0.0,


    -- qb-phone Canlı Yayın / Siber Propaganda Köprüsü. Hype, propagandaMomentum'un
    -- kendisini besler (Recruit_chance zaten momentum'a bağlı); bedel olarak en
    -- yakın trap house'un cyber-leak heatmap'i ve deşifre katsayısı da yükselir.
    -- (Gerçek per-tick artım oranları aşağıda "YARILANMA ÖMRÜ" bölümünde
    -- gerçek-zaman hedeflerinden TÜRETİLİR, burada magic number yazılmaz.)
    LivestreamHypeGeometricFactor    = 1.05,
    LivestreamHypeIncrementPerTick   = 0.05,


    -- Fiziksel Şafak Baskını mürettebat/breach matrisi (deterministik, RNG yok).
    RaidBaseSquadSize          = 2,
    RaidHeatSquadFactor        = 1.5,
    RaidMaxSquadSize           = 8,
    RaidExplosiveBreachThreshold = 0.97,
    RaidBaseEscapeWindowSeconds = 20,
    RaidDeadZoneEscapeBonusSeconds = 25
}


-- =====================================================================
-- YARILANMA ÖMRÜ / GERÇEK-ZAMAN DENGELEMESİ (OYNANABİLİRLİK KİLİDİ)
-- (v1 metni AYNEN korundu.)
-- =====================================================================
Config.Bureau.PatternFullDecryptionRealDays = 5.0
Config.Bureau.PatternAnalysisGain =
    Config.Bureau.RaidDecryptionThreshold
    / ((Config.Bureau.PatternFullDecryptionRealDays * 86400.0) / Config.Bureau.AnalysisIntervalSeconds)


Config.Bureau.LivestreamHeatFullSaturationRealMinutes = 20.0
Config.Bureau.LivestreamAloneFullDecryptionRealHours  = 3.0
Config.Bureau.LivestreamHeatIncrementPerTick =
    Config.Bureau.CyberLeakMaxIntensity / (Config.Bureau.LivestreamHeatFullSaturationRealMinutes * 60.0)
Config.Bureau.LivestreamDecryptionGainPerTick =
    Config.Bureau.RaidDecryptionThreshold / (Config.Bureau.LivestreamAloneFullDecryptionRealHours * 3600.0)


Config.Kitchen = {
    WorkFactor = {
        idle           = 0.0,
        lookout        = 0.01,
        distribution   = 0.02,
        cooking        = 0.035,
        cyber_ops      = 0.015,
        -- ★ KATMAN 7 FAZ 2: sokakta canlı NPC "keş" satışı yapan bir bot,
        -- distribution İLE AYNI yorgunluk yükünü taşır — yeni bir formül
        -- İCAT EDİLMEZ, mevcut ölçek yeniden kullanılır.
        street_dealing = 0.02
    },


    SkillGrowthRate = 0.01,
    FatigueCortisolBleed          = 0.02,
    FatigueWarningThreshold       = 0.8,
    FatigueCriticalThreshold      = 0.9,
    FatigueCriticalDurationSeconds= 3600,
    BurnoutResilienceLoss         = 0.10,
    BurnoutRecoveryRatePenalty    = 0.20,
    BurnoutRecoveryRateFloor      = 0.005,
    CortisolDeviationThreshold    = 0.8,
    CortisolDeviationDistance     = 100.0,


    WithdrawalGainPerAddictionPoint = 0.02,
    WithdrawalSkillPenaltyThreshold = 0.7,
    WithdrawalSkillPenaltyMultiplier= 0.5,
    TheftWithdrawalThreshold      = 1.0,
    TheftGramsPerAddictionPoint   = 10.0,
    RivalInfiltrationPurityThreshold = 0.30,
    CortisolSpike = {
        Gunshot              = 0.40,
        BureauVehicle        = 0.25,
        BureauVehicleRadius  = 50.0
    },
    SnitchThreshold = 0.75
}


Config.Player = {
    DefaultResilience      = 0.5,
    DefaultSkillChemistry  = 0.4,
    StateIdleTimeoutSec    = 600
}


Config.RoleModels = {
    dealer  = 's_m_y_dealer_01',
    runner  = 'a_m_y_runner_01',
    lookout = 'a_m_y_skater_01',
    cooking = 's_m_m_chemsec_01'
}
Config.DefaultRoleModel = 's_m_y_dealer_01'


-- =====================================================================
-- Dinamik Ped Yapılandırma Havuzu (Config Destekli Rol->Ped Ataması)
-- server/main.lua Matrix.SpawnBot/SpawnDispatchActors artık BURADAN, doğrudan
-- katı bir string olarak, bot.role'e karşılık gelen ped modelini okur --
-- ChecksumOf/hash tabanlı bir seçim YOKTUR (0 RNG, tam determinizm).
-- Config.RoleModels ile ÇAKIŞAN roller (runner/lookout) burada KASITLI
-- OLARAK AYNI modele sabitlenmiştir; chemist/inspector bu havuza ÖZGÜDÜR.
-- =====================================================================
Config.BotPedConfiguration = {
    ['runner']    = 's_m_y_dealer_01',
    ['lookout']   = 'g_m_y_ballaeast_01',
    ['chemist']   = 'g_m_y_vagos_01',
    ['inspector'] = 'a_m_m_mexcntry_01'
}


-- =====================================================================
-- ★ TRAFİK YOĞUNLUĞUNA BAĞLI DİNAMİK SÜRAT MOTORU
-- GTA V'de "GetVehicleDensityMultiplier" GİBİ bir GETTER native'i YOKTUR
-- (yalnızca SET_VEHICLE_DENSITY_MULTIPLIER_THIS_FRAME gibi setter'lar
-- vardır ve bunlar yereldeki popülasyon SPAWN oranını etkiler; FXServer'da
-- sunucu tarafında "şu an bu koordinatta ne kadar trafik var" diye
-- OKUNABİLECEK bir API değildir). Bu yüzden gerçek, ağda var olan araç
-- sayısını (GetVehicles() — OneSync-farkında, sunucu tarafında güvenilir
-- bir native) örneklem yarıçapında sayarak DETERMİNİSTİK bir yoğunluk
-- katsayısı türetiyoruz (server/logistics.lua ComputeNearbyVehicleDensity,
-- server/hitsquad.lua ComputePursuitSpeedMultiplier) — math.random YOK.
-- =====================================================================
Config.Traffic = {
    SampleRadius               = 40.0,  -- metre: yogunluk orneklemesi bu yaricapta sayilir
    DensitySaturationCount     = 12,    -- bu sayida veya daha fazla arac -> maksimum tikaniklik (1.0)

    -- Sivil/kurye (dealer, runner) botlari: yogun trafikte surtunmeye
    -- eklenen EK katsayi (frictionDivisor'a dogrudan toplanir -- degeri
    -- ne kadar yuksekse o kadar yavaslarlar).
    CivilianTrafficFrictionMax = 1.60,

    -- Büro (hitsquad) pusu/takip araçları: aynı yoğunluk sinyaline karşı
    -- MAKSIMUM hiz cezasi (sivilden AYRI olcek, carpansal -- 1.0 = ceza yok).
    PursuitTrafficPenaltyMax   = 0.45,
    -- Büro baskısı arttıkça (agresiflik) bu cezanın ne kadarı YOK SAYILIR
    -- (0.0 = sivil ile aynı ceza, 1.0 = trafik onu HİÇ yavaşlatmaz).
    BureauAggressionFactor     = 0.65,
    PursuitMinSpeedMultiplier  = 0.55
}


-- =====================================================================
-- Katman 4: Programli Lojistik Sevk & Zaman-Mesafe Surtunme Motoru
-- =====================================================================
Config.Logistics = {
    BaseSpeedUnitsPerSecond   = 5.0,
    WeightFrictionCoefficient = 0.005,


    DefaultVehicleType     = 'foot',
    DispatchTickIntervalMs = 1000,


    VehicleTypes = {
        foot = {
            SpeedCoefficient           = 0.2,
            FrictionMultiplier         = 1.00,
            PoliceDecryptionMultiplier = 0.05,
            CombatResistance           = 0.00
        },
        motorbike = {
            SpeedCoefficient           = 1.0,
            FrictionMultiplier         = 1.25,
            PoliceDecryptionMultiplier = 1.40,
            CombatResistance           = 0.30
        },
        car = {
            SpeedCoefficient           = 0.6,
            FrictionMultiplier         = 1.85,
            PoliceDecryptionMultiplier = 1.00,
            CombatResistance           = 0.80
        }
    },


    CombatEliminationThreshold = 1.0,


    PoliceDecryptionGainPerTick = 0.01,


    MaxDispatchRangeMeters = 6000.0,


    -- Origin ile hedef arasındaki mesafe bu değerin ALTINDAYSA (nil hedef dahil)
    -- sevk tamamen İPTAL edilir.
    MinDispatchDistanceMeters = 5.0,


    DeadZones = {
        { id = 1, label = 'Tunel Bolgesi',    coords = vector3(-1200.0, -560.0, 30.0),  radius = 300.0 },
        { id = 2, label = 'Endustriyel Vadi', coords = vector3(900.0, -2400.0, 10.0),   radius = 250.0 },
        { id = 3, label = 'Dag Gecidi',       coords = vector3(-1900.0, 2200.0, 150.0), radius = 400.0 }
    },
    DeadZoneLogFlushDelayMs = 4000,


    Fleet = {
        DefaultVehicleClass = 'car',
        DefaultVinStatus    = 'hot',


        WearFrictionBonus = 0.20,


        VinDecryptionMultiplier = {
            factory   = 3.0,
            scratched = 1.5,
            hot       = 1.0
        },


        SeizureSealCertainty = {
            factory   = 0.95,
            scratched = 0.65,
            hot       = 0.40
        },


        BreakdownWearThreshold = 0.75,
        BreakdownStallSeconds  = 45
    }
}


-- =====================================================================
-- Katman 4: Toptancı İlişki Matrisi & Dead Drop Lojistiği
-- =====================================================================
Config.Supplier = {
    Suppliers = {
        { id = 1, name = 'Los Santos Kartel',      base_price_per_gram = 12.0 },
        { id = 2, name = 'Vagos Baglantisi',       base_price_per_gram = 9.5  },
        { id = 3, name = 'Rus Ithalat Agi',        base_price_per_gram = 15.0 }
    },
    DeadDrops = {
        { id = 1, supplier_id = 1, label = 'Liman Konteyner Sahasi',       coords = vector3(-50.0, -2400.0, 5.0),   radius = 15.0 },
        { id = 2, supplier_id = 2, label = 'Terkedilmis Benzin Istasyonu', coords = vector3(1700.0, 3200.0, 40.0),  radius = 15.0 },
        { id = 3, supplier_id = 3, label = 'Havaalani Kargo Deposu',      coords = vector3(-1000.0, -2700.0, 15.0), radius = 15.0 }
    },


    DefaultTrust                = 0.5,
    TrustLatePaymentPenalty     = 0.15,
    TrustForensicLeakPenalty    = 0.10,
    TrustHeatmapPenaltyFactor   = 0.20,
    TrustRecoveryPerCleanPickup = 0.03,


    PassiveTrustRecoveryPerRealDay = 0.02,
    PassiveTrustRecoveryTarget     = 0.5,


    PriceMultiplierFloor   = 1.0,
    PriceMultiplierCeiling = 4.0,
    PriceMultiplierGain    = 1.0,


    SupplyCutTrustThreshold = 0.1,
    BetrayalTrustThreshold  = 0.1,


    ForensicTraceQualityThreshold = 0.5,


    DropHeatGrowthPerUse   = 0.25,
    DropHeatDecayPerMinute = 0.01,


    PickupWindowSeconds = 600
}


-- =====================================================================
-- KATMAN 5: QBOX CO-OP KARTEL HİYERARŞİSİ + BÖLGESEL PİYASA +
-- KILCAL DAMAR HARDCORE MEKANİKLER
-- =====================================================================
Config.Hierarchy = {
    Ranks = {
        Leader            = { level = 3, label = 'Baron' },
        Logistics_Officer = { level = 2, label = 'Lojistik Subayı' },
        Chemist           = { level = 1, label = 'Kimyager' }
    },
    MinRankLevelForCommand = 2
}


Config.Market = {
    Zones = {
        { id = 1, label = 'Liman Bölgesi',  coords = vector3(-50.0, -2400.0, 5.0),   radius = 400.0 },
        { id = 2, label = 'Sanayi Bölgesi', coords = vector3(900.0, -2400.0, 10.0),  radius = 400.0 },
        { id = 3, label = 'Merkez Bölgesi', coords = vector3(200.0, -800.0, 30.0),   radius = 400.0 },
        { id = 4, label = 'Banliyö Bölgesi',coords = vector3(-1200.0, -560.0, 30.0), radius = 400.0 }
    },


    GourmetCognitiveShifterThreshold = 0.7,
    GourmetMinPurity                 = 0.30,


    RejectionPriceDecayRate    = 0.35,
    DemandElasticity           = 0.6,
    PriceMultiplierFloor       = 0.4,
    PriceMultiplierCeiling     = 2.5,
    PriceMultiplierDefault     = 1.0
}


Config.Forensics.WeaponDurabilityLabBlindnessThreshold = 0.5
Config.Forensics.WeaponDurabilityBlindnessDecayRate     = 4.0
Config.Forensics.WeaponJamChanceThreshold               = 0.2
Config.Forensics.WeaponJamBaseChance                    = 0.65
Config.Forensics.WeaponJamHardDeleteRisk                = 0.90


Config.RadioSilence = {
    MaxDurationMinutes = 30
}


-- ---------------------------------------------------------------------
-- ★ KATMAN 7 [T3]: SESSİZLİK İHLALİ CEZA KATSAYILARI
-- Yolda seyir halindeki (aktif dispatch) bir bota, dispatcher /sessizlik
-- altındayken telsizden müdahale edilirse (bkz. server/main.lua
-- Matrix.TriggerPanicEvacuation -> server/market.lua Matrix.RadioSilence.
-- BreakForRedirect) statik parazit şiddeti VE Büro'nun ilgili trap house
-- decryption_confidence'ı (Matrix.Bureau.AdvanceDecryption) BU İKİ TABANDAN
-- BreakGeometricFactor üssel katsayısıyla büyür — art arda ihlaller
-- katlanarak daha pahalıya patlar. Sayaç /sessizlik yeniden başlatıldığında
-- sıfırlanır (bkz. server/market.lua Matrix.RadioSilence.Start).
-- ---------------------------------------------------------------------
Config.RadioSilence.BreakBaseStatic         = 0.35
Config.RadioSilence.BreakBaseDecryptionGain = 0.05
Config.RadioSilence.BreakGeometricFactor    = 1.75


Config.CashDecay = {
    TraceHalfLifeRealDays         = 90.0,
    RaidRiskMultiplierAtMaxTrace  = 2.0,
    LaunderReducesAmount          = true,
    TickIntervalMs                = 60000
}


Config.Undercover = {
    InfiltrationMomentumThreshold = 3.0,
    SuspicionReportWeight   = 0.40,
    SuspicionDealWeight     = -0.15,
    SuspicionThreshold      = 0.50,
    ScanIntervalSeconds     = 300
}


-- =====================================================================
-- KATMAN 5: SAF METİN TABANLI MONOKROM TAKTİK HUD (client/hud.lua)
-- Veri, server'ın zaten dönen 1000ms master ticker'ından push edilir
-- (Config.Tick.IntervalMs) — ayrı bir server-side thread AÇILMAZ.
--
-- ★ SERTLEŞTİRME: inputDialog çıktıları ExecuteCommand'a girmeden önce
-- bu sınırlara göre sanitize edilir (bkz. client/hud.lua). Boşluk içeren
-- veya [%w%-_%.] dışında karakter taşıyan girdiler REDDEDİLİR.
--
-- ★ KATMAN 5 EVRİM: "Sıfır Sayı Standardı" + Multi-Waypoint Rota Motoru.
--   - Bulletins: HUD/F10 arayüzlerinde ham float YASAK; bu eşikler ham
--     cortisol_level/fatigue_level/durability değerlerini edebi/askeri
--     bültenlere çevirmek için client/hud.lua tarafından okunur. Sunucu
--     konsolu (print/Matrix.Log) ve /matrixdump HER ZAMAN ham float
--     döker — bu eşikler yalnızca HUD/F10 GÖRÜNÜMÜNÜ etkiler.
--   - MaxWaypointInputLength / RouteWaypointCount: /rotaciz (F10 -> "Rota
--     Çiz") çoklu-uğrak taktik rota motorunun girdi sanitizasyon sınırları.
--     Waypoint girdisi ya "x,y,z" (vector3) ya da bir Trap House ID (tam
--     sayı) formatındadır; her ikisi de yalnızca rakam/nokta/virgül/eksi
--     karakterlerinden oluşabilir (bkz. client/hud.lua SanitizeWaypointArg).
-- =====================================================================
Config.Hud = {
    ToggleKey            = 'F6',
    -- ★ [F10 FAIL-SAFE] Taktik Komuta Menüsü'nü açan tuş. Önceki sürümde bu
    -- menü hiçbir RegisterKeyMapping'e bağlanmamıştı (bkz. client/hud.lua
    -- OpenMainTacticalMenu) -- F10 hiçbir şey açmıyordu.
    MenuKey              = 'F10',
    MaxBotIdInputValue   = 999999,
    MaxPlateInputLength  = 32,
    MaxHudLines          = 64,


    MaxWaypointInputLength = 64,
    RouteWaypointCount     = 3,


    Bulletins = {
        Cortisol = {
            CalmMax    = 0.20,  -- < 0.20     -> [NABIZ: SOĞUKKANLI SUBAY]
            AnxietyMax = 0.60   -- 0.20-0.60  -> ANKSİYETE; > 0.60 -> AKUT PANİK
        },
        Fatigue = {
            FreshMax   = 0.30,  -- < 0.30     -> [KONDİSYON: DİNÇ]
            ChronicMax = 0.80   -- 0.30-0.80  -> KRONİK BİTKİNLİK; > 0.80 -> NÖRON HASARI
        },
        Mechanical = {
            PristineMin = 0.80, -- > 0.80     -> [MEKANİK: KUSURSUZ CONDITION]
            WornMin     = 0.40  -- 0.40-0.80  -> YİV-SET AŞINMASI; < 0.40 -> KRİTİK ERİME
        }
    }
}


-- =====================================================================
-- ★★★ KATMAN 5 ULTIMATE: CO-OP & SIGINT/COMINT BALİ-LOJİSTİK MATRİSİ ★★★
-- Aşağıdaki bloklar YENİ eklemelerdir; yukarıdaki hiçbir alan/tablo/anahtar
-- DEĞİŞTİRİLMEDİ (mevcut 16 tablo şeması ve tüm eski davranış korunuyor).
-- =====================================================================


-- ---------------------------------------------------------------------
-- [U1] Multi-Waypoint Otomatik İntikal — Trap House varışında otomatik
-- stash teslimatı için "varış" sayılacak yarıçap (metre).
-- ---------------------------------------------------------------------
Config.Logistics.TrapHouseArrivalStashRadius = 15.0


-- ---------------------------------------------------------------------
-- ★ KATMAN 7 [T2]: MÜHİMMAT DAĞITIM GÖREVİ MANİFESTOSU
-- Lojistik rütbesindeki (bot.role == 'runner') bir bot, "Mühimmat Dağıtım
-- Görevi" tetiklendiğinde trap house'un ortak deposundan (matrix_trap_
-- stash_<id>) BU listedeki kalemleri kendi envanterine (dealer_<id>)
-- çeker (bkz. server/logistics.lua Matrix.Logistics.DispatchAmmoRun).
-- Kalemler KASITLI olarak Config.BlackMarket'te ZATEN tanımlı item id'leri
-- kullanır — yeni bir item icat edilmez. Silahlar mühimmatsız (ayrı
-- ammo_rifle item'ı yüklenmeden) teslim edilir; bu ox_inventory'nin zaten
-- var olan silah/mühimmat ayrımıdır.
-- ---------------------------------------------------------------------
Config.Logistics.AmmoRunManifest = {
    { item = 'weapon_assaultrifle', count = 1  }, -- silahsız AK-47 (Config.BlackMarket.Weapons ile aynı item)
    { item = 'ammo_rifle',          count = 90 }, -- şarjör/mühimmat (Config.BlackMarket.Ammo ile aynı item)
    { item = 'weapon_spare_barrel', count = 1  }, -- yedek namlu (Config.BlackMarket.SpareBarrelItem ile aynı item)
    -- ★ [ENVANTER MANİFESTOSU] Açık Hat (Config.BlackMarket.BurnerPhones ile
    -- AYNI item) -- lojistik botlar (runner) bunu depodan çekip sahada
    -- üzerinde telefon olmayan diğer botlara dağıtır. server/bureau.lua
    -- Matrix.Bureau.StartLivestream artık aktif bir 'burner_phone' zorunlu
    -- kılar (bkz. o fonksiyonun güncellenmiş yorumu).
    { item = 'burner_phone',        count = 3  }
}


-- ---------------------------------------------------------------------
-- [U2] TAKTİK KARABORSA TİCARET AĞI (Config.BlackMarket)
-- Tüm fiyatlar oyuncunun nakit (qbx 'cash') parasından tahsil edilir.
-- Kimlik üretimi (plaka/seri no) KESİNLİKLE RNG KULLANMAZ — bkz.
-- server/blackmarket.lua GenerateScratchedPlate/GenerateWeaponSerial
-- (GetGameTimer + girdi-türevli sağlama toplamı, tamamen deterministik).
-- ---------------------------------------------------------------------
Config.BlackMarket = {
    -- Karaborsa araç kataloğu: matrix_fleet'e vin_status='scratched' ile
    -- eklenir. `vehicle_class` DISPATCH_VEHICLE_MODELS (server/main.lua)
    -- üzerinden fiziksel sevk sırasında spawn edilecek modeli belirler —
    -- mevcut sınıf-bazlı spawn mimarisi DEĞİŞTİRİLMEDİ, katalog yalnızca
    -- bu sınıflardan (car/motorbike) seçim sunar.
    Vehicles = {
        { id = 'bm_sultan',  label = 'Sultan (Plaka Silinmiş)',        vehicle_class = 'car',       price = 45000.0, vehicle_wear = 0.35 },
        { id = 'bm_buffalo', label = 'Buffalo (Kaçak İthal Gövde)',    vehicle_class = 'car',       price = 62000.0, vehicle_wear = 0.45 },
        { id = 'bm_bati',    label = 'Bati Motosiklet (Şase Kazınmış)',vehicle_class = 'motorbike', price = 18000.0, vehicle_wear = 0.25 }
    },


    -- Karaborsa silah kataloğu: ox_inventory item adı + başlangıç metadata.
    Weapons = {
        { id = 'bm_pistol', label = 'Tabanca (Seri No Silinmiş)', item = 'weapon_combatpistol', price = 3800.0,  durability = 55.0 },
        { id = 'bm_ak47',   label = 'AK-47 (Seri No Silinmiş)',   item = 'weapon_assaultrifle', price = 15500.0, durability = 45.0 }
    },


    -- ★ KATMAN 6: mühimmat kataloğu — silahlarla AYNI Rendezvous teslim
    -- akışından geçer (bkz. server/rendezvous.lua). `item`/`count` çifti
    -- ox_inventory'ye handoff anında AddItem ile eklenir.
    Ammo = {
        { id = 'bm_ammo_pistol', label = 'Tabanca Mühimmatı (x60, Elden)', item = 'ammo_pistol', count = 60, price = 900.0  },
        { id = 'bm_ammo_rifle',  label = 'Tüfek Mühimmatı (x90, Elden)',   item = 'ammo_rifle',   count = 90, price = 2100.0 }
    },


    -- Yedek Namlu: sarf malzemesi item; /namludegistir bunu tüketir.
    SpareBarrelItem  = 'weapon_spare_barrel',
    SpareBarrelLabel = 'Yedek Namlu (Temiz)',
    SpareBarrelPrice = 2200.0,


    -- Açık Hat (Burner Phone): sahte IMEI'li, COMINT modülünün
    -- "GÜVENLİ AÇIK HAT" durumunu tetikleyen item.
    BurnerPhones = {
        { id = 'bm_burner', label = 'Açık Hat (Sahte IMEI)', item = 'burner_phone', price = 2500.0 }
    },


    -- /namludegistir yalnızca bu whitelist'teki silah item'ları için çalışır.
    ReplaceableWeaponItems = {
        weapon_combatpistol = true,
        weapon_assaultrifle = true
    }
}


Config.Forensics.WeaponShotLifespan = {
    weapon_combatpistol = 15000,
    weapon_assaultrifle = 20000
}
Config.Forensics.WeaponShotLifespanDefault = 15000


Config.Forensics.MechanicalJamThresholdPercent = 40.0 -- Durability (%) bu esigin altindaysa risk baslar
Config.Forensics.MechanicalJamExponent         = 3
Config.Forensics.MechanicalJamCoefficient      = 0.35


Config.Forensics.WeaponEvacuationSeconds = 6 -- 'X' tusu / F10 tahliye progressCircle suresi


-- ---------------------------------------------------------------------
-- [U4] SIGINT — BÖLGE DENETLEYİCİLERİ (Inspectors) & KÖSTEBEK TARAMASI
-- ---------------------------------------------------------------------
Config.Inspector = {
    -- Yalnızca bu rollerdeki botlar 'Inspector'a terfi ettirilebilir
    -- ('dealer' rolünün üstünde çalışacak kıdemli kurye tanımına uyar).
    PromotableRoles = { dealer = true, runner = true },


    MoleSnitchThreshold = 0.75, -- bot.psychology.snitch_tendency bu esigi GECERSE kostebek isaretlenir
    ScanIntervalSeconds = 180
}


-- ---------------------------------------------------------------------
-- [U5] COMINT — TELSİZ / TELEFON İLETİŞİM PROFİLİ
-- ---------------------------------------------------------------------
Config.Comint = {
    NormalCallTriangulationSeconds = 120, -- normal hatta bu sureyi gecen goruşme kirmizi uyari tetikler
    ToggleKey = 'K'                        -- COMINT panelini (Taktik HUD) acan ek tus
}


-- ---------------------------------------------------------------------
-- [U6] BÖLGESEL MALİ RAPOR — Karaborsa ekonomisi kâr/zarar bilançosu.
-- Bu iki sabit, ham gram satışlarını Bölgesel Mali Rapor için brüt
-- ciro/net kâra çevirmek amacıyla kullanılan ŞEFFAF varsayılan birim
-- fiyatlardır (gerçek toptancı fiyatlarının ortalamasına yakın tutuldu).
-- ---------------------------------------------------------------------
Config.Market.StreetBasePricePerGram   = 20.0
Config.Market.EstimatedCostBasisPerGram= 12.0


-- =====================================================================
-- ★★★ KATMAN 6: SİBER-TAKTIK OPERASYON VE STRATEJİK TRAP HOUSE MİMARİSİ ★★★
-- Aşağıdaki bloklar TAMAMEN YENİ EKLEMELERDİR. Katman 1-5(Ultimate)'in
-- hiçbir alanı/tablosu/anahtarı DEĞİŞTİRİLMEDİ. Bu bölüm, yeni server/
-- rendezvous.lua, server/trap_house_interior.lua, server/workbench.lua ve
-- server/door_reinforcement.lua dosyalarının Config sözleşmesidir — o
-- dosyalar YALNIZCA burada tanımlı anahtarları okur.
-- =====================================================================


-- ---------------------------------------------------------------------
-- [K6-1] RENDEZVOUS / DEAD DROP TESLİMATI + BÜRO PUSUSU
-- Karaborsa silah/mühimmat alımı artık envantere ANINDA düşmez; bir
-- buluşma koordinatı (satıcı NPC) üretilir. RNG YOK: koordinat, alıcının
-- citizenid'i + monoton bir sayaç + satın alma anındaki oyuncu konumundan
-- türetilen deterministik bir açı/mesafe ile hesaplanır (bkz.
-- server/rendezvous.lua Matrix.Rendezvous.ComputeHandoffCoords — aynı
-- ChecksumOf deseni server/blackmarket.lua'dan ödünç alınır).
-- ---------------------------------------------------------------------
Config.Rendezvous = {
    Enabled                 = true,
    MinOffsetMeters         = 150.0,
    MaxOffsetMeters         = 400.0,
    PickupWindowSeconds     = 900,
    PickupRadiusMeters      = 8.0,


    SellerPedModel          = 'g_m_y_mexgoon_01',
    SellerScenario          = 'WORLD_HUMAN_STAND_IMPATIENT',


    -- Handoff anında en yakın trap house'un Büro siber ısısı (bkz.
    -- Matrix.Bureau.GetHeat, zaten var olan salt-okunur getter) bu eşiği
    -- (heat / CyberLeakMaxIntensity oranı) GEÇERSE pusu tetiklenir.
    AmbushTraceLevelThreshold = 0.55,


    AmbushPedModel          = 's_m_y_swat_01',
    AmbushWeapon            = 'WEAPON_CARBINERIFLE',
    AmbushSquadSize         = 4,
    AmbushSpawnRadius       = 35.0,
    AmbushAggroRadius       = 60.0
}


-- =====================================================================
-- ★★★ KATMAN 8: DÜŞMAN HÜCUM EKİBİ — "DRIVE-BY" TAKİP MOTORU ★★★
-- server/hitsquad.lua'nın Config sözleşmesi. Hedefleme, server/rendezvous.
-- lua [R2] İLE AYNI trace-level formülünü (Matrix.Bureau.GetHeat / Config.
-- Bureau.CyberLeakMaxIntensity) yeniden kullanır — ikinci bir "ısı" alanı
-- İCAT EDİLMEZ. RNG YOK: eşik karşılaştırması + sabit süreli fazlar.
-- =====================================================================
-- NOT: Config.GangHoods bu dosyada TEK bir yerde tanimlanir (asagida,
-- [KATMAN 7] blogunda, Config.GangHoods.Hoods sekli). KATMAN 8 kendi
-- ayri dizisini ICAT ETMEZ -- ayni mahalle listesini paylasir (bkz.
-- server/hitsquad.lua: Config.GangHoods.Hoods uzerinde doner).
Config.HitSquad = {
    -- Config.Rendezvous.AmbushTraceLevelThreshold İLE PAYLAŞILAN eşik —
    -- KATMAN 6'nın "ne zaman tehlikeli" tanımıyla ÇELİŞMEZ.
    HeatTraceThreshold = Config.Rendezvous.AmbushTraceLevelThreshold,

    -- Hedefleme taraması main.lua'nın bureauAccumulator deseniyle AYNI
    -- TARZDA, Config.Tick.IntervalMs'e göre birikimli sayılır — HER TICK
    -- ÇALIŞMAZ.
    ScanIntervalTicks = 5,

    AttackRange      = 12.0,
    DrivebyRange      = 60.0,
    DrivebySeconds    = 15,
    FleeSeconds       = 20,
    CruiseSpeed       = 18.0,
    AggressiveDriveStyle = 16777216,

    VehicleModel = 'sultan2',
    PedModel     = 'g_m_y_ballasout_01',
    Weapon       = 'WEAPON_MICROSMG',
    PedAccuracy  = 70
}


-- ---------------------------------------------------------------------
-- [K6-2] SANAL MAHALLE EVİ (INTERIOR INSTANCE)
-- Fütüristik/high-tech sığınak YASAK — vanilla GTA V döküntü iç mekan
-- kabukları (motel/apartman) + SetRoutingBucket ile ORTAK koordinatlar
-- üzerinde ÖZEL (instance) bir oda üretilir. Bucket = BucketBase +
-- trapHouseId (her trap house'a biricik bir bucket garanti eder).
-- ---------------------------------------------------------------------
Config.TrapHouseInterior = {
    BucketBase        = 20000,
    EntryRadius       = 1.5,
    ExitRadius        = 1.5,


    -- ★ TEŞHİS DÜZELTMESİ: giriş mesafesi yatay (X,Y) ve dikey (Z) olarak
    -- AYRI ölçülür (bkz. server/trap_house_interior.lua HorizontalDistance).
    -- Trap house koordinatı yer seviyesinde kaydedilmiş olsa bile oyuncu
    -- bir kaldırım/basamak/eşikte durunca Z birkaç metre kayabilir; dikeyde
    -- bu yüzden çok daha toleranslı bir sınır kullanılır.
    EntryZTolerance   = 8.0,


    -- ★ KÖKLÜ DEĞİŞİKLİK (canlı testte doğrulandı): önce Trevor'ın treyleri
    -- (bob74_ipl, interiorId 2562) denendi — koordinat/IPL/export hepsi
    -- doğruydu (IsIplActive=true, GetInteriorAtCoords sıfır değil) ama
    -- `PinInteriorInMemory` + 15 saniye beklemeye rağmen `IsInteriorReady`
    -- HİÇBİR ZAMAN true olmadı: bu sunucu ortamında bu spesifik (tek
    -- oyunculu hikaye içeriği) interior güvenilir şekilde stream edilemiyor.
    -- Kullanıcı kararıyla TAMAMEN TERK EDİLDİ. Yerine bob74_ipl'in GTA Online
    -- "düşük gelirli ev" interior'ı kullanılıyor (GTAOHouseLow1, interiorId
    -- 149761 — bkz. client/trap_house_client.lua GetGTAOHouseLow1Object()).
    -- DLC/çok-oyunculu interior'lar milyonlarca GTA Online oyuncusu
    -- tarafından günlük kullanıldığından çok daha güvenilir stream ediliyor;
    -- ayrıca `Smoke.Set(stage2)` ile bedavaya "hafif kirli/dumanlı" atmosfer
    -- sağlıyor. Koordinat (bob74_ipl'in kendi client.lua'sındaki yorumdan
    -- doğrulandı): X:261.4586 Y:-998.8196 Z:-99.00863 — bu, apartman
    -- interior'larının paylaştığı ayrı/yeraltı "interior cebi" konumudur
    -- (normal harita ile çakışmaz).
    --
    -- ★ DÜZELTME (canlı testte bulundu, KALICI kök-neden çözümü uygulandı):
    -- Workbench/Packaging kapıya çok yakın olunca (INTERACT_RADIUS=2.0
    -- içinde çakışınca) tezgaha basmak için E'ye basıldığında oyuncu AYNI
    -- ANDA çıkış tetiğinin de menzilindeydi ve hem tamir hem çıkış birlikte
    -- tetikleniyordu, oyuncu dışarı fırlıyordu. Asıl düzeltme client/
    -- trap_house_client.lua'nın etkileşim döngüsünde: artık exit/workbench/
    -- packaging bağımsız üç `if` değil, "en yakın TEK bölge" seçiliyor —
    -- noktalar ne kadar yakın olursa olsun çift tetikleme artık YAPISAL
    -- olarak imkansız. Bu yüzden koordinatlar arasındaki mesafe artık bir
    -- doğruluk sorunu değil, yalnızca kozmetik bir tercih. WorkbenchPos,
    -- kullanıcının oyun içinde bizzat durup "/coords" ile aldığı gerçek
    -- konum (bkz. ekran görüntüsü) — EnterCoords/ExitCoords (kapı) kasıtlı
    -- olarak DEĞİŞTİRİLMEDİ. İnteriorun render OLMAMASI durumunda client/
    -- trap_house_client.lua'daki "/traphouseipldebug" teşhis komutu
    -- IsIplActive/GetInteriorAtCoords/IsInteriorReady sonuçlarını F8
    -- konsoluna basar.
    Shell = {
        EnterCoords  = vector4(261.4586, -998.8196, -99.00863, 0.0),
        WorkbenchPos = vector3(258.303, -997.279, -99.015),
        PackagingPos = vector3(258.303, -994.279, -99.015),
        -- ★ [KAMERA VERI TEMIZLIGI] Router kutusu -- PackagingPos ILE AYNI
        -- Y-eksenli ilerleme deseni (3 birim daha oteye), ayni interior
        -- cebinin icinde. /kameralogutemizle bu konuma yakinlik gerektirir.
        RouterPos    = vector3(258.303, -991.279, -99.015),
        ExitCoords   = vector4(261.4586, -998.8196, -99.00863, 180.0)
    },


    -- ★ DÜZELTME: eskiden burada rastgele modelli KOZMETİK "ambient" NPC
    -- listesi (AmbientPedCount/AmbientPedModels) vardı. Kaldırıldı — içeride
    -- artık YALNIZCA server/trap_house_interior.lua'nın GetResidentBots'unun
    -- döndürdüğü, o trap house'a GERÇEKTEN atanmış Matrix.Bots kayıtları
    -- görünür (bkz. client/trap_house_client.lua RESIDENT_BOT_PED_MODEL).
    -- AmbientScenarios sadece bu GERÇEK botların oynadığı animasyon
    -- havuzu olarak kalıyor (kimlik değil, salt duruş/aksiyon çeşitliliği).
    AmbientScenarios = {
        'WORLD_HUMAN_SMOKING', 'WORLD_HUMAN_STAND_IMPATIENT', 'WORLD_HUMAN_LEANING'
    }
}


-- ---------------------------------------------------------------------
-- [K6-3] SİLAH TAMİR TEZGAHI (WORKBENCH) + PAKETLEME ODASI
-- Nakit YOK — yalnızca bileşen tüketimi. Tamir tamamlandığında
-- server/forensics.lua'nın MEVCUT Matrix.Forensics.WipeBallisticRecord
-- fonksiyonu (değiştirilmedi) çağrılır.
-- ---------------------------------------------------------------------
Config.Workbench = {
    Radius = 2.0,
    RequiredItems = {
        { item = 'yiv_set_raybasi',        label = 'Yiv-Set Raybası',            count = 1 },
        { item = 'namlu_celik_tiraslama',  label = 'Namlu Çeliği Tıraşlama Sıvısı', count = 1 },
        { item = 'mekanik_igne_yayi',      label = 'Mekanik İğne Yayı',          count = 1 }
    }
}


Config.PackagingRoom = {
    Radius = 2.0,
    -- Paketleme odasında "çalıştırılan" bir trap house'daki tüm dealer
    -- botları mevcut Kitchen motorunun 'distribution' aktivitesine
    -- (skill_logistics büyümesi + normal fatigue formülü) geçirilir —
    -- YENİ bir ekonomi formülü İCAT EDİLMEZ, var olan sistem yeniden kullanılır.
    FlavorLogIntervalSeconds = 300
}


-- ---------------------------------------------------------------------
-- [K6-4] KAPI SÜRGÜ TAHKİMATI (Door Reinforcement)
-- Seviye arttıkça Matrix.Bureau.IssueRaid'in escapeWindow'una (kapı
-- kırılma süresi) EKLENEN bonus artar. Level 3 + düz arazi (dead-zone
-- bonusu yok) varsayılan olarak TAM 240 saniye üretir:
--   RaidBaseEscapeWindowSeconds(20) + Level3 bonus(220) = 240s.
-- ---------------------------------------------------------------------
Config.DoorReinforcement = {
    MaxLevel = 3,
    Levels = {
        [0] = { label = 'Takviyesiz Eski Ahşap Kapı',      price = 0,     breach_bonus_seconds = 0   },
        [1] = { label = 'Takviyeli Ahşap Sürgü',           price = 8000,  breach_bonus_seconds = 60  },
        [2] = { label = 'Çelik Sürgü Barikatı',            price = 22000, breach_bonus_seconds = 150 },
        [3] = { label = 'Çift Katlı Çelik Barikat (Maks)', price = 45000, breach_bonus_seconds = 220 }
    },

    -- ★ DÜŞMAN TRAP HOUSE KAPI KIRMA DONANIMI: sunucu-otoriteli, fiziksel
    -- olarak elde tutulan (ox_inventory'den DOĞRULANAN) bir alet üzerinden
    -- çalışır. Örgüt üyeliği/hiyerarşi ARANMAZ — bu bilinçli olarak
    -- "dışarıdan" (rakip oyuncu/polis baskını) bir eylemdir; Install
    -- (yukarıdaki Levels) ise SADECE örgüt otoritesiyle çalışan savunma
    -- tarafıdır. Süre seviyeyle ARTAR (daha yüksek barikat = daha uzun
    -- kırma süresi) — RNG YOK, tamamen deterministik.
    BreachingTool = {
        ItemName              = 'hydraulic_pry_bar', -- ox_inventory item adi
        MaxRangeMeters        = 3.0,                 -- server-otoriteli mesafe kontrolu
        BaseSeconds           = 12,
        PerLevelSecondsBonus  = 18,
        LevelsBypassedOnBreach = 1,   -- basarili kirma DoorLevel'i bu kadar DUSURUR
        RecheckIntervalMs     = 1000  -- ilerleme her bu araliktan bir DOGRULANIR (mesafe/item/varlik)
    }
}


-- =====================================================================
-- ★★★ KATMAN 7 [T4] FAZ 1: OTONOM DEPO LOJİSTİĞİ VE BÜRO KİLİDİ ★★★
-- Aşağıdaki bloklar TAMAMEN YENİ EKLEMELERDİR. Katman 1-6'nın hiçbir
-- alanı/tablosu/anahtarı DEĞİŞTİRİLMEDİ. Bu bölüm server/bureau.lua'nın
-- (dosya sonuna eklenen [T4] bloğu) ve YENİ server/district_hubs.lua'nın
-- Config sözleşmesidir.
--
-- ★ ÖNEMLİ KAPSAM NOTU: 'matrix_trap_stash' burada AYRI bir SQL tablosu
-- olarak YENİDEN İCAT EDİLMEDİ — trap house'un ortak deposu zaten
-- server/logistics.lua ve server/main.lua'nın matrix_trap_stash_<id>
-- ox_inventory stash'i (RegisterStash/AddItem/RemoveItem) olarak MEVCUT.
-- server/district_hubs.lua bu MEVCUT stash'ten çeker; ikinci bir kalıcılık
-- kaynağı açmak veri tutarsızlığına yol açardı.
-- =====================================================================

-- [T4-1] BÜRO KİLİDİ (Nükleer Abluka) — decryption_confidence/IssueRaid'in
-- (tek trap house, %90 baraj) ÜZERİNE, aynı trap house'un BİRİKMİŞ telsiz
-- ihlali + ele geçirilen ürün saflığından beslenen İKİNCİ, bağımsız bir
-- deterministik eşik. RNG YOK: coefficient = breachRatio*BreachWeight +
-- purityRatio*PurityWeight; her iki oran da [0,1]'e kırpılır.
Config.Bureau.LockdownEvidenceThreshold = 0.75
Config.Bureau.LockdownBreachCeiling     = 12   -- radio_breach_count bu değerde breachRatio 1.0'a doyar
Config.Bureau.LockdownBreachWeight      = 0.70
Config.Bureau.LockdownPurityWeight      = 0.30
-- IssueRaid tetiklendiğinde (bkz. Config.Bureau.PostRaidHeatmapDecay ile
-- AYNI felsefe) learning-core sayaçları da soğur — ayrı bir sabit İCAT
-- EDİLMEZ, mevcut decay katsayısı yeniden kullanılır.

-- [T4 KÖPRÜ] CANLI YAYIN -> radio_breach_count (bkz. server/bureau.lua
-- Matrix.Bureau.RecordLivestreamRadioLeak). LivestreamHeatIncrementPerTick
-- İLE AYNI "gerçek süreden türet" deseni: sabit bir hızı elle YAZMAK
-- yerine, "sürekli + açık hat + çarpanlı yayın TEK BAŞINA LockdownBreach
-- Ceiling'i kaç dakikada doyurur" sorusuna cevap veriliyor, oran
-- buradan türetiliyor. LockdownBreachCeiling'e bağımlı olduğu için bu
-- satırlar ondan SONRA gelir (Lua dosyaları yukarıdan aşağı çalışır).
Config.Bureau.LivestreamRadioBreachMultiplier       = 3.0   -- talep: "X3 çarpanla üssel tırmanma"
Config.Bureau.LivestreamFullBreachCeilingRealMinutes = 10.0 -- sürekli+açık hat+çarpanlı yayın, LockdownBreachCeiling'i kaç dakikada TEK BAŞINA doyurur
Config.Bureau.LivestreamRadioLeakPerTick =
    Config.Bureau.LockdownBreachCeiling /
    (Config.Bureau.LivestreamFullBreachCeilingRealMinutes * 60.0 * Config.Bureau.LivestreamRadioBreachMultiplier)

-- [T4-2] TOPLU SATIŞ HUB'LARI (District Distribution Hubs) — F10 ile
-- kritik kavşaklara atanan, trap house'un ortak deposundan (matrix_trap_
-- stash_<id>) sabit miktarlı/RNG'siz toplu satış döngüsü yürüten düğümler.
-- Ciro, MEVCUT Matrix.CashDecay.Deposit (server/market.lua) kirli-nakit
-- hattına, MEVCUT Config.Market.StreetBasePricePerGram birim fiyatıyla
-- akar — yeni bir ekonomi formülü icat edilmez.
Config.DistrictHubs = {
    MaxPerTrapHouse       = 3,
    SaleBatchGrams        = 10,
    DemandCycleSeconds    = 45
}

-- [T4-3] GELECEKTEKİ OPENAI / CHATGPT ANALİZ KÖPRÜSÜ — server/bureau.lua
-- [T4] tick'ine eklenen PASİF, varsayılan KAPALI danışma katmanı.
-- fallbackToDeterministic=true olduğu sürece (ve HER durumda, çünkü Büro'nun
-- kilit kararı ASLA bu bloğu beklemez) matrix_bureau_learning_core'daki
-- deterministik motor bu köprüden bağımsız çalışmaya devam eder; internet
-- kesilirse veya apiKey boşsa sistem otomatik olarak yerel sıfır-RNG
-- şablonlarına düşer, resmon 0'da kalır (yeni bir thread AÇILMAZ, mevcut
-- [T4] tick'inin periyoduna eklenir).
--
-- ★★★ [SEC] TAŞINDI — Config.AI_Matrix_Brain ARTIK BU DOSYADA DEĞİL ★★★
-- ADLİ BULGU: Bu dosya (shared/config.lua) fxmanifest.lua'da bir
-- `shared_scripts` girdisidir -- yani FiveM bunu SUNUCUYA VE HER BAĞLI
-- CLIENT'A gönderir. apiKey buradayken, herhangi bir oyuncu (bir Lua
-- Executor/hile menüsüyle, hatta yalnızca client kaynak önbelleğini
-- inceleyerek) GERÇEK OpenAI API anahtarını doğrudan okuyabilirdi --
-- pcall/try-catch bunu KAPATAMAZ, çünkü sorun bir çalışma-zamanı hatası
-- değil, sırrın YANLIŞ DOSYADA tanımlanmasıdır. Tanım artık YALNIZCA
-- server_scripts içinde yüklenen server/config_secrets.lua'dadır (bkz.
-- fxmanifest.lua) -- clientlar bu tabloyu HİÇ GÖRMEZ.
-- =====================================================================


-- =====================================================================
-- ★★★ KATMAN 7 FAZ 2: PAKETLEME ODASI, SOKAK SATIŞ DÖNGÜSÜ, REAL-TIME
-- ÜST ARAMA/EL KOYMA, BAGAJ AMELİYATI, PROPAGANDA→DEVŞİRME KÖPRÜSÜ ★★★
-- Aşağıdaki bloklar TAMAMEN YENİ EKLEMELERDİR. Katman 1-7[T4]'ün hiçbir
-- alanı/tablosu/formülü DEĞİŞTİRİLMEDİ — her biri ZATEN VAR OLAN bir
-- motora (ProcessCook/output_purity, EvaluateSale/GourmetMinPurity,
-- Fleet.SeizeVehicle, Forensics.WipeBallisticRecord, Bureau.
-- RecordRadioBreach, CashDecay.Deposit, CompleteDispatch'in guard'lı
-- hook zinciri) bağlanır; yeni bir paralel ekonomi/formül İCAT EDİLMEZ.
-- =====================================================================

-- [F2-1] MUTFAK PAKETLEME ODASI — Matrix.Kitchen.ProcessCook'un ürettiği
-- output_purity/final_weight, dosya sonuna eklenen tek satırlık bir hook
-- ile trap house deposuna (matrix_trap_stash_<id>) fiziksel bir ham madde
-- item'ı (metadata.purity taşır) olarak yansıtılır. Bu oda o kütleyi
-- kesme ajanıyla karıştırıp 10 gramlık, metadata-purity taşıyan kurye
-- paketlerine (Products listesindeki item'lardan biri) böler.
Config.Kitchen.Packaging = {
    RawItem = 'meth_raw_batch',
    Products = {
        { item = 'meth_bag',   label = 'Metamfetamin Torbasi' },
        { item = 'coke_brick', label = 'Kokain Kalibi' }
    },
    PackageGrams                 = 10.0,
    CuttingAgentItem              = 'cutting_agent',
    CuttingAgentGramsPerPackage   = 2.0,
    PurityDilutionPerCutGram      = 0.015,
    MinPurityFloor                = 0.05,
    MaxPackagesPerRun             = 12,
    ProgressMs                    = 6500
}

-- [F2-2] SOKAKTA CANLI NPC "KEŞ" SATIŞ DÖNGÜSÜ — GourmetMinPurity ZATEN
-- Config.Market'te var (Katman 5); burada yalnızca NPC yaklaşma/devşirme
-- parametreleri eklenir. "Keşin addiction_level'ı" burada matrix_customer_
-- pool (gerçek oyuncu kimliği gerektirir) İLE KARIŞTIRILMAZ — ambient NPC
-- müşteriler kalıcı bir citizenid taşımadığından, bağımlılık BİRİKİMİ
-- dealer/bot başına bir "sokak doygunluğu" sayacı (RAM, matrix_dispatches
-- ile AYNI kalıcılık sınıfı) olarak modellenir; eşik aşılınca bir sonraki
-- yaklaşan NPC devşirme adayı olarak işaretlenir.
Config.Market.StreetDealing = {
    DealingModeCommand         = 'torbacilikyap',
    NpcScanIntervalMs          = 1000,
    NpcApproachIntervalMs      = 25000,
    NpcSearchRadius            = 40.0,
    NpcArriveDistance          = 1.6,
    NpcWalkSpeed               = 1.0,
    NpcTimeoutMs               = 60000,
    MinSaleCash                = 60,
    MaxSaleCash                = 140,
    StreetAddictionGainPerSale = 6.0,
    RecruitAddictionThreshold  = 80.0,
    RecruitDistance            = 3.0
}

-- [F2-3] REAL-TIME BÜRO ÜST ARAMASI / ÇEVİRME — main.lua'nın ZATEN VAR
-- OLAN DISPATCH_BUSTED_* dwell mekaniği botları yakalıyor (DEĞİŞTİRİLMEDİ);
-- burada eklenen SADECE o yakalama anındaki kontrabant muayenesi (gerçek
-- oyuncular için ayrı, hafif bir 8m/dwell taraması) ve el koyma zinciridir.
Config.Forensics.Frisk = {
    Radius                       = 8.0,
    DwellMs                      = 6000,
    CooldownMs                   = 120000,
    BurnerPhoneMaxHoldSeconds    = 120,
    WeaponSerialContrabandPrefix = 'BM-',
    EvidenceIndexJumpRatio       = 0.20
}

-- [F2-4] BAGAJ / ENVANTER AMELİYATI — matrix_fleet ZATEN plaka bazlı kayıt
-- tutuyor; ikinci bir "trunk" tablosu İCAT EDİLMEZ. Bagaj, bota kalıcı
-- atanmış aracın plakasına bağlı bir ox_inventory stash'idir.
Config.Logistics.TrunkOps = {
    StashPrefix = 'matrix_bot_trunk_',
    Slots       = 40,
    MaxWeight   = 80000
}

-- [F2-5] PROPAGANDA → DEVŞİRME KALİTE KÖPRÜSÜ — Matrix.Bureau.
-- GetPropagandaMomentum() (DEĞİŞTİRİLMEDİ) burada YENİ bir tüketici kazanır:
-- server/market.lua'nın sokak satış döngüsünde bağımlılık eşiğini aşan bir
-- "keş", server/recruitment.lua Matrix.Recruitment.RecruitStreetNpc ile
-- ANINDA devşirilirken, yeni ajanın taban resilience/snitch_tendency
-- değerleri AYNI momentum ile DOĞRUSAL ölçeklenir — yeni bir psychology
-- alanı İCAT EDİLMEZ, mevcut Matrix.CreateBotRecord şeması (main.lua) aynen
-- kullanılır. Kampanya ne kadar "ısıtıyorsa" sokaktan gelen devşirmeler o
-- kadar güvenilir (yüksek resilience/düşük snitch_tendency) olur. RNG YOK.
Config.Recruitment.MomentumQualityDivisor      = Config.Bureau.PropagandaMaxMomentum
Config.Recruitment.MomentumQualityCeiling      = 1.6
Config.Recruitment.BaseCandidateResilience     = 0.35
Config.Recruitment.BaseCandidateSnitchTendency = 0.35

-- =====================================================================
-- ★★★ SİBER-TAKTİK GÜVENLİK VE SOSYAL OPSEC GENİŞLEMESİ — FAZ 1 ★★★
-- Aşağıdaki iki blok TAMAMEN YENİ EKLEMELERDİR. Yukarıdaki hiçbir alan/
-- tablo/formül DEĞİŞTİRİLMEDİ. "0 RNG, Sıfır Sayı Standardı, Katı
-- Determinizm" felsefesi HARFİYEN korunur — bu bloklarda math.random YOK.
-- =====================================================================

-- ---------------------------------------------------------------------
-- [OPSEC-1/2] GİRDİ-TÜREVLİ POLİS KİŞİLİK GENETİĞİ + RÜŞVET TEKLİFİ
-- (server/bureau.lua Matrix.Bureau.GetPolicePersonality/ProcessBribeOffer).
-- ChecksumOf'un salt'ı (89) KASITLI OLARAK burada YOKTUR — server/
-- blackmarket.lua'nın GenerateScratchedPlate/GenerateWeaponSerial'indeki
-- AYNI konvansiyon: salt her zaman kod içinde bir literal sabittir, Config'e
-- TAŞINMAZ (bir "güvenlik tuzu"nun Config dosyasında açıkça yazılı olması
-- onu bir sabit olmaktan çıkarmaz, yalnızca okunurluğunu azaltır).
-- ---------------------------------------------------------------------
Config.Bureau.BribeSuccessThreshold   = 0.20  -- score >= bu deger -> rusvet kabul
Config.Bureau.BribeGreedWeight        = 0.45  -- memurun ac gozlulugu skoru POZITIF besler
Config.Bureau.BribeIntegrityWeight    = 0.50  -- memurun durustlugu skoru NEGATIF besler
Config.Bureau.BribeCortisolWeight     = 0.20  -- suphelinin panigi skoru NEGATIF besler (eli titriyor, ikna edici degil)
Config.Bureau.BribeReferenceAmount    = 5000.0 -- bu miktarda teklif "1 birim" moneyFactor sayilir
Config.Bureau.BribeMoneyWeight        = 0.35   -- moneyFactor'un skora katkı carpani
Config.Bureau.BribeMoneyFactorCeiling = 2.0    -- moneyFactor'un ust siniri (asiri teklifle skor sinirsiz sismez)

-- ---------------------------------------------------------------------
-- [OPSEC-3] ÇETE SADAKATİ VE İÇ HIRSIZLIK (server/kitchen.lua Matrix.
-- Kitchen.ProcessTrustWithdrawalTheft). Config.Kitchen.TheftWithdrawalThreshold
-- / TheftGramsPerAddictionPoint ZATEN VAR (yukarıda, Config.Kitchen bloğu —
-- ProcessCook'un aktif pişirim hırsızlığı için) — burada YENİ bir eşik/
-- oran İCAT EDİLMEZ, yalnızca bu MEVCUT iki sabitin İKİNCİ bir tetikleyiciye
-- (çete güveni çökmesi) hangi güven tavanında bağlanacağını ve buna eşlik
-- eden sadakat cezasını tanımlayan sabitler eklenir.
-- ---------------------------------------------------------------------
Config.Kitchen.TrustWithdrawalTheftTrustCeiling = 0.35   -- matrix_supplier_trust ortalaması bu esigin ALTINDAYSA mekanizma silahlanir
Config.Kitchen.TrustWithdrawalLoyaltyPenalty    = 0.10   -- her tetiklenmede psychology.loyalty_base bu kadar duser
Config.Kitchen.GangTrustRefreshIntervalMs       = 60000  -- cete-geneli guven ortalamasi bu periyotta yeniden hesaplanir (RAM onbellek)

-- ---------------------------------------------------------------------
-- [OPSEC-4a] FEAR COEFFICIENT — İnfaz geçmişine dayalı psikolojik direnç
-- (server/bureau.lua Matrix.Bureau.GetFearCoefficient/GetEffectiveSnitchThreshold).
-- matrix_raid_log.outcome='eliminated' ZATEN VAR OLAN bir enum/kolondur.
-- ---------------------------------------------------------------------
Config.Bureau.FearCoefficientEliminationCeiling = 20      -- bu kadar 'eliminated' infazda FearCoefficient 1.0'a doyar
Config.Bureau.FearCoefficientRefreshIntervalMs  = 120000  -- RAM onbellek bu periyotta matrix_raid_log'dan yenilenir
Config.Bureau.FearCoefficientSnitchCeiling      = 0.95    -- efektif SnitchThreshold ASLA bu tavani gecmez

-- ---------------------------------------------------------------------
-- [OPSEC-4b] KANIT ODASI SABOTAJI — server/forensics.lua Matrix.Forensics.
-- TamperEvidenceLockup, server/bureau.lua Matrix.Bureau.ProcessBribeOffer'in
-- (DEĞİŞTİRİLMEDİ, yalnızca opsiyonel bir 4. caseId parametresi eklendi)
-- BAŞARILI sonucuyla konuşur.
-- ---------------------------------------------------------------------
Config.Forensics.TamperGreedThreshold = 0.60  -- personality.greed bu esigin ALTINDAYSA memur kanit odasina dokunmaz (rusvet basarili olsa bile)

-- ---------------------------------------------------------------------
-- [OPSEC-5] FİZİKSEL VE SİBER DELİL İMHA (FORENSIC SANITIZATION) —
-- server/forensics.lua Matrix.Forensics.CollectShells/HackCCTVNetwork.
-- Item adı ZATEN VAR OLAN Config.BlackMarket/Config.Kitchen.Packaging
-- konvansiyonuyla AYNI: ox_inventory'nin kendi items.lua'sında bu isimle
-- KAYITLI olması gerekir (bu resource item TANIMLAMAZ, yalnızca referans
-- eder — mevcut meth_bag/coke_brick/burner_phone İLE AYNI disiplin).
-- Skill kapısı YENİ bir sütun İCAT ETMEZ: matrix_bots.psychology.
-- skill_logistics (fiziksel/kurye) ve skill_cyber (dijital) ZATEN VARDIR.
-- ---------------------------------------------------------------------
-- ---------------------------------------------------------------------
-- [KAMERA VERI TEMIZLIGI] /kameralogutemizle -- oyuncunun kendi dna_id'sine
-- ait, son 30 dakikaya ait TUM matrix_cctv_logs satirlarini (mobese
-- gecis + kiyafet kombinasyon izleri) kalici olarak siler. Router kutusuna
-- (Config.TrapHouseInterior.Shell.RouterPos) fiziksel yakinlik gerektirir --
-- Matrix.Forensics.HackCCTVNetwork (zone-bazli, MEVCUT) ILE AYNI tabloyu
-- okur/yazar, YENİ bir tablo İCAT EDİLMEZ.
-- ---------------------------------------------------------------------
Config.Forensics.RouterSanitization = {
    Radius          = 2.0,
    WindowMinutes   = 30
}

-- ---------------------------------------------------------------------
-- [ADLİ RPG] /davaac + /davasorgula -- çift fazlı mahkeme ifade zinciri
-- (server/bureau.lua). Mahkumiyet Skoru, Propaganda momentumuyla AYNI
-- geometrik tırmanma şekli (a*x+b, tavan 1.0) kullanır -- yeni bir
-- matematiksel biçim İCAT EDİLMEZ, yalnızca bu mekaniğe özgü katsayılar
-- eklenir.
-- ---------------------------------------------------------------------
Config.Bureau.TrialConvictionGeometricFactor = 1.5
Config.Bureau.TrialConvictionIncrement       = 0.15

-- ---------------------------------------------------------------------
-- [KOR NOKTA] KOMA MODU -- bot.biology.withdrawal_index (ZATEN VAR OLAN
-- alan, YENİ bir "under_influence" alanı İCAT EDİLMEZ) >= 1.0 olduğunda
-- status='comatose' kilitlenir; bu süre boyunca müdahale edilmezse
-- 'deceased' arşivine düşer.
-- ---------------------------------------------------------------------
Config.Kitchen.ComaToDeceasedRealHours = 2

Config.Forensics.ShellCasingEvidenceItem          = 'shell_casing_evidence'
Config.Forensics.ShellCollectionRadiusMeters      = 3.0
Config.Forensics.ShellCollectionBaseDurationMs    = 8000  -- skill_logistics=0 iken sure
Config.Forensics.ShellCollectionSkillDurationFloorMs = 2000 -- skill_logistics=1.0 iken bile ALTINA inmez
Config.Forensics.ShellCollectionBaseCortisolSpike = 0.10  -- skill_logistics=0 iken kortizol sicramasi; skill=1.0 iken TAMAMEN engellenir

Config.Forensics.CCTVHackBaseDurationMs           = 12000 -- skill_cyber=0 iken sure
Config.Forensics.CCTVHackSkillDurationFloorMs     = 3000  -- skill_cyber=1.0 iken bile ALTINA inmez
Config.Forensics.CCTVHackBaseCortisolSpike        = 0.15  -- skill_cyber=0 iken kortizol sicramasi; skill=1.0 iken TAMAMEN engellenir

-- =====================================================================
-- OTOMASYONLU REGRESYON ÇEKİRDEĞİ (server/matrix_diagnostics.lua)
-- Hızlı katman (config sınırları + Matrix.* kanca varlığı + salt-okunur
-- DB şeması) onServerResourceStart'ta OTOMATİK, /matrix_run_diagnostics
-- ile MANUEL çalışır — milisaniyeler içinde biter, SIFIR yan etki.
-- DeepModeCommandArg YALNIZCA elle '/matrix_run_diagnostics deep' ile
-- gerçek bir kullan-at test botu doğurup İki-Fazlı Çıkış Köprüsü'nü
-- uçtan uca kanıtlar, ardından TAMAMEN geri alır — ASLA otomatik değildir
-- (bkz. dosya başı KAPSAM KARARI yorumu).
-- =====================================================================
Config.Diagnostics = {
    RunOnResourceStart = true,
    DeepModeCommandArg = 'deep',

    -- =====================================================================
    -- ★ KATMAN 21-22: ACIMASIZ DIAGNOSTICS LABORATUVARI ENJEKSIYONU
    -- Eski KAPSAM KARARI (dosya basi yorumu: "otomatik acilis HER ZAMAN
    -- hizli katman, ASLA deep") bu GM emriyle BILINCLI olarak GECERSIZ
    -- KILINDI -- onServerResourceStart ARTIK HER ZAMAN deep=true calistirir
    -- VE SimulationChecks testlerinden biri basarisiz olursa (assert
    -- firlatirsa) AbortResourceOnSimulationFailure=true iken StopResource
    -- ile kaynak acilisini DURDURUR.
    --
    -- ★ [EMNİYET KİLİDİ] KATMAN 22 GÜNCELLEMESİ (GM emriyle BİLİNÇLİ
    -- olarak false'a çekildi): sunucu açılışı artık simülasyon
    -- başarısızlığında StopResource ile FİZİKSEL OLARAK DURDURULMAZ --
    -- her SimulationChecks testi (Hit-and-Run drive-by, medikal/Büro 2x
    -- sızıntı formülü, bot yara hassasiyeti, eşzamanlılık stresi, Hayalet
    -- Doktor palindromu dahil) yine EKSİKSİZ ve ACIMASIZCA çalışır ve
    -- rapora düşer (konsolda [%d HATA] olarak veya Matrix.Diagnostics.
    -- GetLastReport()/composer_intro bültenine sealed=false olarak
    -- yansır) -- yalnızca kaynağın kendi açılışını felç ETMEZ. true'ya
    -- geri çekmek isteyen bir GM, açılıştan ÖNCE en az bir kez elle
    -- '/matrix_run_diagnostics deep' ile testi doğrulamalıdır.
    --
    -- ★ TEK-SEFERLIK KURULUM GEREKSINIMI (bunlar YOKSA testler basarisiz
    -- RAPORLANIR -- artik kaynagi DURDURMAZ, yalnizca konsolda gorunur):
    --   1) sql/matrix_financial_core.sql calistirilmis olmali (matrix_
    --      diagnostics_stress_log tablosu icin).
    --   2) StressTestItem asagida, sunucunuzun GERCEK ox_inventory
    --      items tablosunda kayitli bir item adiyla DEGISTIRILMELI --
    --      varsayilan deger bir YER TUTUCUDUR, sizin item listenizde
    --      YOKSA test HER ACILISTA basarisiz olur.
    --   3) Acilista guvenmeden ONCE en az bir kez elle
    --      '/matrix_run_diagnostics deep' ile test edilmesi ONERILIR.
    -- =====================================================================
    AbortResourceOnSimulationFailure = false,

    StressTestConcurrency = 100,
    StressTestStashId     = 'matrix_diagnostics_stress_stash',
    -- ★ YER TUTUCU: kendi ox_inventory item listenizdeki GERCEK bir item
    -- adiyla degistirin (bkz. yukaridaki KURULUM notu).
    StressTestItem        = 'matrix_diagnostic_token',
    StressTestTimeoutMs   = 15000,

    PhantomPalindromeEpochCount = 10000
}

-- =====================================================================
-- BESTECİNİN İMZASI (client/composer_intro.lua) — oyuncu spawn olduğunda,
-- kontrolü eline almadan ÖNCE gösterilen monokrom taktik bülten + opsiyonel
-- Bach "Yengeç Kanonu" (BWV 1079) ses katmanı.
--
-- ★ SES DOSYALARI BU REPODA YOK: gerçek bir kayıt/render telif/lisans
-- gerektirir ve bu ortamda ses sentezleme/ikili indirme aracı YOKTUR —
-- guideVoiceFile/counterpointVoiceFile'ı (kendi lisanslı/PD .ogg
-- dosyalarınızla) resource kökünde 'sounds/' altına SİZİN koymanız
-- gerekir. Dosyalar yoksa xsound çağrısı pcall içinde sessizce başarısız
-- olur — script ÇÖKMEZ, yalnızca ses çalmaz; monokrom bülten + zamanlayıcı
-- ETKİLENMEDEN çalışmaya devam eder.
--
-- introDurationMs SABİTTİR: ses/xsound ne yaparsa yapsın (susarsa, dosya
-- eksikse, xsound hiç yüklü değilse) oyuncunun kontrolü bu sürenin
-- SONUNDA KOŞULSUZ geri verilir — bir ses hatasının oyuncuyu kalıcı
-- kara ekranda kilitlemesi YAPISAL OLARAK imkansızdır.
-- =====================================================================
Config.ComposerSignature = {
    playAudioOnLoad        = true,
    volume                 = 0.45,
    guideVoiceFile         = 'sounds/crab_canon_guide.ogg',
    counterpointVoiceFile  = 'sounds/crab_canon_counterpoint.ogg',
    introDurationMs        = 8000, -- toplam sabit sure -- HER ZAMAN bu sürede biter
    counterpointLeadMs     = 2500, -- introDurationMs'in SON bu kadarlik dilimi (sadece rapor 'sealed' ise)
    bulletinLineIntervalMs = 220,  -- taktik bulten satirlarinin akma hizi
    fadeOutMs              = 600   -- introDurationMs'in SON bu kadarlik dilimi: alfa 235'ten 0'a lineer iner
}

-- =====================================================================
-- ★★★ YERALTI FİZİKSEL SAVAŞ + KARA TIP + SIZDIRILAN İSTİHBARAT
-- GENİŞLEMESİ (7 katmanlı görev seti) ★★★
-- Aşağıdaki bloklar TAMAMEN YENİ EKLEMELERDİR. Yukarıdaki hiçbir alan/
-- tablo/formül DEĞİŞTİRİLMEDİ.
-- =====================================================================

-- ---------------------------------------------------------------------
-- [KATMAN 1] FİZİKSEL MUHAFIZ/KURYE BOTLARI + ARAÇ KOMUTU
-- ---------------------------------------------------------------------
Config.Mercenary = {
    EnablePhysicalFollowers = true,

    MaxFollowers        = 2,
    PedModel             = 'g_m_y_mexgoon_02',
    SummonRadius         = 3.0,
    FollowDistance       = 3.0,
    -- Bu mesafenin ÜZERİNDE (oyuncudan koptuysa) takipçi ışınlanarak
    -- yeniden konumlanır -- sonsuz NavMesh kilitlenmesini önler.
    TeleportDistance      = 60.0,
    VehicleEnterRadius    = 10.0,
    CombatAggroRadius     = 35.0,
    -- Performans: mesafe/araç kontrolleri her frame DEĞİL, bu aralıkta
    -- çalışan hafif bir önbellek üzerinden yürütülür.
    CheckIntervalMs       = 1500,
    SummonCooldownMs      = 5000
}

-- ---------------------------------------------------------------------
-- [KATMAN 2] YASAL HASTANE (EMS) ADLİ SORGU / TIBBİ SIZINTI DÖNGÜSÜ
-- Karakter Wipe kararı, ZATEN VAR OLAN /davaac + /davasorgula mahkeme
-- ifade zinciriyle (server/bureau.lua Matrix.Bureau.ExecuteVerdict) AYNI
-- nihai infaz fonksiyonunu paylaşır -- ikinci bir "wipe" yolu İCAT EDİLMEZ.
-- ---------------------------------------------------------------------
Config.Hospital = {
    Enabled           = true,
    TreatmentCommand  = 'tedaviol',
    CheckInPoints = {
        { id = 1, label = 'Pillbox Hill Tibbi Merkezi', coords = vector3(298.72, -584.77, 43.25), radius = 8.0 }
    },
    -- Tedavi aninda Buro'ya ANINDA sizan tibbi rapor: matrix_bureau_intensity
    -- ConVar'ini bu carpanla aninda katlar (bkz. server/wound_system.lua).
    LeakIntensityMultiplier      = 2.0,
    -- Yatak-basi sorgu: yalan soylemek MEVCUT TrialConviction geometrik
    -- bicimiyle AYNI sekilde tirmanir, fakat gorevin istedigi sabit %40
    -- artisla (bkz. Config.Bureau.TrialConvictionIncrement'in AKSINE, bu
    -- akis kendi sabit adimini kullanir -- yatak basi sorgu bir memurun
    -- yonettigi resmi dava DEGIL, EMS/Buro sizintisi kaynakli otonom bir
    -- mini-dava oldugu icin ayri bir sabit tutulur).
    ConvictionWeightLiePenalty   = 0.40,
    ConvictionWipeThreshold      = 1.0
}

-- ---------------------------------------------------------------------
-- [KATMAN 3/4] ARMA-TARZI BÖLGESEL BOT YARALANMA + KALICI SAKATLIK
-- ---------------------------------------------------------------------
Config.BotWounds = {
    -- Deterministik bölge seçimi (RNG YOK): ChecksumOf(botId#hasarSayaci)
    -- bu listenin indeksine kirpilir -- bkz. server/wound_system.lua.
    ZoneOrder                = { 'leg', 'head', 'arm', 'torso' },

    LegSpeedPenalty          = 0.60,  -- -%60 hareket hizi
    HeadDetectionRangeCap    = 15.0,  -- metre
    ArmAccuracyPenalty       = 0.50,  -- isabet dusuklugu (skill_chemistry/cyber etkin degerine uygulanir)
    ArmPerfectCasingQuality  = 1.0,   -- kusursuz kovan kalitesi
    TorsoCortisolLock        = 0.90,
    TorsoAuditAnomalyMultiplier = 3.0, -- +%300
    TorsoStashTheftGrams     = 10.0,

    -- Kalıcı sakatlık eşiği (Katman 4): arm_injury/leg_injury bu değere
    -- ULAŞTIĞINDA permanently_crippled=1 olur -- Trap House yataklarıyla
    -- ARTIK ASLA iyileşmez.
    CripplingThreshold        = 1.0,

    -- Karaborsa Ameliyatı (Trap House tedavisi): bu süre boyunca bot
    -- dispatch kabul edemez, sonunda (yalnızca KALICI OLMAYAN) uzuv
    -- hasarları sıfırlanır.
    TrapHouseTreatmentHours    = 12
}

Config.PermanentCrippling = {
    ArmCraftingShootingPenalty = 0.90, -- -%90 (kalici)
    LegMovementPenalty          = 0.90 -- -%90 (kalici)
}

-- ---------------------------------------------------------------------
-- [KATMAN 4] HAYALET CERRAH (PHANTOM SURGEON) — 5 gizli yeraltı doktor
-- koordinatı arasında, epoch-saat damgası sağlama toplamından türetilen
-- (RNG YOK) 6 saatlik deterministik rotasyon.
-- ---------------------------------------------------------------------
Config.PhantomDoctor = {
    Coords = {
        vector3(-225.9, -1636.2, 33.7),
        vector3(963.4, -155.9, 74.2),
        vector3(-1596.8, -570.9, 108.8),
        vector3(1224.6, -3212.4, 5.9),
        vector3(-3172.8, 1085.6, 20.6)
    },
    RotationIntervalHours = 6,
    SurgeryPrice          = 60000.0,
    SurgeryHours           = 24,
    -- Ameliyat sirasinda klinikte uretilen siber sizinti (en yakin trap
    -- house'un cyber_leak_intensity'sine, MEVCUT Bureau formulune AYNI
    -- birimle eklenir).
    ClinicCyberLeakIntensity = 0.30,
    -- Buro yogunlugu (matrix_bureau_intensity ConVar'i) bu esigi
    -- GECERSE, ameliyat sirasinda federal bir baskin (MEVCUT
    -- Matrix.Bureau.IssueRaid'in en yakin trap house'a) tetiklenir.
    FederalStingIntensityThreshold = 1.5
}

-- ---------------------------------------------------------------------
-- [KATMAN 5/6] DETERMİNİSTİK SATICI DAĞILIMI + PARÇALANMIŞ İSTİHBARAT
-- ---------------------------------------------------------------------
Config.VendorPool = {
    SpawnCount            = 5,
    PedModel               = 'g_m_y_streetdealer_01',
    Scenario                = 'WORLD_HUMAN_STAND_IMPATIENT',
    SpreadRadiusMeters     = 900.0, -- Los Santos merkezinden deterministik dagilim yaricapi

    -- Dusman cete tarafindan finanse edilme esikleri (gang_loyalty,
    -- oyuncunun kendi cetesine sadakat [0,1] olcegi -- DUSUK deger =
    -- dusman finansmanli).
    EnemyLoyaltyRefuseThreshold    = 0.25, -- bunun ALTINDA satis TAMAMEN reddedilir
    EnemyLoyaltySabotageThreshold  = 0.45, -- bunun ALTINDA satilan silahlara gizli jam_accumulator ekiliir
    SabotageJamAccumulatorSeed     = 0.55,

    InterrogateCommand      = 'zorkullan',
    InterrogateRadius       = 5.0,
    -- fear_index vs "propaganda momentumu" (Matrix.Bureau.GetPropagandaMomentum,
    -- ZATEN VAR OLAN) esik farki -- gecilirse allegiance flip olur.
    InterrogateMomentumWeight = 0.20,
    IntelLeakOnFlip           = 0.50,

    ProsecutorBribeCommand      = 'savcitasaboteet',
    ProsecutorGuiltReductionPct = 0.20,
    ProsecutorCooldownMs         = 300000
}

Config.FragmentedIntel = {
    GainPerAction        = 0.10, -- torbacilik/rusvet/dinleme basina
    DiscoveredThreshold   = 1.0,
    -- Karsi-istihbarat vetting: oyuncunun MEVCUT siber-isi metrigi
    -- (server/bureau.lua trap house cyber_leak_intensity / CyberLeakMaxIntensity
    -- orani -- ZATEN VAR OLAN heatmap, ikinci bir "heat" alani ICAT EDILMEZ)
    -- bu esigi GECERSE satici/doktor islemi reddeder ve kontagi kilitler.
    VettingHeatThreshold  = 0.80,

    -- Sting: bir kurye botu cevrilince (InspectBustedBot/mole flag) o
    -- kontak compromised=1 olur; oyuncu orada islem yapmaya DEVAM ederse
    -- front company'nin denetim-uyarisi bu üstel oranla sicrar.
    StingAuditExponentialMultiplier = 1.5 -- +%50
}

-- ---------------------------------------------------------------------
-- [KATMAN 7] DÜŞMAN ÇETE MAHALLELERİ + SIFIR-TOPLAM YAĞMA + BALİSTİK
-- SUÇ YÜKLEME (FRAME-UP)
-- ---------------------------------------------------------------------
Config.GangHoods = {
    Hoods = {
        { id = 1, label = 'Vagos Bolgesi - El Burro Heights',  coords = vector3(365.4, -2036.9, 21.0) },
        { id = 2, label = 'Ballas Bolgesi - Strawberry',       coords = vector3(-99.7, -1655.9, 32.0) },
        { id = 3, label = 'Marabunta Bolgesi - La Puerta',     coords = vector3(-767.8, -1508.6, 4.9) }
    },

    LootWindowSeconds            = 120,
    PatrolCompoundTickSeconds    = 10,
    PatrolCompoundFactor         = 1.25,  -- her tik +%25 bilesik

    DestroyLootCommand           = 'depoyuyak',

    -- Balistik Suc Yukleme: enemy'nin 'unknown suspect' ile arsivlenmis
    -- silahlari yagmalanirken bu meta-etiketi alir; /namludegistir
    -- KOSULMADAN yakalanirsa (Frisk, MEVCUT Config.Forensics.Frisk)
    -- tasiyicinin AKTIF davasina (MEVCUT /davaac -> matrix_trial_records)
    -- %100 Mahkumiyet Skoru olarak islenir.
    FrameUpMetadataTag           = '[ORIGIN: BLOODY LOOT]',

    -- ★ OPENAI DÜŞMAN ÇETE ALDATMA (DARKCHAT DEZENFORMASYON KÖPRÜSÜ)
    -- Mevcut TEK OpenAI entegrasyonu (server/bureau.lua Config.AI_Matrix_Brain,
    -- server-only, bkz. server/config_secrets.lua) burada TEKRAR
    -- KULLANILIR -- ikinci bir API anahtari/entegrasyonu ICAT EDILMEZ.
    -- AI kapali/basarisizsa deterministik anahtar-kelime skoru fallback
    -- olarak calisir (asagidaki BaseCredibilityKeywords) -- Buro'nun
    -- kendi karar mekanizmalari gibi bu da ASLA AI'a bagimli KALMAZ.
    Deception = {
        Enabled                    = true,
        MessageMaxLength           = 280,
        CooldownSeconds            = 120,  -- ayni oyuncu + ayni mahalle icin
        BaseCredibilityKeywords    = {
            'baskin', 'tuzak', 'ihbar', 'pusu', 'polis', 'itiraf', 'yakalandik', 'firar', 'rehin', 'ajan'
        },
        BaseCredibilityThreshold   = 0.34,
        AggressionDecayRate        = 0.6,  -- math.exp(-rate * (skor-esik) * 10) ile PatrolMultiplier'a uygulanir
        MinAggressionMultiplier    = 1.0
    }
}

-- ★ SİVİL MUHBİR / MASKE ENTEGRASYONU
-- GTA V'de "GetPedDensityMultiplier" gibi bir GETTER native'i YOKTUR
-- (server/logistics.lua'daki GetVehicleDensityMultiplier yorumuyla AYNI
-- sinirlama) -- gercek, agda var olan sivil (ped) sayisini GetPeds() ile
-- orneklem yaricapinda sayariz. Maske kontrolu GTA V'in gercek prop
-- sistemi uzerinden yapilir: slot 1 = "Mask" prop kategorisi;
-- GetPedPropIndex(ped, 1) == -1 ise maske YOK demektir.
Config.Witness = {
    SampleRadius                    = 30.0,
    MaskPropSlot                    = 1,
    BureauIntensitySpikeMultiplier  = 2.0,  -- matrix_bureau_intensity ConVar'i (bureau.lua/logistics.lua/wound_system.lua ILE AYNI ConVar)
    HitSquadDispatchOnMasked        = true
}

-- =====================================================================
-- ★★★ KATMAN 8 CRITICAL: SEC-7 + COMINT + EVIDENCE DECAY SABİTLERİ ★★★
-- Bu blok YENİ EKLEMEDİR. Yukarıdaki hiçbir alan DEĞİŞTİRİLMEDİ.
-- =====================================================================

-- [FAZ 1] SEC-7 Dinamik Parola
Config.Bureau.OpsecPassphraseGeometricStep = 0.08    -- Yanlış parola başına üssel katsayı
Config.Bureau.OpsecPassphraseMinLength     = 4       -- Sanitizasyon sınırı
Config.Bureau.OpsecPassphraseMaxLength     = 64      -- VARCHAR(64) ile birebir
Config.Bureau.OpsecDefaultPassphrase       = 'CORE_MATRIX_INIT_PASS'

-- [FAZ 1] Need-to-Know Telemetri Maskesi
Config.Bureau.TelemetryNeedToKnowThreshold = 0.75    -- LockdownEvidenceThreshold ile aynı
-- (Zaten Config.Bureau.LockdownEvidenceThreshold = 0.75 mevcut — bu satır
-- yalnızca OKUNURLUK için; kod ikisini EŞDEĞER kabul eder.)

-- [FAZ 2] COMINT Radyo Spektrum Akümülatörü
Config.Bureau.RadioAccumGainPerTick        = 0.02    -- Bas-konuş süresince tick başına birikim
Config.Bureau.RadioAccumMaxGain            = 1.0     -- Akümülatör tavan (‰90 = 0.9 için önerilen)
Config.Bureau.RadioStaticStep              = 0.05    -- JamStrength artım adımı
Config.Bureau.RadioBreachGainPerTick       = 0.01    -- BreachAccum → AdvanceDecryption dönüşümü
Config.Bureau.RadioStaticMaxIntensity      = 0.90    -- "‰90 maks şiddet" — ApplyStatic üst sınırı
Config.Bureau.RadioDecayPerTick            = 0.005   -- Sessizlik altında saniye başına azalım

-- [FAZ 3] Adli Kanıt Asimptotik Erime
Config.Forensics.EvidenceDecayTickMs               = 60 * 60 * 1000  -- 1 saat
Config.Forensics.EvidenceDecayRate                 = 0.002           -- exp(-0.002 * elapsed_minutes)
Config.Forensics.EvidenceDecayRetentionThreshold   = 0.02            -- Bu eşiğin altındaki satırlar otonom silinir

-- [FAZ 4] Uzaktan İmha Panik Butonu
Config.Bureau.RemoteWipeCooldownMs         = 30000   -- 30 sn spam koruması
Config.Bureau.RemoteWipeConfirmTimeoutMs   = 15000   -- Token TTL

return Config