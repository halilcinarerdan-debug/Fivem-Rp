# \# 🎯 vbs\_core\_matrix

# 

# \*\*Katman 1-8 Birleşik Motor\*\* — FiveM Qbox resource

# Adli balistik • Kartel hiyerarşisi • Karaborsa • Trap House • Mutfak • POLIS AI • Taktik HUD • Drive-By AI

# 

# \---

# 

# \## 📋 İçindekiler

# 

# 1\. \[Sistem Gereksinimleri](#-sistem-gereksinimleri)

# 2\. \[Zorunlu Bağımlılıklar](#-zorunlu-bağımlılıklar)

# 3\. \[Opsiyonel Bağımlılıklar](#-opsiyonel-bağımlılıklar)

# 4\. \[Kurulum Adımları](#-kurulum-adımları)

# 5\. \[xsound Kurulumu](#-xsound-kurulumu)

# 6\. \[ox\_inventory Item Tanımları](#-ox\_inventory-item-tanımları)

# 7\. \[Script Çakışma ve Temizlik](#-script-çakışma-ve-temizlik)

# 8\. \[Test Komutları](#-test-komutları)

# 9\. \[Bilinen Konular](#-bilinen-konular)

# 10\. \[Son Sürüm Notları](#-son-sürüm-notları)

# 

# \---

# 

# \## 🖥️ Sistem Gereksinimleri

# 

# | Bileşen | Minimum | Önerilen |

# |---------|---------|----------|

# | FXServer | 6683+ | 7290+ |

# | MariaDB | 10.6+ | 11.x |

# | Lua | 5.4 | 5.4 |

# | oxmysql | 2.7+ | 2.8+ |

# | ox\_lib | 3.30+ | son sürüm |

# 

# \---

# 

# \## 📦 Zorunlu Bağımlılıklar

# 

# Bu resource \*\*ÇALIŞMAZ\*\* olmadan. Hepsini `server.cfg`'de `ensure` sırasıyla yükle:

# 

# ```cfg

# \# === Core Framework ===

# ensure oxmysql

# ensure ox\_lib

# ensure qbx\_core

# 

# \# === Envanter ===

# ensure ox\_inventory

# 

# \# === Target (Street Dealing için) ===

# ensure ox\_target

# 

# \# === Ses (Radar parazit için) ===

# ensure pma-voice

# \# (veya) ensure mumble-voip

# 

# \# === vbs\_core\_matrix ===

# ensure vbs\_core\_matrix

---

## 🔐 Sandbox Komutları — Sivil / Örgüt-İçi / Sunucu-Supervisoru Ayrımı

Bu resource üç ayrı yetki katmanında komut çalıştırır. Hangi komutun hangi
katmanda olduğu **kod tarafından zorlanır** (`server/main.lua`
`Matrix.Security`), burada yalnızca dokümante edilir.

### 1) ZORUNLU sivil komutlar (oyuncunun KENDİ `player_state`'ine kilitli)

Bu komutlar hiçbir özel yetki gerektirmez — her bağlı oyuncu kullanabilir —
ama sonuçları **yalnızca çağıranın kendi verisini** etkiler; bir hedef
parametresi kabul etmezler (parametre enjeksiyonuna kapalıdır).

| Komut | Ne işe yarar | Lojistik/Kriminolojik karşılığı |
|---|---|---|
| `/telefonuyoket` | Çağıranın **kendi** DNA hattına ait şifreli mesajları ve mühürsüz siber delilleri tek atomik transaction ile kalıcı siler. `args[1]` artık tamamen yok sayılır (önceden bir hedef `dnaId` kabul ediyordu — bu, başka bir oyuncunun kanıtını silmeye izin veren bir parametre-enjeksiyon açığıydı, kapatıldı). | Bir telefonu/SIM kartı imha edip hattaki tüm mesaj geçmişini yok etmek. |
| `/opsecparola` | Bir trap house'un OPSEC parolasını değiştirir. *(Not: bu paylaşımlı bir örgüt kaynağını korur, bu yüzden bireysel değil örgüt-içi Leader/Logistics_Officer yetkisi ister — aşağıdaki 2. kategoriye bakın.)* | Ekip için ortak bir güvenli hat/şifre rotasyonu. |
| `/hud`, `/comintpanel`, `/taktikmenu` | Taktik HUD, COMINT paneli ve F10 Taktik Komuta Menüsü'nü aç/kapat. Salt arayüz — hiçbir sunucu durumu değiştirmez. | Telsiz/taktik ekranı açmak. |
| `/silahtahliye` | Çağıranın kendi elindeki sıkışmış silahı tahliye eder (mekanik tutukluk giderme). | Silah temizliği / tutukluk giderme. |
| `/muhafizcagir`, `/muhafizsalla` | Çağıranın kendi fiziksel muhafız/kurye takipçisini çağırır veya salar. | Kişisel korumanı yanına çağırmak. |

