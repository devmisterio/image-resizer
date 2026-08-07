output "client_id" {
  description = "GitHub Actions için AZURE_CLIENT_ID secret değeri"
  value       = azuread_application.github.client_id
}

output "tenant_id" {
  description = "GitHub Actions için AZURE_TENANT_ID secret değeri"
  value       = data.azurerm_subscription.current.tenant_id
}
