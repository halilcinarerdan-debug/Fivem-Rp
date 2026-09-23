-- =====================================================================
-- MATRIX SERVER-ONLY SECRETS / server/config_secrets.lua
--
-- ★★★ KRİTİK: BU DOSYA fxmanifest.lua'DA YALNIZCA `server_scripts` İÇİNDE
-- OLMALIDIR -- ASLA `shared_scripts`'e TAŞIMAYIN. `shared_scripts`,
-- FiveM tarafından HEM sunucuya HEM DE HER BAĞLI CLIENT'A gönderilir;
-- burada tutulan apiKey gibi sırlar shared_scripts'e taşınırsa herhangi
-- bir oyuncu (Lua Executor/hile menüsü veya yalnızca client kaynak
-- önbelleğini inceleyerek) bunu doğrudan okuyabilir.
--
-- Bu dosya, `Config` global tablosunun (shared/config.lua tarafından
-- ZATEN oluşturulmuş) İÇİNE server-only alanlar ekler. shared/config.lua
-- fxmanifest.lua'da bu dosyadan ÖNCE yüklenir (shared_scripts her zaman
-- server_scripts'ten önce değerlendirilir), bu yüzden `Config` burada
-- her zaman mevcuttur.
-- =====================================================================

Config.AI_Matrix_Brain = {
    enabled                 = false,
    provider                = 'openai',
    apiKey                  = 'sk-...', -- ★ GERÇEK anahtarınızı YALNIZCA BURAYA yazın.
    analysisIntervalMinutes = 60,
    fallbackToDeterministic = true
}
