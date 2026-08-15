# Runtime Flow

`uploads/` container'ına bir görsel yazıldığı andan `thumbnails/` altında thumbnail
belirdiği ana kadar geçen yolun mekanizma seviyesinde anlatımı. Buradaki her adım
`rg-imgresizer-dev` içindeki canlı kaynaklara ve repo dosyalarına dayanır.

Bu belge **ne olduğunu** anlatır. İş bölümü — tekrar edilmez, gerektiğinde link verilir:

| Belge | Kapsamı |
|---|---|
| bu belge | tek bir olayın mekanizma seviyesinde yolu: hangi bileşen ne yapıyor, hangi ayar nereden geliyor |
| [docs/architecture.md](architecture.md) | üst seviye akış ve bileşen envanteri; aynı yolun özeti "uploads/ → thumbnails/ yolculuğu" başlığında |
| [docs/decisions.md](decisions.md) | **neden** böyle seçildiği |
| [docs/bootstrap.md](bootstrap.md) | kimlik altyapısının nasıl kurulduğu |
| [docs/troubleshooting.md](troubleshooting.md) | teşhis: semptomdan nedene giden sorgular, hata kataloğu, canlı kayıtlar |

Akışın tamamı **push** tabanlıdır. Hiçbir yerde polling yoktur: ne container taranır,
ne kuyruk yoklanır. Zincirin her halkası bir sonrakini bir HTTP isteğiyle uyandırır.

---

## Tam akış

```
 İSTEMCİ     stimgresizerdev    egst-imgresizer-dev   func-imgresizer-dev        WORKER SÜRECİ
az CLI / SDK Storage Account      System Topic +        Functions HOST       dotnet-isolated 10.0
         uploads/ · thumbnails/  Event Subscription    blob ext. 5.3.7      ImageResizeFunction.dll
    │               │                    │                     │                       │
    │ 1  PUT blob (PutBlob / PutBlockList) — Entra ID token    │                       │
    ├───────────────►                    │                     │                       │
    │               │ <blob COMMIT edilir>                     │                       │
    │ 201 Created   │                    │                     │                       │
    ◄───────────────┤                    │                     │                       │
    │               │                    │                     │                       │
    │               │ 2  Microsoft.Storage.BlobCreated         │                       │
    │               ├────────────────────►                     │                       │
    │               │ subject = .../containers/uploads/blobs/test.jpg                  │
    │               │                    │                     │                       │
    │               │                    │ 3-4  FİLTRE — abonelik seviyesinde          │
    │               │                    │      eventType ∈ {BlobCreated}?       ✓     │
    │               │                    │      subject ".../uploads/" ile başlıyor mu?  ✓
    │               │                    │                     │                       │
    │               │                    │ 5  POST /runtime/webhooks/blobs             │
    │               │                    ├─────────────────────►                       │
    │               │                    │    ?functionName=Host.Functions.ResizeImage │
    │               │                    │    &code=<blobs_extension system key>       │
    │               │                    │    gövde: EventGridSchema · maxEventsPerBatch=1
    │               │                    │                     │                       │
    │               │                    │                     ├──┐  6  COLD START — instance tahsisi
    │               │                    │                     │  │     alwaysReady=null · plan capacity=0
    │               │                    │                     ◄──┘                    │
    │               │                    │                     │ worker başlat + DI    │
    │               │                    │                     ├───────────────────────►
    │               │                    │                     │                       │
    │               │                    │ HTTP 202 — olay KABUL edildi                │
    │               │                    ◄─────────────────────┤                       │
    │               │                    │    host, invocation'ın bitmesini BEKLEMEZ   │
    │               │                    │    (200 bu değildir; 200 = abonelik handshake'i)
    │               │                    │                     │                       │
    │               │ 7  GET uploads/test.jpg — Managed Identity                       │
    │               ◄──────────────────────────────────────────┤                       │
    │               │ 200 + içerik       │                     │                       │
    │               ├──────────────────────────────────────────►                       │
    │               │                    │                     │ Stream incomingBlob   │
    │               │                    │                     ├───────────────────────►
    │               │                    │                     │ name = "test.jpg"     │
    │               │                    │                     │                       │
    │               │                    │                     │                       ├──┐  8-9  Run() → ImageSharp
    │               │                    │                     │                       │  │       800×600 → 150×112 JPEG
    │               │                    │                     │                       ◄──┘
    │               │                    │                     │                       │
    │               │ 10  PUT thumbnails/test.jpg              │                       │
    │               ◄──────────────────────────────────────────────────────────────────┤
    │               │     DefaultAzureCredential               │                       │
    │               │ 201 Created        │                     │                       │
    │               ├──────────────────────────────────────────────────────────────────►
    │               │                    │                     │                       │
    │               │ 11  BlobCreated (thumbnails/) ÜRETİLİR   │                       │
    │               ├┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄►                     │                       │
    │               │                    │      prefix TUTMAZ → TESLİM EDİLMEZ  ✗      │
    │               │                    │      (sonsuz döngü burada kırılır)          │
    │               │                    │                     │                       │
    │               │                    │                     │ Task tamamlandı       │
    │               │                    │                     ◄───────────────────────┤
    │               │                    │      (webhook yanıtı bundan ÖNCE dönmüştü)  │
    │               │                    │                     │                       │
    │               │                    │                     │                       │ 12  Azure Monitor
    │               │                    │                     │                       │     exporter (batch)
    │               │                    │                     │                       ├┄┄┄┄┄┄┄┄┄► appi-imgresizer-dev
```

