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

