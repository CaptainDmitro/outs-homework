provider "vkcs" {}

data "vkcs_networking_network" "extnet" {
  name = "internet"
}

# сеть и подсеть остались от ДЗ №9
data "vkcs_networking_network" "net" {
  name = "otus-pg-net"
}

data "vkcs_networking_subnet" "subnet" {
  name = "otus-pg-subnet"
}

# роутер нужен только для выхода VM в интернет (SNAT): floating IP в проекте нет
resource "vkcs_networking_router" "bench" {
  name                = "otus-bench-router"
  admin_state_up      = true
  external_network_id = data.vkcs_networking_network.extnet.id
}

resource "vkcs_networking_router_interface" "bench" {
  router_id = vkcs_networking_router.bench.id
  subnet_id = data.vkcs_networking_subnet.subnet.id
}

data "vkcs_images_image" "ubuntu" {
  name = "ubuntu-24-202607090925.gitd6f5e545"
}

data "vkcs_compute_flavor" "bench" {
  name = var.flavor
}

resource "vkcs_compute_instance" "bench" {
  name              = "otus-bench"
  availability_zone = var.availability_zone
  flavor_id         = data.vkcs_compute_flavor.bench.id

  block_device {
    uuid                  = data.vkcs_images_image.ubuntu.id
    source_type           = "image"
    destination_type      = "volume"
    volume_type           = var.volume_type
    volume_size           = var.volume_size
    boot_index            = 0
    delete_on_termination = true
  }

  network {
    uuid = data.vkcs_networking_network.net.id
  }

  user_data = file("${path.module}/../cloud-init/user-data.yaml")

  # скрипты шагов приходят через метаданные сервера (scripts/vkcmd.py)
  lifecycle {
    ignore_changes = [metadata]
  }

  depends_on = [vkcs_networking_router_interface.bench]
}
