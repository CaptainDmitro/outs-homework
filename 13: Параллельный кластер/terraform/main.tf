terraform {
  required_providers {
    yandex = {
      source  = "yandex-cloud/yandex"
      version = "~> 0.130"
    }
  }
}

provider "yandex" {
  folder_id = var.folder_id
}

variable "folder_id" {
  type = string
}

variable "admin_cidr" {
  type        = string
  description = "Адрес, с которого разрешены SSH и веб-интерфейсы YugabyteDB"
}

variable "ssh_public_key" {
  type = string
}

locals {
  # По одной ноде в зоне: квота каждой зоны 2 vCPU / 16 ГБ RAM / 10 ГБ SSD / 20 ГБ HDD.
  # В ru-central1-a и ru-central1-b создание ресурсов закрыто, поэтому только две зоны.
  zones = ["ru-central1-d", "ru-central1-e"]
}

data "yandex_vpc_network" "default" {
  name = "default"
}

data "yandex_vpc_subnet" "zone" {
  for_each = toset(local.zones)
  name     = "default-${each.key}"
}

data "yandex_compute_image" "ubuntu" {
  family    = "ubuntu-2404-lts"
  folder_id = "standard-images"
}

resource "yandex_vpc_security_group" "yb" {
  name       = "otus-yb-sg"
  network_id = data.yandex_vpc_network.default.id

  ingress {
    description    = "SSH"
    protocol       = "TCP"
    port           = 22
    v4_cidr_blocks = [var.admin_cidr]
  }

  ingress {
    description    = "yb-master UI"
    protocol       = "TCP"
    port           = 7000
    v4_cidr_blocks = [var.admin_cidr]
  }

  ingress {
    description    = "yb-tserver UI"
    protocol       = "TCP"
    port           = 9000
    v4_cidr_blocks = [var.admin_cidr]
  }

  ingress {
    description    = "yugabyted UI"
    protocol       = "TCP"
    port           = 15433
    v4_cidr_blocks = [var.admin_cidr]
  }

  ingress {
    description       = "Трафик между нодами кластера"
    protocol          = "ANY"
    predefined_target = "self_security_group"
  }

  egress {
    protocol       = "ANY"
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "yandex_compute_disk" "data" {
  for_each = toset(local.zones)
  name     = "otus-yb-data-${substr(each.key, -1, 1)}"
  zone     = each.key
  type     = "network-hdd"
  size     = 20
}

resource "yandex_compute_instance" "yb" {
  for_each                  = toset(local.zones)
  name                      = "otus-yb-${substr(each.key, -1, 1)}"
  hostname                  = "otus-yb-${substr(each.key, -1, 1)}"
  zone                      = each.key
  platform_id               = "standard-v4a" # standard-v3 в ru-central1-e: "Not enough resources"
  allow_stopping_for_update = true

  resources {
    cores  = 2
    memory = 16
  }

  boot_disk {
    initialize_params {
      image_id = data.yandex_compute_image.ubuntu.id
      size     = 10
      type     = "network-ssd"
    }
  }

  secondary_disk {
    disk_id     = yandex_compute_disk.data[each.key].id
    device_name = "data"
  }

  network_interface {
    subnet_id          = data.yandex_vpc_subnet.zone[each.key].id
    nat                = true
    security_group_ids = [yandex_vpc_security_group.yb.id]
  }

  metadata = {
    serial-port-enable = 1
    user-data          = templatefile("${path.module}/user-data.yaml.tftpl", { ssh_public_key = var.ssh_public_key })
  }
}

output "nodes" {
  value = {
    for z, vm in yandex_compute_instance.yb : vm.name => {
      zone        = z
      internal_ip = vm.network_interface[0].ip_address
      external_ip = vm.network_interface[0].nat_ip_address
    }
  }
}
