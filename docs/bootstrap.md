# Bootstrap

GitHub Actions'ın Azure'a OIDC ile bağlanabilmesi için gereken Entra ID kimliği.
Subscription başına bir kez, `Owner` yetkisine sahip bir kullanıcı tarafından çalıştırılır.

CI/CD bu adımı kendisi yapamaz: Azure'a girebilmek için zaten bu kimliğe ihtiyacı vardır.
Altyapının geri kalanı `infra/` altında Bicep ile tanımlıdır ve pipeline tarafından deploy edilir.

## Değişkenler

```bash
az login
az account set --subscription "<SUBSCRIPTION_ID>"

PROJECT="imgresizer"
APP_NAME="app-github-${PROJECT}"

GITHUB_OWNER="devmisterio"
GITHUB_REPO="image-resizer"
GITHUB_OWNER_ID=$(gh api "/users/${GITHUB_OWNER}" --jq .id)          # 140584513
GITHUB_REPO_ID=$(gh api "/repos/${GITHUB_OWNER}/${GITHUB_REPO}" --jq .id)  # 1326471505

SUBSCRIPTION_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)
```

## Resource provider kaydı

Application Insights oluşturulduğunda Azure otomatik olarak bir "Failure Anomalies"
smart detection kuralı yaratmaya çalışır. `Microsoft.AlertsManagement` kayıtlı değilse
bu, resource group geçmişinde başarısız bir deployment bırakır — uygulamayı etkilemez
ancak gürültü yaratır.

```bash
az provider register --namespace Microsoft.AlertsManagement --wait
```

## Kurulum

```bash
# App Registration ve Service Principal.
# Rol atamaları uygulamaya değil, Service Principal'a yapılır.
APP_ID=$(az ad app create --display-name "$APP_NAME" --query appId -o tsv)
SP_OBJECT_ID=$(az ad sp create --id "$APP_ID" --query id -o tsv)
```

Federated credential'lar. Her GitHub bağlamı farklı bir `sub` claim'i üretir ve
wildcard desteklenmez; `main` ve `pull_request` için ayrı credential gerekir.

```bash
REPO_REF="repo:${GITHUB_OWNER}@${GITHUB_OWNER_ID}/${GITHUB_REPO}@${GITHUB_REPO_ID}"

az ad app federated-credential create --id "$APP_ID" --parameters "{
  \"name\": \"github-actions-main\",
  \"issuer\": \"https://token.actions.githubusercontent.com\",
  \"subject\": \"${REPO_REF}:ref:refs/heads/main\",
  \"audiences\": [\"api://AzureADTokenExchange\"]
}"

az ad app federated-credential create --id "$APP_ID" --parameters "{
  \"name\": \"github-actions-pull-request\",
  \"issuer\": \"https://token.actions.githubusercontent.com\",
  \"subject\": \"${REPO_REF}:pull_request\",
  \"audiences\": [\"api://AzureADTokenExchange\"]
}"
```

Rol atamaları. `main.bicep` subscription scope'ta çalışır ve Resource Group'u kendisi
oluşturur; ayrıca Function App'in Managed Identity'sine storage rolleri atar.
`Role Based Access Control Administrator`, `User Access Administrator` yerine tercih
edilmiştir — aynı yetkiyi verir, yetki yükseltmeye karşı korumalıdır.

```bash
SCOPE="/subscriptions/${SUBSCRIPTION_ID}"

az role assignment create --assignee-object-id "$SP_OBJECT_ID" \
  --assignee-principal-type ServicePrincipal --role "Contributor" --scope "$SCOPE"

az role assignment create --assignee-object-id "$SP_OBJECT_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Role Based Access Control Administrator" --scope "$SCOPE"
```

## GitHub Secrets

| Secret | Değer |
|---|---|
| `AZURE_CLIENT_ID` | `$APP_ID` |
| `AZURE_TENANT_ID` | `$TENANT_ID` |
| `AZURE_SUBSCRIPTION_ID` | `$SUBSCRIPTION_ID` |

Bu değerler credential değildir; secret olarak saklanmaları log maskeleme ve fork
edilmiş PR'lardan erişimi engellemek içindir.

## Doğrulama

```bash
az ad app federated-credential list --id "$APP_ID" --query "[].{name:name, subject:subject}" -o table
az role assignment list --assignee "$SP_OBJECT_ID" --all -o table
```

Beklenen: 2 federated credential, 2 rol ataması.

## Teardown

```bash
az ad app delete --id "$APP_ID"   # SP ve federated credential'lar birlikte silinir
```

## Notlar

- Client secret veya sertifika üretilmez; kimlik doğrulama tamamen OIDC token değişimiyle yapılır.
- Fork'lardan gelen PR'lar OIDC token alamaz (GitHub varsayılanı).
- Scope subscription seviyesindedir çünkü `main.bicep` Resource Group'u kendisi oluşturur.
  Aynı subscription'da başka iş yükleri barındırılacaksa şablonu resource group scope'una
  taşıyıp rolleri o RG'ye daraltın.
