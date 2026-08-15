# Mimari Kararlar

## Hosting: Flex Consumption

.NET 10, Linux Consumption (Y1) hariç tüm hosting planlarında desteklenir. Azure CLI ve
Terraform bu değeri Y1 planına yazmaya izin verse de platform çalıştıramaz
([azure-cli#32523](https://github.com/Azure/azure-cli/issues/32523)). Linux Consumption
ayrıca 30 Eylül 2028'de emekliye ayrılıyor ve yeni özellik almıyor.

Y1 üzerinde `Failed to perform sync trigger — Function app may have malformed content`
ve SCM 503 hataları alınıyordu. Aynı kod ve aynı deployment komutu, yalnızca hosting planı
değiştirildiğinde ilk denemede çalıştı. Bu geçişle `WEBSITE_RUN_FROM_PACKAGE` yönetimi ve
Azure Files content share'e bağlı plaintext storage key de ortadan kalktı.

## IaC: Bicep

Proje Azure-only; multi-cloud hedefi yok. Bicep ARM API'siyle doğrudan konuştuğu için
provider gecikmesi yaşanmaz ve state yönetimi tamamen ortadan kalkar: remote backend,
state storage account, state locking ve provider lock dosyası gerekmez.

Terraform, yaşanan deployment problemlerinin kaynağı değildi — problemler hosting
modelinden kaynaklanıyordu. Bicep'e geçişin getirisi operasyonel sadeleşmedir.

Bedeli: `az deployment group create` incremental çalışır, şablondan silinen kaynağı
Azure'dan silmez. Gerekirse [Deployment Stacks](https://learn.microsoft.com/azure/azure-resource-manager/bicep/deployment-stacks)
ile kapatılabilir; bu ölçekte gerekli görülmedi.

## Blob trigger: Event Grid

Flex Consumption yalnızca Event Grid kaynaklı blob trigger destekler; klasik container
polling (`LogsAndContainerScan`) çalışmaz. Bu zorunluluk aynı zamanda bir iyileştirmedir:
polling'de gecikme container büyüdükçe artar, Event Grid'de olay push edilir.
Ölçülen uçtan uca gecikme ~4 saniye.

Karşılığında altyapıya iki kaynak eklendi: Event Grid System Topic ve Event Subscription.

## Event Grid hedefi: WebHook

`[BlobTrigger] + Source=EventGrid` bir EventGrid trigger değildir. Event Grid'in
`AzureFunction` hedef tipi yalnızca `[EventGridTrigger]` fonksiyonlarını kabul eder ve
denendiğinde şu hatayı verir:

```
Unsupported Azure Function Trigger ... Azure Event Grid supports EventGrid Trigger type only.
```

Doğru hedef, Functions runtime'ının blob uzantı webhook'udur:
`/runtime/webhooks/blobs?functionName=Host.Functions.<Fn>&code=<blobs_extension>`

`[EventGridTrigger]` kullanmak event subscription'dan anahtarı tamamen kaldırırdı ancak
olay JSON'unu parse edip blob'u elle indirmeyi gerektirirdi — binding'in zaten çözdüğü
problemi uygulama koduna taşımak olurdu. `code` bir storage anahtarı değildir; storage
erişimi Managed Identity ile yapılır.

## Deployment komutu: `config-zip`

`az functionapp deploy --src-path`, zip gövdesini `Content-Type: application/octet-stream`
ile gönderir (azure-cli 2.88.0, `appservice/custom.py:11363-11364`). Flex Consumption'ın
One Deploy endpoint'i bu içerik tipini kabul etmez.

Aynı endpoint'e, aynı token ve aynı paketle yalnızca Content-Type değiştirilerek yapılan
istek bunu izole eder:

```
POST /api/publish?type=zip
  Content-Type: application/octet-stream  → 415 Unsupported Media Type
  Content-Type: application/zip           → 202 Accepted
```

`az functionapp deployment source config-zip` Flex planını algılayıp aynı One Deploy
yolunu kullanır, ayrıca sync trigger'ları bekler ve app health kontrolü yapar.

CD'de retry döngüsü yoktur. Önceki sürümde bulunan 5 denemelik döngü bu deterministik
hatayı yakalamak yerine 2.5 dakika boyunca tekrarlayıp yanıltıcı bir "backend
initializing" mesajı üretmişti. Retry yalnızca kanıtlanmış geçici hatalar için eklenir.

## Deployment sırası

1. `main.bicep` → Function App
2. Uygulama kodu → `ResizeImage` fonksiyonu
3. `eventgrid.bicep` → subscription

Event subscription'ın hedefi `.../sites/<app>/functions/ResizeImage` kaynağıdır ve bu
kaynak ancak kod deploy edilince oluşur. Sıra bozulursa:
`Endpoint validation: Destination endpoint not found`.

Event Grid tanımının ayrı dosyada tutulması bu bağımlılığın sonucudur, düzen tercihi değil.

## Bootstrap: dokümantasyon, script değil

Kimlik kurulumu subscription başına bir kez çalışır. Ömrü boyunca bir kez çalışacak bir iş
için script yazmak, çözdüğünden fazla bakım borcu yaratır; reproducibility ihtiyacı
versiyonlanmış dokümantasyonla karşılanır. Microsoft'un resmi Flex Consumption Bicep
örneğinde de shell script bulunmaz.

Kimlik bootstrap'ı IaC aracından bağımsız olarak zorunludur — otomasyon kendi giriş
anahtarını kendi üretemez. Terraform'un state bootstrap'ı ise Bicep'e geçişle tamamen kalktı.

## Resource Group IaC kapsamındadır

`main.bicep`, `targetScope = 'subscription'` ile çalışır ve Resource Group'u kendisi
oluşturur. RG'yi elle veya script ile oluşturmak altyapının bir parçasını IaC dışına
çıkarırdı. Bicep'te bir dosya tek scope'ta çalıştığı için RG-seviyesi kaynaklar
`resources.bicep` modülüne devredilir.

## Boyutlandırma

`instanceMemoryMB = 512` — 150×150 thumbnail üretimi hafif bir iştir. Flex Consumption'ın
aylık ücretsiz kotası (100.000 GB-saniye) hem 512 hem 2048 MB için fazlasıyla yeterli
olduğundan maliyet belirleyici değildir; en küçük yeterli boyut seçildi.

`maximumInstanceCount = 5` — Tavan, rezervasyon değil; boşta duran instance ücretlendirilmez.
Amacı hatalı bir döngüde blast radius'u sınırlamaktır. İkinci savunma hattı
`eventgrid.bicep`'teki `subjectBeginsWith` filtresidir: fonksiyonun kendi çıktısı
(`thumbnails/`) olay üretse bile tetiklemez.

## RBAC

CI/CD kimliği subscription scope'ta `Contributor` + `Role Based Access Control Administrator`.
İkincisi `User Access Administrator` yerine tercih edildi: aynı yetkiyi verir, yetki
yükseltmeye karşı korumalıdır.

Function App Managed Identity yalnızca üç storage veri rolüne sahiptir — Blob Data Owner
(deployment paketi, uploads/thumbnails, host state), Queue Data Contributor (poison queue),
Table Data Contributor (singleton koordinasyonu).

Üretilen ARM şablonunda `listKeys` yalnızca Event Grid webhook anahtarı için geçer;
storage hesap anahtarı bulunmaz.

## Bilinen boşluklar

| Konu | Durum |
|---|---|
| Event Grid dead-lettering | Yok; teslim edilemeyen olaylar 3 denemeden sonra düşer. Ayrı container ve Event Grid'e yazma yetkisi gerektirir. |
| Alerting | Application Insights toplama yapıyor, alert kuralı tanımlı değil. |
| Ortam ayrımı | Yalnızca `dev`. `environment` bir isimlendirme parametresidir, koşullu mantık içermez. |
