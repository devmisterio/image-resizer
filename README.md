# Image Resizer

Event-driven thumbnail servisi. `uploads` container'ına yüklenen görsel Azure Function'ı
tetikler; 150×150 sınırına sığdırılmış thumbnail `thumbnails` container'ına yazılır.

## Mimari

```
                      ┌──────────── Storage Account ────────────┐
   görsel yükle ─────►│ uploads/                     thumbnails/│◄──── thumbnail
                      │    │                              ▲     │
                      │    │ BlobCreated                  │     │
                      └────┼──────────────────────────────┼─────┘
                           ▼                              │
                    Event Grid System Topic               │
                           │ WebHook                      │
                           ▼                              │
                    Function App (Flex Consumption) ──────┘
                    .NET 10 Isolated · BlobTrigger(EventGrid)
                           │
                           └──► Application Insights ──► Log Analytics
```

| Karar | Tercih |
|---|---|
| IaC | Bicep — Azure-only, state yönetimi yok |
| Hosting | Flex Consumption (FC1) — .NET 10'u destekleyen tek serverless plan |
| Tetikleme | Event Grid blob trigger — Flex'in desteklediği tek model |
| Kimlik | Managed Identity + OIDC — depolanan secret yok |
| Deployment | One Deploy — Flex'in tek desteklenen tekniği |

Gerekçeler ve değerlendirilen alternatifler: [docs/decisions.md](docs/decisions.md)

## Yapı

```
infra/
  main.bicep        subscription scope — Resource Group + modül
  resources.bicep   Storage, App Insights, Flex plan, Function App, RBAC
  eventgrid.bicep   System Topic + Event Subscription
src/ImageResizeFunction/
  ResizeImage.cs    BlobTrigger (EventGrid) → resize → thumbnails/
  Program.cs        DI + OpenTelemetry
.github/workflows/
  ci.yml            PR: bicep build + what-if, dotnet build
  cd.yml            main: altyapı → kod → Event Grid
```

## Gereksinimler

Azure CLI 2.88+ · Bicep CLI (`az bicep install`) · .NET SDK 10.0

## Kurulum

Kimlik altyapısı subscription başına bir kez kurulur: [docs/bootstrap.md](docs/bootstrap.md)

Sonrasında `main` branch'e push yeterlidir. Elle çalıştırmak için:

```bash
# 1. Altyapı
az deployment sub create \
  --name image-resizer --location westeurope \
  --template-file infra/main.bicep

# 2. Uygulama
dotnet publish src/ImageResizeFunction/ImageResizeFunction.csproj -c Release -o publish
(cd publish && zip -rq ../app.zip .)
az functionapp deploy -g rg-imgresizer-dev -n func-imgresizer-dev --src-path app.zip --type zip

# 3. Event Grid — 2. adımdan sonra çalıştırılmalıdır
az deployment group create \
  --resource-group rg-imgresizer-dev \
  --template-file infra/eventgrid.bicep
```

Event subscription'ın hedefi `.../functions/ResizeImage` kaynağıdır; bu kaynak ancak
uygulama kodu deploy edildikten sonra oluşur.

## Doğrulama

```bash
az storage blob upload --account-name stimgresizerdev --auth-mode login \
  --container-name uploads --name test.jpg --file test.jpg

az storage blob list --account-name stimgresizerdev --auth-mode login \
  --container-name thumbnails -o table
```

Storage veri rolleri yalnızca Function App'in Managed Identity'sine verilmiştir; blob
okuyup yazabilmek için kendi hesabınıza `Storage Blob Data Contributor` gerekir.

## Güvenlik

ARM şablonunda storage hesap anahtarı bulunmaz. Function App storage'a Managed Identity
ile bağlanır, GitHub Actions Azure'a OIDC ile kimlik doğrular. CI/CD kimliği `Contributor`
ve `Role Based Access Control Administrator` rolleriyle sınırlıdır; Function App'e yalnızca
ihtiyaç duyduğu üç storage veri rolü atanmıştır.

## Kaynaklar

| Kaynak | İsim |
|---|---|
| Resource Group | `rg-imgresizer-dev` |
| Storage Account | `stimgresizerdev` — `uploads`, `thumbnails`, `deploymentpackage` |
| App Service Plan | `asp-imgresizer-dev` — FC1 / FlexConsumption |
| Function App | `func-imgresizer-dev` — .NET 10 isolated, 512 MB, max 5 instance |
| Event Grid System Topic | `egst-imgresizer-dev` |
| Application Insights | `appi-imgresizer-dev` |
| Log Analytics | `log-imgresizer-dev` |
