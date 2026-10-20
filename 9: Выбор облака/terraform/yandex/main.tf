provider "yandex" {
  folder_id = var.folder_id
  zone      = "ru-central1-e"
}

data "yandex_mdb_postgresql_cluster" "pg" {
  name = "otus-pg"
}

data "yandex_vpc_subnet" "e" {
  name = "default-ru-central1-e"
}

data "yandex_compute_image" "ubuntu" {
  family    = "ubuntu-2404-lts"
  folder_id = "standard-images"
}

resource "yandex_vpc_security_group_rule" "psql_subnet" {
  security_group_binding = tolist(data.yandex_mdb_postgresql_cluster.pg.security_group_ids)[0]
  direction              = "ingress"
  description            = "psql from client VM subnet"
  protocol               = "TCP"
  port                   = 6432
  v4_cidr_blocks         = data.yandex_vpc_subnet.e.v4_cidr_blocks
}

resource "yandex_compute_instance" "client" {
  name        = "otus-pg-client"
  platform_id = "standard-v3"

  resources {
    cores  = 2
    memory = 4
  }

  boot_disk {
    initialize_params {
      image_id = data.yandex_compute_image.ubuntu.id
      size     = 10
      type     = "network-ssd"
    }
  }

  network_interface {
    subnet_id = data.yandex_vpc_subnet.e.id
    nat       = true
  }

  metadata = {
    serial-port-enable = 1
    user-data = templatefile("${path.module}/../../cloud-init/user-data.yaml.tftpl", {
      cloud     = "yandex"
      inventory = file("${path.module}/../../ansible/inventory/yandex-vm.yml")
      conninfo  = file("${path.module}/../../ansible/conninfo.yml")
      playbook  = file("${path.module}/../../ansible/playbook.yml")
      pgbench   = file("${path.module}/../../ansible/pgbench.yml")
    })
  }

  depends_on = [yandex_vpc_security_group_rule.psql_subnet]
}
