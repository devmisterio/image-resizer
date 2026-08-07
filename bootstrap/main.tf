terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }

    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

provider "azuread" {}

# Mevcut subscription'ı referans almak için — role assignment scope'unda kullanılır
data "azurerm_subscription" "current" {}

# Terraform state'lerin tutulacağı resource group, account ve container
resource "azurerm_resource_group" "tfstate" {
  name     = "rg-tfstate"
  location = var.location
}

resource "azurerm_storage_account" "tfstate" {
  name                     = "sttfstate${var.project}"
  resource_group_name      = azurerm_resource_group.tfstate.name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"
}

resource "azurerm_storage_container" "tfstate" {
  name                  = "tfstate"
  storage_account_id    = azurerm_storage_account.tfstate.id
  container_access_type = "private"
}

# Github Actions için gerekli uygulama kimliği ve service principal
resource "azuread_application" "github" {
  display_name = "app-github-${var.project}"
}

resource "azuread_service_principal" "github" {
  client_id = azuread_application.github.client_id
}

# GitHub Actions'ın şifresiz bağlanmasını sağlayan federated credential
resource "azuread_application_federated_identity_credential" "github_main" {
  application_id = azuread_application.github.id
  display_name   = "github-actions-main"
  issuer         = "https://token.actions.githubusercontent.com"
  subject        = "repo:${var.github_username}/${var.github_repo}:ref:refs/heads/main"
  audiences      = ["api://AzureADTokenExchange"]
}

# Role Assignments — GitHub Actions SP'nin ihtiyaç duyduğu izinler
#
# NOT: "Contributor" rolü management plane (kaynak yönetimi) için gereklidir.
# Storage blob içeriklerine (data plane) erişim için ayrı bir rol gerekir —
# Contributor bu erişimi sağlamaz.

# Storage Blob Data Contributor — tfstate storage account (data plane)
#   terraform init/apply sırasında state dosyasını (blob) okumak ve yazmak için gerekli.
#   Contributor rolü management plane erişimi sağlar; blob içeriklerine erişim sağlamaz.
resource "azurerm_role_assignment" "github_tfstate_blob" {
  principal_id         = azuread_service_principal.github.object_id
  principal_type       = "ServicePrincipal"
  scope                = azurerm_storage_account.tfstate.id
  role_definition_name = "Storage Blob Data Contributor"
}

# Contributor — subscription scope (management plane)
#   infra/main.tf'teki tüm Azure kaynaklarını (resource group, function app,
#   storage, log analytics vb.) oluşturmak, güncellemek ve silmek için gerekli.
resource "azurerm_role_assignment" "github_contributor" {
  principal_id         = azuread_service_principal.github.object_id
  principal_type       = "ServicePrincipal"
  scope                = data.azurerm_subscription.current.id
  role_definition_name = "Contributor"
}

# User Access Administrator — subscription scope
#   infra/main.tf'te Function App'in Managed Identity'sine blob/queue/table
#   rolleri atanıyor. Bu RBAC atamalarını oluşturabilmek için gerekli.
#   Bu rol olmadan "terraform apply" AuthorizationFailed hatası verir.
resource "azurerm_role_assignment" "github_user_access_admin" {
  principal_id         = azuread_service_principal.github.object_id
  principal_type       = "ServicePrincipal"
  scope                = data.azurerm_subscription.current.id
  role_definition_name = "User Access Administrator"
}