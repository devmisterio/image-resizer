variable "subscription_id" {
  type = string
}

variable "location" {
  type = string
  default = "westeurope"
}

variable "project" {
  type = string
  default = "imgresizer"
}

variable "github_username" {
  type = string
}

variable "github_repo" {
  type = string
  default = "image-resizer"
}