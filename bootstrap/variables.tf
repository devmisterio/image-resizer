variable "subscription_id" {
  type = string
}

variable "location" {
  type    = string
  default = "westeurope"
}

variable "project" {
  type    = string
  default = "imgresizer"
}

variable "github_username" {
  type = string
}

variable "github_repo" {
  type    = string
  default = "image-resizer"
}

# GitHub OIDC token'larındaki yeni sub claim formatı için gerekli.
# GitHub, 2025 itibarıyla sub claim'e kullanıcı ve repo ID'lerini ekledi:
#   repo:USERNAME@USER_ID/REPO@REPO_ID:ref:refs/heads/main
#
# ID'leri almak için:
#   gh api /users/GITHUB_USERNAME --jq .id
#   gh api /repos/GITHUB_USERNAME/REPO_NAME --jq .id
variable "github_user_id" {
  type        = string
  description = "GitHub user/org numeric ID"
}

variable "github_repo_id" {
  type        = string
  description = "GitHub repository numeric ID"
}