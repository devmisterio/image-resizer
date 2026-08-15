# Mimari

Bu belge sistemin **nasıl çalıştığını** anlatır: hangi bileşen neyi tetikler, veri ve kimlik
nereden nereye akar. Kapsam kasıtlı olarak dardır; aşağıdakiler burada tekrarlanmaz:

| Konu | Belge |
|---|---|
| Tercihlerin gerekçesi | [docs/decisions.md](decisions.md) |
| Kimlik altyapısının kurulumu | [docs/bootstrap.md](bootstrap.md) |
| Olayın adım adım mekanizması ve gözlemlenebilirlik | [docs/runtime-flow.md](runtime-flow.md) |
| Pipeline'ın adım adım mekanizması | [docs/deployment.md](deployment.md) |

Tüm iddialar `infra/`, `src/`, `.github/workflows/` altındaki dosyalara ve canlı Azure
durumuna dayanır. Doğrulanamayan noktalar en sonda ayrı bir tabloda toplanmıştır.

---

## 1. İki düzlem

Sistemi tek bir akış olarak düşünmek yanıltıcıdır. Birbirinden bağımsız iki düzlem vardır:

| | Deployment düzlemi | Runtime düzlemi |
|---|---|---|
| Ne zaman çalışır | `main`'e her push | Her blob yüklemesinde |
| Kimlik | GitHub Actions Service Principal (`app-github-imgresizer`) | Function App System-Assigned Managed Identity |
| Muhatap | ARM **control plane** (kaynak yaratma) | Storage **data plane** (blob okuma/yazma) |
| Sonuç | Kaynakların var olması | Bir thumbnail dosyası |
| Hata biçimi | Deployment fail, pipeline kırmızı | Olay 3 denemede düşer, sessiz veri kaybı |

İki düzlem yalnızca iki noktada kesişir: **`stimgresizerdev` storage hesabı** ve
**`func-imgresizer-dev` Function App kaynağı**. Deployment düzlemi bunları yaratır ve
`deploymentpackage/` container'ına uygulama paketini koyar; runtime düzlemi aynı hesabın
`uploads/` ve `thumbnails/` container'larıyla çalışır ve soğuk başlatmada paketi yine aynı
hesaptan okur.