### 2) Örgüt-içi (Leader / Logistics_Officer rütbesi gerekir)

Bu komutlar admin **değildir** — oyunun kendi kartel hiyerarşisi
(`Matrix.Hierarchy.HasCommandAuthority`) tarafından korunur. Bir sunucu
yöneticisinin bunlara dokunmasına gerek yoktur; rütbesiz bir oyuncu
zaten reddedilir. En önemlileri: `/sevket`, `/muhimmatsevk`, `/rotaciz`
(çok-uğraklı sevkiyat — F10 menüsünden çağrılır), `/filoata`, `/filobirak`,
`/bagajyukle`, `/relaypurge`, `/botkilitac`, `/operatiftasfiye`,
`/panikiptal`, `/cetelideriata`, `/denetleyiciata`, `/opsecparola`.

`/rutbeata` (rütbe atama) bu kategorinin **kaynağıdır** ve ayrı, daha sıkı
bir kurala tabidir: yalnızca **mevcut bir Leader** (veya sunucu
supervisoru) rütbe atayabilir — ilk kurulumda hiç Leader yokken tek
istisna olarak ilk atama serbesttir (bootstrap). *(Önceden bu komutun HİÇBİR
kontrolü yoktu — herhangi bir oyuncu kendini Leader yapıp bu listedeki HER
kapıyı geçersiz kılabiliyordu; bu, bulunan en kritik açıktı.)*

`/davaac`, `/davasorgula` (dava açma/sorgulama) ve `/kanityukle` (kanıt
yükleme → doğrudan mahkumiyet) ayrı bir yetki modeli kullanır: **görevde
polis/şerif/LEO** (`Matrix.IsOnDutyPolice`) — kartel rütbesi değil.

### 3) YALNIZCA sunucu supervisorları (debug / test / simülasyon)

