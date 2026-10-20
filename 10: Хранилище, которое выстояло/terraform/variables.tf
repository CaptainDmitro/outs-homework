variable "availability_zone" {
  type    = string
  default = "GZ1"
}

variable "flavor" {
  type    = string
  default = "STD3-8-32"
}

variable "volume_type" {
  type    = string
  default = "high-iops"
}

variable "volume_size" {
  type    = number
  default = 250
}
