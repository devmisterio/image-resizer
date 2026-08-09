variable "subscription_id" {
  type = string
}

variable "project" {
  type    = string
  default = "imgresizer"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "location" {
  type    = string
  default = "westeurope"
}

# GitHub Actions SP client_id (bootstrap output: client_id)
# WEBSITE_RUN_FROM_PACKAGE deployment için storage blob erişim rolü atamasında kullanılır.
variable "github_app_client_id" {
  type        = string
  description = "GitHub Actions application client ID. Bootstrap output: 'terraform output -raw client_id'"
}