Bu komutların **hiçbiri** oynanış için gerekli değildir; hepsi test,
GM müdahalesi veya iç sistem hata ayıklaması içindir. Hepsi
`Matrix.Security.RegisterGatedCommand` üzerinden kayıtlıdır: FiveM'in
kendi native `restricted=true` ACE kapısı (`command.<isim>`) **ve** ayrı
bir Lua kontrolü (`group.admin` VEYA özel `command.matrix_supervisor`
principal'ı) ile çift katmanlı korunur. Yetkisiz bir tetikleme
`matrix_command_tamper_log` tablosuna işlenir.

**`server.cfg` kurulumu (gerekli!):** `restricted=true` olan bir komut,
çağıranın `command.<isim>` (veya bir üst kapsam olan `command`) ACE'ına
sahip olmasını FXServer seviyesinde ZORUNLU kılar — bu satırlar
`server.cfg`'ye eklenmezse **hiç kimse** (adminler dahil) bu komutları
çalıştıramaz:

```cfg
# Tüm restricted komutları group.admin'e aç (en basit kurulum):
add_ace group.admin command allow

# İSTEĞE BAĞLI: daha dar bir "matrix_supervisor" rolü tanımlamak isterseniz
# (tam admin olmayan ama bu resource'u yönetebilen personel için):
add_principal identifier.license:XXXXXXXX group.matrix_supervisor
add_ace group.matrix_supervisor command.matrix_supervisor allow
```

| Komut | Dosya | Ne işe yarar | Lojistik/Kriminolojik karşılığı |
|---|---|---|---|
| `/botyarat`, `/botspawn`, `/botdespawn` | main.lua | Sıfırdan bot kaydı oluşturur / dünyaya çıkarır / geri çeker (gerçek işe alım ekonomisini atlar). | Kağıt üzerinde personel oluşturmak (GM müdahalesi). |
| `/balistiktest`, `/botbalistik` | main.lua | Bir silah ateşlemesini/balistik kanıt zincirini simüle eder. | Laboratuvar test atışı. |
| `/botskill`, `/botbio`, `/botmekanik` | main.lua | Bir botun psikoloji/biyoloji/silah aşınma değerlerini doğrudan yazar. | Bir ajanın dosyasını elle değiştirmek. |
| `/radyoparazit` | main.lua | Herhangi bir kaynağa telsiz statiği uygular. | Telsiz karıştırma testi. |
| `/matrixdump`, `/fizikselsevk` | main.lua | Tüm botların/aktif sevkiyatların ham iç durumunu döker. | Tam sistem dökümü (denetim). |
| `/burokilitzorla`, `/baskinzorla`, `/baskinsonuclandir` | bureau.lua | Büro kilidini/baskınını zorla tetikler veya sonucunu elle belirler. | Baskın tatbikatı / sahte operasyon sonucu. |
| `/traphouseekle`, `/desifreekle`, `/propagandatetikle` | bureau.lua | Keyfi konumda trap house oluşturur; deşifre/propaganda sayaçlarını elle ilerletir. | Harita üzerinde saha kurulumu (GM). |
| `/dropsizintiekle`, `/dropsizintisifirla`, `/dropsizintidurum` | bureau.lua | Dead-drop adli sızıntı kayıtlarını enjekte/sıfırlar/döker (citizenid ifşası dahil). | Sahte delil senaryosu kurmak. |
| `/yayinbaslat`, `/yayinbitir` | bureau.lua | Canlı yayın durumunu test amaçlı başlatır/bitirir. | Yayın ekipmanı testi. |
| `/polisgenetigi` | bureau.lua | Bir memurun gizli dürüstlük/açgözlülük kişiliğini ifşa eder. | Personel gizli dosyası sorgusu. |
| `/aracele`, `/hasarver`, `/oldur` | logistics.lua | Bir aracı ele geçirir; bir bota hasar/ölüm uygular. | Araç müsaderesi / tatbikat kaybı. |
| `/guvengoster`, `/gecodeme` | logistics.lua | Bir oyuncu-toptancı güven ilişkisini gösterir/manipüle eder. | Tedarikçi güven denetimi. |
| `/dropdurum` | logistics.lua | Tüm açık dead-drop'ları (sahip citizenid dahil) döker. | Aktif operasyon listesi denetimi. |
| `/piyasasifirla` | market.lua | Bir bölgenin fiyat çarpanını sıfırlar. | Piyasa sıfırlama (ekonomi müdahalesi). |
| `/nakityatir`, `/nakitakla` | market.lua | Bir trap house'un kirli nakit/aklama durumunu uzaktan manipüle eder. | Kasayı elden düzenlemek. |
| `/gizliajandurum` | market.lua | Tüm gizli ajanları (undercover) listeler. | Gizli ajan listesi ifşası (yalnızca GM). |
| `/denetleyicidurum`, `/bolgeselrapor`, `/sokaksatisrapor` | market.lua | Bölge denetleyici/mali/sokak satışı iç verilerini döker. | Tam mali/personel denetimi. |
| `/kovantopla`, `/mobesehackle`, `/cctvkaydet`, `/kanitsabotaj` | forensics.lua | Keyfi konumdan kovan toplar; bölge CCTV geçmişini siler; sahte CCTV kaydı ekler; rüşvet akışını atlayıp kanıtı sabote eder. | Saha temizliği / delil karartma (yalnızca test). |
| `/forensicdump`, `/forensicrapor`, `/asinmaayarla` | forensics.lua | Balistik/kanıt kayıtlarını döker; silah aşınmasını elle ayarlar. | Laboratuvar dosyası sorgusu/düzenlemesi. |
| `/sorgu`, `/musterikaydet`, `/havuztara`, `/adaygoster`, `/baskiuygula`, `/sorgubitir`, `/sokakdevsir` | recruitment.lua | İşe alım/sorgu boru hattının tamamını (300sn bekleme dahil) anlık test eder. Dosyanın kendi başlığı: *"herkese açık test grubu"*. | İşe alım simülasyonu / sorgu tatbikatı. |
| `/mutfaktest`, `/dakikadongusu`, `/saatdongusu`, `/yakalatest`, `/kortizolsicramasi`, `/katmandurum`, `/katmantemizle` | kitchen.lua | Üretim/zaman döngülerini ve bot "bilgi maskesi"ni anlık test eder. | Üretim hattı hız testi. |
| `/interiordurum` | trap_house_interior.lua | Tüm trap house iç mekanlarındaki oyuncu/bot konumlarını döker. | Canlı konum denetimi. |
| `/hubata`, `/hublistele` | district_hubs.lua | Keyfi konumda satış hub'ı oluşturur/listeler. | Dağıtım merkezi kurulumu (GM). |
| `/karaborsagecmisi` | blackmarket.lua | Herhangi bir citizenid'in son 20 karaborsa işlemini döker. | Satın alma geçmişi denetimi. |
| `/rendezvousdurum` | rendezvous.lua | Tüm bekleyen buluşma/pusu durumunu döker. | Aktif randevu listesi denetimi. |
| `/matrix_run_diagnostics`, `/matrix_diag_detay` | matrix_diagnostics.lua | Tam/derin sistem tanılamasını çalıştırır ve dökümünü basar. | Sistem sağlık denetimi. |

**Kırma aleti (breaching_tool) notu:** `server/door_reinforcement.lua`'daki
yeni `/matrix:server:doorReinforcement:startBreach` mekaniği (F10'a
bağlanmaz, doğrudan net-event ile tetiklenir) bu listede DEĞİLDİR — o,
örgüt üyeliği ARANMAYAN, bilinçli olarak "dışarıdan" bir eylemdir
(rakip/polis bir kapıyı fiziksel bir alet ve gerçek mesafeyle zorlar).
Sunucu-otoritesi mesafe + envanter kontrolüyle sağlanır, ACE ile değil.

**Kapı Sürgü Tahkimatı — Qbox genel mağazasından satın alma:** F10
dialogunun yanı sıra, artık `server/door_reinforcement.lua` her seviye
için bir ox_inventory "kullanılabilir eşya" export'u kaydeder
(`kapi_tahkimat_seviye1/2/3`). Bu kalemleri kendi mağaza sisteminize
eklemeniz gerekir:

1. `ox_inventory/data/items.lua`'ya ekleyin:
   ```lua
   ['kapi_tahkimat_seviye1'] = { label = 'Kapı Tahkimat Kiti (Seviye 1)', weight = 5000,  stack = true, close = true },
   ['kapi_tahkimat_seviye2'] = { label = 'Kapı Tahkimat Kiti (Seviye 2)', weight = 8000,  stack = true, close = true },
   ['kapi_tahkimat_seviye3'] = { label = 'Kapı Tahkimat Kiti (Seviye 3)', weight = 12000, stack = true, close = true },
   ```
2. Genel mağaza tanımınıza (qbx_core/ox_inventory shop config) bu üç
   kalemi `Config.DoorReinforcement.Levels[n].price` (8000/22000/45000)
   ile AYNI fiyattan satılacak şekilde ekleyin — fiyatı burada
   değiştirirseniz mağazadaki fiyatı da güncelleyin, aksi halde
   ekonomi tutarsız olur.
3. Eşya kullanıldığında (`usingItem`), oyuncunun `Config.DoorReinforcement.
   ItemUseMaxDistanceMeters` (varsayılan 15m) içindeki EN YAKIN trap
   house'a otomatik kurulur — manuel ID girişi gerekmez. Ödeme mağazadan
   alınırken zaten yapıldığı için kurulum sırasında İKİNCİ bir ücret
   ALINMAZ. Kurulum başarısız olursa (örn. sıra dışı seviye atlama) eşya
   TÜKETİLMEZ, oyuncu onu kaybetmez.
4. ox_inventory'nin "kullanılabilir eşya" export sözleşmesi (`usingItem`
   event adı/argüman sırası) sürüme göre değişebilir — kod bunu pcall
   ile sarar (yanlış imza sessizce çalışmaz, ÇÖKMEZ). Kurulumdan sonra
   oyun içinde test edip eşya tüketilip seviye değişmiyorsa, kurulu
   ox_inventory sürümünüzün dokümantasyonunu kontrol edin.

**`Sandbox: ACE Privilege Verification` (matrix_diagnostics.lua):** Sunucu
her açıldığında, yukarıdaki üçüncü kategorideki (supervisor-only) HER
komutun gerçekten `RegisterGatedCommand` üzerinden kayıtlı olduğunu
doğrular. Biri eksikse ("hayalet debug komutu") kaynak açılışı
`Config.Diagnostics.AbortResourceOnSimulationFailure` ayarından BAĞIMSIZ
olarak sert şekilde durdurulur.