```
╔═══════════════ DEPLOYMENT DÜZLEMİ · control plane · push başına bir kez ═══════════════╗
║                                                                                        ║
║   git push main ──► GitHub Actions (cd.yml)                                            ║
║                          │ OIDC JWT   sub=repo:...:ref:refs/heads/main                 ║
║                          ▼                                                             ║
║                     Entra ID · app-github-imgresizer  (client secret YOK)              ║
║                          │ ARM access token                                            ║
║                          ▼                                                             ║
║                     Azure Resource Manager                                             ║
║                          │                                                             ║
║   ADIM 1  az deployment sub create ── main.bicep ──► rg-imgresizer-dev                 ║
║           (subscription scope)                        ├─ stimgresizerdev + 3 container ║
║                                                       ├─ log-  / appi-imgresizer-dev   ║
║                                                       ├─ asp-imgresizer-dev  (FC1)     ║
║                                                       ├─ func-imgresizer-dev (+ MI)    ║
║                                                       └─ 3 × roleAssignment            ║
║                          │                                                             ║
║   ADIM 2  az functionapp deployment source config-zip ──► SCM /api/publish             ║
║                          │                                     │                       ║
║                          │        platform, paketi app'in MI'sı ile yazar              ║
║                          │                                     ▼                       ║
║                          │                          deploymentpackage/ (paket blob'u)  ║
║                          │                                     │                       ║
║                          │                          host paketi yükler → ResizeImage   ║
║                          │                          fonksiyonu kaydolur                ║
║                          ▼                                                             ║
║   ADIM 3  az deployment group create ── eventgrid.bicep ──► egst-imgresizer-dev        ║
║           (resource group scope)                    └─ sub-uploads-to-resizeimage      ║
║                                                                                        ║
╚════════════════════════════════════════════════════════════════════════════════════════╝
                                          │
              ORTAK YÜZEY:  stimgresizerdev   ·   func-imgresizer-dev
                                          │
╔═════════════════ RUNTIME DÜZLEMİ · data plane · olay başına ═══════════════════════════╗
║                                                                                        ║
║   istemci ── PutBlob ──►┌──────────────── stimgresizerdev ─────────────────┐           ║
║                         │  uploads/foto.jpg          thumbnails/foto.jpg   │           ║
║                         └────┬───────────────────────────────▲─────────────┘           ║
║                              │ BlobCreated                   │ UploadAsync             ║
║                              │ (hesabın TAMAMI için)         │ (overwrite: true)       ║
║                              ▼                               │                         ║
║                    egst-imgresizer-dev · System Topic        │                         ║
║                    source = storage hesabının kendisi        │                         ║
║                              │                               │                         ║
║                              ▼                               │                         ║
║                    sub-uploads-to-resizeimage                │                         ║
║                    filter: BlobCreated                       │                         ║
║                          + subject ^ /.../containers/uploads/│                         ║
║                              │ HTTPS POST · EventGridSchema  │                         ║
║                              │ maxEventsPerBatch = 1         │                         ║
║                              ▼                               │                         ║
║       func-imgresizer-dev.azurewebsites.net                  │                         ║
║           /runtime/webhooks/blobs                            │                         ║
║             ?functionName=Host.Functions.ResizeImage         │                         ║
║             &code=<blobs_extension system key>               │                         ║
║                              │                               │                         ║
║                              ▼   cold start · ölçek 0 → 1    │                         ║
║                    Functions host ──► blob uzantısı          │                         ║
║                              │   binding: Stream + name      │                         ║
║                              │   (içerik MI ile okunur)      │                         ║
║                              ▼                               │                         ║
║                    ResizeImage.Run() · 150×150 Max · JPEG ───┘                         ║
║                              │   SixLabors.ImageSharp · ResizeMode.Max                 ║
║                              └──► OpenTelemetry ──► appi-imgresizer-dev                ║
║                                                     └──► log-imgresizer-dev (30 gün)   ║
╚════════════════════════════════════════════════════════════════════════════════════════╝
```

Runtime düzleminde **hiç polling yoktur**. Storage olayı üretir, Event Grid taşır, webhook
ölçeği sıfırda olan uygulamayı uyandırır. Ölçülen uçtan uca gecikme
[decisions.md:33](decisions.md)'te ~4 saniye olarak kayıtlıdır; baskın bileşeninin cold
start olduğu **değerlendirilmektedir**, adım bazlı ölçüm yapılmamıştır
([runtime-flow.md:81-82](runtime-flow.md)). Yapılandırma her olayın sıfırdan ölçeklenmeyle
karşılaşmasına açıktır: `alwaysReady: null`, plan `capacity: 0`.

---

## 2. Bileşen envanteri