**202'nin invocation'dan önce dönmesi ölçülmüştür.** 2026-08-15 canlı dizisi
([troubleshooting.md #8](troubleshooting.md#8--abonelik-succeeded-ama-thumbnail-üretilmiyor-200-vs-202)):
webhook POST `10:53:08.073`'te başlar ve 1356 ms sürer (bitiş ~`10:53:09.43`); `ResizeImage`
invocation'ı `10:53:09.577`'de **başlar**. Yani host olayı kabul edip yanıtı döndürmüş,
fonksiyon henüz çalışmamıştır. Aynı dizideki `200`, ayrı bir zamanda (`11:08:27.633`, 45 ms)
gerçekleşen abonelik doğrulama handshake'idir ve arkasından invocation gelmez.

Ölçülen uçtan uca gecikme ~4 saniye ([docs/decisions.md:33](decisions.md)). Bu sürenin
baskın bileşeninin adım 6 olduğu değerlendirilmektedir; adım bazlı ölçüm yapılmamıştır.
Webhook POST'unun 1356 ms sürmesi cold start'ın bu pencerenin içinde olmasıyla tutarlıdır,
ancak bu tek gözlemden çıkarılmış bir yorumdur — ölçüm değildir.

---

## 1 — Blob `uploads/` container'ına yazılıyor

**Ne oluyor:** İstemci Blob REST API'sine bir `Put Blob` (küçük dosya) veya
`Put Block` + `Put Block List` (büyük dosya) çağrısı yapar. Yazma commit edildiğinde
istemciye `201 Created` döner.

**Hangi kimlik:** Bu adım akıştaki tek yer ki fonksiyonun Managed Identity'si burada
devrede değildir — yükleyen kim ise onun kimliği kullanılır.
[README.md:82-90](../README.md) doğrulama akışında `--auth-mode login` ile Entra ID
token'ı kullanılır ve yükleyen hesabın storage üzerinde `Storage Blob Data Contributor`
rolüne ihtiyacı olduğu not edilmiştir; Function App'in MI'sine verilen roller kişisel
hesabınızı kapsamaz.

**Neden commit anı önemli:** Olay yazma tamamlandıktan **sonra** üretilir. Bu, adım 7'de
blob'un okunmaya hazır olduğunun garantisidir — fonksiyon yarım yazılmış bir dosyayla
karşılaşmaz.

`uploads` ve `thumbnails` container'ları
[infra/resources.bicep:45-50](../infra/resources.bicep) içinde tek bir döngüyle,
`deploymentpackage` ise [infra/resources.bicep:53-56](../infra/resources.bicep) içinde
ayrıca oluşturulur. Hesap `StorageV2 / Standard_LRS`, `allowBlobPublicAccess: false`,
`minimumTlsVersion: TLS1_2` ([infra/resources.bicep:26-38](../infra/resources.bicep)) —
yani thumbnail'lar anonim erişime açık değildir.

---

## 2 — Storage `Microsoft.Storage.BlobCreated` üretiyor

**Ne oluyor:** Storage hesabı, blob commit'i sonrasında bir olay yayınlar. Bu yayın
**hesap seviyesindedir**, container seviyesinde değil. `stimgresizerdev` altındaki beş
container'ın (`uploads`, `thumbnails`, `deploymentpackage`, `azure-webjobs-hosts`,
`azure-webjobs-secrets`) tamamındaki her yazma olay akışına girer.

**`subject` formatı:**

```
/blobServices/default/containers/uploads/blobs/test.jpg
└──────────────── sabit ────────────────┘└─┬─┘└──┬───┘
                                       container  blob adı (klasör benzeri
                                                  yollar dahil, ör. 2026/08/a.jpg)
```

Bu formatın `/blobServices/default/containers/uploads/` kısmı kesindir: canlı
aboneliğin `subjectPrefix` değeri birebir budur. Sonrasındaki `blobs/{ad}` segmenti
Storage olay şemasının standardıdır; elimizdeki Azure çıktılarında ham bir olay gövdesi
olmadığı için **doğrudan doğrulanamadı**.

**Olay içeriği:** Olay blob'un **kendisini değil, referansını** taşır (URL + subject +
`contentLength`, `eTag` gibi metadata). İçeriği okuyan taraf adım 7'deki binding
katmanıdır.

---

## 3 — System Topic akışı yakalıyor

**Bileşen:** `egst-imgresizer-dev`, `Microsoft.EventGrid/systemTopics`.

**Nasıl bağlanıyor:** [infra/eventgrid.bicep:30-37](../infra/eventgrid.bicep) topic'i
`source: storage.id` ve `topicType: 'Microsoft.Storage.StorageAccounts'` ile kurar.
Canlı doğrulama, kaynağın container değil **hesabın tamamı** olduğunu gösteriyor:

```
kaynak: /subscriptions/.../resourceGroups/rg-imgresizer-dev
        /providers/Microsoft.Storage/storageAccounts/stimgresizerdev
tip:    Microsoft.Storage.StorageAccounts
durum:  Succeeded
```

**Kritik sonuç:** Topic seviyesinde **hiçbir filtre yoktur**. Deployment paketi yazımı,
Functions host'unun `azure-webjobs-hosts` altındaki lock/state blob'ları
([infra/resources.bicep:24-25](../infra/resources.bicep) bu container'ların amacını
açıklıyor) ve fonksiyonun kendi thumbnail çıktısı — hepsi bu topic'ten geçer. Elemenin
tamamı bir sonraki adımda yapılır.

---

## 4 — Abonelik filtresi değerlendiriliyor

**Bileşen:** `sub-uploads-to-resizeimage`
([infra/eventgrid.bicep:39-74](../infra/eventgrid.bicep)).

İki katmanlı eleme yapılır
([infra/eventgrid.bicep:57-64](../infra/eventgrid.bicep)):

| Katman | Ayar | Elediği |
|---|---|---|
| Olay tipi | `includedEventTypes: ['Microsoft.Storage.BlobCreated']` | `BlobDeleted`, `BlobTierChanged`, `BlobRenamed`, `DirectoryCreated` … |
| Subject prefix | `subjectBeginsWith: '/blobServices/default/containers/uploads/'` | `thumbnails`, `deploymentpackage`, `azure-webjobs-hosts`, `azure-webjobs-secrets` |

Bu bir düz string prefix karşılaştırmasıdır; regex veya glob değildir.

**Sondaki `/` karakteri anlamlıdır.** `.../containers/uploads` yazılsaydı,
`uploads-backup` gibi bir container ileride eklendiğinde onun olayları da eşleşirdi.
Bicep bunu `'/blobServices/default/containers/${sourceContainer}/'`
([infra/eventgrid.bicep:63](../infra/eventgrid.bicep)) ile garanti eder.

