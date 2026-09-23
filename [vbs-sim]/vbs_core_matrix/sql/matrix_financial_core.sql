-- =====================================================================
-- ★★★ MATRIX FINANCIAL CORE — TEK DOSYA KONSOLIDASYON MUHURU ★★★
-- sql/matrix_financial_core.sql
--
-- Bu dosya, projenin ONCEDEN 9 ayri dosyaya dagilmis TUM sema gecmisinin
-- BIRLESTIRILMIS HALIDIR -- artik sql/ klasorunde BASKA HICBIR .sql dosyasi
-- YOKTUR, tek calistirma adimi budur:
--   1) matrix.sql              (temel sema, Katman 1-5)
--   2) layer5_ultimate.sql     (Katman 5 Ultimate -- Co-Op/SIGINT/COMINT)
--   3) layer6_trap_house.sql   (Katman 6 -- Trap House ic mekan/tezgah)
--   4) layer7_faz1.sql         (Katman 7 [T4] Faz 1 -- Buro Kilidi + Hub'lar)
--   5) layer7_faz3.sql         (Katman 7 [T4] Faz 3 -- loyalty_base)
--   6) matrix_security_hardening.sql (SEC-2 offline iade defteri)
--   7) matrix_cctv_network.sql (mobese agi -- matrix_cctv_logs)
--   8) layer_regression_schema.sql  (9 geri-enjekte DB kontrolu + Adli RPG/
--      Kor Nokta semasi -- /davaac, /telefonuyoket, Koma Modu, FragmentTerritory)
--   9) layer_splinter_cells.sql (Otonom Alt Hucre Bolunmesi -- Splinter Cells)
-- Ilk 7 bolum, hangi eski dosyadan geldigini gosteren bir "★ KAYNAK"
-- basligiyla ayrilmistir; o basliklarin ALTINDAKI icerik o dosyalarin
-- ORIJINAL halinden TEK BIR SATIR BILE ATLANMADAN/DEGISTIRILMEDEN
-- birebir tasindi. Son iki bolum bu oturumda eklenen YENI migration'lardir
-- (asagida da "★ KAYNAK" basligiyla ayri ayri isaretlenmistir).
--
-- ★ BILINCLI DISLAMA NOTU: bu dosyaya elle yapistirilan bir onceki taslakta
-- ("FAZ 2/3/KATMAN14 KONSOLIDASYON DUZELTME") matrix_purchase_logs/
-- matrix_trial_records/matrix_gang_learning_core/matrix_legal_plate_evidence
-- icin BU dosyadaki (8. bolum) semadan FARKLI kolon adlari/tipleri ve
-- RecordAuditableInvoice/ProcessLegalPlateALPR/GetEvidenceLinesForDefendant
-- gibi BU DALDA (bureau.lua) MEVCUT OLMAYAN fonksiyonlara atif iceriyordu.
-- Bu dalin GERCEKTE calisan kodu (server/bureau.lua Matrix.Bureau.OpenTrial/
-- RecordTrialResponse/ExecuteVerdict/SabotagePhoneLine/RunHourlyFinancialAudit,
-- server/district_hubs.lua FragmentTerritory) 8. bolumdeki semaya yazar/okur
-- -- bu yuzden o alternatif taslak BURAYA DAHIL EDILMEDI (sessizce
-- calisan kodu kirmamak icin). O taslak ayri, daha genis bir "Paravan
-- Isletme/Mali Denetim" ozelligiyse, ayri bir migration + karsilik gelen
-- Lua degisiklikleriyle BIRLIKTE getirilmelidir.
--
-- CALISTIRMA: bu TEK dosyayi, dogrudan (bastan sona) sirayla import edin.
-- Ayri ayri calistirma adimi ARTIK YOKTUR.
-- =====================================================================



-- =======================================================================
-- ★ KAYNAK: sql/matrix.sql (orijinal icerik, birebir asagida, hicbir satir atlanmadi)
-- =======================================================================

-- =====================================================================
-- MATRIX SCHEMA v3 — Katman 5 (Qbox Co-op Kartel Hiyerarşisi & Piyasa)
-- Katman 1-2-3-4-5 Birlesik Motor - Kalici Veri Tabani
--
-- ★ DEĞİŞİKLİK NOTU (v2 → v3):
--   (1) KATMAN 5 tabloları eklendi: matrix_hierarchy (co-op rütbe),
--       matrix_market_zones (bölgesel piyasa fiyat çarpanı), matrix_cash_decay
--       (kirlenen nakit sönümlenmesi). v2'nin "ON UPDATE CURRENT_TIMESTAMP
--       KULLANMA" politikası aynen sürdürüldü — `updated_at` uygulama
--       katmanında (market.lua) her UPDATE/UPSERT'te explicit NOW() ile
--       yazılır.
--   (2) matrix_cash_decay, matrix_trap_houses'a FK ile bağlı olduğundan
--       FOREIGN_KEY_CHECKS=0 sarması İÇİNE, diğer Katman 1-4 tablolarından
--       SONRA eklendi (parent zaten mevcut).
--   (3) Katman 1-4 tabloları/yorumları HİÇ DEĞİŞMEDİ (aşağıdaki v1→v2 notu
--       olduğu gibi korunmuştur).
--
-- ★ DEĞİŞİKLİK NOTU (v1 → v2):
--   (1) Tüm `DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP`
--       kombinasyonları KALDIRILDI. Neden: bazı MariaDB/MySQL derlemeleri
--       bu kombinasyonu kolon-tanımı parser'ında reddediyor ve CREATE
--       TABLE sessizce başarısız oluyordu → matrix_fleet ve
--       matrix_supplier_trust gibi Katman 4 tabloları hiç yaratılmıyordu.
--       Uygulama katmanı `updated_at = NOW()`'u her UPDATE/UPSERT
--       sorgusunda explicit gönderiyor (main.lua BOT_UPSERT_TAIL,
--       logistics.lua FlushDirtyFleet / FlushDirtySupplierTrust), bu
--       yüzden DB-seviyesi auto-update KAYBI YOKTUR.
--
--   (2) Tüm tablolar parent→child sırasına göre yeniden dizildi:
--       matrix_trap_houses  →  pattern_log/bureau_intel/raid_log/...
--       matrix_ballistic_weapons  →  matrix_forensic_evidence
--       matrix_bots  →  matrix_snitch_events
--
--   (3) `SET FOREIGN_KEY_CHECKS = 0` sarması eklendi: mevcut bir şemayı
--       yeniden import ederken FK ihlali yaşanmaz. Sonunda tekrar 1'e
--       döndürülür.
--
--   (4) Tüm kolon tipleri FULL MySQL 5.7 / MariaDB 10.x uyumludur.
--       DECIMAL ve ENUM sınırları korunmuştur.
--
-- ★ ADLİ KAYIT POLİTİKASI (DOKUNULMADI):
--   matrix_forensic_evidence, matrix_ballistic_weapons, matrix_touch_log,
--   matrix_alpr_hits, matrix_vehicle_seizures, matrix_dead_drop_events,
--   matrix_raid_log, matrix_livestream_events — asla silinmez, yalnızca
--   eklenir. Uygulama katmanı DELETE yalnızca matrix_bots ve matrix_fleet
--   için çağırır (hard-delete politika).
--
-- ★ KATMAN 8 NOTU (Hard-Wipe / E_total): İstek metninde tanımlanan "Ortak
--   Risk Kontratı" (çete-çapında kümülatif kanıt matrisi tetiklendiğinde
--   TÜM oyuncu verisinin aynı saniyede DROP edilmesi) BİLİNÇLİ OLARAK bu
--   şemaya EKLENMEDİ. Eşik/kapsam/hangi tabloların etkileneceği tanımsız;
--   tanımsız bir toplu-silme mekanizmasını tahminle şemaya kilitlemek,
--   yanlış bir tasarımı geri alınması güç hale getirir. Katman 8 netleşince
--   ayrı bir migration olarak eklenmelidir.
-- =====================================================================


SET FOREIGN_KEY_CHECKS = 0;


-- =====================================================================
-- KATMAN 1: CORE MATRIX  (Kalıcı Kimlik ve Biyoloji)
-- =====================================================================