| Kaynak | Ad | Tanım | Görevi | Kiminle konuşur |
|---|---|---|---|---|
| Resource Group | `rg-imgresizer-dev` | [main.bicep:30-33](../infra/main.bicep) | Diğer her şeyin kapsayıcısı; IaC kapsamındadır | — |
| Storage Account | `stimgresizerdev` | [resources.bicep:26-38](../infra/resources.bicep) | Uygulama verisi + deployment paketi + host state, tek hesapta | Function App (MI), Event Grid (olay kaynağı) |
| Blob container'ları | `uploads`, `thumbnails` (copy-loop), `deploymentpackage` | [resources.bicep:40-56](../infra/resources.bicep) | Girdi / çıktı / uygulama paketi | Function App |
| Log Analytics | `log-imgresizer-dev` | [resources.bicep:58-67](../infra/resources.bicep) | Telemetrinin nihai deposu, 30 gün retention | App Insights |
| Application Insights | `appi-imgresizer-dev` | [resources.bicep:69-77](../infra/resources.bicep) | Workspace-based; `WorkspaceResourceId` ile workspace'e bağlı | Function App (connection string), Log Analytics |
| App Service Plan | `asp-imgresizer-dev` | [resources.bicep:80-91](../infra/resources.bicep) | FC1 / FlexConsumption; ölçek ve faturalama modeli | Function App |
| Function App | `func-imgresizer-dev` | [resources.bicep:97-143](../infra/resources.bicep) | Kod barındırır; System-Assigned MI taşır | Plan, Storage, App Insights, Event Grid (webhook hedefi) |
| Rol atamaları | 3 adet, `guid()` ile deterministik | [resources.bicep:148-158](../infra/resources.bicep) | Function App MI'sına storage veri yetkisi | Storage (scope), Function App (principal) |
| Event Grid System Topic | `egst-imgresizer-dev` | [eventgrid.bicep:30-37](../infra/eventgrid.bicep) | Storage hesabının olay yayın noktası | Storage (source), Event Subscription |
| Event Subscription | `sub-uploads-to-resizeimage` | [eventgrid.bicep:39-74](../infra/eventgrid.bicep) | Filtre + WebHook teslimi + retry politikası | System Topic (parent), Function App (webhook) |

### Bicep'te tanımlı olmayan, canlıda var olan kaynaklar

`azure-webjobs-hosts` ve `azure-webjobs-secrets` container'larını Functions host'u çalışma
anında kendisi yaratır; `Application Insights Smart Detection` action group'unu ise Azure
otomatik ekler (azure-state-2.txt:30-31, azure-state-1.txt:10). Deployment incremental
modda çalıştığı için hiçbiri silinmez — bu, [decisions.md:24-26](decisions.md)'da kabul
edilmiş bir bedeldir.

### Bağımlılıklar: hiç `dependsOn` yazılmamıştır

`infra/*.bicep` içinde tek bir explicit `dependsOn` yoktur. Tüm sıralama üç kaynaktan
implicit doğar: symbolic property referansı (`plan.id`, `appInsights.properties.ConnectionString`,
`storage.properties.primaryEndpoints.blob`, `functionApp.identity.principalId`), `parent:`
ve `scope:` anahtar kelimeleri. Ortaya çıkan graf üç bağımsız kökten oluşur ve ARM bunları
paralel işler:

```
  KÖK 1: stimgresizerdev       KÖK 2: log-imgresizer-dev     KÖK 3: asp-imgresizer-dev
     │        │                          │                            │
     │        └─ blobServices/default    ▼                            │
     │                ├─ uploads         appi-imgresizer-dev          │
     │                ├─ thumbnails              │                    │
     │                └─ deploymentpackage       │                    │
     │                                           │                    │
     └────────────────────┬──────────────────────┴────────────────────┘
                          ▼
                   func-imgresizer-dev    ◄── üç dalın birleştiği düğüm
                   dependsOn = [components, serverfarms, storageAccounts]
                          │
                          ▼
                   3 × roleAssignment     scope: storage
                                          principalId: functionApp.identity.principalId
```

Dikkat: `deploymentpackage` container'ı Function App'in `dependsOn` listesinde **yoktur** —
[resources.bicep:112](../infra/resources.bicep) container'ın symbolic referansını değil
yalnızca `storage.properties.primaryEndpoints.blob`'u okur. Ayrıntı için son bölümdeki
tabloya bakın.

`eventgrid.bicep`'teki `storage` ve `functionApp` ise `existing` referanslarıdır
([eventgrid.bicep:22-28](../infra/eventgrid.bicep)): hiçbir ARM kaynağı üretmez, yalnızca
`resourceId()` / `reference()` / `listKeys()` ifadelerine derlenir. Bu yüzden o dosya
kaynakları yeniden tanımlamaz, sahiplenmez ve güncellemez.

### Flex Consumption'ın getirdiği yapısal fark