**Sonsuz döngü koruması burada.** Fonksiyon `thumbnails/` altına yazıyor; filtre
olmasaydı kendi çıktısı aynı aboneliğe düşer ve kendini yeniden tetiklerdi. Dikkat
edilecek nokta adım 11'de: filtre olayın **üretilmesini** değil, **teslim edilmesini**
engeller. Aynı savunmanın ikinci katmanı `maximumInstanceCount = 5`'tir
([infra/main.bicep:25-28](../infra/main.bicep),
[docs/decisions.md:112](decisions.md)) — filtre bir gün bozulsa bile ölçeklenme
5 instance ile sınırlıdır.

**Filtre içerik tipine bakmaz.** `uploads/` altına konan bir `.txt` dosyası filtreyi
geçer ve adım 9'da exception fırlatır. Eleme yalnızca container düzeyindedir.

---

## 5 — Event Grid WebHook'a POST ediyor

**Hedef tipi `WebHook`'tur, `AzureFunction` değildir.** Canlı abonelikte
`hedefTip: WebHook`, `sema: EventGridSchema` görünür. Gerekçe
[docs/decisions.md:37-53](decisions.md) içinde: Event Grid'in `AzureFunction` hedefi
yalnızca `[EventGridTrigger]` imzalı fonksiyonları kabul eder;
`[BlobTrigger] + Source = EventGrid` bir EventGrid trigger değildir.

**URL anatomisi** ([infra/eventgrid.bicep:52](../infra/eventgrid.bicep)):

```
https://func-imgresizer-dev.azurewebsites.net    ①  Function App default host adı
        /runtime/webhooks/blobs                  ②  blob uzantısının sabit webhook yolu
        ?functionName=Host.Functions.ResizeImage ③  host'un iç fonksiyon kimliği
        &code=<blobs_extension system key>       ④  webhook yetkilendirmesi
```

① `functionApp.properties.defaultHostName` ile deploy anında okunur; canlı değer
`func-imgresizer-dev.azurewebsites.net`. `httpsOnly: true`.

② Bu yol Functions host'unun blob uzantısına aittir; uygulama kodunda karşılığı yoktur.
Uzantı publish çıktısındaki `extensions.json` üzerinden yüklenir
(`Microsoft.Azure.WebJobs.Extensions.Storage.Blobs 5.3.7.0`).

③ `Host.Functions.` öneki **zorunludur**; çıplak `ResizeImage` çözülmez. Bicep tarafında
fonksiyon adı [infra/eventgrid.bicep:15-16](../infra/eventgrid.bicep) ile parametredir ve
açıklaması C# tarafındaki `[Function(nameof(ResizeImage))]`
([src/ImageResizeFunction/ResizeImage.cs:11](../src/ImageResizeFunction/ResizeImage.cs))
ile birebir eşleşmesi gerektiğini söyler.

④ `code`, `listKeys('${functionApp.id}/host/default', ...).systemKeys.blobs_extension`
ile deploy anında okunan bir **system key**'dir. Bu bir storage anahtarı **değildir**;
tek işi webhook'u yetkisiz çağrılara karşı korumaktır ve repoda saklanmaz. Üretilen ARM
şablonundaki tek `listKeys` çağrısı budur ([docs/decisions.md:127-128](decisions.md)).

**Batch:** `maxEventsPerBatch: 1`
([infra/eventgrid.bicep:53](../infra/eventgrid.bicep)) — her POST tek olay taşır, yani
her teslim tam bir fonksiyon çağrısına karşılık gelir. Kısmi başarı durumu oluşmaz.

**Deployment sırası bu adımın sonucudur.** Abonelik oluşturulurken Event Grid endpoint
validation yapar; fonksiyon henüz deploy edilmemişse
`Endpoint validation: Destination endpoint not found` alınır. Bu yüzden
[infra/eventgrid.bicep:1-3](../infra/eventgrid.bicep) uyarısı ve ayrı dosya olması. CD'deki
altyapı → kod → Event Grid sırası üç ayrı yerden gelir
([.github/workflows/cd.yml](../.github/workflows/cd.yml)):

| Adım | Yer | Ne yapar |
|---|---|---|
| altyapı | `infra` job'ı, satır 18-44 (`Deploy Bicep` adımı 34-44) | `main.bicep` → Function App |
| kod | `deploy` job'ı, satır 74-79 | zip publish → `ResizeImage` fonksiyonu var olur |
| Event Grid | `deploy` job'ı, satır 81-86 | `eventgrid.bicep` → abonelik, endpoint validation geçer |

İki job arasındaki sırayı satır 49'daki `needs: infra` zorlar; job içindeki sırayı adımların
tanım sırası. Gerekçe [docs/decisions.md:77-81](decisions.md).

---

## 6 — Cold start

**Neden:** Flex Consumption planında ısıtılmış instance tanımlı değildir. Canlı durum:

```
scaleAndConcurrency: { alwaysReady: null, instanceMemoryMB: 512,
                       maximumInstanceCount: 5, triggers: null }
serverFarm sku:      { name: FC1, tier: FlexConsumption, capacity: 0 }
```

`capacity: 0` boşta hiçbir instance çalışmadığını gösterir. Boşta duran instance
ücretlendirilmez ([docs/decisions.md:112](decisions.md)); bedeli, boş bir dönemden sonra
gelen ilk olayda tam bir soğuk başlatmadır.

**Nasıl:** Webhook POST'u `*.azurewebsites.net` üzerine gelen sıradan bir HTTPS
isteğidir; özel bir "olay uyandırma" yolu yoktur. Platform instance tahsis eder,
Functions host ayağa kalkar, ardından worker süreci başlatılır. `worker.config.json`
başlatma sözleşmesini verir: `defaultExecutablePath: "dotnet"`,
`defaultWorkerPath: "ImageResizeFunction.dll"`, `workerIndexing: "true"`,
`canUsePlaceholder: true`. Proje `OutputType=Exe`
([src/ImageResizeFunction/ImageResizeFunction.csproj:6](../src/ImageResizeFunction/ImageResizeFunction.csproj))
olduğu için worker gerçekten ayrı bir OS sürecidir.

Worker açılışında sırayla:
[Program.cs:9](../src/ImageResizeFunction/Program.cs) builder,
[:11](../src/ImageResizeFunction/Program.cs) ASP.NET Core entegrasyonu,
[:13-30](../src/ImageResizeFunction/Program.cs) `BlobServiceClient` singleton kaydı,
[:32-37](../src/ImageResizeFunction/Program.cs) OpenTelemetry,
[:39](../src/ImageResizeFunction/Program.cs) `Build().Run()` — burada worker host'a gRPC
ile bağlanır ve fonksiyon metadata'sını bildirir (worker indexing).