-- ---------------------------------------------------------------------
-- Bot / Dealer Kalıcı Kimlik ve Biyoloji Profili
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_bots` (
    `id`                         INT          NOT NULL,
    `dna_id`                     VARCHAR(64)  NOT NULL,
    `name`                       VARCHAR(100) NOT NULL,
    `role`                       VARCHAR(32)  NOT NULL DEFAULT 'runner',
    `status`                     ENUM('active','burned','deceased','retired') NOT NULL DEFAULT 'active',
    `fear_factor`                FLOAT        NOT NULL DEFAULT 0.0,
    `resilience`                 FLOAT        NOT NULL DEFAULT 0.5,
    `snitch_tendency`            FLOAT        NOT NULL DEFAULT 0.0,
    `economic_pressure`          FLOAT        NOT NULL DEFAULT 0.0,
    `cognitive_shifter`          FLOAT        NOT NULL DEFAULT 0.5,
    `skill_chemistry`            FLOAT        NOT NULL DEFAULT 0.3,
    `skill_cyber`                FLOAT        NOT NULL DEFAULT 0.0,
    `skill_logistics`            FLOAT        NOT NULL DEFAULT 0.0,
    `fatigue_level`              FLOAT        NOT NULL DEFAULT 0.0,
    `cortisol_level`             FLOAT        NOT NULL DEFAULT 0.0,
    `withdrawal_index`           FLOAT        NOT NULL DEFAULT 0.0,
    `addiction_level`            FLOAT        NOT NULL DEFAULT 0.0,
    `base_cortisol_recovery_rate` FLOAT       NOT NULL DEFAULT 0.05,
    `trap_house_id`              INT          NULL,
    `created_at`                 DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `updated_at`                 DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_matrix_bots_dna_id` (`dna_id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- Oyuncu Kalıcı Bio-Durumu (fingerprint/kortizol formülleri için)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_player_state` (
    `citizenid`      VARCHAR(50) NOT NULL,
    `cortisol_level` FLOAT       NOT NULL DEFAULT 0.0,
    `fatigue_level`  FLOAT       NOT NULL DEFAULT 0.0,
    `updated_at`     DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`citizenid`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- Kalıcı Balistik Silah Kaydı (yiv-set imza kodu ile)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_ballistic_weapons` (
    `ballistic_id`            VARCHAR(64) NOT NULL,
    `weapon_serial`           VARCHAR(64) NOT NULL,
    `wear_level`              FLOAT       NOT NULL DEFAULT 0.0,
    `sealed_as_crime_weapon`  TINYINT(1)  NOT NULL DEFAULT 0,
    `seal_certainty`          FLOAT       NULL,
    `first_registered`        DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`ballistic_id`),
    UNIQUE KEY `uq_matrix_ballistic_weapon_serial` (`weapon_serial`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- Kalıcı Adli Kanıt Veri Tabanı (asla silinmez)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_forensic_evidence` (
    `id`                      INT          NOT NULL AUTO_INCREMENT,
    `ballistic_id`            VARCHAR(64)  NOT NULL,
    `evidence_type`           VARCHAR(32)  NOT NULL DEFAULT 'casing',
    `striation_quality`       FLOAT        NOT NULL,
    `fingerprint_id`          VARCHAR(64)  NOT NULL,
    `fingerprint_quality`     FLOAT        NOT NULL,
    `match_certainty`         FLOAT        NOT NULL,
    `sealed_as_crime_weapon`  TINYINT(1)   NOT NULL DEFAULT 0,
    `coords_x`                FLOAT        NOT NULL DEFAULT 0.0,
    `coords_y`                FLOAT        NOT NULL DEFAULT 0.0,
    `coords_z`                FLOAT        NOT NULL DEFAULT 0.0,
    `created_at`              DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_forensic_evidence_ballistic_id` (`ballistic_id`),
    CONSTRAINT `fk_matrix_forensic_evidence_ballistic`
        FOREIGN KEY (`ballistic_id`) REFERENCES `matrix_ballistic_weapons` (`ballistic_id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- Dokunulan Nesneler - Genel Parmak İzi Günlüğü (asla silinmez)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_touch_log` (
    `id`                  INT          NOT NULL AUTO_INCREMENT,
    `fingerprint_id`      VARCHAR(64)  NOT NULL,
    `fingerprint_quality` FLOAT        NOT NULL,
    `inventory_id`        VARCHAR(64)  NOT NULL,
    `slot_id`             INT          NOT NULL,
    `created_at`          DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_touch_log_fingerprint_id` (`fingerprint_id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- Karanlık Mülakat - Müşteri Havuzu (deterministik trait çıkarımı)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_customer_pool` (
    `citizenid`                  VARCHAR(50)  NOT NULL,
    `name`                       VARCHAR(100) NOT NULL,
    `police_encounters_nearby`   INT          NOT NULL DEFAULT 0,
    `completed_deals`            INT          NOT NULL DEFAULT 0,
    `times_reported`             INT          NOT NULL DEFAULT 0,
    `failed_payments`            INT          NOT NULL DEFAULT 0,
    `chemistry_hints`            INT          NOT NULL DEFAULT 0,
    `addiction_level`            FLOAT        NOT NULL DEFAULT 0.0,
    `promoted_to_candidate`      TINYINT(1)   NOT NULL DEFAULT 0,
    `created_at`                 DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`citizenid`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- Karanlık Mülakat - Sorgu Oturumu Sonuç Günlüğü
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_recruitment_sessions` (
    `id`                     INT          NOT NULL AUTO_INCREMENT,
    `candidate_citizenid`    VARCHAR(50)  NOT NULL,
    `fear_factor`            FLOAT        NOT NULL,
    `resilience`             FLOAT        NOT NULL,
    `lies_told`              INT          NOT NULL DEFAULT 0,
    `confessions`            INT          NOT NULL DEFAULT 0,
    `outcome`                ENUM('recruited','released','burned') NOT NULL,
    `created_at`             DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_recruitment_sessions_candidate` (`candidate_citizenid`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- =====================================================================
-- KATMAN 2: THE BUREAU  (Trap House + Desifre + Baskin + Yayin)
-- =====================================================================


-- ---------------------------------------------------------------------
-- Trap House Kayıtları (üçgenleme/desifre hedefleri)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_trap_houses` (
    `id`                    INT          NOT NULL AUTO_INCREMENT,
    `label`                 VARCHAR(100) NOT NULL,
    `coord_x`               FLOAT        NOT NULL,
    `coord_y`               FLOAT        NOT NULL,
    `coord_z`               FLOAT        NOT NULL,
    `decryption_confidence` FLOAT        NOT NULL DEFAULT 0.0,
    `cyber_leak_intensity`  FLOAT        NOT NULL DEFAULT 0.0,
    `raid_ordered`          TINYINT(1)   NOT NULL DEFAULT 0,
    `last_raid_at`          DATETIME     NULL,
    `created_at`            DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- Pattern Desifre Dongusu - Saat/Gun Kalibi Gunlugu
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_pattern_log` (
    `id`               INT      NOT NULL AUTO_INCREMENT,
    `trap_house_id`    INT      NOT NULL,
    `day_of_week`      TINYINT  NOT NULL,
    `hour_of_day`      TINYINT  NOT NULL,
    `occurrence_count` INT      NOT NULL DEFAULT 1,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_matrix_pattern_log_bucket` (`trap_house_id`, `day_of_week`, `hour_of_day`),
    CONSTRAINT `fk_matrix_pattern_log_trap_house`
        FOREIGN KEY (`trap_house_id`) REFERENCES `matrix_trap_houses` (`id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- Buro Istihbarat Katmani (ucgenleme / siber sizinti yogunlugu)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_bureau_intel` (
    `id`             INT          NOT NULL AUTO_INCREMENT,
    `trap_house_id`  INT          NOT NULL,
    `category`       ENUM('triangulation','cyber_leak','pattern') NOT NULL,
    `intensity`      FLOAT        NOT NULL DEFAULT 0.0,
    `updated_at`     DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_matrix_bureau_intel_bucket` (`trap_house_id`, `category`),
    CONSTRAINT `fk_matrix_bureau_intel_trap_house`
        FOREIGN KEY (`trap_house_id`) REFERENCES `matrix_trap_houses` (`id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- Fiziksel Safak Baskini Gunlugu - murettebat/breach/sonuc kaydi
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_raid_log` (
    `id`                             INT          NOT NULL AUTO_INCREMENT,
    `trap_house_id`                  INT          NOT NULL,
    `squad_size`                     INT          NOT NULL,
    `breach_method`                  VARCHAR(32)  NOT NULL DEFAULT 'ram',
    `decryption_confidence_at_raid`  FLOAT        NOT NULL,
    `escape_window_seconds`          INT          NOT NULL DEFAULT 0,
    `outcome`                        ENUM('pending','captured','escaped','eliminated') NOT NULL DEFAULT 'pending',
    `created_at`                     DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `resolved_at`                    DATETIME     NULL,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_raid_log_trap_house` (`trap_house_id`),
    CONSTRAINT `fk_matrix_raid_log_trap_house`
        FOREIGN KEY (`trap_house_id`) REFERENCES `matrix_trap_houses` (`id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- qb-phone Canli Yayin / Siber Propaganda Gunlugu (asla silinmez)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_livestream_events` (
    `id`               INT          NOT NULL AUTO_INCREMENT,
    `citizenid`        VARCHAR(50)  NOT NULL,
    `duration_seconds` INT          NOT NULL DEFAULT 0,
    `hype_multiplier`  FLOAT        NOT NULL DEFAULT 1.0,
    `heat_added`       FLOAT        NOT NULL DEFAULT 0.0,
    `trap_house_id`    INT          NULL,
    `created_at`       DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- =====================================================================
-- KATMAN 3: İHANET & MUTFAK
-- =====================================================================


-- ---------------------------------------------------------------------
-- Ihanet & Muhbirlik Gunlugu
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_snitch_events` (
    `id`             INT         NOT NULL AUTO_INCREMENT,
    `bot_id`         INT         NOT NULL,
    `trap_house_id`  INT         NOT NULL,
    `snitch_index`   FLOAT       NOT NULL,
    `lied`           TINYINT(1)  NOT NULL DEFAULT 0,
    `created_at`     DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_snitch_events_bot` (`bot_id`),
    CONSTRAINT `fk_matrix_snitch_events_bot`
        FOREIGN KEY (`bot_id`) REFERENCES `matrix_bots` (`id`),
    CONSTRAINT `fk_matrix_snitch_events_trap_house`
        FOREIGN KEY (`trap_house_id`) REFERENCES `matrix_trap_houses` (`id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- Mutfak Motoru - Seyreltme/Kesme Isletim Gunlugu
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_kitchen_batches` (
    `id`                           INT          NOT NULL AUTO_INCREMENT,
    `trap_house_id`                INT          NOT NULL,
    `actor_identifier`             VARCHAR(64)  NOT NULL,
    `raw_weight`                   FLOAT        NOT NULL,
    `raw_purity`                   FLOAT        NOT NULL,
    `agent_weight`                 FLOAT        NOT NULL,
    `theoretical_purity`           FLOAT        NOT NULL,
    `error_coefficient`            FLOAT        NOT NULL,
    `output_purity`                FLOAT        NOT NULL,
    `waste_volume`                 FLOAT        NOT NULL,
    `theft_amount`                 FLOAT        NOT NULL DEFAULT 0.0,
    `rival_infiltration_triggered` TINYINT(1)   NOT NULL DEFAULT 0,
    `created_at`                   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_kitchen_batches_trap_house` (`trap_house_id`),
    CONSTRAINT `fk_matrix_kitchen_batches_trap_house`
        FOREIGN KEY (`trap_house_id`) REFERENCES `matrix_trap_houses` (`id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- =====================================================================
-- KATMAN 4: İLLEGAL FİLO + TOPTANCI İLİŞKİ MATRİSİ + DEAD DROP
-- =====================================================================


-- ---------------------------------------------------------------------
-- İllegal Filo - Aktif Araç Havuzu. Bir araç ele geçirilirse (çatışma/
-- baskın) bu tablodan hard-delete edilir; kalıcı adli mühür ayrı olarak
-- matrix_vehicle_seizures'a yazılır.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_fleet` (
    `id`                      INT          NOT NULL AUTO_INCREMENT,
    `plate`                   VARCHAR(32)  NOT NULL,
    `vehicle_class`           ENUM('motorbike','car') NOT NULL DEFAULT 'car',
    `vin_status`              ENUM('factory','scratched','hot') NOT NULL DEFAULT 'hot',
    `vehicle_wear`            FLOAT        NOT NULL DEFAULT 0.0,
    `registered_by_citizenid` VARCHAR(50)  NULL,
    `assigned_bot_id`         INT          NULL,
    `assignment_mode`         ENUM('permanent','temporary') NULL,
    `verified_stolen_plate`   TINYINT(1)   NOT NULL DEFAULT 0,
    `created_at`              DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `updated_at`              DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_matrix_fleet_plate` (`plate`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- Büro ALPR / Görsel Eşkal Eşleşme Günlüğü (asla silinmez).
-- Plaka + dealer fingerprint_dna_id + organizasyon imzası bağlanır.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_alpr_hits` (
    `id`                     INT          NOT NULL AUTO_INCREMENT,
    `plate`                  VARCHAR(32)  NOT NULL,
    `fingerprint_dna_id`     VARCHAR(64)  NOT NULL,
    `organization_signature` VARCHAR(50)  NOT NULL,
    `trap_house_id`          INT          NOT NULL,
    `created_at`             DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_alpr_hits_plate` (`plate`),
    CONSTRAINT `fk_matrix_alpr_hits_trap_house`
        FOREIGN KEY (`trap_house_id`) REFERENCES `matrix_trap_houses` (`id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- Ele Geçirilen Araç Mührü - kalıcı kanıt katsayısı (asla silinmez).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_vehicle_seizures` (
    `id`                     INT          NOT NULL AUTO_INCREMENT,
    `plate`                  VARCHAR(32)  NOT NULL,
    `vin_status`             ENUM('factory','scratched','hot') NOT NULL,
    `vehicle_wear`           FLOAT        NOT NULL DEFAULT 0.0,
    `fingerprint_dna_id`     VARCHAR(64)  NOT NULL,
    `organization_signature` VARCHAR(50)  NOT NULL,
    `seizure_cause`          VARCHAR(32)  NOT NULL DEFAULT 'unknown',
    `seal_certainty`         FLOAT        NOT NULL,
    `coords_x`               FLOAT        NOT NULL DEFAULT 0.0,
    `coords_y`               FLOAT        NOT NULL DEFAULT 0.0,
    `coords_z`               FLOAT        NOT NULL DEFAULT 0.0,
    `created_at`              DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_vehicle_seizures_plate` (`plate`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- Toptancı Güven Matrisi - oyuncu/toptancı ilişkisi kalıcıdır.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_supplier_trust` (
    `citizenid`      VARCHAR(50) NOT NULL,
    `supplier_id`    INT         NOT NULL,
    `trust`          FLOAT       NOT NULL DEFAULT 0.5,
    `late_payments`  INT         NOT NULL DEFAULT 0,
    `forensic_leaks` INT         NOT NULL DEFAULT 0,
    `created_at`     DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `updated_at`     DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`citizenid`, `supplier_id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- Dead Drop Teslim Alma Günlüğü (asla silinmez)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_dead_drop_events` (
    `id`                    INT          NOT NULL AUTO_INCREMENT,
    `drop_id`               INT          NOT NULL,
    `supplier_id`           INT          NOT NULL,
    `citizenid`             VARCHAR(50)  NOT NULL,
    `heat_at_pickup`        FLOAT        NOT NULL DEFAULT 0.0,
    `forensic_trace_left`   TINYINT(1)   NOT NULL DEFAULT 0,
    `created_at`            DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_dead_drop_events_drop` (`drop_id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- =====================================================================
-- KATMAN 5: QBOX CO-OP KARTEL HİYERARŞİSİ + BÖLGESEL PİYASA +
-- KILCAL DAMAR HARDCORE MEKANİKLER
-- =====================================================================


-- ---------------------------------------------------------------------
-- Co-op Kartel Rütbe Ataması (CitizenID bazlı, kalıcı)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_hierarchy` (
    `citizenid`   VARCHAR(50) NOT NULL,
    `rank`        ENUM('Leader','Logistics_Officer','Chemist') NOT NULL DEFAULT 'Chemist',
    `assigned_by` VARCHAR(50) NULL,
    `created_at`  DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `updated_at`  DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`citizenid`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- Bölgesel Piyasa - anlık fiyat çarpanı / reddedilen parti sayacı
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_market_zones` (
    `zone_id`          INT      NOT NULL,
    `price_multiplier` FLOAT    NOT NULL DEFAULT 1.0,
    `rejected_streak`  INT      NOT NULL DEFAULT 0,
    `updated_at`       DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`zone_id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- Kirlenen Nakit Sönümlenmesi - trap house başına biriken kirli nakit ve
-- ilk yatırılma zamanı (adli koku/seri no izi τ=90 gün formülü buradan
-- türetilir; bkz. market.lua Matrix.CashDecay).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_cash_decay` (
    `trap_house_id`  INT      NOT NULL,
    `dirty_amount`   FLOAT    NOT NULL DEFAULT 0.0,
    `deposited_at`   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `updated_at`     DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`trap_house_id`),
    CONSTRAINT `fk_matrix_cash_decay_trap_house`
        FOREIGN KEY (`trap_house_id`) REFERENCES `matrix_trap_houses` (`id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- =====================================================================
-- FOREIGN KEY CHECK'LERİNİ YENİDEN AÇ
-- =====================================================================
SET FOREIGN_KEY_CHECKS = 1;


-- =====================================================================
-- DOĞRULAMA SORGUSU (opsiyonel — çalıştırıldığında 22 dönmeli)
-- =====================================================================
-- SELECT COUNT(*) AS matrix_table_count
-- FROM information_schema.tables
-- WHERE table_schema = DATABASE()
--   AND table_name LIKE 'matrix\_%';


-- =====================================================================
-- BAKIM: Sıfırdan yeniden kurmak isterseniz aşağıdaki blok
-- (yalnızca FK sırasına göre tersten) DROP eder. Yorumdan çıkarıp
-- çalıştırın. Bu blok TÜM VERİYİ SİLER — dikkatli kullanın.
-- =====================================================================
-- SET FOREIGN_KEY_CHECKS = 0;
-- DROP TABLE IF EXISTS `matrix_cash_decay`;
-- DROP TABLE IF EXISTS `matrix_market_zones`;
-- DROP TABLE IF EXISTS `matrix_hierarchy`;
-- DROP TABLE IF EXISTS `matrix_livestream_events`;
-- DROP TABLE IF EXISTS `matrix_dead_drop_events`;
-- DROP TABLE IF EXISTS `matrix_supplier_trust`;
-- DROP TABLE IF EXISTS `matrix_vehicle_seizures`;
-- DROP TABLE IF EXISTS `matrix_alpr_hits`;
-- DROP TABLE IF EXISTS `matrix_fleet`;
-- DROP TABLE IF EXISTS `matrix_kitchen_batches`;
-- DROP TABLE IF EXISTS `matrix_snitch_events`;
-- DROP TABLE IF EXISTS `matrix_raid_log`;
-- DROP TABLE IF EXISTS `matrix_bureau_intel`;
-- DROP TABLE IF EXISTS `matrix_pattern_log`;
-- DROP TABLE IF EXISTS `matrix_trap_houses`;
-- DROP TABLE IF EXISTS `matrix_recruitment_sessions`;
-- DROP TABLE IF EXISTS `matrix_customer_pool`;
-- DROP TABLE IF EXISTS `matrix_touch_log`;
-- DROP TABLE IF EXISTS `matrix_forensic_evidence`;
-- DROP TABLE IF EXISTS `matrix_ballistic_weapons`;
-- DROP TABLE IF EXISTS `matrix_player_state`;
-- DROP TABLE IF EXISTS `matrix_bots`;
-- SET FOREIGN_KEY_CHECKS = 1;


-- =======================================================================
-- ★ KAYNAK: sql/layer5_ultimate.sql (orijinal icerik, birebir asagida, hicbir satir atlanmadi)
-- =======================================================================

-- =====================================================================
-- MATRIX SCHEMA — KATMAN 5 ULTIMATE EK MİGRASYONU (sql/layer5_ultimate.sql)
-- Co-Op & SIGINT/COMINT Bali-Logistics Matrix
--
-- ★ BU DOSYA TAMAMEN EKLEMELİDİR (ADDITIVE-ONLY):
--   matrix.sql'deki (v3) 16 tabloya HİÇBİRİNE DOKUNULMAZ — ALTER YOK,
--   DROP YOK, kolon eklenmedi. Yalnızca 4 YENİ tablo eklenir. matrix.sql'i
--   İMPORT ETTİKTEN SONRA bu dosyayı çalıştırın.
--
--   Bu dosya, matrix.sql ile AYNI konvansiyonları izler:
--     - ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
--     - "DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP" KULLANILMAZ
--       (bazı MariaDB/MySQL derlemelerinde CREATE TABLE'ı sessizce
--       başarısız kılıyordu — v1→v2 notu, bkz. matrix.sql). `updated_at`/
--       `flagged_at`/`assigned_at` uygulama katmanında (server/market.lua,
--       server/blackmarket.lua) her UPSERT'te explicit NOW() ile yazılır.
--     - Tablo/kolon adları geriye dönük `matrix_` önekini korur.
--
--   ★ KASITLI TASARIM KARARI — FK YOK: `matrix_zone_inspectors.bot_id` ve
--     `matrix_mole_flags.bot_id`, KASITLI OLARAK `matrix_bots.id`'ye FOREIGN
--     KEY İLE BAĞLANMAZ. Sebep: server/logistics.lua'nın Matrix.Logistics.
--     OnDealerEliminated'i (F10 "Operatif Tasfiye Et" -> /operatiftasfiye,
--     bkz. server/main.lua) matrix_bots satırını GERÇEK bir DELETE ile
--     kalıcı olarak siler (hard-delete politikası, matrix.sql başlığında
--     zaten tanımlı). Bir Inspector'a atanmış veya köstebek olarak
--     işaretlenmiş bir botu tasfiye etmek İSTİSNASIZ ÇALIŞMALIDIR — bir FK
--     kısıtı (varsayılan RESTRICT/NO ACTION) bu hard-delete'i SESSİZCE
--     BLOKE ederdi. RAM tarafında (server/market.lua Matrix.Inspector)
--     zaten stale bot_id'lere karşı dayanıklı: silinen bir bot bir
--     sonraki taramada otomatik olarak atamadan düşer (self-healing).
-- =====================================================================


SET FOREIGN_KEY_CHECKS = 0;


-- ---------------------------------------------------------------------
-- [U2] Karaborsa Ticaret Ağı - satın alma günlüğü (asla silinmez; mevcut
-- "adli kayıt politikası" ruhuna uygun kalıcı bir kâğıt izi).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_blackmarket_purchases` (
    `id`          INT          NOT NULL AUTO_INCREMENT,
    `citizenid`   VARCHAR(50)  NOT NULL,
    `item_type`   ENUM('vehicle','weapon','barrel','burner_phone') NOT NULL,
    `item_ref`    VARCHAR(64)  NOT NULL,
    `price_paid`  FLOAT        NOT NULL DEFAULT 0.0,
    `created_at`  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_blackmarket_purchases_citizenid` (`citizenid`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- [U4] SIGINT - Bölge Denetleyicisi (Inspector) ataması. Bölge başına
-- TEK aktif denetleyici (PRIMARY KEY = zone_id); yeniden atama UPSERT ile
-- öncekinin yerini alır.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_zone_inspectors` (
    `zone_id`                INT         NOT NULL,
    `bot_id`                 INT         NOT NULL,
    `assigned_by_citizenid`  VARCHAR(50) NULL,
    `assigned_at`            DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`zone_id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- [U4] SIGINT - Köstebek/muhbir tarama sonucu kalıcı bülteni. Bir botun
-- Operatif Tasfiye Et ile arındırılmasından SONRA da (kanıt/denetim amaçlı)
-- kalır; matrix_bots.id hard-delete sonrası hiçbir zaman yeniden
-- kullanılmaz (Matrix.NextBotId monoton artar), bu yüzden stale satır bir
-- sonraki bot ile ASLA çakışmaz.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_mole_flags` (
    `bot_id`           INT      NOT NULL,
    `snitch_tendency`  FLOAT    NOT NULL DEFAULT 0.0,
    `flagged_at`       DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`bot_id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- [U6] Bölgesel Mali Rapor - bölge başına yuvarlanan (rolling) kâr/zarar
-- bilançosu. matrix_market_zones (fiyat çarpanı/ardarda-red) ile AYNI
-- zone_id uzayını paylaşır ama BAĞIMSIZ bir tablodur (o da zone_id'ye FK
-- taşımıyor — zone'lar Config.Market.Zones'ta statik tanımlı, ayrı bir
-- "zones" ebeveyn tablosu hiç var olmadı).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_zone_ledger` (
    `zone_id`            INT      NOT NULL,
    `sale_count`         INT      NOT NULL DEFAULT 0,
    `total_grams`        FLOAT    NOT NULL DEFAULT 0.0,
    `gross_revenue`      FLOAT    NOT NULL DEFAULT 0.0,
    `net_profit`         FLOAT    NOT NULL DEFAULT 0.0,
    `price_crash_count`  INT      NOT NULL DEFAULT 0,
    `updated_at`         DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`zone_id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


SET FOREIGN_KEY_CHECKS = 1;


-- =====================================================================
-- DOĞRULAMA SORGUSU (opsiyonel — bu dosya çalıştırıldıktan sonra 4 dönmeli)
-- =====================================================================
-- SELECT COUNT(*) AS layer5_ultimate_table_count
-- FROM information_schema.tables
-- WHERE table_schema = DATABASE()
--   AND table_name IN (
--       'matrix_blackmarket_purchases',
--       'matrix_zone_inspectors',
--       'matrix_mole_flags',
--       'matrix_zone_ledger'
--   );


-- =====================================================================
-- BAKIM: Yalnızca bu migrasyonun eklediği 4 tabloyu geri almak isterseniz
-- (matrix.sql'in 16 tablosuna DOKUNMAZ). Yorumdan çıkarıp çalıştırın.
-- =====================================================================
-- SET FOREIGN_KEY_CHECKS = 0;
-- DROP TABLE IF EXISTS `matrix_zone_ledger`;
-- DROP TABLE IF EXISTS `matrix_mole_flags`;
-- DROP TABLE IF EXISTS `matrix_zone_inspectors`;
-- DROP TABLE IF EXISTS `matrix_blackmarket_purchases`;
-- SET FOREIGN_KEY_CHECKS = 1;


-- =======================================================================
-- ★ KAYNAK: sql/layer6_trap_house.sql (orijinal icerik, birebir asagida, hicbir satir atlanmadi)
-- =======================================================================

-- =====================================================================
-- MATRIX SCHEMA — KATMAN 6 EK MİGRASYONU (sql/layer6_trap_house.sql)
-- Siber-Taktik Operasyon ve Stratejik Trap House Mimarisi
--
-- ★ BU DOSYA TAMAMEN EKLEMELİDİR (ADDITIVE-ONLY):
--   matrix.sql (v3, 22 tablo) ve sql/layer5_ultimate.sql (4 tablo)
--   HİÇBİR ŞEKİLDE değiştirilmez — ALTER YOK, DROP YOK, kolon eklenmedi.
--   Yalnızca 3 YENİ tablo eklenir. matrix.sql VE layer5_ultimate.sql'i
--   İMPORT ETTİKTEN SONRA bu dosyayı çalıştırın.
--
--   Aynı konvansiyonlar korunur: ENGINE=InnoDB DEFAULT CHARSET=utf8mb4,
--   "ON UPDATE CURRENT_TIMESTAMP" KULLANILMAZ (uygulama katmanı NOW() ile
--   yazar), `matrix_` öneki korunur, FK'ler yalnızca gerçekten var olan
--   kalıcı ebeveyn tablolara (matrix_trap_houses) bağlanır.
-- =====================================================================


SET FOREIGN_KEY_CHECKS = 0;


-- ---------------------------------------------------------------------
-- [K6-4] Kapı Sürgü Tahkimatı — trap house başına TEK aktif seviye
-- (0-3). server/door_reinforcement.lua tarafından okunur/yazılır.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_door_reinforcement` (
    `trap_house_id` INT      NOT NULL,
    `level`         TINYINT  NOT NULL DEFAULT 0,
    `installed_by_citizenid` VARCHAR(50) NULL,
    `updated_at`    DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`trap_house_id`),
    CONSTRAINT `fk_matrix_door_reinforcement_trap_house`
        FOREIGN KEY (`trap_house_id`) REFERENCES `matrix_trap_houses` (`id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- [K6-1] Rendezvous / Dead Drop teslimatı adli kaydı — asla silinmez
-- (mevcut "adli kayıt politikası" ile aynı ruh: bir pusu/teslimatın
-- gerçekten olup olmadığı sonradan denetlenebilir kalır).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_rendezvous_events` (
    `id`               INT          NOT NULL AUTO_INCREMENT,
    `citizenid`        VARCHAR(50)  NOT NULL,
    `catalog_type`     ENUM('weapon','ammo') NOT NULL,
    `catalog_id`       VARCHAR(64)  NOT NULL,
    `handoff_x`        FLOAT        NOT NULL DEFAULT 0.0,
    `handoff_y`        FLOAT        NOT NULL DEFAULT 0.0,
    `handoff_z`        FLOAT        NOT NULL DEFAULT 0.0,
    `trace_level_at_handoff` FLOAT  NOT NULL DEFAULT 0.0,
    `ambush_triggered` TINYINT(1)   NOT NULL DEFAULT 0,
    `outcome`          ENUM('pending','delivered','expired') NOT NULL DEFAULT 'pending',
    `created_at`       DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `resolved_at`      DATETIME     NULL,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_rendezvous_events_citizenid` (`citizenid`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- [K6-3] Paketleme Odası çalışma durumu — trap house başına TEK kayıt.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_packaging_room_state` (
    `trap_house_id` INT      NOT NULL,
    `active`        TINYINT(1) NOT NULL DEFAULT 0,
    `started_by_citizenid` VARCHAR(50) NULL,
    `updated_at`    DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`trap_house_id`),
    CONSTRAINT `fk_matrix_packaging_room_state_trap_house`
        FOREIGN KEY (`trap_house_id`) REFERENCES `matrix_trap_houses` (`id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


SET FOREIGN_KEY_CHECKS = 1;


-- =====================================================================
-- DOĞRULAMA SORGUSU (opsiyonel — bu dosya çalıştırıldıktan sonra 3 dönmeli)
-- =====================================================================
-- SELECT COUNT(*) AS layer6_table_count
-- FROM information_schema.tables
-- WHERE table_schema = DATABASE()
--   AND table_name IN (
--       'matrix_door_reinforcement',
--       'matrix_rendezvous_events',
--       'matrix_packaging_room_state'
--   );


-- =====================================================================
-- BAKIM: Yalnızca bu migrasyonun eklediği 3 tabloyu geri almak isterseniz
-- (matrix.sql/layer5_ultimate.sql'e DOKUNMAZ). Yorumdan çıkarıp çalıştırın.
-- =====================================================================
-- SET FOREIGN_KEY_CHECKS = 0;
-- DROP TABLE IF EXISTS `matrix_packaging_room_state`;
-- DROP TABLE IF EXISTS `matrix_rendezvous_events`;
-- DROP TABLE IF EXISTS `matrix_door_reinforcement`;
-- SET FOREIGN_KEY_CHECKS = 1;


-- =======================================================================
-- ★ KAYNAK: sql/layer7_faz1.sql (orijinal icerik, birebir asagida, hicbir satir atlanmadi)
-- =======================================================================

-- =====================================================================
-- KATMAN 7 [T4] FAZ 1: OTONOM DEPO LOJISTIGI VE BURO KILIDI
-- Additive migration. Yukaridaki (matrix.sql / layer5_ultimate.sql /
-- layer6_trap_house.sql) hicbir tablosu/alani DEGISTIRILMEDI -- her
-- ifade IF NOT EXISTS ile guvenlidir.
--
-- ★ KAPSAM NOTU: 'matrix_trap_stash' burada BULUNMUYOR -- trap house'un
-- ortak deposu zaten server/logistics.lua ve server/main.lua'nin
-- matrix_trap_stash_<id> ox_inventory stash'i (RegisterStash/AddItem/
-- RemoveItem) olarak MEVCUT. Ikinci bir SQL tablosu acmak veri
-- tutarsizligina yol acardi.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Kalici Kolektif Ogrenme Hafizasi -- trap house basina, RAID'LERDE
-- SIFIRLANMAYAN, birikimli telsiz ihlali + ele gecirilen urun saflik
-- kaydi. server/bureau.lua [T4] blogunun Buro Kilidi (lockdown_active)
-- karari BU tablodan turer; matrix_bureau_intel (mevcut) ile KARISTIRILMAZ
-- -- o yalnizca heat/triangulation/pattern yogunlugu tasir.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_bureau_learning_core` (
    `id`                          INT      NOT NULL AUTO_INCREMENT,
    `trap_house_id`               INT      NOT NULL,
    `frequent_zones`              TEXT     NULL COMMENT 'JSON array: bu trap house icin tekrarlanan ihlal etiketleri',
    `radio_breach_count`          INT      NOT NULL DEFAULT 0,
    `average_purity_intercepted`  FLOAT    NOT NULL DEFAULT 0.0 COMMENT '[0,1] olcek, matrix_kitchen_batches.output_purity ile ayni',
    `purity_sample_count`         INT      NOT NULL DEFAULT 0 COMMENT 'average_purity_intercepted hareketli ortalamasinin kendi bagimsiz sayaci',
    `lockdown_active`             TINYINT(1) NOT NULL DEFAULT 0,
    `updated_at`                  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_matrix_learning_core_trap_house` (`trap_house_id`),
    CONSTRAINT `fk_matrix_learning_core_trap_house`
        FOREIGN KEY (`trap_house_id`) REFERENCES `matrix_trap_houses` (`id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

-- ---------------------------------------------------------------------
-- Toplu Satis Hub'lari (District Distribution Hubs) -- F10 ile kritik
-- kavsaklara atanan, trap house'un ortak deposundan (matrix_trap_stash_
-- <id>) sabit miktarli/RNG'siz toplu satis dongusu yuruten dugumler.
-- `locked`, server/bureau.lua [T4]'un 'matrix:internal:bureauLockdown'
-- yayinindan senkronize edilir (server/district_hubs.lua).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_district_hubs` (
    `id`             INT          NOT NULL AUTO_INCREMENT,
    `trap_house_id`  INT          NOT NULL,
    `label`          VARCHAR(100) NOT NULL,
    `coord_x`        FLOAT        NOT NULL,
    `coord_y`        FLOAT        NOT NULL,
    `coord_z`        FLOAT        NOT NULL,
    `active`         TINYINT(1)   NOT NULL DEFAULT 1,
    `locked`         TINYINT(1)   NOT NULL DEFAULT 0,
    `created_at`     DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_district_hubs_trap_house` (`trap_house_id`),
    CONSTRAINT `fk_matrix_district_hubs_trap_house`
        FOREIGN KEY (`trap_house_id`) REFERENCES `matrix_trap_houses` (`id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- =======================================================================
-- ★ KAYNAK: sql/layer7_faz3.sql (orijinal icerik, birebir asagida, hicbir satir atlanmadi)
-- =======================================================================

-- =====================================================================
-- KATMAN 7 [T4] FAZ 3: OX_TARGET SOKAK DEVSIRME KOPRUSU
-- Additive migration. Yukaridaki (matrix.sql / layer5_ultimate.sql /
-- layer6_trap_house.sql / layer7_faz1.sql) hicbir tablosu/alani
-- DEGISTIRILMEDI -- ayni disiplin, yeni bir ALTER TABLE.
--
-- loyalty_base: [0,1] olcek, diger psychology alanlari (resilience,
-- snitch_tendency, ...) ILE AYNI sekilde matrix_bots'a eklenir.
-- server/recruitment.lua Matrix.Recruitment.RecruitStreetNpc'nin
-- ustunde calistigi TEK psikoloji semasi budur -- ikinci bir tablo
-- ACILMAZ. Varsayilan 0.5 (mevcut resilience/cognitive_shifter
-- varsayilanlariyla AYNI taban); yalnizca Ox_Target "Kadroya Kat"
-- devsirmesi (server/market.lua, /sokakdevsir test komutu ile AYNI
-- disiplin) bunu acikca 1.0 (mutlak sadik) yazar.
--
-- NOT: `ADD COLUMN IF NOT EXISTS`, MySQL 8.0.29+ / MariaDB 10.0+
-- gerektirir (oxmysql'in desteklediği surumlerin tamami bunu karsilar).
-- =====================================================================
ALTER TABLE `matrix_bots`
    ADD COLUMN IF NOT EXISTS `loyalty_base` FLOAT NOT NULL DEFAULT 0.5
        COMMENT '[0,1]; Ox_Target ile devsirilen ajanlar 1.0 (mutlak sadik) alir'
        AFTER `snitch_tendency`;


-- =======================================================================
-- ★ KAYNAK: sql/matrix_security_hardening.sql (orijinal icerik, birebir asagida, hicbir satir atlanmadi)
-- =======================================================================

-- =====================================================================
-- MATRIX SECURITY HARDENING PATCH / sql/matrix_security_hardening.sql
--
-- Bu migration, server/blackmarket.lua + server/bureau.lua ADLİ GÜVENLİK
-- DENETİMİ (7 maddelik zafiyet raporu) sonucu eklenen TEK yeni tabloyu
-- taşır: [SEC-2] "Hard Drop-Out / Orphan State" düzeltmesinin son çare
-- (son-kertede) tahsilat defteri.
--
-- matrix.sql'in KENDİSİ değiştirilmedi (mevcut şemaya elle dokunmak
-- riskli) -- bu proje layer5_ultimate.sql / layer6_trap_house.sql /
-- layer7_faz1.sql / layer7_faz3.sql ile AYNI "ek (additive) migration"
-- disiplinini izler. matrix.sql'den (veya son layer dosyasından) SONRA,
-- FOREIGN_KEY_CHECKS zaten 1'e dönmüş haldeyken import edilmelidir.
--
-- NOT: bu dosya "layer8" olarak ADLANDIRILMADI -- matrix.sql'in kendi
-- yorumunda KATMAN 8 zaten "Hard-Wipe / E_total" adlı, henüz tanımsız ve
-- BİLİNÇLİ OLARAK ertelenmiş ayrı bir özelliğe ayrılmış. Bu dosya o
-- katmanla KARIŞTIRILMASIN diye bağımsız bir isim taşır.
-- =====================================================================


-- ---------------------------------------------------------------------
-- ★ [SEC-2] Offline İade Son Çare Defteri
--
-- RefundCash (server/blackmarket.lua) şu sırayla dener:
--   1) Oyuncu çevrimiçiyse: Matrix.QBX Functions.AddMoney (anında).
--   2) Değilse: players.money JSON_SET ile ACID tek-UPDATE offline iade.
--   3) O UPDATE 0 satır etkilerse (citizenid players'ta yok -- silinmiş/
--      tanınmayan karakter): bu tabloya yazılır. Para HİÇBİR KOŞULDA
--      sessizce kaybolmaz; bir admin bu tabloyu görüp manuel mutabakat
--      yapabilir. Asla otomatik silinmez/işlenmez (yalnızca INSERT).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_pending_refunds` (
    `id`          INT          NOT NULL AUTO_INCREMENT,
    `citizenid`   VARCHAR(50)  NOT NULL,
    `amount`      DECIMAL(12,2) NOT NULL,
    `reason`      VARCHAR(100) NOT NULL,
    `resolved`    TINYINT(1)   NOT NULL DEFAULT 0,
    `resolved_by` VARCHAR(50)  DEFAULT NULL,
    `resolved_at` DATETIME     DEFAULT NULL,
    `created_at`  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_pending_refunds_citizenid` (`citizenid`),
    KEY `idx_matrix_pending_refunds_resolved` (`resolved`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- =======================================================================
-- ★ KAYNAK: sql/matrix_cctv_network.sql (orijinal icerik, birebir asagida, hicbir satir atlanmadi)
-- =======================================================================

-- =====================================================================
-- MATRIX CCTV NETWORK PATCH / sql/matrix_cctv_network.sql
--
-- Bu migration, server/forensics.lua ★ [OPSEC FAZ 1 EK] FİZİKSEL VE SİBER
-- DELİL İMHA MEKANİZMASI (Matrix.Forensics.HackCCTVNetwork) için TEK yeni
-- tabloyu taşır. matrix.sql'in (veya son layer/hardening dosyasının)
-- KENDİSİ değiştirilmedi -- bu proje layer5_ultimate.sql / layer6_trap_
-- house.sql / layer7_faz1.sql / layer7_faz3.sql / matrix_security_
-- hardening.sql İLE AYNI "ek (additive) migration" disiplinini izler.
-- matrix.sql'den (veya son migration dosyasından) SONRA, FOREIGN_KEY_CHECKS
-- zaten 1'e dönmüş haldeyken import edilmelidir.
--
-- ★ KAPSAM NOTU: bu migration YALNIZCA HackCCTVNetwork'ün SİLDİĞİ tabloyu
-- tanımlar. Mobese ağının oyuncu/bot kıyafet eşleşmesini GERÇEKTEN nasıl
-- TESPİT EDİP bu tabloya YAZACAĞI (bir algılama/computer-vision motoru)
-- bu görevin kapsamı DIŞINDADIR -- Config.AI_Matrix_Brain'in "altyapı
-- hazır, motor gelecekte devreye girer" (enabled=false) köprüsüyle AYNI
-- bilinçli erteleme. server/forensics.lua'daki /cctvkaydet test komutu,
-- gerçek bir algılama motoru olmadan bu tabloyu manuel doldurmak için
-- (bkz. server/bureau.lua /dropsizintiekle İLE AYNI "test-veri-ekleme"
-- disiplini) eklendi.
-- =====================================================================


-- ---------------------------------------------------------------------
-- Mobese Dağıtım Kutusu Kayıtları — bölge başına, zaman damgalı kıyafet/
-- maskeleme eşleşme günlüğü. HackCCTVNetwork yalnızca `masked = 0`
-- (maskesiz/şüpheli) VE son 30 dakika içindeki satırları siler; maskeli
-- (masked = 1) satırlar veya 30 dakikadan eski satırlar HİÇ ETKİLENMEZ.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_cctv_logs` (
    `id`           INT          NOT NULL AUTO_INCREMENT,
    `zone_id`      INT          NOT NULL,
    `dna_id`       VARCHAR(64)  NOT NULL,
    `masked`       TINYINT(1)   NOT NULL DEFAULT 0,
    `clothing_tag` VARCHAR(64)  NOT NULL DEFAULT 'unknown',
    `created_at`   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_cctv_logs_zone_time` (`zone_id`, `created_at`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- =====================================================================
-- DOĞRULAMA SORGUSU (opsiyonel — bu dosya çalıştırıldıktan sonra 1 dönmeli)
-- =====================================================================
-- SELECT COUNT(*) AS matrix_cctv_network_table_count
-- FROM information_schema.tables
-- WHERE table_schema = DATABASE()
--   AND table_name IN ('matrix_cctv_logs');


-- =====================================================================
-- BAKIM: Yalnızca bu migrasyonun eklediği tabloyu geri almak isterseniz.
-- Yorumdan çıkarıp çalıştırın.
-- =====================================================================
-- DROP TABLE IF EXISTS `matrix_cctv_logs`;


-- =======================================================================
-- ★ KAYNAK: sql/layer_regression_schema.sql (bu oturumda eklendi, birebir asagida)
-- =======================================================================

-- =====================================================================
-- ★★★ REGRESYON: 9 DB ŞEMA KONTROLÜ + ADLİ RPG / KOR NOKTA ŞEMASI ★★★
-- matrix_diagnostics.lua DbChecks tablosuna geri enjekte edilen 9 kontrolün
-- dayandığı şema + /davaac (Adli RPG), FragmentTerritory (Gang Learning
-- Core) ve /telefonuyoket (Adli Sabotaj) için gereken YENİ tablolar/kolonlar.
-- Bu dosya defalarca çalıştırılabilir (IF NOT EXISTS / kolon varlık
-- kontrolü olmayan ALTER'lar için, MySQL 8+ üzerinde ADD COLUMN IF NOT
-- EXISTS kullanılır; eski MySQL 5.7 için elle bir kez uygulayın).
-- =====================================================================

-- [1] matrix_zone_ledger.dirty_cash_pool -- bölgeye bağlı, henüz aklanmamış
-- kirli nakit havuzu (Matrix.CashDecay ile AYNI "kirli nakit" kavramı,
-- yalnızca bölge bazında ayrı bir toplam).
ALTER TABLE `matrix_zone_ledger`
    ADD COLUMN IF NOT EXISTS `dirty_cash_pool` FLOAT NOT NULL DEFAULT 0.0;

-- [2] matrix_bots.accounting_precision -- botun kendi nakit/envanter
-- muhasebesinin (BotStreetCash vb.) ne kadar "temiz" tutulduğunu ölçen,
-- [0,1] ölçekli bir sağlık katsayısı.
ALTER TABLE `matrix_bots`
    ADD COLUMN IF NOT EXISTS `accounting_precision` FLOAT NOT NULL DEFAULT 1.0;

-- [KOR NOKTA] matrix_bots.handler_citizenid + genişletilmiş status ENUM'u
-- (server/bureau.lua Matrix.Bureau.ExecuteVerdict bulk-disband hedeflemesi
-- + Koma Modu için).
ALTER TABLE `matrix_bots`
    ADD COLUMN IF NOT EXISTS `handler_citizenid` VARCHAR(50) NULL;
ALTER TABLE `matrix_bots`
    MODIFY COLUMN `status` ENUM('active','burned','deceased','retired','disbanded','comatose') NOT NULL DEFAULT 'active';

-- [3] matrix_zone_inspectors.is_wiped -- bir Denetleyici'nin istihbaratı
-- (kendi kayıtları) bir /kameralogutemizle veya /telefonuyoket sabotajıyla
-- kazınmışsa işaretlenir.
ALTER TABLE `matrix_zone_inspectors`
    ADD COLUMN IF NOT EXISTS `is_wiped` TINYINT(1) NOT NULL DEFAULT 0;

-- [4] matrix_purchase_logs -- Büro'nun saatlik mali denetiminin (bkz.
-- server/bureau.lua Matrix.Bureau.RunHourlyFinancialAudit) 24 saatten eski
-- satırları otonom budadığı genel fatura/işlem günlüğü.
CREATE TABLE IF NOT EXISTS `matrix_purchase_logs` (
    `id`          INT          NOT NULL AUTO_INCREMENT,
    `citizenid`   VARCHAR(50)  NULL,
    `item_ref`    VARCHAR(100) NOT NULL,
    `amount`      FLOAT        NOT NULL DEFAULT 0.0,
    `created_at`  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_purchase_logs_created_at` (`created_at`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

-- [5] matrix_customer_pool.is_dead -- bir sokak müşterisinin (keş) kalıcı
-- olarak havuzdan düşmesi gerektiğini işaretler (aşırı doz/koma zinciriyle
-- AYNI felsefe, bkz. Koma Modu).
ALTER TABLE `matrix_customer_pool`
    ADD COLUMN IF NOT EXISTS `is_dead` TINYINT(1) NOT NULL DEFAULT 0;

-- [6] matrix_gang_learning_core -- FragmentTerritory (server/district_hubs.lua)
-- her bölünmede bir satır işler: hangi trap house'un cete lideri düştü,
-- kaç Alt Hücre'ye (Splinter Cell) bölündü.
CREATE TABLE IF NOT EXISTS `matrix_gang_learning_core` (
    `id`               INT      NOT NULL AUTO_INCREMENT,
    `trap_house_id`    INT      NOT NULL,
    `splinter_count`   INT      NOT NULL DEFAULT 0,
    `aggression_level` FLOAT    NOT NULL DEFAULT 0.0,
    `updated_at`       DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_gang_learning_core_trap_house` (`trap_house_id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

-- [7] matrix_trial_records -- /davaac + /davasorgula (server/bureau.lua)
-- çift fazlı adli RPG diyalog zincirinin kalıcı dava dosyası.
CREATE TABLE IF NOT EXISTS `matrix_trial_records` (
    `id`                   INT          NOT NULL AUTO_INCREMENT,
    `defendant_citizenid`  VARCHAR(50)  NOT NULL,
    `dna_id`               VARCHAR(64)  NOT NULL,
    `ballistic_id`         VARCHAR(64)  NULL,
    `match_certainty`      FLOAT        NOT NULL DEFAULT 0.0,
    `lie_count`            INT          NOT NULL DEFAULT 0,
    `conviction_weight`    FLOAT        NOT NULL DEFAULT 0.0,
    `verdict`              VARCHAR(20)  NOT NULL DEFAULT 'pending',
    `opened_at`            DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `closed_at`            DATETIME     NULL,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_trial_records_defendant` (`defendant_citizenid`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

-- [8] matrix_player_state.imprisoned -- /davaac verdict %100 mahkumiyette
-- karakter kilidi (Karakter Wipe + DropPlayer).
ALTER TABLE `matrix_player_state`
    ADD COLUMN IF NOT EXISTS `imprisoned` TINYINT(1) NOT NULL DEFAULT 0;

-- [9] matrix_legal_plate_evidence -- plaka-bazlı adli delil izi (matrix_fleet
-- ile AYNI plaka kimlik uzayı; ikinci bir "plaka" kavramı İCAT EDİLMEZ).
CREATE TABLE IF NOT EXISTS `matrix_legal_plate_evidence` (
    `id`            INT          NOT NULL AUTO_INCREMENT,
    `plate`         VARCHAR(32)  NOT NULL,
    `citizenid`     VARCHAR(50)  NULL,
    `ballistic_id`  VARCHAR(64)  NULL,
    `recorded_at`   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_legal_plate_evidence_plate` (`plate`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

-- [KOR NOKTA] /telefonuyoket adli sabotaj komutunun sildiği kriptolu mesaj
-- günlüğü (YENİ tablo -- matrix_forensic_evidence'ın evidence_type='cyber'
-- satırlarıyla BİRLİKTE, aynı atomik transaction'da silinir).
CREATE TABLE IF NOT EXISTS `matrix_encrypted_messages` (
    `id`           INT          NOT NULL AUTO_INCREMENT,
    `dna_id`       VARCHAR(64)  NOT NULL,
    `content_hash` VARCHAR(64)  NOT NULL,
    `created_at`   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_encrypted_messages_dna_id` (`dna_id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- =======================================================================
-- ★ KAYNAK: sql/layer_splinter_cells.sql (bu oturumda eklendi, birebir asagida)
-- =======================================================================

-- =====================================================================
-- ★★★ OTONOM ALT HÜCRE BÖLÜNMESİ (FragmentTerritory / Splinter Cells) ★★★
-- Bir otonom çete lideri (bot.role == 'Leader') 'deceased' durumuna
-- düştüğünde (bkz. server/main.lua Matrix.RemoveBot), o trap house'a bağlı
-- TÜM matrix_district_hubs kayıtları bu tabloya "parçalanır" -- yeni bir
-- paralel ekonomi İCAT EDİLMEZ, yalnızca server/district_hubs.lua'nın
-- ZATEN VAR OLAN ProcessHubDemandCycle'ı + server/rendezvous.lua'nın
-- ZATEN VAR OLAN pusu event'i (matrix:client:rendezvous:triggerAmbush) +
-- server/bureau.lua'nın ZATEN VAR OLAN Matrix.Bureau.TriggerPropaganda
-- (siber-sızıntı) formülü bu yeni düğümlere BAĞLANIR.
-- =====================================================================
CREATE TABLE IF NOT EXISTS `matrix_splinter_cells` (
    `id`               INT          NOT NULL AUTO_INCREMENT,
    `parent_hub_id`    INT          NULL,
    `trap_house_id`    INT          NOT NULL,
    `splinter_index`   INT          NOT NULL,
    `coord_x`          FLOAT        NOT NULL,
    `coord_y`          FLOAT        NOT NULL,
    `coord_z`          FLOAT        NOT NULL,
    `active`           TINYINT(1)   NOT NULL DEFAULT 1,
    `created_at`       DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_splinter_cells_trap_house` (`trap_house_id`),
    CONSTRAINT `fk_matrix_splinter_cells_trap_house`
        FOREIGN KEY (`trap_house_id`) REFERENCES `matrix_trap_houses` (`id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- =======================================================================
-- ★ KAYNAK: sql/layer_underworld_expansion.sql (bu oturumda eklendi, birebir asagida)
-- =======================================================================

-- =====================================================================
-- ★★★ YERALTI FİZİKSEL SAVAŞ + KARA TIP + SIZDIRILAN İSTİHBARAT
-- GENİŞLEMESİ (7 katmanlı görev seti) ★★★
-- Additive migration -- yukaridaki hicbir tablo/kolon DEGISTIRILMEZ.
-- =====================================================================


-- ---------------------------------------------------------------------
-- [KATMAN 2] Legal Hospital / EMS Sizinti Döngüsü — matrix_player_state'e
-- yara/balistik imza kolonlari.
-- ---------------------------------------------------------------------
ALTER TABLE `matrix_player_state`
    ADD COLUMN IF NOT EXISTS `has_wound` TINYINT(1) NOT NULL DEFAULT 0;
ALTER TABLE `matrix_player_state`
    ADD COLUMN IF NOT EXISTS `wound_ballistic_id` VARCHAR(64) NULL;


-- ---------------------------------------------------------------------
-- [KATMAN 3/4] Arma-tarzi Bölgesel Bot Yaralanma/Etkisizleştirme +
-- Kalıcı Uzuv Sakatlığı. Koma modu (status='comatose', ZATEN VAR OLAN
-- withdrawal_index tetiği, bkz. server/bureau.lua) DEĞİŞTİRİLMEZ.
-- ---------------------------------------------------------------------
ALTER TABLE `matrix_bots`
    ADD COLUMN IF NOT EXISTS `wound_zone` VARCHAR(16) NULL;
ALTER TABLE `matrix_bots`
    ADD COLUMN IF NOT EXISTS `leg_injury` FLOAT NOT NULL DEFAULT 0.0;
ALTER TABLE `matrix_bots`
    ADD COLUMN IF NOT EXISTS `head_injury` FLOAT NOT NULL DEFAULT 0.0;
ALTER TABLE `matrix_bots`
    ADD COLUMN IF NOT EXISTS `arm_injury` FLOAT NOT NULL DEFAULT 0.0;
ALTER TABLE `matrix_bots`
    ADD COLUMN IF NOT EXISTS `permanently_crippled` TINYINT(1) NOT NULL DEFAULT 0;
ALTER TABLE `matrix_bots`
    ADD COLUMN IF NOT EXISTS `installed_prosthetic` TINYINT(1) NOT NULL DEFAULT 0;
-- Karaborsa Ameliyati / Trap House tedavisi kilit sayaci (12s tedavi /
-- 24s Hayalet Cerrah ameliyati bu tek kolonu paylasir -- ayni "kilitli
-- zaman damgasi" deseni ComaClock ILE AYNI felsefe, RAM yerine kalici).
ALTER TABLE `matrix_bots`
    ADD COLUMN IF NOT EXISTS `medical_lock_until` DATETIME NULL;


-- ---------------------------------------------------------------------
-- [KATMAN 3] Bölge kitapları (matrix_zone_ledger, ZATEN VAR OLAN) için
-- denetim-uyarısı anomali oranı -- gövde yarası + Büro sting'i buraya
-- yazar.
-- ---------------------------------------------------------------------
ALTER TABLE `matrix_zone_ledger`
    ADD COLUMN IF NOT EXISTS `audit_anomaly_rate` FLOAT NOT NULL DEFAULT 0.0;


-- ---------------------------------------------------------------------
-- [KATMAN 5] Deterministik Taze-Kurulum Satıcı Dağılımı — sunucu ilk
-- açılışta, server/DB adı + satıcı id'sinin sağlama toplamından türetilir
-- (RNG YOK, bkz. server/underworld_network.lua ChecksumOf).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_vendor_pool` (
    `id`               INT          NOT NULL AUTO_INCREMENT,
    `vendor_citizenid` VARCHAR(50)  NULL,
    `coord_x`          FLOAT        NOT NULL,
    `coord_y`          FLOAT        NOT NULL,
    `coord_z`          FLOAT        NOT NULL,
    `gang_loyalty`     FLOAT        NOT NULL DEFAULT 0.5,
    `fear_index`       FLOAT        NOT NULL DEFAULT 0.3,
    `status`           VARCHAR(32)  NOT NULL DEFAULT 'active',
    PRIMARY KEY (`id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;
-- Satici tekilligi/istismar izi -- sabotajli silahlarin (jam_accumulator
-- onceden yuksek) hangi saticidan gectigini kaydeder; ikinci bir tablo
-- ACILMAZ, tek bayrak kolonu yeterlidir.
ALTER TABLE `matrix_vendor_pool`
    ADD COLUMN IF NOT EXISTS `compromised` TINYINT(1) NOT NULL DEFAULT 0;


-- ---------------------------------------------------------------------
-- [KATMAN 6] Parçalanmış İstihbarat Defteri + Karşı-İstihbarat Vetting.
-- contact_ref: hangi somut satici/doktor kaydina (matrix_vendor_pool.id
-- veya 'phantom_doctor') ait oldugunu belirtir -- literal spesifikasyon
-- semasi (citizenid/contact_type/intel_fragments) KORUNUR, yalnizca
-- discovered/compromised/contact_ref ADDITIVE olarak eklenir.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_fragmented_intel` (
    `id`              INT          NOT NULL AUTO_INCREMENT,
    `citizenid`       VARCHAR(50)  NOT NULL,
    `contact_type`    VARCHAR(50)  NOT NULL,
    `intel_fragments` FLOAT        DEFAULT 0.0,
    PRIMARY KEY (`id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;
ALTER TABLE `matrix_fragmented_intel`
    ADD COLUMN IF NOT EXISTS `contact_ref` VARCHAR(64) NULL;
ALTER TABLE `matrix_fragmented_intel`
    ADD COLUMN IF NOT EXISTS `discovered` TINYINT(1) NOT NULL DEFAULT 0;
ALTER TABLE `matrix_fragmented_intel`
    ADD COLUMN IF NOT EXISTS `compromised` TINYINT(1) NOT NULL DEFAULT 0;
ALTER TABLE `matrix_fragmented_intel`
    ADD COLUMN IF NOT EXISTS `updated_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP;


-- ---------------------------------------------------------------------
-- [KATMAN 7] Düşman Çete Mahalleleri + Sıfır-Toplam Yağma Motoru +
-- Balistik Suç Yükleme (Frame-Up). stash_id: matrix_trap_stash_<id> ILE
-- AYNI ox_inventory RegisterStash disiplini -- ikinci bir kalicilik
-- kaynagi ACILMAZ.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_gang_hoods` (
    `id`           INT          NOT NULL AUTO_INCREMENT,
    `hood_label`   VARCHAR(100) NOT NULL,
    `control_ratio` FLOAT       NOT NULL DEFAULT 1.0,
    `stash_id`     VARCHAR(64)  NULL,
    PRIMARY KEY (`id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;
ALTER TABLE `matrix_gang_hoods`
    ADD COLUMN IF NOT EXISTS `coord_x` FLOAT NOT NULL DEFAULT 0.0;
ALTER TABLE `matrix_gang_hoods`
    ADD COLUMN IF NOT EXISTS `coord_y` FLOAT NOT NULL DEFAULT 0.0;
ALTER TABLE `matrix_gang_hoods`
    ADD COLUMN IF NOT EXISTS `coord_z` FLOAT NOT NULL DEFAULT 0.0;
ALTER TABLE `matrix_gang_hoods`
    ADD COLUMN IF NOT EXISTS `nearest_trap_house_id` INT NULL;
ALTER TABLE `matrix_gang_hoods`
    ADD COLUMN IF NOT EXISTS `loot_opened_at` DATETIME NULL;
ALTER TABLE `matrix_gang_hoods`
    ADD COLUMN IF NOT EXISTS `loot_compound_ticks` INT NOT NULL DEFAULT 0;


-- =====================================================================
-- ★ KATMAN 21: ACIMASIZ DIAGNOSTICS LABORATUVARI -- 100 eszamanli async
-- satis stres testinin (server/matrix_diagnostics.lua RunConcurrencyStressCheck)
-- yazdigi kayitlar icin, CANLI ekonomi tablolarindan TAMAMEN izole,
-- tani-yalnizca bir gunluk. Her calistirmadan sonra run_token'a gore
-- silinir -- kalici veri BIRIKTIRMEZ.
-- =====================================================================
CREATE TABLE IF NOT EXISTS `matrix_diagnostics_stress_log` (
    `id`           INT AUTO_INCREMENT,
    `run_token`    VARCHAR(64) NOT NULL,
    `worker_index` INT         NOT NULL,
    `removed_ok`   TINYINT     NOT NULL DEFAULT 0,
    `created_at`   DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_run_token` (`run_token`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- =====================================================================
-- DOĞRULAMA SORGUSU (opsiyonel — bu dosya çalıştırıldıktan sonra 4 dönmeli)
-- =====================================================================
-- SELECT COUNT(*) AS underworld_expansion_table_count
-- FROM information_schema.tables
-- WHERE table_schema = DATABASE()
--   AND table_name IN (
--       'matrix_vendor_pool',
--       'matrix_fragmented_intel',
--       'matrix_gang_hoods',
--       'matrix_diagnostics_stress_log'
--   );
-- =====================================================================
-- ★ KATMAN 23: DIAGNOSTICS BEKÇİLERİ — EKSİK KOLONLAR ★
-- =====================================================================
SET FOREIGN_KEY_CHECKS = 0;

ALTER TABLE `matrix_vendor_pool`
    ADD COLUMN IF NOT EXISTS `vendor_license` VARCHAR(64) NULL;

ALTER TABLE `matrix_player_state`
    ADD COLUMN IF NOT EXISTS `recovery_target_epoch` BIGINT NULL;

ALTER TABLE `matrix_forensic_evidence`
    ADD COLUMN IF NOT EXISTS `evidence_tampering` TINYINT(1) NOT NULL DEFAULT 0;

ALTER TABLE `matrix_forensic_evidence`
    ADD COLUMN IF NOT EXISTS `biological_trauma` TINYINT(1) NOT NULL DEFAULT 0;

ALTER TABLE `matrix_forensic_evidence`
    ADD COLUMN IF NOT EXISTS `inflicted_force_striation` FLOAT NOT NULL DEFAULT 0.0;

SET FOREIGN_KEY_CHECKS = 1;

-- =======================================================================
-- ★ KAYNAK: sql/layer8_milsim_expansion.sql (bu oturumda birlestirildi)
-- =======================================================================
-- ★★★ KATMAN 8: LİMAN KAÇAKÇILIK + KRİPTO CÜZDAN AĞLARI ★★★
-- Additive-only. Yukaridaki hicbir tablo/kolon DEGISTIRILMEZ.
-- =======================================================================

SET FOREIGN_KEY_CHECKS = 0;

-- ---------------------------------------------------------------------
-- [CEPHE A] Liman Gumruk Check-in Gunlugu -- bot rampa bolgesine
-- girdiginde matrix_bureau_intensity ConVar'ının x2 katlanmasını ve
-- client-relay driveby isteginin kanıt kaydını tutar.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_port_smuggling_events` (
    `id`               INT          NOT NULL AUTO_INCREMENT,
    `bot_id`           INT          NOT NULL,
    `port_zone`        VARCHAR(32)  NOT NULL DEFAULT 'port_ramp',
    `intensity_before` FLOAT        NOT NULL DEFAULT 1.0,
    `intensity_after`  FLOAT        NOT NULL DEFAULT 1.0,
    `dispatch_plate`   VARCHAR(32)  NULL,
    `driveby_pushed`   TINYINT(1)   NOT NULL DEFAULT 0,
    `created_at`       DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_port_smuggling_bot` (`bot_id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

-- ---------------------------------------------------------------------
-- [CEPHE B] Anonim Kripto Cuzdan Agi -- SEC-6 rolling cipher mutasyon
-- protokolu. wallet_address SHA-256 benzeri 64-karakter hex (0x onekli).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_crypto_wallets` (
    `wallet_address`     VARCHAR(64)  NOT NULL,
    `holder_identifier`  VARCHAR(50)  NOT NULL,
    `holder_type`        ENUM('player','bot') NOT NULL DEFAULT 'player',
    `crypto_balance`     DECIMAL(16,4) NOT NULL DEFAULT 0.0000,
    `rolling_cipher_key` VARCHAR(64)  NOT NULL,
    `tx_sequence`        INT          NOT NULL DEFAULT 0,
    `created_at`         DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `updated_at`         DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`wallet_address`),
    KEY `idx_matrix_crypto_wallets_holder` (`holder_type`, `holder_identifier`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

SET FOREIGN_KEY_CHECKS = 1;


-- =======================================================================
-- ★ KAYNAK: sql/layer_23_diagnostics_bekcileri.sql (bu oturumda birlestirildi)
-- =======================================================================
-- ★ KATMAN 23: DIAGNOSTICS BEKÇİLERİ — EKSİK KOLON MİGRASYONU ★
-- server/matrix_diagnostics.lua'nın [ADDITIVE] bekçilik kontrolleri
-- (KATMAN 5/6 GM emirleri) dayandığı kolonları ekler. Yukarıdaki hiçbir
-- tabloya/kolona DOKUNULMAZ — yalnızca ADD COLUMN IF NOT EXISTS.
-- =======================================================================

SET FOREIGN_KEY_CHECKS = 0;

-- [KATMAN 6] Satıcı lisansı — düşman finansmanlı satıcıların kimlik izi
ALTER TABLE `matrix_vendor_pool`
    ADD COLUMN IF NOT EXISTS `vendor_license` VARCHAR(64) NULL
        COMMENT 'Sahte/belgeli satici kimlik izi';

-- [KATMAN 5] 24 Saatlik Data Recovery — müsadere edilen cihazın çözülme
-- hedefi (Unix epoch, restart'ta geri sarmaz)
ALTER TABLE `matrix_player_state`
    ADD COLUMN IF NOT EXISTS `recovery_target_epoch` BIGINT NULL
        COMMENT 'Musadere edilen cihazin cozulme hedef zamani (Unix epoch)';

-- [KATMAN 4] Taktiksel Güç Uygulaması — adli kanıt zinciri bayrakları
ALTER TABLE `matrix_forensic_evidence`
    ADD COLUMN IF NOT EXISTS `evidence_tampering` TINYINT(1) NOT NULL DEFAULT 0
        COMMENT 'Kanit odasi sabotaji gordu mu (TamperEvidenceLockup)';
ALTER TABLE `matrix_forensic_evidence`
    ADD COLUMN IF NOT EXISTS `biological_trauma` TINYINT(1) NOT NULL DEFAULT 0
        COMMENT 'Biyolojik tramva kaniti mi (kontrollugucuyula)';
ALTER TABLE `matrix_forensic_evidence`
    ADD COLUMN IF NOT EXISTS `inflicted_force_striation` FLOAT NOT NULL DEFAULT 0.0
        COMMENT 'Uygulanan fiziksel gucun uzuv bazli hasar katsayisi';

-- =====================================================================
-- ★ KATMAN 8 CRITICAL: OPSEC DİNAMİK PAROLA + TAMPER LOG
-- =====================================================================
SET FOREIGN_KEY_CHECKS = 0;

-- [FAZ 1] Trap house başına oyun içi rotasyona açık parola (hash).
-- Default 'CORE_MATRIX_INIT_PASS' — ilk açılışta her trap house bu
-- passphrase ile mühürlenir, GM panelinden değiştirilebilir.
ALTER TABLE `matrix_trap_houses`
    ADD COLUMN IF NOT EXISTS `opsec_passphrase` VARCHAR(64) NOT NULL
        DEFAULT 'CORE_MATRIX_INIT_PASS'
        COMMENT 'SEC-7 dinamik parola — düz metin değil, SHA256-benzeri hex';

-- [FAZ 1] Yanlış parola → adli iz kaydı (asla silinmez, "adli kayıt
-- politikası" ruhuna uygun).
CREATE TABLE IF NOT EXISTS `matrix_opsec_tamper_log` (
    `id`                        INT          NOT NULL AUTO_INCREMENT,
    `trap_house_id`             INT          NOT NULL,
    `citizenid`                 VARCHAR(50)  NULL,
    `attempted_passphrase_hash` VARCHAR(64)  NOT NULL,
    `geometric_step`            FLOAT        NOT NULL DEFAULT 0.0,
    `decryption_after`          FLOAT        NOT NULL DEFAULT 0.0,
    `created_at`                DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_opsec_tamper_trap` (`trap_house_id`),
    KEY `idx_matrix_opsec_tamper_citizen` (`citizenid`),
    CONSTRAINT `fk_matrix_opsec_tamper_trap`
        FOREIGN KEY (`trap_house_id`) REFERENCES `matrix_trap_houses` (`id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

SET FOREIGN_KEY_CHECKS = 1;

-- =====================================================================
-- ★ KATMAN 9: TASK EKİ — ADLİ KAN DELİLİ + AJAN HAVUZU KALICILIĞI
-- Bu blok TAMAMEN EKLEMEDİR. Hiçbir mevcut tablonun/kolonun tipi/anlamı
-- DEĞİŞTİRİLMEDİ -- yalnızca ADD COLUMN IF NOT EXISTS kullanılır.
-- =====================================================================

-- [1] matrix_forensic_evidence.blood_pool_purity -- server/forensics.lua
-- Matrix.Forensics.RecordBloodEvidence tarafından yazılan, biyolojik kan
-- izinin (evidence_type='biological_blood') anlık saflığı. NULL == bu
-- satır kan delili değil (mevcut kovan/mermi satırları etkilenmez).
ALTER TABLE `matrix_forensic_evidence`
    ADD COLUMN IF NOT EXISTS `blood_pool_purity` FLOAT NULL DEFAULT NULL
        COMMENT 'MODUL 2: biological_blood kanitlarinin anlik saflik degeri (0..1), lineer olarak zamanla azalir';

-- [2] matrix_bots.activity -- /muhafizcagir anti-dupe havuz filtresi
-- (server/mercenary_followers.lua Matrix.Mercenary.RequestSummon) artık
-- runtime state.activity alanini ('idle'/'deployed') KALICI olarak takip
-- edebilsin diye (sunucu yeniden başladığında havuz durumu korunur).
ALTER TABLE `matrix_bots`
    ADD COLUMN IF NOT EXISTS `activity` VARCHAR(32) NOT NULL DEFAULT 'idle'
        COMMENT 'MODUL 1: idle=havuzda cagrilabilir, deployed=bir oyuncuya atanmis/sahada';

-- [3] matrix_forensic_evidence.inflicted_force_striation -- server/forensics.lua
-- Matrix.Forensics.SimulateWeaponFire: pompalı/sawnoff (shotgun) ateşlemelerinde
-- klasik yiv-set eşleşmesi (striation_quality) SABİT 0.0'a kilitlenir; bunun
-- yerine bu kolon (pellet-kütle vekili, pellet sayısıyla DOĞRUSAL) balistik
-- eşleştirme için kullanılır. NULL == bu satır shotgun ateşlemesi değil.
ALTER TABLE `matrix_forensic_evidence`
    ADD COLUMN IF NOT EXISTS `inflicted_force_striation` FLOAT NULL DEFAULT NULL
        COMMENT 'MODUL 4: shotgun pellet-kutle vekili balistik esleme degeri';