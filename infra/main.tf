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

  backend "azurerm" {
    resource_group_name  = "rg-tfstate"
    storage_account_name = "sttfstateimgresizer"
    container_name       = "tfstate"
    key                  = "image-resizer.tfstate"
    use_azuread_auth     = true  # Storage key yerine Entra ID (OIDC) ile kimlik doğrulama
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

provider "azuread" {}

# GitHub Actions Service Principal lookup
#   client_id (application ID) üzerinden SP'nin object_id'sini bulur.
#   WEBSITE_RUN_FROM_PACKAGE deployment için gerekli rol atamasında kullanılır.
data "azuread_service_principal" "github" {
  client_id = var.github_app_client_id
}

# Resource Group
resource "azurerm_resource_group" "rg" {
  name     = "rg-${var.project}-${var.environment}"
  location = var.location
}

# Storage Account
resource "azurerm_storage_account" "sa" {
  name                     = "st${var.project}${var.environment}"
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"
  https_traffic_only_enabled = true
}

resource "azurerm_storage_container" "uploads" {
  name = "uploads"
  storage_account_id = azurerm_storage_account.sa.id
  container_access_type = "private"
}

resource "azurerm_storage_container" "thumbnails" {
  name = "thumbnails"
  storage_account_id = azurerm_storage_account.sa.id
  container_access_type = "private"
}

# Application Insights
resource "azurerm_log_analytics_workspace" "law" {
  name                = "log-${var.project}-${var.environment}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_application_insights" "ai" {
  name                = "appi-${var.project}-${var.environment}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  workspace_id        = azurerm_log_analytics_workspace.law.id
  application_type    = "web"
}

# App Service Plan (Consumption)
resource "azurerm_service_plan" "asp" {
  name                = "asp-${var.project}-${var.environment}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  os_type             = "Linux"
  sku_name            = "Y1"
}

# Function App
resource "azurerm_linux_function_app" "func" {
  name                  = "func-${var.project}-${var.environment}"
  resource_group_name   = azurerm_resource_group.rg.name
  location              = azurerm_resource_group.rg.location
  service_plan_id       = azurerm_service_plan.asp.id
  storage_account_name  = azurerm_storage_account.sa.name
  storage_uses_managed_identity = true
  
  identity {
    type = "SystemAssigned"
  }
  
  site_config {
    application_stack {
      dotnet_version = "10"
      use_dotnet_isolated_runtime = true
    }
  }
  
  app_settings = {
    APPLICATIONINSIGHTS_CONNECTION_STRING = azurerm_application_insights.ai.connection_string
    FUNCTIONS_WORKER_RUNTIME              = "dotnet-isolated"
    AzureWebJobsStorage__accountName      = azurerm_storage_account.sa.name
    AzureWebJobsStorage__credential       = "managedidentity"
  }

  # Terraform'a dışarıdan (GitHub Action) eklenen paket URL'sini silmemesini söyler
  lifecycle {
    ignore_changes = [
      app_settings["WEBSITE_RUN_FROM_PACKAGE"]
    ]
  }
}

# Storage Blob Data Contributor — GitHub Actions SP (deployment)
#   Azure/functions-action, Linux Consumption + RBAC kombinasyonunda deployment
#   paketini (zip) WEBSITE_RUN_FROM_PACKAGE modunda blob'a yükler. Bu işlem
#   GitHub Actions SP kimliğiyle yapılır; SP'nin uygulama storage'a
#   veri yazabilmesi için bu rol zorunludur.
resource "azurerm_role_assignment" "github_app_storage_blob" {
  principal_id         = data.azuread_service_principal.github.object_id
  principal_type       = "ServicePrincipal"
  scope                = azurerm_storage_account.sa.id
  role_definition_name = "Storage Blob Data Contributor"
}


# Blob Data Contributor:
#   - uploads container'dan blob stream okuma (BlobTrigger binding)
#   - thumbnails container'a yazma (uygulama kodu)
#   - azure-webjobs-hosts container'ı: blob receipt takibi (tekrar işlemeyi önler)
resource "azurerm_role_assignment" "blob_data_contributor" {
  principal_id         = azurerm_linux_function_app.func.identity[0].principal_id
  scope                = azurerm_storage_account.sa.id
  role_definition_name = "Storage Blob Data Contributor"
}

# Queue Data Contributor:
#   - Poison queue: BlobTrigger 5 kez hata verince "webjobs-blobtrigger-poison"
#     queue'suna mesaj yazar. Bu izin olmadan başarısız işlemler sessizce kaybolur.
resource "azurerm_role_assignment" "queue_data_contributor" {
  principal_id         = azurerm_linux_function_app.func.identity[0].principal_id
  scope                = azurerm_storage_account.sa.id
  role_definition_name = "Storage Queue Data Contributor"
}

# Table Data Contributor:
#   - Functions host runtime: distributed blob scanning state ve singleton
#     coordination (distributed lock) için Table Storage kullanır.
resource "azurerm_role_assignment" "table_data_contributor" {
  principal_id         = azurerm_linux_function_app.func.identity[0].principal_id
  scope                = azurerm_storage_account.sa.id
  role_definition_name = "Storage Table Data Contributor"
}
