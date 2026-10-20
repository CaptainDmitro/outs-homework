variable "availability_zone" {
  type    = string
  default = "GZ1"
}

variable "flavor" {
  type    = string
  default = "STD3-2-8"
}

variable "allowed_cidrs" {
  type = list(string)
}

variable "db_password" {
  type      = string
  sensitive = true
}

variable "public_access" {
  type    = bool
  default = true
}
