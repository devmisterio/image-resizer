# Deployment Akışı

Bu doküman dört senaryonun **execution flow**'unu anlatır: bir `git push`'tan sonra hangi
bileşen neyi, neden, hangi sırayla yapıyor ve kontrolü bir sonrakine nasıl devrediyor.

Kararların *gerekçesi* [docs/decisions.md](decisions.md), kimlik kurulumu
[docs/bootstrap.md](bootstrap.md) içindedir; burada tekrarlanmaz, gerektiğinde link verilir.

Bu dokümandaki iddialar üç kaynağa dayanır: repo dosyaları, canlı Azure durumu ve bu makinede
kurulu `azure-cli 2.88.0` kaynağı. Doğrulanamayan noktalar açıkça işaretlenmiştir; kapanışta
[toplu liste](#doğrulanamayanlar) vardır.

## Pipeline topolojisi

Azure'a yazan tek yol `cd.yml`'dir. Üç deployment adımı vardır ve sırası zorunludur.

```
  PR → main                          push → main
  ─────────────                      ─────────────
  ci.yml                             cd.yml
  ├── job: infra   (salt-okunur)     ├── job: infra    ─┐ ADIM 1  altyapı
  │   Bicep build                    │   Deploy Bicep   │
  │   Azure login (OIDC)             │                  │ needs:
  │   Bicep what-if                  └── job: deploy   ─┘
  └── job: build   (Azure'suz)           Publish and package
      Restore                            Deploy to Function App   ADIM 2  kod
      Build                              Connect Event Grid       ADIM 3  Event Grid
```

İki workflow ayrı dosyadır çünkü aralarında veri akışı yoktur. Buna karşılık `infra` ve
`deploy` **aynı** dosyada olmak zorundadır: `Connect Event Grid` adımı `infra` job'ının
ürettiği resource group adını okur ve GitHub Actions'ta job output'ları workflow sınırını
geçmez.

Kaynak adları ([README.md](../README.md) tablosunun karşılıkları): `rg-imgresizer-dev`,
`stimgresizerdev`, `asp-imgresizer-dev`, `func-imgresizer-dev`, `egst-imgresizer-dev`,
`appi-imgresizer-dev`, `log-imgresizer-dev`.

---

# A. Sıfırdan ilk kurulum

## A.0 Bootstrap — pipeline'ın dışında kalan tek adım

Otomasyon kendi giriş anahtarını kendi üretemez. `az ad app create`, iki federated credential
ve iki rol ataması subscription başına bir kez, elle çalıştırılır:
[docs/bootstrap.md](bootstrap.md).

Bu adımın çıktısı üç GitHub secret'tır (`AZURE_CLIENT_ID`, `AZURE_TENANT_ID`,
`AZURE_SUBSCRIPTION_ID`). Bunlar credential değildir — client secret veya sertifika hiç
üretilmez ([docs/bootstrap.md:112](bootstrap.md)); secret olmalarının amacı log maskeleme ve
fork PR'lardan erişimi engellemektir.

## A.1 Tetikleme

`main`'e push → [.github/workflows/cd.yml:6-8](../.github/workflows/cd.yml). `workflow_dispatch`
tanımlı olmadığı için elle deploy yolu yoktur; her deployment bir `main` commit'ine karşılık gelir.

`infra` job'ı başlar: `actions/checkout@v4`, ardından `Azure login (OIDC)`
([cd.yml:27-32](../.github/workflows/cd.yml)).

## A.2 Kimlik: OIDC token değişimi

`azure/login@v2`'ye `client-secret` verilmediği için action parola tabanlı akış yerine
**federated (client assertion)** akışına düşer.

```
 [1] runner ──► GitHub OIDC servisi
       │        ACTIONS_ID_TOKEN_REQUEST_URL / _TOKEN env değişkenleri üzerinden
       │        ⚠ bu env'ler yalnızca permissions.id-token: write varsa enjekte edilir
       │           (cd.yml:10-12) — yoksa azure/login token'ı hiç isteyemez
       ▼
 [2] imzalı JWT
       iss = https://token.actions.githubusercontent.com
       aud = api://AzureADTokenExchange
       sub = <REPO_REF>:ref:refs/heads/main        ← CD
             <REPO_REF>:pull_request               ← CI
       ▼
 [3] azure/login ──► Entra ID (app-github-imgresizer)
       client assertion olarak sunulur; Entra issuer+subject+audience
       üçlüsünde TAM eşleşme arar (wildcard yok) → bu yüzden bootstrap
       iki AYRI federated credential yaratır (bootstrap.md:47-65)
       ▼
 [4] ARM access token (Service Principal adına)
       ▼
 [5] ARM ──► RBAC kontrolü: bu SP ne yapabilir?
```

`permissions` bloğunun açıkça yazılması ikinci bir sertleştirmedir: bildirildiği anda
listelenmeyen tüm `GITHUB_TOKEN` kapsamları `none`'a düşer; `contents: read` yalnızca
`actions/checkout` için bırakılmıştır.