Klasik planlarda app setting olan her şey burada `functionAppConfig` altında yaşar
([resources.bicep:108-126](../infra/resources.bicep)):

| Alan | Canlı değer | Yerini aldığı ayar |
|---|---|---|
| `deployment.storage` | `https://stimgresizerdev.blob.core.windows.net/deploymentpackage`, auth = `SystemAssignedIdentity` | `WEBSITE_RUN_FROM_PACKAGE` |
| `runtime` | `dotnet-isolated` 10.0 | `FUNCTIONS_WORKER_RUNTIME`, `FUNCTIONS_EXTENSION_VERSION` |
| `scaleAndConcurrency` | `instanceMemoryMB: 512`, `maximumInstanceCount: 5` | — |

Sonuç canlı ortamda ölçülebilir: uygulamada **yalnızca iki app setting** vardır —
`AzureWebJobsStorage__accountName` ve `APPLICATIONINSIGHTS_CONNECTION_STRING`
(azure-state-1.txt:48-52). `WEBSITE_CONTENTAZUREFILECONNECTIONSTRING` /
`WEBSITE_CONTENTSHARE` yoktur çünkü Flex, Azure Files content share kullanmaz; bu aynı
zamanda plaintext storage key'i de ortadan kaldırır.

---

## 3. Kimlik ve güven zinciri

Sistemde **iki ayrı kimlik** vardır ve yetkileri kesişmez. Karıştırılmaları en sık yapılan
kavramsal hatadır: biri kaynak yaratır ama veriye dokunamaz, diğeri veriye dokunur ama
kaynak yaratamaz.

```
KİMLİK 1 — CI/CD  ·  yalnızca deployment düzleminde
────────────────────────────────────────────────────────────────────────────
 GitHub Actions runner
   │  permissions: id-token: write  → runner OIDC token isteyebilir
   ▼
 GitHub OIDC servisi
   │  iss = https://token.actions.githubusercontent.com
   │  aud = api://AzureADTokenExchange
   │  sub = repo:<owner@id>/<repo@id>:ref:refs/heads/main   (CD)
   │        repo:<owner@id>/<repo@id>:pull_request          (CI)
   ▼  client assertion — parola veya sertifika yok
 Entra ID · App Registration  app-github-imgresizer
   │  federated credential eşleşmesi: issuer + subject + audience TAM eşleşme,
   │  wildcard yok → main ve pull_request için iki AYRI kayıt (bootstrap.md:47-65)
   ▼  ARM access token
 Azure Resource Manager   —   Contributor
                              Role Based Access Control Administrator
                              (subscription scope)
   │
   ├─ kaynak yaratır / günceller
   ├─ rol ataması yapar  ← Contributor tek başına YETMEZ; resources.bicep:148-158
   │                       Microsoft.Authorization/roleAssignments kaynağı üretir
   └─ storage VERİSİNE erişemez: bu kimliğe hiçbir storage veri rolü verilmemiştir


KİMLİK 2 — Function App System-Assigned Managed Identity  ·  yalnızca runtime + paket okuma
────────────────────────────────────────────────────────────────────────────
 principalId = f664b13f-5aea-4559-b5cf-662f5d89beab   (azure-state-1.txt:42)
   │  token'ı platformun instance'a sağladığı yerel kimlik uç noktasından alır
   │  (uç noktanın adı bu proje kapsamında doğrulanmadı); host tarafında
   │  AzureWebJobsStorage__accountName, uygulama tarafında DefaultAzureCredential
   │  (Program.cs:27-29)
   ▼  scope: yalnızca stimgresizerdev
 Storage Blob Data Owner         → deploymentpackage, uploads, thumbnails,
                                    azure-webjobs-hosts, azure-webjobs-secrets
 Storage Queue Data Contributor  → poison queue
 Storage Table Data Contributor  → singleton koordinasyonu
```

