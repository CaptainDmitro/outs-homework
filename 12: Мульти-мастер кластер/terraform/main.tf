provider "yandex" {
  folder_id = var.folder_id
}

data "yandex_vpc_network" "default" {
  name = "default"
}

data "yandex_vpc_subnet" "zone" {
  for_each = local.vms
  name     = "default-ru-central1-${each.key}"
}

data "yandex_compute_image" "ubuntu" {
  family    = "ubuntu-2404-lts"
  folder_id = "standard-images"
}

locals {
  ssh_key = trimspace(file(pathexpand(var.ssh_public_key)))

  # Для облака доступны только зоны d и e по 2 vCPU, поэтому на crdb-d два узла CockroachDB.
  # Каждому узлу достаётся 2 ГБ кеша и 2 ГБ SQL-памяти. Две реплики на одном HDD 20 ГБ не помещаются,
  # поэтому у node2 второе хранилище на загрузочном SSD.
  vms = {
    d = {
      ip     = "10.130.0.20"
      memory = 16
      nodes = {
        node1 = { port = 26257, http = 8080, mem = ".125", extra = "" }
        node2 = { port = 26258, http = 8081, mem = ".125", extra = "--store=path=/var/lib/cockroach/node2,size=4GiB" }
      }
    }
    e = {
      ip     = "10.131.0.20"
      memory = 8
      nodes = {
        node3 = { port = 26257, http = 8080, mem = ".25", extra = "" }
      }
    }
  }
  join = join(",", flatten([for vm in local.vms : [for n in vm.nodes : "${vm.ip}:${n.port}"]]))
}

resource "yandex_vpc_security_group" "crdb" {
  name       = "otus-crdb-sg"
  network_id = data.yandex_vpc_network.default.id

  ingress {
    description    = "SSH"
    protocol       = "TCP"
    port           = 22
    v4_cidr_blocks = [var.admin_cidr]
  }
  dynamic "ingress" {
    for_each = { "CockroachDB SQL" = [26257, 26258], "CockroachDB DB Console" = [8080, 8081], "PostgreSQL" = [5432, 5432] }
    content {
      description    = ingress.key
      protocol       = "TCP"
      from_port      = ingress.value[0]
      to_port        = ingress.value[1]
      v4_cidr_blocks = [var.admin_cidr]
    }
  }
  ingress {
    description    = "Внутренний трафик VPC (RPC между узлами, клиенты)"
    protocol       = "ANY"
    v4_cidr_blocks = ["10.128.0.0/14"]
  }
  egress {
    protocol       = "ANY"
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}

# Данные на network-hdd: квота SSD всего 10 ГБ на зону и уходит под загрузочный диск
resource "yandex_compute_disk" "data" {
  for_each = local.vms
  name     = "crdb-${each.key}-data"
  zone     = "ru-central1-${each.key}"
  type     = "network-hdd"
  size     = 20
}

resource "yandex_compute_instance" "node" {
  for_each    = local.vms
  name        = "crdb-${each.key}"
  hostname    = "crdb-${each.key}"
  zone        = "ru-central1-${each.key}"
  platform_id = "standard-v3"

  resources {
    cores         = 2
    core_fraction = 100
    memory        = each.value.memory
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
    ip_address         = each.value.ip
    nat                = true
    security_group_ids = [yandex_vpc_security_group.crdb.id]
  }

  metadata = {
    serial-port-enable = 1
    user-data = templatefile("${path.module}/node.yaml.tftpl", {
      ssh_key = local.ssh_key
      ip      = each.value.ip
      zone    = "ru-central1-${each.key}"
      join    = local.join
      nodes   = each.value.nodes
    })
  }
}