[4]'teki token tek başına hiçbir kaynağa erişim vermez; ne yapılabileceğini [5]'te devreye giren
rol atamaları belirler ([A.3](#a3-yetki-rbac-iki-ayrı-yerde-devreye-girer)).

## A.3 Yetki: RBAC iki ayrı yerde devreye girer

İki ayrı özne, iki ayrı zaman:

| | GitHub Service Principal | Function App Managed Identity |
|---|---|---|
| Ne zaman | Deploy anında (control plane) | Runtime'da (data plane) |
| Nerede tanımlı | [bootstrap.md:73-82](bootstrap.md), elle | [infra/resources.bicep:148-158](../infra/resources.bicep), deployment tarafından |
| Scope | Subscription | Yalnızca `stimgresizerdev` |
| Roller | `Contributor` + `Role Based Access Control Administrator` | Blob Data Owner, Queue Data Contributor, Table Data Contributor |

`Contributor` **tek başına yetmez**: [resources.bicep:148-158](../infra/resources.bicep) bir
`Microsoft.Authorization/roleAssignments` kaynağı yaratır ve rol ataması yaratmak ayrı bir
yetkidir. Scope'un subscription seviyesinde olmasının sebebi ise
[main.bicep:4](../infra/main.bicep)'teki `targetScope = 'subscription'` ve
[main.bicep:30-33](../infra/main.bicep)'te Resource Group'un şablon tarafından yaratılmasıdır.

GitHub SP'ye **storage veri rolü verilmemiştir**: [bootstrap.md:73-82](bootstrap.md) yalnızca
`Contributor` + `Role Based Access Control Administrator` atar. Elimizdeki canlı RBAC çıktısı
assignee'ye göre Function App MI'siyle sınırlı olduğundan, storage scope'unda başka principal
bulunmadığı bu analizde **doğrulanmadı**. Deploy eden kimliğin neden storage rolüne ihtiyaç
duymadığı [B.3](#b3-deploy-to-function-app)'te.

## A.4 Deploy Bicep — ARM kaynakları hangi sırayla oluşturur

```bash
az deployment sub create \
  --name image-resizer --location westeurope \
  --template-file infra/main.bicep \
  --query properties.outputs -o json
```

`--parameters` geçilmez; [main.bicep:11,16](../infra/main.bicep) varsayılanları
(`project=imgresizer`, `environment=dev`) etkin olur. `--location` oluşturulan kaynakların
değil, subscription-seviyesi deployment kaydının bölgesidir.

Repoda **tek bir explicit `dependsOn` yoktur** (`grep -rn dependsOn infra/` → 0 sonuç). Tüm
bağımlılıklar üç şeyden implicit doğar: symbolic property referansı, `parent:` ve `scope:`.
Aşağıdaki graf `az bicep build` çıktısından birebir okunmuştur:

```
az deployment sub create  (subscription scope)
│
├─ Microsoft.Resources/resourceGroups   rg-imgresizer-dev      dependsOn: —
│
└─ Microsoft.Resources/deployments      "resources"            dependsOn: [rg]
   nested · mode=Incremental · expressionEvaluationOptions.scope=inner
   │
   │   ÜÇ BAĞIMSIZ KÖK — hiçbirinin dependsOn'u yok, ARM üçünü PARALEL kurar
   ├──────────────────────┬───────────────────────┬─────────────────────┐
   ▼                      ▼                       ▼                     │
 stimgresizerdev      log-imgresizer-dev     asp-imgresizer-dev          │
 (StorageV2)          (Log Analytics)        (FC1 / FlexConsumption)     │
   │                      │                       │                     │
   ▼ parent:              ▼ WorkspaceResourceId   │                     │
 blobServices/default   appi-imgresizer-dev       │                     │
   │                    (App Insights)            │                     │
   ├─ uploads      ┐        │                     │                     │
   ├─ thumbnails   │ copy   │                     │                     │
   └─ deploymentpackage     │                     │                     │
                            │                     │                     │
   └────────────────────────┴─────────────────────┘                     │
                            ▼                                           │
                   func-imgresizer-dev                                  │
                   dependsOn: [appi, asp, stimgresizerdev]  ◄───────────┘
                   identity: SystemAssigned
                            │
                            ▼  principalId ancak app oluşunca bilinir
                   3 × roleAssignments  (scope: stimgresizerdev)
                   dependsOn: [func-imgresizer-dev, stimgresizerdev]
```

Function App'in üç bağımlılığının hepsi *property okumasından* doğar:
`plan.id` ([resources.bicep:105](../infra/resources.bicep)),
`appInsights.properties.ConnectionString` ([:138](../infra/resources.bicep)),
`storage.properties.primaryEndpoints.blob` ([:112](../infra/resources.bicep)). ARM bir property
okunuyorsa o kaynağın önce hazır olmasını zorunlu kılar.

**Flex'e özgü kritik nokta:** runtime ve deployment ayarları app setting değil,
`functionAppConfig` altındadır ([resources.bicep:108-126](../infra/resources.bicep)). Bu yüzden
`WEBSITE_RUN_FROM_PACKAGE`, `WEBSITE_CONTENTAZUREFILECONNECTIONSTRING`, `WEBSITE_CONTENTSHARE`,
`FUNCTIONS_WORKER_RUNTIME`, `FUNCTIONS_EXTENSION_VERSION` **ayarlanmaz**
([resources.bicep:93-96](../infra/resources.bicep)). Canlı ortam bunu deneysel olarak doğrular:
app settings'te tam olarak 2 satır vardır.

## A.5 App Insights nasıl bağlanıyor

Zincir dört halkadır ve ilk halkası bu deployment'ta kurulur:

```
logAnalytics.id ──► appInsights.WorkspaceResourceId      resources.bicep:75
                    (workspace-based model)
appInsights.properties.ConnectionString
        │
        └──► app setting APPLICATIONINSIGHTS_CONNECTION_STRING   resources.bicep:137-138
                    │
                    └──► worker: UseAzureMonitorExporter()       Program.cs:34-37
                         host.json telemetryMode: OpenTelemetry  host.json:3
                                │
                                └──► appi-imgresizer-dev ──► log-imgresizer-dev
```

Bağlantı Bicep'te bir string enjeksiyonundan ibarettir; telemetriyi gönderen taraf worker'dır.
`UseAzureMonitorExporter()` yalnızca `!IsDevelopment()` iken devrededir
([Program.cs:34-36](../src/ImageResizeFunction/Program.cs)).

## A.6 A'nın sonunda ne var, ne yok

**Var:** 6 Azure kaynağı — `rg-imgresizer-dev`, `stimgresizerdev`, `log-imgresizer-dev`,
`appi-imgresizer-dev`, `asp-imgresizer-dev`, `func-imgresizer-dev`. Ayrıca `blobServices/default`
ve üç container (`uploads`, `thumbnails`, boş `deploymentpackage`), Function App'in
System-Assigned Managed Identity'si ve üç storage rol ataması,
`az deployment sub create` çıktısından okunan iki output.

**Yok:** Fonksiyon yok (`func-imgresizer-dev` kabuktur, kodu yoktur). `egst-imgresizer-dev` de
henüz yok — o kaynak yalnızca [eventgrid.bicep:30](../infra/eventgrid.bicep)'da tanımlıdır ve
Adım 3'te oluşur; dolayısıyla Event Grid bağlantısı yok. `azure-webjobs-hosts` /
`azure-webjobs-secrets` container'ları henüz yok.

`Deploy Bicep` adımı output'ları `$GITHUB_OUTPUT`'a yazar
([cd.yml:43-44](../.github/workflows/cd.yml)). [main.bicep:47-49](../infra/main.bicep) üç output
verir; CD ikisini tüketir, `storageAccountName` kullanılmaz.

---

# B. İlk application deployment

## B.1 Yeni runner — taşınan tek şey string

`deploy` job'ı ayrı bir sanal makinede başlar. `infra` job'ının dosya sistemi, Azure CLI oturumu
ve token'ı **taşınmaz**; bu yüzden `actions/checkout@v4` ve `Azure login (OIDC)` tekrarlanır
([cd.yml:51-58](../.github/workflows/cd.yml)) — aynı federated credential üzerinden ikinci bir
token değişimi yapılır.

Job'lar arasında geçen tek şey string output'lardır ve aktarım dört katmanlıdır:

```
Deploy Bicep step scripti
   └─► $GITHUB_OUTPUT dosyası                  cd.yml:43-44
        └─► steps.deploy.outputs.*             (yalnızca aynı job içinde görünür)
             └─► jobs.infra.outputs.*          cd.yml:21-23   ← job sınırını aşan köprü
                  └─► needs.infra.outputs.*    cd.yml:77-78, 84
```

`needs: infra` ([cd.yml:49](../.github/workflows/cd.yml)) tek satırı üç şeyi aynı anda garanti
eder: **sıra** (altyapı bitmeden zip atılmaz), **veri** (`needs.infra.outputs` context'i ancak
`needs:` bildirilirse dolar), **başarısızlık kapısı** (infra düşerse `deploy` hiç koşmaz).

## B.2 Publish and package — deployment paketi neyden oluşuyor

```bash
dotnet publish src/ImageResizeFunction/ImageResizeFunction.csproj \
  --configuration Release --output ./publish
cd publish && zip -rq ../app.zip .
```

`cd publish` sonrası zip'lenmesi önemlidir: publish çıktısı zip'in **kökünde** yer alır, sarmalayıcı
klasör oluşmaz.

Paketin içindeki iki kritik dosya:

| Dosya | Üreten | Rolü |
|---|---|---|
| `ImageResizeFunction.dll` | derleyici (`OutputType Exe`, [csproj:6](../src/ImageResizeFunction/ImageResizeFunction.csproj)) | isolated worker süreci |
| `functions.metadata` | `Microsoft.Azure.Functions.Worker.Sdk` ([csproj:19](../src/ImageResizeFunction/ImageResizeFunction.csproj)) | fonksiyon kataloğu |

`functions.metadata`, `[Function]` ve `[BlobTrigger]` attribute'larından **build zamanında**
üretilir — host çalışma anında assembly'yi reflection'la taramaz, bu dosyayı okur. Yerel build
çıktısının tamamı:

```json
[{ "name": "ResizeImage",
   "scriptFile": "ImageResizeFunction.dll",
   "entryPoint": "ImageResizeFunction.ResizeImage.Run",
   "language": "dotnet-isolated",
   "properties": { "IsCodeless": false },
   "bindings": [{ "name": "incomingBlob", "direction": "In", "type": "blobTrigger",
                  "path": "uploads/{name}", "source": "EventGrid",
                  "connection": "AzureWebJobsStorage",
                  "properties": { "supportsDeferredBinding": "True" } }] }]
```

Azure'ın `func-imgresizer-dev/ResizeImage` için raporladığı binding bu `bindings` girdisiyle
birebir örtüşür — `properties.supportsDeferredBinding` dahil yedi alanın hepsi taşınmıştır.
(Fonksiyon düzeyindeki `IsCodeless` ARM'ın fonksiyon çıktısında görünmez.) Yani "Azure
fonksiyonu nereden biliyor" sorusunun cevabı bu dosyadır ve kaynağı
[ResizeImage.cs:11,15](../src/ImageResizeFunction/ResizeImage.cs)'tir.

## B.3 Deploy to Function App

```bash
az functionapp deployment source config-zip \
  --resource-group "${{ needs.infra.outputs.resourceGroup }}" \
  --name "${{ needs.infra.outputs.functionApp }}" \
  --src app.zip
```

Komut jenerik bir zipdeploy değildir; plan tipine göre dallanır. `azure-cli 2.88.0` kaynağında
doğrulanan yol:

```
config-zip
 └─ enable_zip_deploy_functionapp
     └─ is_flex_functionapp()            utils.py:230-235
        sku.lower() == 'flexconsumption'  ← canlı sku: FlexConsumption ✓ dal kesin alınıyor
         └─ enable_zip_deploy_flex        custom.py:839
             runtime = "dotnet-isolated"
             build_remote = build_remote or runtime == 'python'   → False
             POST {scm}/api/publish?RemoteBuild=False&Deployer=az_cli
             Content-Type: application/zip
             Authorization: Bearer <AAD token>   (get_scm_site_headers_flex)
```

İki sonuç: (1) Flex'te klasik `/api/zipdeploy` yerine **One Deploy** kullanılır ve CLI bunu kendi
seçer — workflow'da ek bayrak yoktur. (2) SCM'e **publishing-profile basic auth ile değil, AAD
bearer token ile** gidilir; yani OIDC kimliği data-plane'i de kapsar ve saklanan bir publish
profile secret'ı yoktur.

Alternatif komut `az functionapp deploy --src-path` bu projede kullanılmaz: aynı kaynakta
`_get_ondeploy_headers` (custom.py:11363-11364) `--src-path` yolunda `application/octet-stream`
gönderir ve One Deploy endpoint'i bu içerik tipini kabul etmez.
Gerekçe ve izolasyon testi: [docs/decisions.md:55-71](decisions.md).

Paket nihayetinde `deploymentpackage` container'ına yazılır ve Flex uygulamayı **oradan
çalıştırır** — hedef ve kimlik [resources.bicep:108-116](../infra/resources.bicep)'te bildirilmiştir:

```
value:          https://stimgresizerdev.blob.core.windows.net/deploymentpackage
authentication: SystemAssignedIdentity          ← Function App'in KENDİ kimliği
```

**GitHub SP'nin storage veri rolüne ihtiyaç duymamasının sebebi budur:** yazma işlemini deploy eden
kimlik değil, uygulamanın kendi Managed Identity'si yapar. Bu yüzden
[A.4](#a4-deploy-bicep--arm-kaynakları-hangi-sırayla-oluşturur)'teki Blob Data Owner ataması bu
adımdan önce tamamlanmış olmalıdır. *(Bu, bildirilen konfigürasyonun sonucudur; platformun iç
hand-off'u bu doküman kapsamında izlenmedi.)*

## B.4 Komut neden bloke olur — sıralamayı mümkün kılan asıl mekanizma

`config-zip` POST'tan sonra dönmez. Bekleme iki ayrı fonksiyona bölünmüştür — önce paketin
yüklenmesi, sonra uygulamanın sağlığı:

```
enable_zip_deploy_flex                                custom.py:839
  POST {scm}/api/publish
  202 ise → _check_zip_deployment_status_flex         custom.py:10088
            {scm}/api/deployments/latest döngüyle yoklanır
  409 ise → "There may be an ongoing deployment"

check_flex_app_after_deployment                       custom.py:800-836
  1. logger.warning("Waiting for sync triggers...")
     time.sleep(60)                                   ← SABİT 60 saniye
  2. master key alınır → GET {host}/admin/host/status
     header: x-functions-key
     15 deneme × 2 sn arayla
  3. 200 gelmezse:
     CLIError("Deployment was successful but the app appears to be unhealthy")
     → step kırılır → job kırılır → Connect Event Grid HİÇ KOŞMAZ
```

Deployment durumu yoklaması POST'u yapan fonksiyonun **içindedir**; health check ondan sonra,
ayrı bir fonksiyonda çalışır. `check_flex_app_after_deployment`'ın ilk işi bir HTTP çağrısı değil,
koşulsuz 60 saniyelik `sleep`'tir.

CD'de ayrı bir `wait` veya retry adımı bulunmaması ihmal değildir — **bekleme komutun içindedir**.
Retry döngüsünün bilinçli olarak kaldırıldığı [docs/decisions.md:73-75](decisions.md)'te kayıtlıdır.

## B.5 Host paketi alır, fonksiyonları keşfeder, trigger'lar canlanır

```
host başlar
   └─ deploymentpackage'tan paketi okur   (functionAppConfig.deployment.storage)
       └─ functions.metadata'yı okur → ResizeImage'ı kaydeder
           ├─ blobTrigger + source=EventGrid → blob uzantısını yükler
           │    └─ blobs_extension SYSTEM KEY'i burada var olur   ⚑ Adım 3'ün ön koşulu
           ├─ azure-webjobs-secrets  container'ını oluşturur      (Bicep'te YOK)
           └─ azure-webjobs-hosts    container'ını oluşturur      (Bicep'te YOK)
   └─ sync triggers: trigger envanteri platforma bildirilir
```

Son iki container'ın runtime'da yaratıldığı canlı durumla kanıtlanır: storage'da beş container
vardır ama [resources.bicep:45-56](../infra/resources.bicep) yalnızca üçünü tanımlar
(`uploads`, `thumbnails`, `deploymentpackage`).

`AzureWebJobsStorage__accountName` ([resources.bicep:133-134](../infra/resources.bicep)) çift alt
çizgi soneki sayesinde identity-based connection devreye girer: host hesap adından servis
URI'lerini türetir ve Managed Identity ile bağlanır. Uygulama tarafındaki karşılığı
[Program.cs:21-29](../src/ImageResizeFunction/Program.cs)'daki `DefaultAzureCredential`'dır.

## B.6 Connect Event Grid — neden EN SON

```bash
az deployment group create \
  --resource-group "${{ needs.infra.outputs.resourceGroup }}" \
  --name eventgrid \
  --template-file infra/eventgrid.bicep
```

Bu **RG scope'unda ikinci ve bağımsız** bir deployment'tır (main.bicep subscription scope'undaydı);
`--location` almaz, ama RG adına ihtiyaç duyar — job output'unun ikinci tüketim noktası budur.

En sona kalması **iki bağımsız zorunluluğa** dayanır:

**(1) Anahtar.** Derlenmiş `endpointUrl` ifadesi:

```
listKeys(format('{0}/host/default', resourceId('Microsoft.Web/sites', ...)),
         '2024-11-01').systemKeys.blobs_extension
```

`blobs_extension` ancak host blob uzantısını yükledikten sonra vardır — yani B.5'ten önce
`listKeys` çözülemez. Derlenmiş şablonlarda `listKeys` sayımı: `main.json` = **0**,
`resources.json` = **0**, `eventgrid.json` = **1**. Anahtarın niteliği (storage anahtarı değil,
webhook'un yetkilendirmesi) [docs/decisions.md:50-53, 127-128](decisions.md)'de.

**(2) Endpoint doğrulama.** Event Grid subscription yaratılırken webhook hedefini doğrular;
`Host.Functions.ResizeImage` kayıtlı değilse
`Endpoint validation: Destination endpoint not found` alınır
([eventgrid.bicep:1-3](../infra/eventgrid.bicep)).

Hedefin `AzureFunction` değil `WebHook` olmasının sebebi ayrı bir konudur:
[docs/decisions.md:37-53](decisions.md).

Dosyadaki iki `existing` referansı ([eventgrid.bicep:22-28](../infra/eventgrid.bicep)) **hiçbir ARM
kaynağı üretmez** ve **hiçbir dependsOn oluşturmaz** — derlenmiş `eventgrid.json`'da toplam 2 kaynak
vardır ve `systemTopic`, `source: storage.id` kullanmasına rağmen `dependsOn`'u yoktur. `existing`
yalnızca `resourceId()` / `reference()` / `listKeys()` ifadelerine derlenir.

## B.7 Doğrulanmış son durum

```
uploads/ ──BlobCreated──► egst-imgresizer-dev ──WebHook──► func-imgresizer-dev
                          (Succeeded)          maxEvents=1  /runtime/webhooks/blobs
                                                            ?functionName=Host.Functions.ResizeImage
                                                            &code=<blobs_extension>
                                                                    │
                                    filtre: subjectBeginsWith       ▼
                                    /blobServices/default/          ResizeImage.Run
                                    containers/uploads/             150×150 Max
                                                                    │
                                    ⚑ filtre olmasa kendi çıktısı   ▼
                                      sonsuz döngü yaratırdı        thumbnails/
```

Canlı doğrulama: `sub-uploads-to-resizeimage` (adı
[eventgrid.bicep:41](../infra/eventgrid.bicep)'deki `sub-${sourceContainer}-to-${toLower(functionName)}`
ifadesinin karşılığı) durumu `Succeeded`, hedef tipi `WebHook`, retry 3 deneme / 1440 dakika.

Deployment geçmişindeki zaman damgaları sıralamayı da gösteriyor: `image-resizer` 11:05:02'de,
`eventgrid` 11:08:38'de tamamlanmış. Aradaki ~3 dk 36 sn tek bir adımın değil **B.1-B.6'nın
tamamının** penceresidir: `deploy` runner'ının tahsisi, `checkout` + `Azure login` +
`setup-dotnet` ([cd.yml:51-62](../.github/workflows/cd.yml)), publish + zip, upload, 60 sn sync
bekleme, health check ve `eventgrid` deployment'ının kendisi. Sonuncunun payı ölçülüdür: ARM'ın
raporladığı süre 13,2 sn.

---

# C. Sonraki application deployment'lar

## C.1 Fark

Pipeline **birebir aynıdır** — her push üç adımı da çalıştırır. Tek fark şudur: `Deploy Bicep`
artık pratikte hiçbir şeyi değiştirmez, `Deploy to Function App` ise her seferinde gerçek iş yapar.

Bu, "gereksiz adım" değildir: altyapının her deploy'da yeniden bildirilmesi, elle yapılmış drift'in
geri alınmasını ve şablonun tek doğruluk kaynağı kalmasını sağlar.

## C.2 what-if kanıtı

Mevcut canlı ortama karşı `az deployment sub what-if` (CI'ın çalıştırdığı komutun aynısı, salt-okunur)
şu sonucu verir:

```
NoChange  rg-imgresizer-dev              Ignore  egst-imgresizer-dev
NoChange  log-imgresizer-dev             Ignore  Application Insights Smart Detection
NoChange  stimgresizerdev
NoChange  asp-imgresizer-dev             Modify  ×9
                                         ─────────────────────
                                         4 NoChange · 9 Modify · 2 Ignore
```

**`Ignore` satırları incremental mode'un doğrudan kanıtıdır.** `egst-imgresizer-dev` bu şablonda
tanımlı değildir (o `eventgrid.bicep`'in kaynağıdır), "Smart Detection" action group'unu ise platform
yaratmıştır. Incremental mode şablonda olmayan kaynağı **silmez**, yok sayar
([docs/decisions.md:24-26](decisions.md)).

## C.3 Dokuz `Modify` neden gerçek değişiklik değil

Bu ayrım operasyonel olarak önemlidir: CI'daki what-if çıktısı hiçbir zaman "tertemiz" olmaz ve
hangi satırların artefakt olduğunu bilerek okumak gerekir.

| Kaynak | Delta | Neden artefakt |
|---|---|---|
| 3 × roleAssignment | `properties.principalId` Modify | `before` = `f664b13f-…` (gerçek GUID), `after` = **çözülmemiş** `reference(...).identity.principalId`. what-if runtime referanslarını çözemez; deploy'da aynı GUID'e çözülür. |
| `func-imgresizer-dev` | `functionAppConfig.deployment.storage.value` Modify | `before` = literal URL, `after` = çözülmemiş `format(reference(...))`. Aynı sebep. |
| `func-imgresizer-dev` | `localMySqlEnabled`, `netFrameworkVersion` Create | Provider tarafı varsayılanlar; şablonda yok. |
| `appi-imgresizer-dev` | `Flow_Type`, `Request_Source` Create | Aynı şekilde provider varsayılanı. |
| `blobServices/default` + 3 container | `properties` **Delete** | Şablon dördünü de property'siz tanımlar ([resources.bicep:40-43](../infra/resources.bicep) blobServices, [:45-56](../infra/resources.bicep) container'lar); what-if bunu "silinecek" diye projekte eder. Incremental mode'da belirtilmeyen property'ler korunur. |

Yani dokuz satırın hiçbiri drift değildir; ARM'ın `reference()` çözemediği ve provider
varsayılanlarını bilmediği plan-zamanı sınırlarıdır.

## C.4 Idempotency'yi taşıyan üç mekanizma

1. **Deterministik isimler.** `guid(storage.id, functionApp.id, roleId.value)`
   ([resources.bicep:151](../infra/resources.bicep)) aynı üç girdi için hep aynı GUID'i üretir.
   Kanıt: what-if üç rol atamasını *mevcut* kaynaklarla eşleştirdi — tekrar deploy yeni atama
   yaratmaz, aynı kaynağa idempotent PUT yapar. `guid()` ayrıca roleAssignment adının GUID
   formatında olma zorunluluğunu da karşılar.
2. **Sabit deployment adları.** `image-resizer` / `resources` / `eventgrid`. Canlı geçmiş bunu
   doğruluyor: subscription'da **tek** kayıt (`image-resizer`), RG'de **iki** kayıt (`resources`,
   `eventgrid`). Sabit ad her koşuda aynı kaydın üzerine yazar — geçmiş şişmez, ama önceki koşunun
   ayrı bir kaydı da kalmaz.
3. **PUT semantiği.** ARM diff uygulamaz, her kaynağı hedef durumuyla yeniden bildirir; değişmemiş
   kaynaklar [C.2](#c2-what-if-kanıtı)'deki dört `NoChange` satırını üretir.

## C.5 Gerçekten değişen ne

**Adım 2 her zaman gerçek iş yapar:** yeni `app.zip` üretilir, `deploymentpackage`'a yazılır, host
yeni paketle yeniden başlar. Uygulama deployment'ının kendisi idempotent değildir ve olması da
beklenmez.

**Adım 3 idempotenttir ama boşuna değildir:** `endpointUrl` her koşuda canlı `blobs_extension`
anahtarından yeniden hesaplanır, yani subscription güncel anahtara yeniden sabitlenir. *(Bu, şablonun
yapısından çıkan bir sonuçtur; anahtar rotasyonu senaryosu test edilmedi.)*

## C.6 Tekrarlanan deploy'larda gözlenen boşluklar

Bunlar [docs/decisions.md:130-136](decisions.md)'daki listeye ek gözlemlerdir:

- **`concurrency:` bloğu yok.** `main`'e arka arkaya iki push çakışan iki CD koşusu üretebilir;
  ikisi de `image-resizer` deployment adını kullanır ve ikinci `config-zip` "ongoing deployment"
  (409) alabilir. Pratikte gerçekleşip gerçekleşmediği doğrulanmadı.
- **Artifact provenance zinciri yok.** CI hiçbir artifact üretmez; `deploy` job'ı kaynaktan yeniden
  publish eder ([cd.yml:64-68](../.github/workflows/cd.yml)). PR'da derlenen binary ile prod'a giden
  binary aynı build değildir.
- **Test adımı yok.** CI'ın `build` job'ı yalnızca `Restore` + `Build` çalıştırır; `src/` altında
  test projesi bulunmaz.
- **Environment protection / manuel onay / rollback yok.** `main`'e push doğrudan `dev`'i değiştirir.

---

# D. Infrastructure değişikliği

## D.1 Akış

```
infra/*.bicep düzenlenir
   └─ PR açılır ──► ci.yml
        Bicep build      (offline; ARM JSON üretir, Azure'a bağlanmaz → fail fast,
                          bu yüzden Azure login'den ÖNCE koşar — ci.yml:21-24)
        Azure login (OIDC)
        Bicep what-if    (yalnızca main.bicep; eventgrid.bicep hariç — ci.yml:33-34)
   └─ merge ──► cd.yml ──► Deploy Bicep ──► ARM
```

`eventgrid.bicep` CI'da **derlenir** ([ci.yml:24](../.github/workflows/ci.yml)); CI'da atlanan tek
şey onun what-if'idir — hedefi olan fonksiyon PR anında henüz değerlendirilebilir durumda değildir.

what-if `--parameters` almaz, yani fark **canlı `dev` ortamına karşı** hesaplanır.

## D.2 ARM'ın rolü

**Sıralamayı şablon değil ARM belirler.** Bağımlılık grafı topolojik sıralanır, bağımsız düğümler
eşzamanlı işlenir — [A.4](#a4-deploy-bicep--arm-kaynakları-hangi-sırayla-oluşturur)'teki üç kök ve
`appContainers` copy-loop'unun iki elemanı bu yüzden paralel oluşur.

**Incremental mode.** `az deployment sub/group create` varsayılanı; derlenmiş şablonda nested
deployment için de açıkça `"mode": "Incremental"` görünür. Şablondan **silinen kaynak Azure'dan
silinmez** — [C.2](#c2-what-if-kanıtı)'deki iki `Ignore` satırı bunun canlı kanıtıdır. Gerekirse
Deployment Stacks ile kapatılabilir ([docs/decisions.md:24-26](decisions.md)).

**Deployment history.** Üç sabit ad üç kayıt üretir ve her koşu kendi kaydının üzerine yazar:

```
subscription  └─ image-resizer   (cd.yml:38)
rg-imgresizer-dev
              ├─ resources       (main.bicep:36 — modül adı)
              └─ eventgrid       (cd.yml:85)
```

**Nested deployment.** [main.bicep:35-45](../infra/main.bicep)'teki modül,
`Microsoft.Resources/deployments` tipine derlenir. `expressionEvaluationOptions.scope = "inner"`
olduğu için modül parametreleri kendi bağlamında değerlendirilir; `main.bicep` değişkenleri modüle
sızmaz. Bicep'te bir dosyanın tek scope'ta çalışması nedeniyle RG-seviyesi kaynaklar bu modüle
devredilmek zorundadır ([docs/decisions.md:99-104](decisions.md)).

## D.3 Hangi değişiklikler uygulamanın yeniden deploy edilmesini gerektirir

### Gerektirmeyenler

`maximumInstanceCount`, `instanceMemoryMB` ([main.bicep:21-28](../infra/main.bicep)), Log Analytics
`retentionInDays` — `functionAppConfig` / kaynak property güncellemesidir, paket etkilenmez.

### Gerektirenler

**Deployment container adı** ([resources.bicep:15](../infra/resources.bicep)). Değiştirildiğinde
`functionAppConfig.deployment.storage.value` **yeni ve boş** bir container'a döner; mevcut paket eski
container'da kalır. Yeni konumda paket olmadığı için uygulama kodsuz kalır.

```
öncesi:  value → …/deploymentpackage      [paket VAR]
sonrası: value → …/yenicontainer          [BOŞ]  → config-zip çalışana kadar kod yok
```

CD'de bu kendiliğinden düzelir çünkü Adım 2 her zaman Adım 1'i takip eder. **Elle yalnızca altyapı
deploy edilirse uygulama kırılır** — [README.md:59-74](../README.md)'teki üç adımın sırasının sebebi budur.

**Runtime sürümü.** Aynı sürüm **dört yerde** tekrarlanır ve birlikte hareket etmek zorundadır:

```
infra/resources.bicep:123-124   runtime: dotnet-isolated / 10.0   ← platform worker'ı
src/…/ImageResizeFunction.csproj:4  <TargetFramework>net10.0</…>  ← paketin hedefi
.github/workflows/ci.yml:50     dotnet-version: "10.x"            ← CI SDK
.github/workflows/cd.yml:62     dotnet-version: "10.x"            ← paketi üreten SDK
```

Yalnızca Bicep değiştirilirse eski paket yeni worker'da kalır; yalnızca `csproj` değiştirilirse
platform eski worker'ı yüklemeye devam eder. Her iki durumda da paketin yeniden üretilmesi, yani
uygulama deployment'ı zorunludur.

**Fonksiyon adı** — `[Function(nameof(ResizeImage))]`
([ResizeImage.cs:11](../src/ImageResizeFunction/ResizeImage.cs)) ile `functionName` parametresi
([eventgrid.bicep:16](../infra/eventgrid.bicep)) birebir aynı olmalıdır. Burada incremental mode'un
keskin bir yan etkisi vardır: subscription adı `sub-${sourceContainer}-to-${toLower(functionName)}`
formülünden geldiği için ad değişince **yeni** bir subscription yaratılır, eskisi silinmez (`Ignore`)
→ iki subscription aynı olayı teslim eder. Eskisi elle silinmelidir.

**Kaynak container** ([eventgrid.bicep:18](../infra/eventgrid.bicep)) — üçlü kuplaj: subscription adı,
`subjectBeginsWith` filtresi ve `BlobTrigger("uploads/{name}")`
([ResizeImage.cs:15](../src/ImageResizeFunction/ResizeImage.cs)). Aynı `Ignore` tuzağı geçerlidir.

**Storage hesabı adı** (`project` / `environment` parametreleri) — yeni hesap, yeni container'lar, boş
`deploymentpackage`; eski hesap yerinde kalır. *Bu senaryo test edilmedi; isimlendirme şablonundan
çıkarımdır.*

## D.4 Parametre kuplajı — mekanizmasız bir bağ

Ne [cd.yml:37-41](../.github/workflows/cd.yml) ne de [cd.yml:83-86](../.github/workflows/cd.yml)
`--parameters` geçer. Dolayısıyla:

```
main.bicep:11,16        project='imgresizer'  environment='dev'
eventgrid.bicep:7,11    project='imgresizer'  environment='dev'
                        └── bu iki dosya ELLE senkron tutulur; zorlayan mekanizma YOK
```

`main.bicep`'te `project` değiştirilip `eventgrid.bicep` unutulursa, `eventgrid.bicep`'in `existing`
referansları var olmayan bir storage/app'i hedefler ve Adım 3 çözümleme hatasıyla düşer. Bugün
tutarlıdırlar (canlı adlar bunu doğruluyor), ancak bu kırılganlığın bilinçli kabul edildiği
dokümanlarda yer almıyor.

---

## Doküman driftleri

Bunlar doğrulanmış tutarsızlıklardır; kod yolu doğru, onu tarif eden metin eskimiş:

- **[README.md:68](../README.md)** hâlâ `az functionapp deploy … --type zip` öneriyor;
  [cd.yml:76](../.github/workflows/cd.yml) ve [docs/decisions.md:55-71](decisions.md) `config-zip`
  diyor.
- **[cd.yml:70-71](../.github/workflows/cd.yml)** yorumu 415'in sebebini `Content-Type:
  application/json` olarak yazıyor; gönderilen tip `application/octet-stream`'dir
  ([B.3](#b3-deploy-to-function-app)).

## Doğrulanamayanlar

- **OIDC `sub` claim biçimi.** [bootstrap.md:51](bootstrap.md) subject'i immutable-ID biçiminde
  (`repo:owner@<id>/repo@<id>:…`) kuruyor. Gerçekte yayımlanan token payload'ı incelenmedi.
- **`reserved` uyuşmazlığı.** [resources.bicep:89](../infra/resources.bicep) `reserved: true` yazar,
  canlı plan çıktısı `"reserved": null` gösterir. App `kind: functionapp,linux` olarak çalıştığı için
  pratikte Linux olduğu kesin; alanın neden null döndüğü belirsiz.
- **`siteUpdateStrategy: { type: Recreate }`** canlı `functionAppConfig` altında görünüyor ama
  [infra/resources.bicep](../infra/resources.bicep)'te hiç tanımlı değil. Platform varsayılanı olduğu
  tahmin ediliyor; `functionAppConfig` değişikliklerinde site'ı gerçekten recreate edip etmediği test
  edilmedi — bu, D.3'teki "gerektirmeyenler" listesini etkileyebilir.
- **`allowSharedKeyAccess`** ayarlanmamış, canlı çıktıda `sharedKey: null`. "Ayarlanmamış" mı "devre
  dışı" mı olduğu çıktıdan anlaşılmıyor.
- **Implicit bağımlılık boşluğu.** Function App'in `dependsOn` listesi
  `[appi, asp, stimgresizerdev]`'dir; `deploymentpackage` container'ı **listede yoktur**, çünkü
  [resources.bicep:112](../infra/resources.bicep) container'ın symbolic referansını değil yalnızca
  `storage.properties.primaryEndpoints.blob`'u okur ve container adı bir string değişkenidir. Yani
  ARM ikisini paralel oluşturabilir. Gerçek bir yarış koşulu yaratıp yaratmadığı doğrulanmadı;
  mevcut ortamda her şey `Succeeded`.
- **RBAC propagasyon zamanlaması.** Rol atamaları Function App'ten sonra oluşur, ancak app'in paketi
  çekebilmesi Blob Data Owner'a bağlıdır. `infra` ve `deploy`'un ayrı job olması araya gecikme koyar,
  fakat bunun propagasyon için bilinçli bir önlem olduğu ne [cd.yml](../.github/workflows/cd.yml)'de
  ne [decisions.md](decisions.md)'de belirtilmiş — bu bir çıkarımdır.
- **RBAC çıktısının kapsamı.** Canlı sorgu assignee = Function App MI ile filtrelenmiştir. Bu yüzden
  iki şey doğrulanmadı: SP'nin `Contributor` + `Role Based Access Control Administrator` atamaları
  (yalnızca [bootstrap.md:73-82](bootstrap.md)'ye dayanıyor) ve `stimgresizerdev` scope'unda başka
  principal'ın veri rolü bulunmadığı ([A.3](#a3-yetki-rbac-iki-ayrı-yerde-devreye-girer)).
- **`/admin/host/status` 200 dönmesi**, `.../functions/ResizeImage` ARM alt kaynağının varlığını
  biçimsel olarak garanti etmez. Güçlü bir vekil göstergedir; pratikte çalıştığı canlı durumla sabittir.
- **`az bicep install` adımı yok** ([ci.yml:21-24](../.github/workflows/ci.yml)); Bicep CLI'ın
  `ubuntu-latest`'te hazır bulunduğu veya `az bicep build` tarafından otomatik kurulduğu repo içinden
  doğrulanamadı.
- **Ölçüm iddiaları** — [decisions.md:33](decisions.md)'teki "~4 saniye uçtan uca gecikme" ve
  [main.bicep:21](../infra/main.bicep)'deki "512 = 0.25 vCPU" bu analiz kapsamında doğrulanmadı.