Kimliklerin sınırı ilginç bir noktada belirginleşir: paketi SCM'e **CI/CD kimliği** gönderir
(`config-zip`, AAD bearer token ile), ancak paketi `deploymentpackage/` container'ına yazan
taraf platformdur ve bunu `functionAppConfig.deployment.storage.authentication.type =
SystemAssignedIdentity` yapılandırmasına göre **uygulamanın kendi kimliğiyle** yapar
(azure-state-1.txt:16-24). *Bu, bildirilen konfigürasyondan çıkan sonuçtur; platformun iç
hand-off'u izlenmedi ([deployment.md B.3](deployment.md)).* Yazma işini deploy eden kimliğin
yapmaması, GitHub SP'ye tek bir storage veri rolü bile gerekmemesinin sebebidir; canlıda
storage rollerinin tamamı Function App MI'sındadır (azure-state-2.txt:46-51).

### Kimlik olmayan üçüncü anahtar: `blobs_extension` system key

Event Grid'in çağırdığı webhook URL'indeki `code=` parametresi bir kimlik değil, bir kapı
anahtarıdır: webhook'u yetkisiz çağrıya karşı korur. Deploy anında
`listKeys('<siteId>/host/default', ...).systemKeys.blobs_extension` ile okunur
([eventgrid.bicep:52](../infra/eventgrid.bicep)) ve repoda saklanmaz. Üretilen ARM
şablonlarındaki tek `listKeys` çağrısı budur; **storage hesap anahtarı hiçbir şablonda
geçmez** ([decisions.md:127-128](decisions.md)).

### Zincirin kırılma noktaları

| Kaldırılan / bozulan | Sonuç |
|---|---|
| `permissions.id-token: write` | Runner'a OIDC endpoint değişkenleri enjekte edilmez; `azure/login` token isteyemez, her iki workflow da login'de patlar |
| `github-actions-main` federated credential | Yalnızca CD kırılır, CI çalışmaya devam eder |
| `github-actions-pull-request` credential | Yalnızca CI'ın `infra` job'ı kırılır; `build` job'ı login içermediği için etkilenmez |
| RBAC Administrator rolü | Kaynaklar oluşur, rol ataması adımında deployment fail eder |
| Function App MI rolleri | Kaynaklar var olur ama app paketi okuyamaz, blob okuyup yazamaz |

Fork'lardan gelen PR'lar GitHub varsayılanı gereği OIDC token alamaz
([bootstrap.md:113](bootstrap.md)) — pratikte fork PR'larında CI'ın `infra` job'ı kimlik
doğrulayamaz.

---

## 4. Veri akışı

### Container'ların rolleri

| Container | Kim yazar | Kim okur | Düzlem |
|---|---|---|---|
| `uploads/` | İstemci | Trigger binding (MI) | Runtime — girdi |
| `thumbnails/` | `ResizeImage` (MI, `BlobServiceClient`) | İstemci | Runtime — çıktı |
| `deploymentpackage/` | Platform (app MI'sı ile) | Functions host, her cold start'ta | **İki düzlemin köprüsü** |
| `azure-webjobs-hosts/`, `azure-webjobs-secrets/` | Host, runtime'da | Host | Runtime — iç state |

`deploymentpackage` yalnızca bir deployment artefaktı deposu değildir: Flex Consumption
uygulamayı **oradan çalıştırır**. Yani her soğuk başlatma bu container'a bir okuma yapar ve
bu okuma da Managed Identity ile yetkilendirilir. Deployment düzleminin ürünü, runtime
düzleminin girdisi hâline gelen tek nesne budur.

### uploads/ → thumbnails/ yolculuğu

Adım adım mekanizma — her adımın kanıtı, filtre değerlendirmesi, ImageSharp davranışı ve
gözlemlenebilirlik sorguları — [docs/runtime-flow.md](runtime-flow.md) içindedir. Mimari
düzeyde zincir şudur:

```
 uploads/foto.jpg (PutBlob commit) ─► BlobCreated
     subject = /blobServices/default/containers/uploads/blobs/foto.jpg
   ─► abonelik filtresi: eventType + subjectBeginsWith
   ─► HTTPS POST /runtime/webhooks/blobs
        ?functionName=Host.Functions.ResizeImage&code=<blobs_extension>
   ─► cold start (0 → 1) ─► blob uzantısı binding: Stream + name
   ─► ResizeImage.Run(): 150×150 Max, JPEG
   ─► thumbnails/foto.jpg (overwrite: true) ─► host 2xx ─► olay akıştan düşer
   ─► OpenTelemetry ─► appi-imgresizer-dev (batch'li; thumbnail'dan SONRA görünür)
```

Bu zincirin mimariyi belirleyen üç özelliği:

- **Olay içerik taşımaz.** Gövde blob'un referansıdır (URL, subject, `eTag`,
  `contentLength`); bu Storage olay şemasının özelliğidir. İçeriği okuyan taraf
  host/worker binding katmanıdır ve okuma Managed Identity ile yetkilendirilir. Canlı
  binding metadata'sındaki `supportsDeferredBinding: True` (azure-state-1.txt:58-68) ayrı
  bir olgudur: blob → `Stream` dönüşümünün gRPC kanalında bayt serialize edilmeden, worker
  tarafında yapıldığını gösterir ([runtime-flow.md:137-139, 336-340](runtime-flow.md)).
