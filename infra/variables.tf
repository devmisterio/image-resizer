variable "subscription_id" {
  type = string
}

variable "project" {
  type = string
  default = "imgresizer"
}

variable "environment" {
  type = string
  default = "dev"
}

variable "location" {
  type = string
  default = "westeurope"
}