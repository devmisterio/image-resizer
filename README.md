# Image Resizer

Azure üzerinde çalışan, event-driven bir thumbnail oluşturma servisi. `uploads` container'ına bir görsel yüklendiğinde Azure Function otomatik olarak tetiklenir ve 150×150 piksel thumbnail'ı `thumbnails` container'ına yazar.

## Mimari

```
uploads/         BlobTrigger        thumbnails/
[Storage] ──────────────────> [Function App] ──> [Storage]
                                    │
                                    └──> [Application Insights]
                                              │
                                         [Log Analytics]
```

**Temel kararlar:**

| Karar | Tercih | Neden |
|---|---|---|
| Kimlik doğrulama | Managed Identity | Connection string sıfır; secret yok |
| Compute | Consumption Plan (Y1) | Event-driven iş yükü, maliyet optimizasyonu |
| Telemetri | OpenTelemetry | Vendor-agnostic; ileride backend değiştirilebilir |
| Runtime | .NET 10, Isolated Worker | In-process deprecated; tek desteklenen model |
| IaC | Terraform | Remote state, modüler bootstrap/infra ayrımı |

## Proje Yapısı

```
image-resizer/
├── bootstrap/          # Terraform state backend + CI/CD identity (bir kez çalıştır)
│   ├── main.tf         # Storage account, Service Principal, Federated Credential, RBAC
│   └── variables.tf
│
├── infra/              # Uygulama altyapısı (CI/CD pipeline'dan çalışır)
│   ├── main.tf         # Function App, Storage, Application Insights, RBAC
│   ├── outputs.tf
│   └── variables.tf
│
└── src/
    └── ImageResizeFunction/
        ├── ResizeImage.cs   # BlobTrigger → thumbnail işleme mantığı
        ├── Program.cs       # DI kurulumu, OpenTelemetry konfigürasyonu
        └── host.json
```

## Gereksinimler

| Araç | Minimum Sürüm |
|---|---|
| [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) | 2.60+ |
| [Terraform](https://developer.hashicorp.com/terraform/install) | 1.9+ |
| [.NET SDK](https://dotnet.microsoft.com/download) | 10.0 |
| [Azure Functions Core Tools](https://learn.microsoft.com/en-us/azure/azure-functions/functions-run-local) | 4.x |
| [Azurite](https://learn.microsoft.com/en-us/azure/storage/common/storage-use-azurite) | 3.x (local test) |

## Deployment

### 1. Bootstrap (İlk kurulumda bir kez)

Bootstrap, Terraform state'ini tutacak storage account'ı ve GitHub Actions için kimlik altyapısını oluşturur.

```bash
cd bootstrap

# terraform.tfvars oluştur (git'e commit edilmez)
cat > terraform.tfvars <<EOF
subscription_id = "<AZURE_SUBSCRIPTION_ID>"
github_username = "<GITHUB_USERNAME>"
github_repo     = "image-resizer"
EOF

terraform init
terraform apply
```

Bootstrap çıktılarını GitHub repository **Settings → Secrets and Variables → Actions** bölümüne ekle:

| Secret | Değer |
|---|---|
| `AZURE_CLIENT_ID` | Service Principal client ID |
| `AZURE_TENANT_ID` | Azure tenant ID |
| `AZURE_SUBSCRIPTION_ID` | Subscription ID |

### 2. Infra Deploy

Bootstrap tamamlandıktan sonra infra, CI/CD pipeline üzerinden deploy edilir.

Manuel çalıştırmak için:

```bash
cd infra

# terraform.tfvars oluştur (git'e commit edilmez)
cat > terraform.tfvars <<EOF
subscription_id = "<AZURE_SUBSCRIPTION_ID>"
EOF

terraform init   # Remote backend'e bağlanır (sttfstateimgresizer)
terraform apply
```

## Local Development

Azurite ile local storage emulator kullanılarak test yapılabilir:

```bash
# Azurite başlat (ayrı terminal)
azurite --silent --location /tmp/azurite

# Function'ı çalıştır
cd src/ImageResizeFunction
func start
```

`local.settings.json` dosyası `.gitignore`'dadır; yerel olarak `UseDevelopmentStorage=true` kullanılır. Bu değer `AzureWebJobsStorage` env variable'ı üzerinden Azurite'e bağlanır.

## Güvenlik

- **Sıfır secret:** Function App, storage account'a connection string yerine **Managed Identity** ile bağlanır.
- **Workload Identity Federation:** GitHub Actions, client secret olmadan Azure'a OIDC token ile kimlik doğrular.
- **RBAC:** Her kimliğe yalnızca ihtiyaç duyduğu roller atanmıştır (least-privilege).
- **TLS 1.2+:** Tüm storage account'larda minimum TLS versiyonu zorunlu tutulmuştur.

## Azure Kaynakları

| Kaynak | İsim | Açıklama |
|---|---|---|
| Resource Group | `rg-imgresizer-dev` | Tüm uygulama kaynakları |
| Storage Account | `stimgresizerd` | uploads + thumbnails container'ları |
| Function App | `func-imgresizer-dev` | BlobTrigger, Consumption Plan |
| App Service Plan | `asp-imgresizer-dev` | Y1 (Serverless) |
| Log Analytics | `log-imgresizer-dev` | Telemetri workspace |
| Application Insights | `appi-imgresizer-dev` | Distributed tracing ve metrikler |
