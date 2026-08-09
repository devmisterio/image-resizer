# CI/CD Pipeline — Uygulama Planı

> **Tarih:** 8 Ağustos 2026
> **Kapsam:** GitHub Actions CI/CD pipeline oluşturma, WIF federated credential genişletme, environment stratejisi analizi
> **Referans:** [architecture_evaluation.md](file:///Users/semih/projects/image-resizer/docs/architecture_evaluation.md) — Madde 3.4, 5.1, 5.3

---

## Mevcut Durum

| Bileşen | Durum |
|---|---|
| Service Principal | ✅ Oluşturuldu (`app-github-imgresizer`) |
| Federated Credential | ⚠️ Sadece `refs/heads/main` — PR'lar bağlanamaz |
| RBAC | ✅ Contributor + User Access Admin + Blob Data Contributor |
| `.github/workflows/` | ❌ Boş |
| Infra remote backend | ✅ Çalışıyor (`sttfstateimgresizer`) |

---

## Yapılması Gerekenler

### 1. Federated Credential — Pull Request Subject Eklenmeli

> [!IMPORTANT]
> Mevcut bootstrap'ta sadece bir credential var:
> ```
> subject = "repo:devmisterio/image-resizer:ref:refs/heads/main"
> ```
> Bu, **yalnızca** `main` branch üzerinde çalışan workflow'ların Azure'a bağlanmasına izin verir. PR'da çalışan `terraform plan` workflow'u **AuthenticationError** alır çünkü PR'ların OIDC token'ındaki `sub` claim'i farklıdır:
> ```
> repo:devmisterio/image-resizer:pull_request
> ```

Bu, WIF'in çalışma prensibi: her farklı GitHub bağlamı (branch, PR, environment) için **ayrı bir federated credential** gerekir. Wildcard desteklenmez.

#### [MODIFY] [main.tf](file:///Users/semih/projects/image-resizer/bootstrap/main.tf)

Eklenecek kaynak:
```hcl
# PR'larda çalışan terraform plan workflow'unun Azure'a bağlanabilmesi için
resource "azuread_application_federated_identity_credential" "github_pr" {
  application_id = azuread_application.github.id
  display_name   = "github-actions-pull-request"
  issuer         = "https://token.actions.githubusercontent.com"
  subject        = "repo:${var.github_username}/${var.github_repo}:pull_request"
  audiences      = ["api://AzureADTokenExchange"]
}
```

---

### 2. GitHub Actions Workflow'ları

Rapordaki 5.1 maddesi üç operasyonu gerektiriyor. Bunları **iki workflow** olarak tasarlıyorum:

#### Neden iki ayrı workflow?

```
ci.yml  → PR tetikler     → "Bu değişiklik güvenli mi?" sorusuna cevap verir
cd.yml  → main merge → "Bu değişikliği production'a uygula" komutunu çalıştırır
```

Bu, **separation of concerns** prensibi. CI read-only'dir (plan, build, test), CD mutasyonel'dir (apply, deploy). Aynı YAML'da olmaları karmaşıklık ve hata riski yaratır.

---

#### [NEW] [ci.yml](file:///Users/semih/projects/image-resizer/.github/workflows/ci.yml) — Pull Request Pipeline

```
Tetikleme: pull_request → main
Kimlik:    WIF (pull_request subject)
```

**Adımlar:**

| # | Adım | Neden |
|---|---|---|
| 1 | `actions/checkout@v4` | Kaynak kodu çek |
| 2 | `azure/login@v2` (OIDC) | Passwordless Azure bağlantısı |
| 3 | `hashicorp/setup-terraform@v3` | Terraform CLI kur |
| 4 | `terraform init` | Remote backend'e bağlan |
| 5 | `terraform fmt -check` | Format tutarlılığı kontrol et |
| 6 | `terraform validate` | HCL syntax doğrulama |
| 7 | `terraform plan` (exit code ile) | Altyapı değişiklik önizleme |
| 8 | `actions/setup-dotnet@v4` (.NET 10) | SDK kur |
| 9 | `dotnet restore` | Paketleri çek |
| 10 | `dotnet build --no-restore` | Derleme hata kontrolü |

> [!NOTE]
> `terraform plan` çıktısını PR comment'e yazmak mümkün (örn. `hashicorp/setup-terraform`'un `stdout` output'ı ile) — ama ilk versiyon için buna gerek yok. Basit tut, sonra ekle.

---

#### [NEW] [cd.yml](file:///Users/semih/projects/image-resizer/.github/workflows/cd.yml) — Deploy Pipeline

```
Tetikleme: push → main
Kimlik:    WIF (refs/heads/main subject)
```

**Adımlar:**

| # | Adım | Neden |
|---|---|---|
| 1 | `actions/checkout@v4` | Kaynak kodu çek |
| 2 | `azure/login@v2` (OIDC) | Passwordless Azure bağlantısı |
| 3 | `hashicorp/setup-terraform@v3` | Terraform CLI kur |
| 4 | `terraform init` | Remote backend'e bağlan |
| 5 | `terraform apply -auto-approve` | Altyapı değişikliğini uygula |
| 6 | `actions/setup-dotnet@v4` (.NET 10) | SDK kur |
| 7 | `dotnet publish` | Release build |
| 8 | `Azure/functions-action@v1` | Function App'e deploy et |

> [!IMPORTANT]
> `terraform apply -auto-approve` güvenlidir çünkü:
> 1. Main branch'e sadece PR ile merge edilir (branch protection)
> 2. PR'da `terraform plan` zaten çalışmış ve review edilmiştir
> 3. Her apply otomatik olarak remote state'e kaydedilir

---

### 3. Environment Stratejisi — Analiz

Rapordaki 5.3 maddesi:

> `var.environment = "dev"` tanımlı ama sadece tek environment var. En az `dev` + `prod` ayrımı olmalı.

**Değerlendirme: Şu an eklenmemeli.**

Nedenleri:

| Argüman | Açıklama |
|---|---|
| CI/CD önce gelmeli | Environment ayrımı, pipeline'ın doğru çalıştığından emin olduktan sonra anlamlı olur |
| Maliyet | İkinci environment = ikinci set kaynak = ~2x maliyet (Consumption'da düşük ama sıfır değil) |
| Karmaşıklık zamanlaması | Pipeline → tek environment → sorunsuz çalışıyor → ikinci environment ekleme sırası doğrudur |
| Rapor da bunu söylüyor | "CI/CD pipeline tamamlandıktan sonra ele alınmalı" |

Ancak **şu karar şimdi alınmalı:** pipeline YAML'ında environment değişkeni **parametre olarak** tanımlanmalı ki ileride `prod` eklendiğinde workflow değişikliği minimum olsun. Bu, premature implementation değil, premature consideration — doğru bir yaklaşım.

---

### 4. GitHub Repository Hazırlığı

Pipeline çalışmadan önce GitHub tarafında yapılması gerekenler:

| Ayar | Nerede | Değer |
|---|---|---|
| `AZURE_CLIENT_ID` | Repository Secrets | `terraform output -raw client_id` |
| `AZURE_TENANT_ID` | Repository Secrets | `terraform output -raw tenant_id` |
| `AZURE_SUBSCRIPTION_ID` | Repository Secrets | `cd419795-c7f9-4616-90e3-e1e1a56f8b16` |
| Branch protection | main branch | PR required, status checks required |

---

## Doğrulama Planı

| Test | Nasıl |
|---|---|
| CI workflow çalışıyor | Feature branch → PR aç → workflow başarıyla tamamlanır |
| CD workflow çalışıyor | PR'ı merge et → infra apply + function deploy başarılı |
| WIF PR credential | PR'da `azure/login` başarılı (403 almıyor) |
| Function App çalışıyor | Deploy sonrası uploads container'a görsel yükle, thumbnail oluştuğunu doğrula |

---

## Open Questions

> [!IMPORTANT]
> **GitHub Secrets ayarlandı mı?** `bootstrap/` apply sonrasında `terraform output` ile aldığın `client_id` ve `tenant_id` değerlerini GitHub repository secrets'a ekledin mi? Pipeline'lar bunlar olmadan çalışamaz.

> [!IMPORTANT]
> **Branch protection:** Main branch'e direkt push yerine PR zorunluluğu koymak istiyor musun? CI/CD'nin tam anlamlı olması için gerekli ama tek kişilik projede friction yaratabilir. Karar senin.
