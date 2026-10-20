provider "yandex" {
  folder_id = var.folder_id
}

data "yandex_vpc_network" "default" {
  name = "default"
}

data "yandex_vpc_subnet" "zone" {
  for_each = toset(["d", "e"])
  name     = "default-ru-central1-${each.key}"
}

data "yandex_compute_image" "ubuntu" {
  family    = "ubuntu-2404-lts"
  folder_id = "standard-images"
}

locals {
  ssh_key = trimspace(file(pathexpand(var.ssh_public_key)))

  # Две площадки: основной кластер Patroni в зоне d, standby-кластер в зоне e.
  # Standby ходит напрямую к трём узлам основного кластера (порты 5441-5443 ВМ pg-d).
  sites = {
    d = { ip = "10.130.0.10", scope = "bananaflow-d", standby_from = "" }
    e = { ip = "10.131.0.10", scope = "bananaflow-e", standby_from = "10.130.0.10" }
  }
}

resource "yandex_vpc_security_group" "ha" {
  name       = "otus-ha-sg"
  network_id = data.yandex_vpc_network.default.id

  ingress {
    description    = "SSH"
    protocol       = "TCP"
    port           = 22
    v4_cidr_blocks = [var.admin_cidr]
  }
  ingress {
    description    = "Внутренний трафик VPC (репликация, клиенты)"
    protocol       = "ANY"
    v4_cidr_blocks = ["10.128.0.0/14"]
  }
  ingress {
    description    = "PostgreSQL через NLB (адрес клиента сохраняется)"
    protocol       = "TCP"
    port           = 5432
    v4_cidr_blocks = [var.admin_cidr]
  }
  ingress {
    description       = "Проверки NLB"
    protocol          = "TCP"
    port              = 8404
    predefined_target = "loadbalancer_healthchecks"
  }
  egress {
    protocol       = "ANY"
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "yandex_compute_instance" "site" {
  for_each    = local.sites
  name        = "pg-${each.key}"
  hostname    = "pg-${each.key}"
  zone        = "ru-central1-${each.key}"
  platform_id = "standard-v3"

  resources {
    cores         = 2
    core_fraction = 50
    memory        = 4
  }

  boot_disk {
    initialize_params {
      image_id = data.yandex_compute_image.ubuntu.id
      size     = 10
      type     = "network-ssd"
    }
  }

  network_interface {
    subnet_id          = data.yandex_vpc_subnet.zone[each.key].id
    ip_address         = each.value.ip
    nat                = true
    security_group_ids = [yandex_vpc_security_group.ha.id]
  }

  metadata = {
    serial-port-enable = 1
    user-data = templatefile("${path.module}/site.yaml.tftpl", {
      ssh_key    = local.ssh_key
      dockerfile = filebase64("${path.module}/../docker/Dockerfile")
      entrypoint = filebase64("${path.module}/../docker/entrypoint.sh")
      haproxy    = filebase64("${path.module}/../docker/haproxy.cfg")
      compose    = base64encode(templatefile("${path.module}/../docker/compose.yaml.tftpl", { scope = each.value.scope }))
      patroni = base64encode(templatefile("${path.module}/../docker/patroni.yml.tftpl", {
        standby_host = each.value.standby_from == "" ? "" : join(",", [for p in [5441, 5442, 5443] : each.value.standby_from])
        standby_port = "5441,5442,5443"
      }))
    })
  }
}

# Балансировщик: трафик идёт только на площадку, где HAProxy видит лидера на запись
resource "yandex_lb_target_group" "pg" {
  name = "pg-sites"

  dynamic "target" {
    for_each = yandex_compute_instance.site
    content {
      subnet_id = target.value.network_interface[0].subnet_id
      address   = target.value.network_interface[0].ip_address
    }
  }
}

resource "yandex_lb_network_load_balancer" "pg" {
  name = "pg-nlb"
  type = "external"

  listener {
    name        = "postgres"
    port        = 5432
    target_port = 5432
    protocol    = "tcp"
    external_address_spec {
      ip_version = "ipv4"
    }
  }

  attached_target_group {
    target_group_id = yandex_lb_target_group.pg.id
    healthcheck {
      name                = "haproxy-primary"
      interval            = 2
      timeout             = 1
      unhealthy_threshold = 2
      healthy_threshold   = 2
      http_options {
        port = 8404
        path = "/health"
      }
    }
  }
}

locals {
  nlb_ip = one([for l in yandex_lb_network_load_balancer.pg.listener : one(l.external_address_spec).address])
}

resource "yandex_dns_zone" "internal" {
  name             = "bananaflow-internal"
  zone             = "bananaflow.internal."
  public           = false
  private_networks = [data.yandex_vpc_network.default.id]
}

resource "yandex_dns_recordset" "pg" {
  zone_id = yandex_dns_zone.internal.id
  name    = "pg"
  type    = "A"
  ttl     = 60
  data    = [local.nlb_ip]
}
