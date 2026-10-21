variable "folder_id" {
  type = string
}

variable "ssh_public_key" {
  type = string
}

variable "admin_cidr" {
  description = "Адрес, с которого пускать по SSH, SQL и в DB Console"
  type        = string
}