**Cold start'a yazılan gereksiz maliyet:** Uygulamada hiç HTTP trigger yoktur — hem üretilen
`functions.metadata` hem canlı Azure tanımı tek bir `blobTrigger` gösteriyor. Buna rağmen
ASP.NET Core tüm katmanıyla pakette taşınır. Maliyeti getiren üç yer, bağımlılık sırasıyla:

| Yer | Ne | Rolü |
|---|---|---|
| [csproj:12](../src/ImageResizeFunction/ImageResizeFunction.csproj) | `<FrameworkReference Include="Microsoft.AspNetCore.App" />` | **koşulsuz**; framework'ü deploy paketine sokan şey budur |
| [csproj:18](../src/ImageResizeFunction/ImageResizeFunction.csproj) | `…Worker.Extensions.Http.AspNetCore 2.1.0` | `ConfigureFunctionsWebApplication()` uzantı metodunu sağlar |
| [Program.cs:11](../src/ImageResizeFunction/Program.cs) | `builder.ConfigureFunctionsWebApplication()` | yukarıdakileri **kullanan** taraf |

Nedensellik bu yönde işler: `Program.cs:11` referansı "sokan" değil, var olan referansın
sağladığı metodu çağıran satırdır. Yalnızca o satır silinseydi `Microsoft.AspNetCore.App`
pakette kalmaya devam ederdi; kazanç için üçünün birlikte kaldırılması gerekir. Kaldırmanın
cold start'a etkisi ölçülmedi.

---

## 7 — Blob içeriği `Stream`'e bağlanıyor

**Bileşen:** Functions host'undaki blob uzantısı + worker SDK'sının converter'ı. Burası
uygulama kodu değildir.

Canlı binding tanımı ve build-time üretilen `functions.metadata` birebir aynı:

```json
{ "name": "incomingBlob", "direction": "In", "type": "blobTrigger",
  "path": "uploads/{name}", "source": "EventGrid",
  "connection": "AzureWebJobsStorage",
  "properties": { "supportsDeferredBinding": "True" } }
```

**Path şablonu:** `uploads/{name}`
([ResizeImage.cs:15](../src/ImageResizeFunction/ResizeImage.cs)). Subject'in container'dan
sonraki kısmı `{name}` token'ına düşer ve binding data sözlüğüne konur — adım 8'de
`string name` parametresini dolduran şey budur.

**Kimlik — hiçbir yerde connection string yok.** `Connection = "AzureWebJobsStorage"`
klasik bir bağlantı dizesini işaret etmez. App settings'te yalnızca iki ayar var:

```
AzureWebJobsStorage__accountName        stimgresizerdev
APPLICATIONINSIGHTS_CONNECTION_STRING   InstrumentationKey=…
```

Düz `AzureWebJobsStorage` **yoktur**. `__accountName` soneki host'a "bu bağlantıyı
kimlikle çöz" der ([infra/resources.bicep:130-135](../infra/resources.bicep) yorumu bunu
açıklıyor): host `https://stimgresizerdev.blob.core.windows.net` URI'sini türetir ve
token'ı System-Assigned Managed Identity ile alır.

**RBAC:** Kimlik `identity: { type: 'SystemAssigned' }`
([infra/resources.bicep:101-103](../infra/resources.bicep)) ile üretilir; canlı principal
`f664b13f-5aea-4559-b5cf-662f5d89beab`. Storage hesabı scope'unda üç rol atanmıştır
([infra/resources.bicep:148-158](../infra/resources.bicep)):

| Rol | Kullanım |
|---|---|
| Storage Blob Data Owner | deployment paketi, `uploads` okuma, `thumbnails` yazma, host state |
| Storage Queue Data Contributor | poison queue |
| Storage Table Data Contributor | singleton koordinasyonu |

Atama adları `guid(storage.id, functionApp.id, roleId)` ile deterministiktir; tekrar
deploy yeni atama üretmez. Aynı MI deployment paketinin okunmasında da kullanılır
(`functionAppConfig.deployment.storage.authentication.type: SystemAssignedIdentity`).

**Deferred binding:** `supportsDeferredBinding: True`, blob içeriğinin host↔worker gRPC
kanalında bayt bayt serialize edilmek yerine referans olarak aktarıldığını, tip
dönüşümünün (blob → `Stream`) worker tarafında yapıldığını gösterir. İndirmeyi fiilen
hangi tarafın yaptığı Azure çıktılarından **doğrulanamadı**; kesin olan, kimlik çözümünün
her iki durumda da aynı ayardan geldiği.

---

## 8 — Worker `ResizeImage.Run` çalıştırıyor

Host, gRPC üzerinden çağrıyı worker'a iletir. İmza
([ResizeImage.cs:12-18](../src/ImageResizeFunction/ResizeImage.cs)):

```csharp
public async Task Run(
    [BlobTrigger("uploads/{name}", Source = BlobTriggerSource.EventGrid,
                 Connection = "AzureWebJobsStorage")]
    Stream incomingBlob,      // ← binding (metadata'daki tek binding)
    string name,              // ← binding DEĞİL: {name} token'ından, isim eşleşmesiyle
    FunctionContext context)  // ← worker'ın kendi enjeksiyonu; gövdede kullanılmıyor
```

`name` bir binding değildir — `functions.metadata` içindeki `bindings` dizisi tek eleman
(`incomingBlob`) içerir. Parametre adı token adıyla birebir aynı olmak zorundadır;
`blobName` olarak yeniden adlandırılsaydı çözülemezdi.

`ILogger<ResizeImage>` ve `BlobServiceClient` primary constructor ile enjekte edilir
([ResizeImage.cs:9](../src/ImageResizeFunction/ResizeImage.cs)); ikisi de adım 6'da
kurulan worker DI konteynerinden gelir. İlk log
([ResizeImage.cs:20](../src/ImageResizeFunction/ResizeImage.cs)) structured logging
kullanır — `{ImageName}` bir placeholder'dır, string interpolation değil; bu sayede adım
12'de aranabilir bir özellik olarak çıkar.