- **Olay blob yazıldıktan sonra üretilir**, dolayısıyla fonksiyon çalıştığında blob
  okunmaya hazırdır; sistemde hiçbir "hazır mı" beklemesi yoktur.
- **Çıktı adı kaynakla aynı, içerik daima JPEG.** `foto.png` yüklenirse
  `thumbnails/foto.png` adında ama JPEG içerikli bir blob oluşur
  ([ResizeImage.cs:30-38](../src/ImageResizeFunction/ResizeImage.cs)). `ResizeMode.Max`
  en-boy oranını korur ve 150×150'ye **sığdırır** (kırpmaz, dolgu yapmaz).

### Sonsuz döngü neden oluşmuyor

Yaygın yanılgı, filtrenin olayın **üretilmesini** engellediğidir. Engellemez: fonksiyonun
kendi çıktısı da gerçek bir `BlobCreated` olayı üretir ve hesabın tamamını dinleyen System
Topic'e girer. Eleme **teslim** aşamasındadır — `subjectBeginsWith` tutmadığı için eşleşen
abonelik kalmaz, POST atılmaz, host uyanmaz. Aynı mekanizma `deploymentpackage/` ve
`azure-webjobs-*` yazımlarını da eler. Diyagramlı anlatım:
[runtime-flow.md § 11](runtime-flow.md).

Döngüye karşı iki bağımsız katman vardır ve ikisi de aynı kararın parçasıdır
([decisions.md:112-115](decisions.md)):

| Katman | Ne yapar |
|---|---|
| `subjectBeginsWith` filtresi ([eventgrid.bicep:61-63](../infra/eventgrid.bicep)) | Kendi çıktısının teslim edilmesini engeller; prefix'in sonundaki `/` kritiktir, onsuz `uploads-backup` da eşleşirdi |
| `maximumInstanceCount = 5` | Filtre bozulsa bile hatalı döngünün blast radius'unu 5 instance ile sınırlar |

### Hata yolu

Fonksiyon exception fırlatırsa host 2xx dışında yanıt verir ve Event Grid **toplam 3
denemeye** kadar yeniden dener (`maxDeliveryAttempts: 3`). `eventTimeToLiveInMinutes: 1440`
bu yapılandırmada fiilen etkisizdir; gerçek sınır deneme sayısıdır. Dead-letter tanımlı
olmadığı için üçüncü denemeden sonra olay **düşer**: blob `uploads/` içinde thumbnail'sız
kalır; geriye yalnızca Event Grid teslim metrikleri ve — fonksiyon gerçekten çalıştıysa —
App Insights'taki exception kaydı kalır. Alert kuralı yoktur, bu bilinçli kabul edilmiş bir
boşluktur ([decisions.md:130-137](decisions.md)).

