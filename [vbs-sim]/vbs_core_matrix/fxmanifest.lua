fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'projeFivem'
description 'Katman 1-2-3-4-5 ULTIMATE + KATMAN 6 Birlesik Motor + KATMAN 7 [T1-T4] Faz 1-2 + KATMAN 8: Core Matrix, Adli Balistik (+ Gercekci Namlu Asinmasi/Tutukluk + Real-Time Ust Arama), Recruitment (+ Propaganda Devsirme Koprusu), The Bureau (+ Buro Kilidi/Nukleer Abluka + AI Danisma Koprusu), Mutfak & Psikoloji Simulasyonu (+ Paketleme Odasi), Programli Lojistik Sevk (+ Otomatik Rota Teslimati + GTAO Cikis Koprusu + Toplu Satis Hub Lojistigi + Bagaj Ameliyati), Qbox Co-op Kartel Hiyerarsisi & Bolgesel Piyasa (+ Canli Sokak Satis Dongusu), Taktik Karaborsa Ticaret Agi (+ Rendezvous Teslimati/Buro Pususu), SIGINT/COMINT Bolge Denetleyicileri, Sanal Mahalle Evi (Interior Instance), Silah Tamir Tezgahi & Paketleme Odasi, Kapi Surgu Tahkimati, Monokrom Taktik HUD, Dusman Hucum Ekibi Drive-By Takip Motoru'
version '1.7.0'

shared_scripts {
    '@ox_lib/init.lua',
    'shared/config.lua'
}

client_scripts {
    'client/hud.lua',
    'client/trap_house_client.lua',
    'client/composer_intro.lua',
    'client/mercenary_followers.lua',        -- ✅ VİRGÜL EKLENDİ
    -- ★ [H4-v2][GEMINI-2] HUMINT Adaptif Takip Motoru — spawn öncesi yüklenmeli
    'client/humint_stalking.lua',
    -- ★ [TASK EKI] Anti-glitch PvP hareket duzeltmeleri + hayalet-bakis
    -- (ghost-peek) tespiti + baski/tunel-gorusu vinyeti (Modul 5/6/7)
    'client/anti_glitch.lua'
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/main.lua',
    'server/forensics.lua',
    'server/recruitment.lua',
    'server/bureau.lua',
    'server/district_hubs.lua',
    'server/kitchen.lua',
    'server/logistics.lua',
    'server/market.lua',
    'server/blackmarket.lua',
    'server/rendezvous.lua',
    'server/trap_house_interior.lua',
    'server/workbench.lua',
    'server/door_reinforcement.lua',
    'server/wound_system.lua',
    'server/underworld_network.lua',
    'server/gang_hoods.lua',
    'server/mercenary_followers.lua',
    'server/hitsquad.lua',
    'server/phone_bridge.lua',         -- ✅ Diagnostics'TEN ÖNCE
    'server/matrix_diagnostics.lua'    -- ✅ EN SON (kilit nokta)
}

-- ★ Bestecinin İmzası ses dosyaları: bu repoda YOK (bkz. shared/config.lua
-- Config.ComposerSignature yorumu). Gerçek .ogg dosyalarınızı BURAYA
-- (resource kökünde 'sounds/') koyduğunuzda FiveM'in NUI köprüsü
-- (client/composer_intro.lua'nın cfx-nui-<resource>/... isteği) onları
-- servis edebilsin diye önceden bildiriliyor -- dosyalar yokken bu satır
-- zararsızdır (yalnızca "yayınlanabilir" bir yol listeler).
files {
    'sounds/*.ogg'
}

dependencies {
    'ox_lib',
    'qbx_core',
    'oxmysql',
    'ox_inventory',
    -- ★ KATMAN 7 [T4] FAZ 3: sokak "keş" NPC'sinde "Kadroya Kat (Ajan
    -- Devşir)" etkileşim seçeneği (client/hud.lua SpawnStreetNpc) için.
    'ox_target',
    -- ★ Bestecinin İmzası: özel .ogg dosyalarını (Config.ComposerSignature)
    -- çalmak için -- DOĞRULANMASI GEREKİR: xsound'un export imzası forka
    -- göre değişebilir, client/composer_intro.lua PlayUrl/Destroy'u
    -- pcall içinde çağırır (yanlış imza -> sessizce ses çalmaz, ÇÖKMEZ).
    -- Kurulum: https://github.com/Xanthenite/xsound -> resources/ klasörüne
    -- çıkarıp server.cfg'ye "start xsound" ekleyin.
    'xsound',
    -- ★ KATMAN 6: Trap house iç mekanı (client/trap_house_client.lua)
    -- GTA Online "düşük gelirli ev" interior'ını doğru render etmek için
    -- bu kaynağı kullanır (bkz. shared/config.lua Config.TrapHouseInterior.
    -- Shell yorumu).
    -- Kurulum: https://github.com/Bob74/bob74_ipl -> resources/ klasörüne
    -- çıkarıp server.cfg'ye "start bob74_ipl" ekleyin (bu satırdan ÖNCE
    -- veya bağımsız bir yerde olabilir, sıra kritik değildir).
    'bob74_ipl'
}