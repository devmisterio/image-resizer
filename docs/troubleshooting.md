# Sorun Giderme

Bu projenin teslimat zincirinde karşılaşılan hataların teşhis rehberi. Çoğu fiilen alınmış;
bir kısmının (#5, #7) mekanizması canlı ortamda doğrulanabiliyor ancak bu repoda alındığı
kanıtlanamıyor — kataloğun "Durum" sütunu bu ayrımı taşır. Her bölüm bir belirtiden başlar,
kök nedene iner ve çalıştırılabilir bir doğrulama komutu verir.

Buradaki komutlar `rg-imgresizer-dev` üzerinde 2026-08-15 ve 2026-08-16'da çalıştırılıp
doğrulanmıştır.
Kararların gerekçeleri [decisions.md](decisions.md), kimlik kurulumu [bootstrap.md](bootstrap.md).

Aksi belirtilmedikçe tüm komutlar salt-okunurdur. Durum değiştirenler `[YAZAR]` ile işaretlidir.

> **`az monitor app-insights query` tuzağı:** komut zaman aralığını sunucuya ayrı bir parametre
> olarak gönderir ve `--offset` varsayılanı **1 saattir**. KQL içine yazılan `ago(1d)` bu pencereyi
> genişletmez; ikisinin kesişimi alınır ve sorgu sessizce boş döner. Bu dokümandaki App Insights
> sorguları bu yüzden açık `--offset` ile verilmiştir; aralığı kendi olayınıza göre büyütün.
>
> Aynı komutta `-o table` de boş basar (yanıt bir `tables` zarfıdır, tablo biçimlendirici düz
> satır bulamaz). Çıktı için `-o json` kullanın — bu yüzden buradaki örneklerin hepsi öyle.

---

## Teslimat zinciri ve hata noktaları

```
  blob PUT            System Topic              Function host                ImageSharp
 uploads/x.jpg ─────► egst-imgresizer-dev ────► /runtime/webhooks/blobs ───► ResizeImage ───► thumbnails/x.jpg
      │                     │                          │                          │
      │                     │                          │                          └─ #2  403 AuthorizationPermissionMismatch
      │                     │                          └─ #5  hedef tipi WebHook değilse abonelik hiç kurulmaz
      │                     │                             #6  fonksiyon yoksa handshake 404
      │                     │                             #8  HTTP 200 = handshake, 202 = gerçek olay
      │                     └─ MatchedEventCount = 0  → subjectBeginsWith filtresi
      │                        DroppedEventCount > 0  → 3 deneme tükendi, dead-letter yok
      └─ Kod hiç deploy edilmediyse zincirin tamamı sessizdir → #1 #3 #4
```

## Triyaj: "thumbnail üretilmiyor"

```
                        Fonksiyon runtime'da kayıtlı mı?
                        az functionapp function list ...
                                     │
                 ┌───────────────────┴───────────────────┐
             boş liste                            ResizeImage var
                 │                                       │
        Kod deploy edilmemiş                 Webhook isteği App Insights'ta var mı?
        → #1 (plan/runtime), #3 (415),       requests | POST /runtime/webhooks/blobs
           #4 (ilk publish 502)                          │
                                    ┌────────────────────┼────────────────────┐
                              hiç istek yok        yalnızca 200            202 var
                                    │                    │                    │
                          Event Grid göndermedi   Abonelik kuruldu,   Olay kabul edildi,
                          → #5, #6 + EG metrikleri olay eşleşmiyor    hata fonksiyon içinde
                                                  → filtre / #8        → #2, ImageSharp, OOM
```

---

## 0. Ön koşul: `az functionapp show` alanları null geliyor

Bu, aşağıdaki her teşhisin önüne geçer. Yanlış bir "null" okuması, sağlıklı bir sistemi
bozuk gösterir.

**BELİRTİ**

```console
$ az functionapp show -g rg-imgresizer-dev -n func-imgresizer-dev \
    --query "{sku:sku, state:state, fac:functionAppConfig}" -o json
{ "fac": null, "sku": null, "state": null }
```

**KÖK NEDEN** — Alanlar eksik değil, bir seviye derinde. az CLI 2.88.0 bu çağrıyı
`api-version=2023-12-01` ile yapıyor (`az functionapp show --debug 2>&1 | grep -o "api-version=[0-9-]*"`)
ve yanıtı düzleştirmeden ham ARM zarfı olarak veriyor: üst seviyede yalnızca
`id, name, type, location, kind, identity, resourceGroup, properties` var. Alışkanlıkla
yazılan `--query sku` üst seviyeye bakar ve null döner.

Not: eski API sürümü `functionAppConfig`'i **döndürüyor** — yani sorun sürüm boşluğu değil,
çıktı şekli. "az eski API kullandığı için alan yok" açıklaması bu makinede **doğrulanamadı**.

**ÇÖZÜM** — İki yol var; ikincisi tercih edilir.

```bash
# 1) Aynı komut, doğru yol
az functionapp show -g rg-imgresizer-dev -n func-imgresizer-dev \
  --query "{sku:properties.sku, state:properties.state, runtime:properties.functionAppConfig.runtime}" -o json

# 2) ARM'a doğrudan, api-version sabitlenmiş — CLI sürümünden bağımsız kararlı şekil
SUB=cd419795-c7f9-4616-90e3-e1e1a56f8b16
az rest --method get \
  --url "https://management.azure.com/subscriptions/$SUB/resourceGroups/rg-imgresizer-dev/providers/Microsoft.Web/sites/func-imgresizer-dev?api-version=2024-11-01" \
  --query "{sku:properties.sku, state:properties.state, runtime:properties.functionAppConfig.runtime}" -o json
```

Doğrulanmış çıktı: `{"sku": "FlexConsumption", "state": "Running", "runtime": {"name": "dotnet-isolated", "version": "10.0"}}`

`az appservice plan show` bu sorundan etkilenmez — `sku.tier`/`sku.name` düzleşmiş gelir
(`FlexConsumption`/`FC1`); yalnızca `reserved` null döner. Plan SKU kontrolü için yeterlidir.

---

## Hata kataloğu

| # | Belirti | Katman | Durum |
|---|---|---|---|
| 1 | `Failed to perform sync trigger — malformed content`, SCM 503 | Hosting planı (Y1) | Kapatıldı — FC1 |
| 2 | `AuthorizationPermissionMismatch` (403) | Managed Identity / storage RBAC | Kapatıldı |
| 3 | `POST /api/publish?type=zip → 415` | Deployment komutu | Kapatıldı — `config-zip` |
| 4 | İlk publish 502, SCM aynı anda 200 | Kudu deployment backend | Kapatıldı |
| 5 | `Unsupported Azure Function Trigger` | Event Grid hedef tipi | Önlem alındı (WebHook) — bu repoda alındığı doğrulanamadı |
| 6 | `Endpoint validation: Destination endpoint not found` | Deployment sırası | Kapatıldı — sıra zorunlu |
| 7 | `MissingSubscriptionRegistration` | Subscription önkoşulu | Önlem alındı (bootstrap) — bu repoda alındığı doğrulanamadı |
| 8 | Abonelik `Succeeded`, thumbnail yok | Teşhis sinyali (200 vs 202) | Referans |

---

### #1 — Sync trigger başarısız / SCM 503

**BELİRTİ**

```
Failed to perform sync trigger — Function app may have malformed content
```
SCM tarafında eşzamanlı 503. Aynı zip, aynı komut, tekrar tekrar başarısız.

**KÖK NEDEN** — .NET 10, Linux Consumption (Y1) hariç tüm planlarda desteklenir. Terraform ve
Azure CLI bu kombinasyonu **yazmaya** izin verir, platform **çalıştıramaz**. Konfigürasyon
anında hata alınmadığı için sorun deployment aşamasına ötelenir ve "malformed content" gibi
paketi işaret eden, tamamen alakasız bir mesajla yüzeye çıkar.

Eski Terraform tanımı bu ikiliyi yan yana kabul ediyordu: `git show 3494313:infra/main.tf`
→ `sku_name = "Y1"` (satır 88) ve `dotnet_version = "10.0"` (satır 106). Y1 ayrıca Azure Files
content share zorunlu kıldığı için `WEBSITE_CONTENTAZUREFILECONNECTIONSTRING` ile plaintext
storage key'i app settings'e sokuyordu (aynı dosya, satır 118-119).

Bu hata ailesinin peşinde harcanan denemeler git geçmişinde okunabilir: `42bc84a` ZipDeploy,
`15ebbee` `func publish`, `f7f2599` functions-action, `b0f1ca2` ZipDeploy, `0a9a20e`
`az functionapp deploy`, `d06ac3c` content share geri alma. Hepsi yanlış katmanda.

**NASIL DOĞRULARSIN** — Önce plan, sonra runtime. İkisi farklı yerlerden okunur, uyumsuzluk
kolay kaçar.

```bash
az appservice plan show -g rg-imgresizer-dev -n asp-imgresizer-dev \
  --query "{tier:sku.tier, name:sku.name}" -o json
# Beklenen: {"tier": "FlexConsumption", "name": "FC1"}
# tier=Dynamic veya name=Y1 + .NET 10 → teşhis burada biter, başka adım denemeyin.
```

Y1 kalıntısı app setting'ler Flex'te **bulunmamalıdır**:

```bash
az functionapp config appsettings list -g rg-imgresizer-dev -n func-imgresizer-dev \
  --query "[?starts_with(name,'WEBSITE_') || name=='FUNCTIONS_WORKER_RUNTIME' || name=='FUNCTIONS_EXTENSION_VERSION'].name" -o tsv
# Beklenen: boş çıktı. Canlıda yalnızca 2 setting var:
# AzureWebJobsStorage__accountName, APPLICATIONINSIGHTS_CONNECTION_STRING
```

**ÇÖZÜM** — Plan FC1/FlexConsumption ([infra/resources.bicep](../infra/resources.bicep), satır
79-91, `reserved: true`), runtime `functionAppConfig.runtime` altında (satır 122-125) — app
setting olarak değil. Yasaklı setting listesi aynı dosyanın 93-96. satırlarında yorum olarak
duruyor. Aynı kod ve aynı deployment komutu, yalnızca plan değişince ilk denemede çalıştı
(commit `1ebe806`; [decisions.md](decisions.md) "Hosting: Flex Consumption").

> Tam hata metinleri yalnızca [decisions.md](decisions.md) satır 10-11'de kayıtlı; ham CI/Azure
> log çıktısı repoda yok. Olayın yaşandığı commit mesajıyla doğrulanıyor, metinlerin birebir
> doğruluğu **doğrulanamadı**.

---

### #2 — 403 AuthorizationPermissionMismatch

**BELİRTİ** — Fonksiyon tetikleniyor, blob işlemi düşüyor:

```
Azure.RequestFailedException: This request is not authorized to perform this operation
using this permission. Status: 403 ... ErrorCode: AuthorizationPermissionMismatch
```

Host'un retry back-off'u nedeniyle aralık her denemede ikileyerek tekrarlar (~1.6 sn'den
başlayıp ~120 sn'de tavana oturur) — aşağıdaki kapanış notunda canlı ölçüm var.

**KÖK NEDEN** — Managed Identity'nin storage veri rolü eksik ya da atanmış olsa bile RBAC
propagasyonu tamamlanmamış. Kritik ayrım: **control-plane** (`az role assignment list`) atamayı
anında `Succeeded` gösterir, **data-plane** token'ı birkaç dakika eski yetkiyle gelir. Bu yüzden
"rol duruyor ama çağrı 403" tablosu normaldir ve yanıltıcıdır.

Arayışın izi: `cce2de2` (GitHub SP'ye Blob Data Contributor), `adca4bd` (propagasyon beklemesi
+ retry), `ec570d4` (rolü Owner'a yükseltme).

**NASIL DOĞRULARSIN**

```bash
PID=$(az functionapp show -g rg-imgresizer-dev -n func-imgresizer-dev --query identity.principalId -o tsv)
SUB=cd419795-c7f9-4616-90e3-e1e1a56f8b16

az role assignment list --assignee "$PID" \
  --scope "/subscriptions/$SUB/resourceGroups/rg-imgresizer-dev/providers/Microsoft.Storage/storageAccounts/stimgresizerdev" \
  --query "[].roleDefinitionName" -o tsv
```

Beklenen tam olarak üç satır: `Storage Blob Data Owner`, `Storage Queue Data Contributor`,
`Storage Table Data Contributor`. Sayı üçten farklıysa teşhis oradadır.

Hata kodunu ayırt et — hepsi 403 döner ama farklı şeylerdir:

```bash
az monitor app-insights query --app appi-imgresizer-dev -g rg-imgresizer-dev --offset 30d \
  --analytics-query "exceptions | project timestamp, type, outerMessage | order by timestamp desc" -o json
```

`AuthorizationPermissionMismatch` → rol eksik veya propagate olmamış.
`AuthenticationFailed` / `InvalidAuthenticationInfo` → kimlik hiç oluşmamış ya da connection
string kalıntısı var; bu bölüm değil, [Program.cs](../src/ImageResizeFunction/Program.cs) satır
13-30'daki storage istemci seçimi bakılacak yer.

**ÇÖZÜM** — Roller [infra/resources.bicep](../infra/resources.bicep) satır 148-158'de
`guid(storage.id, functionApp.id, roleId.value)` ile deterministik atanır; tekrar deploy yeni
atama üretmez. CD'de bilinçli bir bekleme yoktur: roller `infra` job'ında, kod deploy'u ayrı bir
`deploy` job'ında çalıştığı için araya doğal gecikme girer ([.github/workflows/cd.yml](../.github/workflows/cd.yml),
satır 18 ve 46). Kalıcı 403'te `az functionapp restart` ile host'un token cache'i tazelenir. `[YAZAR]`

> Bu maddenin canlı telemetri kanıtı duruyor ve sorgulanabilir. `--offset 30d` ile
> `appi-imgresizer-dev` üzerinde 29 adet `Azure.RequestFailedException` kaydı dönüyor
> (`ErrorCode: AuthorizationPermissionMismatch`, 2026-08-10T21:56:16Z – 22:26:07Z arası).
> Kayıtların zaman farkları back-off'u birebir gösteriyor: 1.6 → 2.5 → 4.6 → 8.6 → 16.6 → 32.7 →
> 64.6 sn diye ikileyerek açılıyor, sonra ~120 sn'de tavana oturuyor. Dizi bir kez baştan başlıyor
> (host yeniden başladığında sayaç sıfırlanır), bu yüzden 29 kayıt iki seri hâlinde okunur.
>
> Varsayılan `--offset` (1 saat) ile aynı sorgu 0 satır döner — bu, verinin silindiği değil,
> pencerenin dar olduğu anlamına gelir.

---

### #3 — 415 Unsupported Media Type

**BELİRTİ**

```
POST /api/publish?type=zip → 415 Unsupported Media Type
```

Etrafındaki 5 denemelik retry döngüsü hatayı 2.5 dakika geciktirip
`Attempt N failed; deployment backend may still be initializing.` mesajı ürettiği için sorun
uzun süre "geçici/timing" sanıldı.

**KÖK NEDEN** — Gönderilen `Content-Type` ile Flex One Deploy endpoint'inin kabul ettiği tip
uyuşmuyor. `az functionapp deploy` içerik tipini hangi kaynak bayrağını verdiğinize göre seçer
(azure-cli 2.88.0, `appservice/custom.py:11363-11364`):

```python
if params.src_path:    content_type = 'application/octet-stream'
elif params.src_url:   content_type = 'application/json'
```

CD `--src-path` kullanıyordu, yani kabloya çıkan tip `application/octet-stream` idi. Flex
Consumption'ın One Deploy endpoint'i bu tipi kabul etmiyor. Aynı endpoint'e aynı token ve aynı
paketle, yalnızca Content-Type değiştirilerek yapılan izolasyon testi kök nedeni tek başına
gösteriyor:

```
POST /api/publish?type=zip
  Content-Type: application/octet-stream  → 415 Unsupported Media Type
  Content-Type: application/zip           → 202 Accepted
```

Yani CI ortamı ya da zamanlama sorunu değil. `az functionapp deploy`'un preview olması ayrı bir
olgudur (`--help` çıktısı bugün de preview uyarısı basıyor) ve **415'in kök nedeni değildir**.

**NASIL DOĞRULARSIN** — Kabloya çıkan tipi oku; `--src-path` yolunda `application/octet-stream`
görmelisiniz:

```bash
az functionapp deploy -g rg-imgresizer-dev -n func-imgresizer-dev \
  --src-path app.zip --type zip --debug 2>&1 | grep -iE "content-type|415"   # [YAZAR]
```

**ÇÖZÜM** — `az functionapp deployment source config-zip` ([.github/workflows/cd.yml](../.github/workflows/cd.yml),
satır 76-79). Flex planını algılayıp aynı One Deploy yolunu doğru Content-Type ile kullanır,
ayrıca sync trigger'ları bekler ve app health kontrolü yapar. Retry döngüsü kaldırıldı
(`git show 39f4077 -- .github/workflows/cd.yml`).

> **Tuzak:** [README.md](../README.md) satır 68'deki manuel kurulum adımı hâlâ
> `az functionapp deploy --src-path app.zip --type zip` yazıyor — yani 415 üreten çağrının kendisi.
> CD ve [decisions.md](decisions.md) `config-zip` diyor. README'yi takip eden biri çözülmüş bir
> hatayı yeniden üretir.

---

### #4 — İlk publish 502 (SCM aynı anda 200)

**BELİRTİ** — Yeni oluşturulmuş bir Function App'e yapılan ilk publish çağrısı 502 döner.
Yanıltıcı kısım: aynı anda `https://func-imgresizer-dev.scm.azurewebsites.net/api/deployments`
HTTP 200 verir. "SCM ayakta mı" pollaması hazır der, publish yine de düşer.

**KÖK NEDEN** — Flex Consumption'da SCM sitesinin yanıt vermesi ile deployment backend'inin
(One Deploy işleyicisi) hazır olması ayrı olaylardır. SCM 200 yanlış bir hazırlık sinyalidir.
Bu yanlış sinyalin peşinden gidilen üç deneme: `6fb612c` (sleep 30 + restart + sleep 15),
`d58e4ab` (SCM `/api/deployments` smart polling), `39f4077` (hepsinin kaldırılması).

**NASIL DOĞRULARSIN** — İki sinyali ayrı ayrı ölç; aynı anda çelişiyorlarsa imza budur.

```bash
TOKEN=$(az account get-access-token --resource https://management.azure.com --query accessToken -o tsv)
curl -s -o /dev/null -w "SCM=%{http_code}\n" -H "Authorization: Bearer $TOKEN" \
  https://func-imgresizer-dev.scm.azurewebsites.net/api/deployments

az functionapp show -g rg-imgresizer-dev -n func-imgresizer-dev --query properties.state -o tsv   # Running
```

**ÇÖZÜM** — SCM'i pollama. `config-zip` kendi içinde sync trigger'ları bekleyip app health
kontrolü yaptığı için bu pencereyi kapatır. Retry gerekiyorsa proxy sinyaline değil, publish
çağrısının kendisine eklenir ([decisions.md](decisions.md) "Deployment komutu: `config-zip`").

> 502'nin tam metni hiçbir yerde kayıtlı değil. Tek kanıt `git show 1ebe806:.github/workflows/cd.yml`
> satır 70-73'teki yorum ("ilk çağrı ... 502 dönebilir"), o da parafraze. Belirti tarifi güvenilir,
> tam hata metni **doğrulanamadı**; app zaten mevcut olduğu için yeniden üretilemez.

---

### #5 — Unsupported Azure Function Trigger

**BELİRTİ** — Event subscription oluşturulurken:

```
Unsupported Azure Function Trigger ... Azure Event Grid supports EventGrid Trigger type only.
```

**AYRIM** — `[BlobTrigger] + Source = BlobTriggerSource.EventGrid` bir EventGrid trigger
**değildir**; Event Grid kaynaklı beslenen bir blob trigger'dır. Event Grid'in
`endpointType: 'AzureFunction'` hedefi yalnızca `[EventGridTrigger]` imzalı fonksiyonları kabul
eder, dolayısıyla bu projede hedef `WebHook` olmak zorundadır. Gerekçe ve değerlendirilen
alternatif: [decisions.md](decisions.md) "Event Grid hedefi: WebHook". Hedef URL'inin
`Host.Functions.` öneki ve `code` (system key) parçaları
[infra/eventgrid.bicep](../infra/eventgrid.bicep) satır 44-53'te yorumlu olarak duruyor.

**NASIL DOĞRULARSIN** — Hedef tipini oku:

```bash
az eventgrid system-topic event-subscription show -g rg-imgresizer-dev \
  --system-topic-name egst-imgresizer-dev -n sub-uploads-to-resizeimage \
  --query "{tip:destination.endpointType, durum:provisioningState}" -o json
# Beklenen: {"tip": "WebHook", "durum": "Succeeded"}   — "AzureFunction" görürsen yanlış.
```

Karşı taraftan da doğrula — binding `blobTrigger` + `EventGrid` olmalı, `eventGridTrigger` değil:

```bash
az functionapp function list -g rg-imgresizer-dev -n func-imgresizer-dev \
  --query "[].{name:name, trigger:config.bindings[0].type, source:config.bindings[0].source}" -o table
# func-imgresizer-dev/ResizeImage  blobTrigger  EventGrid
```

> Bu hatanın bu repoda fiilen alındığına dair commit, CI log'u veya Azure kaydı **bulunamadı**;
> metin yalnızca [decisions.md](decisions.md) satır 44'te geçiyor. Mekanizma canlı abonelikle
> doğrulanıyor (hedef tipi WebHook), hatanın burada yaşandığı **doğrulanamadı**.

---

### #6 — Endpoint validation: Destination endpoint not found

**BELİRTİ**

```
az deployment group create --template-file infra/eventgrid.bicep
→ Endpoint validation: Destination endpoint not found
```

Genellikle "Event Grid çalışmıyor" diye teşhis edilir; oysa sorun sıradadır.

**KÖK NEDEN** — Event Grid, abonelik kurarken hedef endpoint'e bir doğrulama handshake'i
gönderir. Hedef URL `?functionName=Host.Functions.ResizeImage` içerdiği için runtime'ın o
fonksiyonu tanıması gerekir; fonksiyon ise ancak uygulama kodu deploy edilince var olur.
Altyapı ile kod arasında `eventgrid.bicep` çalıştırılırsa handshake 404 alır. Event Grid
tanımının ayrı dosyada tutulmasının sebebi budur, düzen tercihi değil.

**NASIL DOĞRULARSIN** — Abonelikten önce fonksiyonun runtime'da gerçekten var olduğunu kontrol
et. Boş liste dönüyorsa `eventgrid.bicep`'i çalıştırma:

```bash
az functionapp function list -g rg-imgresizer-dev -n func-imgresizer-dev --query "[].name" -o tsv
# Beklenen: func-imgresizer-dev/ResizeImage
```

Webhook'u elle yokla — 404 gelirse hedef henüz yoktur:

```bash
KEY=$(az functionapp keys list -g rg-imgresizer-dev -n func-imgresizer-dev --query systemKeys.blobs_extension -o tsv)
curl -s -o /dev/null -w "%{http_code}\n" -X POST \
  "https://func-imgresizer-dev.azurewebsites.net/runtime/webhooks/blobs?functionName=Host.Functions.ResizeImage&code=$KEY"
```

**ÇÖZÜM** — Sıra zorunludur:

```
1. infra/main.bicep      → altyapı, Function App
2. dotnet publish + zip  → ResizeImage fonksiyonu runtime'da oluşur
3. infra/eventgrid.bicep → system topic + subscription
```

CD'de bu, ayrı `infra`/`deploy` job'ları ve `config-zip`'ten **sonra** gelen "Connect Event Grid"
adımıyla sağlanıyor ([.github/workflows/cd.yml](../.github/workflows/cd.yml), satır 74-87).
CI'da `eventgrid.bicep` aynı sebeple what-if kapsamı dışında, yalnızca `bicep build` ediliyor
([.github/workflows/ci.yml](../.github/workflows/ci.yml), satır 24 ve 33-40).

**İkinci tuzak:** `functionName` parametresi ([infra/eventgrid.bicep](../infra/eventgrid.bicep),
satır 16) ile C# tarafındaki `[Function(nameof(ResizeImage))]`
([ResizeImage.cs](../src/ImageResizeFunction/ResizeImage.cs), satır 11) birebir aynı olmalıdır.
Yeniden adlandırma yapılırsa sıra doğruyken de aynı hata alınır.

> Hatanın alındığına dair CI çalışması veya başarısız deployment kaydı **bulunamadı**; RG
> geçmişinde yalnızca 2 `Succeeded` kayıt var. Sıralama zorunluluğu koda ve yorumlara dayanıyor.
>
> Ayrıca: `eventgrid.bicep` erken çalıştırıldığında hatanın önce nerede oluşacağı belirsiz.
> `listKeys(.../host/default).systemKeys.blobs_extension` (satır 52) fonksiyon deploy edilmemişken
> null dönebilir ve şablon endpoint validation'a gelmeden düşebilir. Hangisinin önce geldiği
> **test edilmedi** — test etmek canlı altyapıyı değiştirirdi.
>
> Not: [decisions.md](decisions.md) satır 77 hedefi ARM `functions/ResizeImage` kaynağı olarak
> tarif ediyor; canlı implementasyon bir WebHook URL'i. Sıralama zorunluluğu her iki okumada da
> geçerli, mekanizma webhook handshake'idir.

---

### #7 — MissingSubscriptionRegistration

**BELİRTİ** — RG deployment geçmişinde, kimsenin başlatmadığı başarısız bir kayıt:

```
MissingSubscriptionRegistration: The subscription is not registered to use
namespace 'Microsoft.AlertsManagement'
```

Uygulama sorunsuz çalışır; sadece geçmişi kirletir ve gerçek hataları ararken gürültü yaratır.

**KÖK NEDEN** — Application Insights bileşeni oluşturulduğunda Azure otomatik olarak bir
"Failure Anomalies" smart detection kuralı provision etmeye çalışır. Kural
`Microsoft.AlertsManagement` namespace'ine aittir; provider kayıtlı değilse otomatik deployment
başarısız olur. Kaynak IaC şablonunda görünmediği için nereden geldiği anlaşılmaz.

**NASIL DOĞRULARSIN**

```bash
az provider show --namespace Microsoft.AlertsManagement --query registrationState -o tsv   # Registered

az deployment group list -g rg-imgresizer-dev \
  --query "[].{name:name, state:properties.provisioningState, ts:properties.timestamp}" -o table
```

Başarısız bir kaydın detayı için:

```bash
az deployment operation group list -g rg-imgresizer-dev --name <failedDeploymentName> \
  --query "[?properties.provisioningState=='Failed'].properties.statusMessage"
```

**ÇÖZÜM** — Subscription başına bir kez: `az provider register --namespace Microsoft.AlertsManagement --wait`.
Bu bir uygulama hatası değil, subscription önkoşuludur; bu yüzden IaC'de değil
[bootstrap.md](bootstrap.md) satır 27-36'da durur. `[YAZAR]`

> Başarısız kayıt RG geçmişinde artık görünmüyor ve provider `Registered`. Hatanın gerçekten
> yaşandığı mı yoksa geçmişin RG yeniden oluşturulurken mi sıfırlandığı **ayırt edilemiyor**;
> kanıt commit `5cf5941` mesajı ve RG'de duran "Application Insights Smart Detection" action
> group'unun varlığıyla sınırlı.

---

### #8 — Abonelik `Succeeded` ama thumbnail üretilmiyor: 200 vs 202

Bu bir hata değil, bu projedeki en değerli tekrarlanabilir teşhis sinyali.

App Insights'ta `POST /runtime/webhooks/blobs` iki farklı kodla görünür:

| Kod | Anlamı | Devamı |
|---|---|---|
| **200** | Event Grid abonelik doğrulama handshake'i | Invocation **takip etmez**. Abonelik her kurulduğunda/yenilendiğinde görülür. |
| **202** | Gerçek `BlobCreated` olayının kabulü | ~1 sn içinde bir `ResizeImage` invocation'ı takip **etmelidir**. |

**Süre bir teşhis sinyali değildir.** 2026-08-14 – 08-15 penceresindeki canlı `requests` verisinde
handshake'ler (200) 44.7 ms ile 1076.5 ms arasında, gerçek olaylar (202) 313.4 ms ile 1356.4 ms
arasında ölçüldü — aralıklar iç içe geçiyor, bir handshake bir olaydan uzun sürebiliyor. Tek
ayırt edici şey durum kodu ve arkasından invocation gelip gelmediğidir.

Bu ayrım "abonelik Succeeded ama çıktı yok" şikâyetini üç dala böler:

```
webhook isteği hiç yok  → Event Grid göndermedi        → filtre/abonelik tarafı, EG metrikleri
sadece 200, 202 yok     → abonelik doğrulandı, olay     → subjectBeginsWith yanlış container'ı
                          eşleşmiyor                       gösteriyor (eventgrid.bicep:63)
202 var, invocation yok → olay kabul edildi, hata       → #2 (403), ImageSharp, OOM
                          fonksiyonun içinde
```

**SORGU**

```bash
az monitor app-insights query --app appi-imgresizer-dev -g rg-imgresizer-dev --offset 3d \
  --analytics-query "requests | project timestamp, name, resultCode, success, duration | order by timestamp asc" -o json
```

Uçtan uca korelasyon ve hata tarafı:

```bash
az monitor app-insights query --app appi-imgresizer-dev -g rg-imgresizer-dev --offset 3d \
  --analytics-query "traces | where message contains 'thumbnail' | project timestamp, message, operation_Id | order by timestamp desc" -o json

az monitor app-insights query --app appi-imgresizer-dev -g rg-imgresizer-dev --offset 3d \
  --analytics-query "exceptions | project timestamp, type, outerMessage, operation_Id | order by timestamp desc" -o json
```

Zaman aralığını KQL'e değil `--offset`'e yazın — sebebi dokümanın başındaki tuzak notunda.
`--offset` yerine `--start-time`/`--end-time` de kullanılabilir; ikisi birden verilirse
`--offset` yok sayılır.

**SAĞLIKLI ÖRÜNTÜ** — 2026-08-15'te canlıdan alınan gerçek dizi:

```
10:53:08.073  POST /runtime/webhooks/blobs   202   1356 ms   ← olay kabul edildi
10:53:09.577  ResizeImage                      0    567 ms   ← invocation, success=True
10:53:10.115  trace: "cd-verified.jpg için thumbnail başarıyla oluşturuldu."
11:08:27.633  POST /runtime/webhooks/blobs   200     45 ms   ← handshake; eventgrid
                                                               deployment 11:08:38'de bitti
```

`ResizeImage` satırındaki `resultCode: 0` normaldir — HTTP kodu değil, invocation sonucudur.
Log metinleri [ResizeImage.cs](../src/ImageResizeFunction/ResizeImage.cs) satır 20 ve 40'tan gelir.

`host.json`'da `telemetryMode: OpenTelemetry` olmasına rağmen klasik App Insights tabloları
(`requests`, `traces`, `exceptions`, `dependencies`) doluyor ve sorgulanabiliyor
([host.json](../src/ImageResizeFunction/host.json), satır 3). Ayrı bir OTel şeması öğrenmeye gerek yok.

`az monitor app-insights query` için `application-insights` extension'ı gerekir:
`az extension add -n application-insights`.

---

## Genel teşhis seti

Üç komut, hatayı katmana indirger: deployment mi olmadı, fonksiyon mu kayıtlı değil, olay mı
teslim edilmedi.

### 1. Deployment durumu

```bash
# Kod deployment'ları — status=4 → Success. Flex'te message/status_text boş gelir, normaldir.
az functionapp log deployment list -g rg-imgresizer-dev -n func-imgresizer-dev \
  --query "[].{status:status, end:end_time, complete:complete}" -o table

# Son deployment'ın logu
az functionapp log deployment show -g rg-imgresizer-dev -n func-imgresizer-dev

# Aynı bilgi SCM'den, tek kayıt hâlinde
TOKEN=$(az account get-access-token --resource https://management.azure.com --query accessToken -o tsv)
curl -s -H "Authorization: Bearer $TOKEN" \
  https://func-imgresizer-dev.scm.azurewebsites.net/api/deployments/latest

# Altyapı deployment'ları (ARM tarafı)
az deployment group list -g rg-imgresizer-dev \
  --query "[].{name:name, state:properties.provisioningState, ts:properties.timestamp}" -o table
```

Canlı referans: 3 kod deployment'ı (status=4, `deployer: az_cli`), 2 ARM deployment'ı
(`resources`, `eventgrid` — ikisi de `Succeeded`).

### 2. Fonksiyon kayıtlı mı

```bash
az functionapp function list -g rg-imgresizer-dev -n func-imgresizer-dev \
  --query "[].{name:name, trigger:config.bindings[0].type, source:config.bindings[0].source, path:config.bindings[0].path}" -o table
```

Boş liste = sync trigger olmamış, kod runtime'a ulaşmamış. Bu durumda Event Grid'e bakmanın
anlamı yok; `eventgrid.bicep` de çalıştırılmamalı (#6).

Flex konfigürasyonunun bütünü — `properties.` önekini unutma (#0):

```bash
az functionapp show -g rg-imgresizer-dev -n func-imgresizer-dev --query properties.functionAppConfig -o json
```

### 3. Event Grid teslim ediyor mu

```bash
TOPIC="/subscriptions/cd419795-c7f9-4616-90e3-e1e1a56f8b16/resourceGroups/rg-imgresizer-dev/providers/Microsoft.EventGrid/systemTopics/egst-imgresizer-dev"

az monitor metrics list --resource "$TOPIC" \
  --metrics MatchedEventCount DeliverySuccessCount DeliveryAttemptFailCount DroppedEventCount \
  --aggregation Total --interval PT1H --filter "EventSubscriptionName eq '*'" \
  --start-time 2026-08-15T08:00:00Z \
  --query "value[].{metric:name.value, points:timeseries[0].data[?total>\`0\`].[timeStamp,total]}" -o json
```

Yorumlama:

| Gözlem | Anlam |
|---|---|
| `MatchedEventCount = 0` | Filtre eşleşmiyor — `subjectBeginsWith` yanlış container'ı gösteriyor ([infra/eventgrid.bicep](../infra/eventgrid.bicep), satır 63) |
| `MatchedEventCount > 0`, `DeliverySuccessCount = 0`, `DeliveryAttemptFailCount > 0` | Webhook reddediyor — yanlış `code`, eksik `Host.Functions.` öneki, veya fonksiyon yok |
| `DroppedEventCount > 0` | 3 deneme tükendi, olay **kayboldu**. Dead-letter yapılandırılmamıştır ([infra/eventgrid.bicep](../infra/eventgrid.bicep), satır 68-72); geriye tek kanıt bu metriktir |

Canlı referans: `MatchedEventCount = DeliverySuccessCount = 2`, fail ve dropped boş.

`--filter "EventSubscriptionName eq '*'"` sonucu abonelik bazında kırar; sorguyu her hâlükârda
filtreli çalıştırmak güvenlidir. (Filtresiz sorgunun boş döndüğü yönündeki gözlem bu makinede
tekrar üretilemedi — **doğrulanamadı**.) Mevcut metrik adları:
`az monitor metrics list-definitions --resource "$TOPIC" --query "[].name.value" -o tsv`

Abonelik sağlığı:

```bash
az eventgrid system-topic event-subscription show -g rg-imgresizer-dev \
  --system-topic-name egst-imgresizer-dev -n sub-uploads-to-resizeimage \
  --query "{durum:provisioningState, tip:destination.endpointType, filtre:filter.subjectBeginsWith, retry:retryPolicy}" -o json
```

### 4. Fonksiyon çalıştı mı

Bkz. [#8](#8--abonelik-succeeded-ama-thumbnail-üretilmiyor-200-vs-202) — `requests`, `traces`,
`exceptions` sorguları ve sağlıklı örüntü.

### 5. Uçtan uca duman testi `[YAZAR]`

```bash
az storage blob upload --account-name stimgresizerdev --auth-mode login \
  --container-name uploads --name smoke.jpg --file smoke.jpg

sleep 10
az storage blob list --account-name stimgresizerdev --auth-mode login \
  --container-name thumbnails -o table
```

Kendi hesabınıza `Storage Blob Data Contributor` gerekir; storage veri rolleri yalnızca Function
App'in Managed Identity'sine verilmiştir.

---

## Prensipler — nereden okunacağı

Bu dokümandaki vakaların her biri genelleşebilir bir dersi somut kanıtıyla birlikte taşıyor.
Prensibi tek başına okumak yerine vakasına gidin:

- Hatanın yüzeye çıktığı katman, oluştuğu katman değildir → [#1](#1--sync-trigger-başarısız--scm-503)
- Yazılabiliyor olması çalışacağı anlamına gelmez (Y1 + .NET 10) → [#1](#1--sync-trigger-başarısız--scm-503)
- Control-plane doğrulaması data-plane'i doğrulamaz → [#2](#2--403-authorizationpermissionmismatch)
- Deterministik hataya retry uygulanmaz → [#3](#3--415-unsupported-media-type)
- Proxy sinyali pollama, işlemin kendisini doğrula → [#4](#4--i̇lk-publish-502-scm-aynı-anda-200)
- Aracın varsayılan zaman penceresi sorgunun kendisinden önce gelir → [#8](#8--abonelik-succeeded-ama-thumbnail-üretilmiyor-200-vs-202)

Karar gerekçeleri tek yerde: [decisions.md](decisions.md).