Mimari sonuç: **runtime düzleminin hata biçimi sessiz veri kaybıdır.** Deployment
düzleminde hata pipeline'ı kırar ve görünür; burada kırılacak bir şey yoktur. Senaryolar,
retry davranışı ve öksüz blob taraması: [runtime-flow.md § 13](runtime-flow.md).

---

## 5. Neden bu mimari

Gerekçelerin tamamı [docs/decisions.md](decisions.md)'dedir; burada yalnızca kararların
birbirini nasıl kilitlediği. Her düğüm ilgili karar başlığına karşılık gelir:

```
  .NET 10 gerekiyor
        │
        └─► Flex Consumption (FC1)              → decisions.md "Hosting: Flex Consumption"
              │
              ├─► Event Grid blob trigger zorunlu → decisions.md "Blob trigger: Event Grid"
              │     ├─► hedef WebHook olmak zorunda → decisions.md "Event Grid hedefi: WebHook"
              │     └─► hedef koda bağımlı ⇒ deployment sırası zorunlu (aşağıda)
              │
              ├─► Azure Files content share yok ⇒ plaintext storage key yok
              │
              └─► functionAppConfig ⇒ canlıda 2 app setting kalır

  IaC: Bicep                                     → decisions.md "IaC: Bicep"
        └─► incremental ⇒ şablondan silinen Azure'dan silinmez   (decisions.md:24-26)
```

Deployment sırasının (**altyapı → kod → Event Grid**) zorunlu olması bir düzen tercihi
değildir, iki bağımsız teknik kısıtın sonucudur:

1. `eventgrid.bicep` deploy anında `listKeys(...).systemKeys.blobs_extension` okur; bu
   sistem anahtarı ancak host blob uzantısını yükledikten sonra vardır.
2. Event Grid, abonelik oluşturulurken webhook hedefini doğrular; `Host.Functions.ResizeImage`
   kayıtlı değilse `Endpoint validation: Destination endpoint not found` döner
   ([eventgrid.bicep:1-3](../infra/eventgrid.bicep)).

Bu sıra pipeline'da açık bir "bekle" adımı olmadan çalışır çünkü
`az functionapp deployment source config-zip` deploy sonrası bloke olur: sync trigger'lar
için bekler ve `/admin/host/status` sağlık kontrolünü geçene kadar dönmez. Sağlık kontrolü
geçmezse komut hata verir, job kırılır ve Event Grid adımı hiç çalışmaz
([cd.yml:74-86](../.github/workflows/cd.yml), [decisions.md:70-71](decisions.md)).

Komutun `az functionapp deploy` yerine seçilmiş olması da bir tercih değildir:
`--src-path` yolunda CLI gövdeyi `Content-Type: application/octet-stream` ile gönderir
(azure-cli 2.88.0, `appservice/custom.py:11363-11364`; `application/json` yalnızca
`--src-url` dalında kullanılır) ve Flex Consumption'ın One Deploy endpoint'i bu içerik
tipini kabul etmez. Aynı endpoint'e aynı token ve aynı paketle yapılan izolasyon testinde
`application/octet-stream` → **415**, `application/zip` → **202**
([decisions.md:57-68](decisions.md)).

CD'nin tek workflow olması da bir tercih değil: `Connect Event Grid` adımı
`needs.infra.outputs.resourceGroup` değerine muhtaçtır ve GitHub Actions'ta job output'ları
workflow sınırını geçmez. CI ile CD'nin ayrı dosya olması ise tam tersi sebeple mümkündür —
aralarında hiçbir veri akışı yoktur, yalnızca farklı tetikleyicilere bağlı farklı
sorumluluklardır (`pull_request` = doğrula, `push: main` = uygula).

---

## 6. Doğrulanamayanlar ve bilinen boşluklar

