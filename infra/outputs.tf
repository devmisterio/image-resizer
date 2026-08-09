output "function_app_name" {
  value = azurerm_linux_function_app.func.name
}

output "resource_group_name" {
  value = azurerm_resource_group.rg.name
}

output "storage_account_name" {
  value = azurerm_storage_account.sa.name
}