---

## 9 — ImageSharp: 800×600 neden 150×112 oluyor

```csharp
using var image = await Image.LoadAsync(incomingBlob);          // :22
image.Mutate(x => x.Resize(new ResizeOptions {                  // :24-28
    Size = new Size(150, 150),
    Mode = ResizeMode.Max
}));
using var outputStream = new MemoryStream();                    // :30
await image.SaveAsJpegAsync(outputStream);                      // :31
outputStream.Position = 0;                                      // :32
```

**`LoadAsync`** format parametresi almaz; decoder stream'in magic byte'larından seçilir.
Bu, `uploads/` içine atılan her desteklenen formatın kabul edileceği, desteklenmeyen bir
dosyanın ise burada exception fırlatacağı anlamına gelir (adım 13). `using`, ImageSharp'ın
havuzlanmış belleğini geri verir — 512 MB'lık instance'ta bu ihmal edilebilir bir detay
değildir.

**`ResizeMode.Max`** 150×150'yi bir **sınır kutusu** olarak yorumlar: en-boy oranı
korunur, görüntü kutuya sığdırılır, kırpma veya dolgu yapılmaz.

Ölçek iki orandan küçük olanıdır: `min(150/800, 150/600) = 0.1875`. Kısıtlayan kenar
genişliktir → `800 × 0.1875 = 150`, `600 × 0.1875 = 112.5 → 112`.