Aşağıda **mimari kararları etkileyen** doğrulanamayanlar toplanmıştır. Düzlem bazındaki
tam listeler kardeş dokümanlardadır ve burada tekrarlanmaz: deployment düzlemi için
[deployment.md § Doğrulanamayanlar](deployment.md), runtime düzlemi için
[runtime-flow.md § Doğrulanamayanlar ve tuzaklar](runtime-flow.md). Bilinçli olarak kabul
edilmiş boşluklar (dead-lettering, alerting, ortam ayrımı) karar kaydındadır:
[decisions.md:130-137](decisions.md).

| Konu | Durum |
|---|---|
| `sharedKey: null` | "Shared key erişimi kapalı" **demek değildir**. `allowSharedKeyAccess` [resources.bicep:33-37](../infra/resources.bicep)'de hiç ayarlanmamıştır; `null` = property set edilmemiş. Hesap anahtarıyla erişim aktif olarak engellenmiş değildir — uygulama kullanmıyor olsa bile. Güvenlik duruşunu doğrudan etkileyen tek açık nokta, sertleştirme fırsatı |
| Function App ↔ `deploymentpackage` sırası | Function App'in `dependsOn` listesi `[components, serverfarms, storageAccounts]`; container listede **yoktur** ([resources.bicep:112](../infra/resources.bicep) yalnızca `storage.properties.primaryEndpoints.blob`'u okur). Teorik olarak paralel oluşabilirler; gerçek bir yarış koşulu yaratıp yaratmadığı **doğrulanamadı** (canlıda her şey `Succeeded`) |
| RBAC propagasyon zamanlaması | Rol atamaları Function App'ten sonra oluşur; `infra` ve `deploy` job'larının ayrı olması araya gecikme koyar, ancak bunun bilinçli bir önlem olduğu ne `cd.yml`'de ne `decisions.md`'de yazılıdır — çıkarımdır |
| Parametre kuplajı | Ne [cd.yml:37-41](../.github/workflows/cd.yml) ne [cd.yml:83-86](../.github/workflows/cd.yml) `--parameters` geçer. `main.bicep` ve `eventgrid.bicep` arasındaki isim tutarlılığı yalnızca varsayılanların elle senkron tutulmasına dayanır; hiçbir mekanizma zorlamaz |
| CI/CD SP rol atamaları | Yalnızca [bootstrap.md:76-82](bootstrap.md)'ye dayanıyor; eldeki canlı RBAC çıktısı yalnızca Function App MI'sını listeliyor (azure-state-2.txt:46-51), SP rolleri canlı çıktıyla teyit edilmedi |
| Bicep ↔ canlı durum uyuşmazlıkları | `reserved: true` yazılı ama canlıda `null`; `siteUpdateStrategy: Recreate` canlıda var ama Bicep'te tanımsız. İkisi de mimari davranışı değiştirmiyor (app `kind: functionapp,linux` çalışıyor); ayrıntı [deployment.md § Doğrulanamayanlar](deployment.md) |
| `deploymentpackage` içindeki blob adı | Paketin bu container'a yazıldığı `functionAppConfig.deployment.storage` ile kesin; One Deploy'un blob'u hangi adla yazdığı elde blob listesi olmadığı için **bilinmiyor**. `app.zip` yalnızca runner'daki yerel dosya adıdır ([cd.yml:68](../.github/workflows/cd.yml)) |
| Eşzamanlılık | Her iki workflow'da da `concurrency:` bloğu yok. `main`'e arka arkaya iki push çakışan iki CD koşusu üretebilir; ikisi de aynı `image-resizer` deployment adını kullanır |
| Test | `src/` altında test projesi yok; CI'ın `build` job'ı yalnızca restore + build yapar |
| Doküman kayması | [cd.yml:70-73](../.github/workflows/cd.yml) yorumu `az functionapp deploy`'un reddedilme sebebini hâlâ "preview olması" ve `application/json` olarak yazıyor. Gerçek sebep ölçüldü ve farklı: `--src-path` yolunda gönderilen tip `application/octet-stream`'dir (§5). Yorum güncellenmelidir |