Ölçülen doğrulama: 800×600 · 28.049 bayt girdi → **150×112** · 2.543 bayt çıktı.
112.5'in 112'ye inmesi ölçülmüş sonuçtur; ImageSharp'ın kullandığı yuvarlama kuralının
kendisi (floor mu, banker's rounding mu) kaynak koddan **doğrulanmadı**.

**Pratik sonuç:** Çıktı genelde 150×150 **değildir**. Kare thumbnail beklentisi varsa
`ResizeMode.Crop` gerekir; bu bilinçli bir tercih.

**`SaveAsJpegAsync`** encoder parametresi almaz, varsayılan kalite kullanılır (kodda
açıkça set edilmemiştir; varsayılan sayısal değer paket dosyalarından **doğrulanmadı**).

**`Position = 0` fonksiyonel olarak zorunludur.** Yazma sonrası imleç sonda kalır;
sıfırlanmasaydı adım 10'daki `UploadAsync` sıfır baytlık bir blob yazardı.

---

## 10 — Thumbnail `thumbnails/` container'ına yazılıyor

```csharp
var outputClient = blobServiceClient                    // :34
    .GetBlobContainerClient("thumbnails")               // :35
    .GetBlobClient(name);                               // :36
await outputClient.UploadAsync(outputStream, overwrite: true);  // :38
```

**Çıktı için output binding kullanılmamıştır**; doğrudan Azure SDK client'ı kullanılır.
Bu, container adının kodda sabit olması pahasına tam kontrol verir.

**Client nereden geliyor:** [Program.cs:13-30](../src/ImageResizeFunction/Program.cs)
iki kollu bir singleton fabrikası kaydeder ve `IConfiguration` yerine doğrudan
`Environment.GetEnvironmentVariable` okur:

```
Program.cs:15   AzureWebJobsStorage dolu mu?
                ├── EVET → new BlobServiceClient(connectionString)     ← yalnızca yerel
                │           (local.settings.json: UseDevelopmentStorage=true → Azurite)
                └── HAYIR → AzureWebJobsStorage__accountName oku       ← Azure
                            yoksa: InvalidOperationException (:22-25)
                            varsa: new BlobServiceClient(
                                      https://{accountName}.blob.core.windows.net,
                                      new DefaultAzureCredential())    ← :27-29
```

Azure'da app settings listesinde düz `AzureWebJobsStorage` **yoktur**, dolayısıyla
üretimde her zaman ikinci kol çalışır. `DefaultAzureCredential` zinciri, hiçbir yerde
`AZURE_CLIENT_ID` tanımlı olmadığı için platformun enjekte ettiği System-Assigned MI'ye
düşer — adım 7'deki okumayla **aynı kimlik**, farklı süreç ve farklı client.

```
                   func-imgresizer-dev · tek instance, iki OS süreci
   ┌────────────────────────────────────┐  gRPC  ┌────────────────────────────────────┐
   │ HOST SÜRECİ                        │◄──────►│ WORKER SÜRECİ                      │
   │ Functions runtime v4               │        │ dotnet ImageResizeFunction.dll     │
   │ WebJobs.Extensions.Storage.Blobs   │        │ Worker 2.52.0 + kendi DI konteyneri│
   │ 5.3.7 (extensions.json)            │        │ (Program.cs)                       │
   │                                    │        │                                    │
   │ Connection = "AzureWebJobsStorage" │        │ BlobServiceClient (singleton)      │
   └──────────────┬─────────────────────┘        └──────────────┬─────────────────────┘
                  │ OKUMA                                       │ YAZMA
                  │ AzureWebJobsStorage__accountName            │ accountName +
                  │ + Managed Identity                          │ DefaultAzureCredential
                  ▼                                             ▼
           uploads/test.jpg                              thumbnails/test.jpg
           └────────── stimgresizerdev · aynı hesap, aynı kimlik ──────────┘
```

**`overwrite: true` idempotency içindir.** Event Grid en-az-bir-kez teslim garantisi
verir; aynı olay tekrar gelirse veya bir retry başarılı olursa `BlobAlreadyExists` (409)
yerine üzerine yazılır.

**İki bilinen pürüz:**

- Çıktı her zaman JPEG encode edilir
  ([:31](../src/ImageResizeFunction/ResizeImage.cs)) ama blob adı olarak orijinal `name`
  uzantısıyla kullanılır ([:36](../src/ImageResizeFunction/ResizeImage.cs)).
  `uploads/foto.png` → `thumbnails/foto.png` adlı ama içeriği JPEG olan blob.
- `UploadAsync`'e `BlobHttpHeaders` verilmediği için `Content-Type` ayarlanmaz. Container
  zaten anonim erişime kapalı (`allowBlobPublicAccess: false`), ama doğrudan tarayıcıda
  görüntüleme senaryosu eklenirse bu düzeltilmelidir.

---

## 11 — Neden bu yazma yeni bir tetikleme yaratmıyor

Yaygın yanılgı: "filtre olay üretilmesini engelliyor". **Engellemiyor.**

```
   thumbnails/test.jpg yazıldı
            │
            ▼
   Microsoft.Storage.BlobCreated ÜRETİLİR          ← System Topic hesabın tamamını dinliyor
   subject = /blobServices/default/containers/thumbnails/blobs/test.jpg
            │
            ▼
   sub-uploads-to-resizeimage filtresi
   subjectBeginsWith = /blobServices/default/containers/uploads/
            │
            │   "…/containers/thumbnails/…"  vs  "…/containers/uploads/"
            │              ↑ prefix TUTMUYOR
            ▼
   eşleşen abonelik yok → olay Event Grid içinde DÜŞÜRÜLÜR
   WebHook'a POST atılmaz, host uyanmaz, ücret oluşmaz
```

Aynı mekanizma `deploymentpackage` ve `azure-webjobs-hosts` yazımları için de çalışır —
her deployment ve host'un sürekli yazdığı state blob'ları olay üretir, hiçbiri teslim
edilmez. Gerekçe [infra/eventgrid.bicep:61-63](../infra/eventgrid.bicep) yorumunda ve
[docs/decisions.md:112](decisions.md) içinde kayıtlı.

**Webhook 2xx'i fonksiyonun başarısı değildir.** Event Grid teslim başarısını **HTTP durum
koduna** göre belirler, ama host bu kodu invocation'ı beklemeden döndürür — canlı dizide
webhook yanıtı (`202`, `10:53:09.43`) `ResizeImage` invocation'ının başlangıcından
(`10:53:09.577`) önce dönmüştür
([troubleshooting.md #8](troubleshooting.md#8--abonelik-succeeded-ama-thumbnail-üretilmiyor-200-vs-202)).
Kodun anlamı da bunu söylüyor: `202 Accepted` = "işlenmek üzere kabul edildi", "tamamlandı"
değil.

Pratik sonucu, hata ayıklarken hangi sinyalin neyi kanıtladığıdır:

| Sinyal | Kanıtladığı |
|---|---|
| webhook `202` | olay host'a ulaştı ve kabul edildi — adım 1-5 sağlam |
| webhook `200` | yalnızca abonelik doğrulama handshake'i; arkasından invocation gelmez |
| App Insights `ResizeImage` invocation kaydı | fonksiyon fiilen çalıştı |
| `thumbnails/` altındaki blob | adım 10 tamamlandı — **başarının tek kesin kanıtı budur** |

`maxEventsPerBatch: 1` sayesinde tek yanıt tek olayın akıbetini belirler; kısmi başarı
durumu oluşmaz.

---

## 12 — Telemetri Application Insights'a akıyor

Telemetri **iki katmanlıdır** çünkü iki süreç vardır:

| Katman | Ayar | Kapsam |
|---|---|---|
| Host | [host.json:3](../src/ImageResizeFunction/host.json) `"telemetryMode": "OpenTelemetry"` | trigger, binding, scale, invocation kaydı |
| Worker | [Program.cs:32](../src/ImageResizeFunction/Program.cs) `AddOpenTelemetry().UseFunctionsWorkerDefaults()` | kullanıcı kodunun log ve span'leri |

`UseFunctionsWorkerDefaults()`, worker'ın ActivitySource'unu kaydeder ve OTel Resource'unu
Functions'a göre doldurur; host ile worker aynı trace context'e bağlanır.

**Exporter koşulludur** ([Program.cs:34-37](../src/ImageResizeFunction/Program.cs)):

```csharp
if (!builder.Environment.IsDevelopment())
    openTelemetryBuilder.UseAzureMonitorExporter();
```

Azure'da `ASPNETCORE_ENVIRONMENT` / `DOTNET_ENVIRONMENT` / `AZURE_FUNCTIONS_ENVIRONMENT`
app setting'i tanımlı **değildir** — app settings listesinde yalnızca iki ayar var ve
[infra/resources.bicep:129-140](../infra/resources.bicep) başka bir şey yazmıyor.
Ortam adı belirtilmediğinde varsayılan `Production`'dır, dolayısıyla koşul true olur ve
exporter devreye girer. (Platformun bu değişkeni kendiliğinden set etmediği ayrıca
**doğrulanmadı**; sonuç, uygulamanın canlıda telemetri üretiyor olmasıyla tutarlı.)

**Protokol OTLP değildir.** Toplama OpenTelemetry SDK'sıyla yapılır, dışa aktarım
`Azure.Monitor.OpenTelemetry.Exporter 1.7.0` ile Azure Monitor'ün kendi ingestion
protokolü üzerindendir
([csproj:17](../src/ImageResizeFunction/ImageResizeFunction.csproj),
[Program.cs:36](../src/ImageResizeFunction/Program.cs) `UseAzureMonitorExporter()`).
`OpenTelemetry.Exporter.OpenTelemetryProtocol` paketi projede yoktur ve
`OTEL_EXPORTER_OTLP_ENDPOINT` app setting'i tanımlı değildir.

Exporter hedefini `APPLICATIONINSIGHTS_CONNECTION_STRING`'den okur; canlı ingestion
endpoint'i `https://westeurope-5.in.applicationinsights.azure.com/` — bir OTLP endpoint'i
değil.

**Nereye düşüyor:** `appi-imgresizer-dev` workspace-based'tir
(`WorkspaceResourceId` → `log-imgresizer-dev`,
[infra/resources.bicep:69-77](../infra/resources.bicep)); veri nihai olarak Log Analytics
workspace'inde toplanır, retention 30 gün
([infra/resources.bicep:58-67](../infra/resources.bicep)).

**Zamanlama:** Toplama fonksiyon yürütmesinin içinde olur, dışa aktarım **batch**'lidir.
Bu yüzden thumbnail `thumbnails/` altında göründükten bir süre **sonra** App Insights'ta
belirir. İkisi eşzamanlı değildir: "blob var ama log yok" kısa vadede normaldir, birkaç
dakika sonra hâlâ yoksa sorundur.

**Hangi tabloya düşüyor:** `telemetryMode: OpenTelemetry` olmasına rağmen klasik App
Insights tabloları (`requests`, `traces`, `exceptions`, `dependencies`) doluyor ve
sorgulanabiliyor — ayrı bir OTel şeması yok. Canlı kanıt
[troubleshooting.md #8](troubleshooting.md#8--abonelik-succeeded-ama-thumbnail-üretilmiyor-200-vs-202)
içindeki 2026-08-15 dizisidir.

---

## 13 — Hata yolu

Event Grid'in retry politikası yalnızca **webhook yanıt koduna** bakar
([infra/eventgrid.bicep:66-72](../infra/eventgrid.bicep)):

```
  deneme 1  ──► 2xx dışı  ┐
  deneme 2  ──► 2xx dışı  ├─ maxDeliveryAttempts: 3  (üstel geri çekilme; tam aralıklar
  deneme 3  ──► 2xx dışı  ┘                           yapılandırmada yok, Azure varsayılanı)
        │
        ▼
  deadLetterDestination TANIMLI DEĞİL
        │
        ▼
  olay SESSİZCE DÜŞER
        │
        ├─ uploads/test.jpg     → duruyor, thumbnail'sız (öksüz blob)
        ├─ thumbnails/          → boş
        ├─ App Insights         → exception kaydı var (fonksiyon çalıştıysa)
        └─ alert                → yok  (docs/decisions.md:135)
```

**Fonksiyon içi hatanın bu zincire girip girmediği doğrulanmadı.** Adım 11'deki ölçüm
webhook yanıtının invocation başlamadan döndüğünü gösteriyor; bu geçerliyse gövdedeki bir
`Image.LoadAsync` hatası webhook'a 2xx dışı bir kod olarak yansımaz ve Event Grid retry'ı
hiç tetiklenmez. Retry'ın kesin olarak kapsadığı durum, host'a ulaşamayan veya host'un
kabul etmediği **teslimdir** (adım 5-6 tarafı). Ayrımı canlıda çözmenin yolu, aynı
`operation_Id`'nin `exceptions` tablosunda tekrarlanıp tekrarlanmadığına bakmaktır
(Gözlemlenebilirlik §2); bu deployment'ta böyle bir tekrar gözlenmemiştir.

`eventTimeToLiveInMinutes: 1440` (24 saat) de tanımlıdır ama bu yapılandırmada **fiilen
etkisizdir**: 3 deneme her zaman 24 saatten çok önce tükenir. Gerçek sınır deneme
sayısıdır.

**İki tipik senaryo:**

| Senaryo | Sonuç |
|---|---|
| `uploads/` altına görsel olmayan dosya (`.txt`) | `Image.LoadAsync` deterministik olarak fırlatır; retry çalışsa da her deneme aynı hatayı verir. Her hâlükârda sonuç: thumbnail yok, `exceptions` kaydı var, olay düşer |
| Cold start sırasında teslim zaman aşımı | Bu, retry'ın kesin kapsadığı durumdur; ikinci deneme genellikle başarılı olur, instance ısınmıştır. `overwrite: true` sayesinde çift yazım zararsızdır |

Dead-lettering ve alerting bilinçli olarak kapsam dışı bırakılmış, bilinen boşluk olarak
kayıt altına alınmıştır ([docs/decisions.md:130-136](decisions.md)). Pratik anlamı:
**başarısız bir işlemi fark etmenin tek otomatik yolu Event Grid teslim metrikleridir**;
aşağıdaki blob karşılaştırması bu boşluğu elle kapatmak içindir.

`host.json` minimaldir — `extensions.blobs` altında retry, `maxDegreeOfParallelism` veya
poison queue ayarı yoktur, tümü varsayılandır. Yani hata karşısındaki tek koruma katmanı
Event Grid'in retry politikasıdır.

---

## Gözlemlenebilirlik

Genel teşhis seti — deployment durumu, fonksiyonun kayıtlı olup olmadığı, `requests` /
`traces` / `exceptions` sorguları, sağlıklı örüntünün canlı kaydı ve uçtan uca duman testi —
[troubleshooting.md → Genel teşhis seti](troubleshooting.md#genel-teşhis-seti) ve
[#8](troubleshooting.md#8--abonelik-succeeded-ama-thumbnail-üretilmiyor-200-vs-202)
altındadır. Burada yalnızca bu belgedeki adımlara özgü olanlar var.

`{ImageName}` structured placeholder olduğu için dosya adı `traces` kaydında
`customDimensions` içinde ayrı bir alandır ve doğrudan filtrelenebilir (adım 8, adım 12).

### 1. Cold start'ın gecikmedeki payını görmek

```kusto
requests
| where timestamp > ago(24h) and name == "ResizeImage"
| summarize n=count(), p50=percentile(duration,50), p95=percentile(duration,95)
```

`alwaysReady: null` olduğu için p50 ile p95 arasında belirgin bir açıklık beklenir: sık
tetiklenen dönemler sıcak instance'a, seyrek dönemlerin ilk çağrısı soğuk başlatmaya denk
gelir. Bu ayrım, adım 6'nın gecikmedeki payını doğrulamanın en doğrudan yolu.

### 2. Retry fiilen oluyor mu

Adım 13'teki açık soru — fonksiyon içi hatanın Event Grid retry'ını tetikleyip
tetiklemediği — bu sorguyla çözülür:

```kusto
exceptions
| where timestamp > ago(24h)
| project timestamp, type, outerMessage, operation_Id
| order by timestamp desc
```

Aynı `operation_Id` birden fazla kez görünüyorsa teslim gerçekten yeniden denenmiştir; tek
kayıt kalıyorsa hata webhook koduna yansımamış demektir. Bu deployment'ta tekrar
gözlenmemiştir.

### 3. Event Grid teslim metrikleri

Dead-letter olmadığı için düşen olaylar **yalnızca** buradan görünür. Adlar bu topic'te
doğrulanmıştır:

```bash
TOPIC_ID=$(az eventgrid system-topic show \
  -g rg-imgresizer-dev -n egst-imgresizer-dev --query id -o tsv)

az monitor metrics list --resource "$TOPIC_ID" \
  --metrics MatchedEventCount DeliverySuccessCount DeliveryAttemptFailCount DroppedEventCount \
  --aggregation Total --interval PT1H --filter "EventSubscriptionName eq '*'"
```

Canlı referans değeri ve her metriğin ne anlama geldiğini veren yorum tablosu
[troubleshooting.md → Genel teşhis seti §3](troubleshooting.md#3-event-grid-teslim-ediyor-mu)
içinde.

Bu belge açısından anlamlı olan ilişki: `MatchedEventCount` yalnızca adım 4 filtresini geçen
olayları sayar, dolayısıyla `uploads/` yazımları kadar olmalıdır. Hesap genelinde üretilen
olay sayısı (thumbnail, deployment paketi, host state yazımları) bundan **büyüktür** ve
metriklerde görünmez. `MatchedEventCount`'un yüklenen blob sayısının üzerine çıkması adım 4
veya adım 11'deki elemenin bozulduğunun ilk işaretidir.

### 4. Öksüz blob taraması

Dead-lettering'in yerine geçen en basit sağlık kontrolü: `uploads/` içinde olup
`thumbnails/` içinde olmayan bloblar. Blob komutları çağıran hesabın storage üzerinde
`Storage Blob Data Contributor` rolüne sahip olmasını gerektirir — veri rolleri yalnızca
Function App'in MI'sine verilmiştir ([README.md:89-90](../README.md)).

```bash
az storage blob list --account-name stimgresizerdev --auth-mode login \
  --container-name uploads     --query "[].name" -o tsv | sort > /tmp/uploads.txt

az storage blob list --account-name stimgresizerdev --auth-mode login \
  --container-name thumbnails  --query "[].name" -o tsv | sort > /tmp/thumbs.txt

comm -23 /tmp/uploads.txt /tmp/thumbs.txt   # işlenmemiş = başarısız veya henüz sırada
```

Adım 10'daki isim eşleşmesi (`thumbnails/{name}`, kaynakla aynı ad) bu karşılaştırmayı
mümkün kılan şeydir.

### 5. Teşhis sinyalinden adıma haritalama

Duman testi ve komutları için
[troubleshooting.md → Genel teşhis seti §5](troubleshooting.md#genel-teşhis-seti). Sonuç
gelmiyorsa hangi kontrolün bu belgedeki hangi adımı elediği:

| Kontrol | Elediği adımlar |
|---|---|
| abonelik `Succeeded` mi, endpoint hâlâ geçerli mi | 4-5 |
| Event Grid teslim metrikleri teslim gösteriyor mu | 5-6 (sorun Event Grid'de mi, host'ta mı) |
| App Insights'ta invocation / exception var mı | 8-10 |
| `thumbnails/` altında blob var mı | 10 — tek kesin başarı kanıtı |

---

## Doğrulanamayanlar ve tuzaklar

Aşağıdakiler bu belgeyi yazarken karşılaşılan, kanıtla desteklenmeyen veya kolayca yanlış
okunan noktalardır.

- **`sharedKey: null` "shared key kapalı" demek DEĞİLDİR.** `az` çıktısındaki `null`,
  `allowSharedKeyAccess` özelliğinin hiç set edilmediği anlamına gelir;
  [infra/resources.bicep:33-37](../infra/resources.bicep) yalnızca `minimumTlsVersion`,
  `supportsHttpsTrafficOnly` ve `allowBlobPublicAccess` ayarlar. Yani Azure varsayılanı
  geçerlidir ve hesap anahtarıyla erişim **aktif olarak engellenmiş değildir** —
  uygulama onu kullanmıyor olsa bile. Anahtarla erişimi gerçekten kapatmak isterseniz
  `allowSharedKeyAccess: false` eklenmelidir.
- **Olay `subject`'inin tam metni.** `/blobServices/default/containers/uploads/` kısmı
  canlı `subjectPrefix` değerinden kesindir; sonrasındaki `blobs/{ad}` segmenti Storage
  olay şemasına dayanan çıkarımdır. Elimizde ham bir olay gövdesi yok.
- **Deferred binding'in veri yolu.** İçeriği host'un mu yoksa worker converter'ının mı
  indirdiği görülmedi.
- **Cold start'ı hangi platform bileşeninin başlattığı.** "Sıradan bir HTTPS isteği gibi
  ele alınır" ifadesi endpoint'in `*.azurewebsites.net/runtime/webhooks/...` olmasından
  çıkarılmıştır. `canUsePlaceholder: true` ayarının bu app için fiilen kullanılıp
  kullanılmadığı da görülmedi.
- **Webhook 2xx'i başarı sanmak.** `202`, olayın host tarafından **kabul edildiğini**
  söyler; fonksiyonun çalıştığını değil. Ölçülen dizide yanıt invocation başlamadan
  dönmüştür (adım 11). Ayrı bir tuzak: `200` gerçek olay teslimi değil, abonelik doğrulama
  handshake'idir.
- **Fonksiyon içi hatanın Event Grid retry'ını tetikleyip tetiklemediği.** Yapılandırmada
  `maxDeliveryAttempts: 3` var, ama webhook yanıtı invocation'dan önce döndüğü için
  gövdedeki bir exception'ın bu sayaca girmesi beklenmez. Canlıda ne doğrulandı ne
  çürütüldü; ayırt etme yöntemi Gözlemlenebilirlik §2'de.
- **Retry backoff aralıkları.** Yapılandırmada yok; Azure varsayılanına tabi.
- **Gecikme rakamı.** Repoda yazılı tek ölçüm [docs/decisions.md:33](decisions.md)
  içindeki ~4 saniyedir. Adım bazlı bir dağılım ölçülmemiştir; "cold start baskın
  bileşendir" bir değerlendirmedir, ölçüm değil.
- **Yerel geliştirme.** `Source = EventGrid` blob trigger'ı Azurite'a dosya atmakla
  tetiklenmez; olayın elle `/runtime/webhooks/blobs` uç noktasına POST edilmesi gerekir.
  Repoda bunu yapan bir script yok. `local.settings.json` `.gitignore` ile dışlanmıştır.
- **Ortam adı.** `IsDevelopment()`'ın yerelde `false` dönüp dönmediği (dolayısıyla
  geliştirici makinesinden App Insights'a telemetri gidip gitmediği) repo dosyalarından
  doğrulanamadı; bu Azure Functions Core Tools'un konvansiyonuna bağlıdır.
