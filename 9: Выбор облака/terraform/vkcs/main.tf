provider "vkcs" {}

data "vkcs_networking_network" "extnet" {
  name = "internet"
}

data "vkcs_compute_flavor" "db" {
  name = var.flavor
}

resource "vkcs_networking_network" "pg" {
  name = "otus-pg-net"
}

resource "vkcs_networking_subnet" "pg" {
  name       = "otus-pg-subnet"
  network_id = vkcs_networking_network.pg.id
  cidr       = "192.168.199.0/24"
}

resource "vkcs_networking_router" "pg" {
  name                = "otus-pg-router"
  admin_state_up      = true
  external_network_id = data.vkcs_networking_network.extnet.id
}

resource "vkcs_networking_router_interface" "pg" {
  router_id = vkcs_networking_router.pg.id
  subnet_id = vkcs_networking_subnet.pg.id
}

resource "vkcs_networking_secgroup" "pg" {
  name        = "otus-pg-sg"
  description = "psql from my IP"
}

resource "vkcs_networking_secgroup_rule" "psql" {
  for_each          = toset(var.allowed_cidrs)
  direction         = "ingress"
  protocol          = "tcp"
  port_range_min    = 5432
  port_range_max    = 5432
  remote_ip_prefix  = each.value
  security_group_id = vkcs_networking_secgroup.pg.id
}

resource "vkcs_db_instance" "pg" {
  name              = "otus-pg"
  availability_zone = var.availability_zone
  flavor_id         = data.vkcs_compute_flavor.db.id
  size              = 10
  volume_type       = "ceph-ssd"

  datastore {
    type    = "postgresql"
    version = "17"
  }

  network {
    uuid            = vkcs_networking_network.pg.id
    security_groups = [vkcs_networking_secgroup.pg.id]
  }

  floating_ip_enabled = var.public_access

  disk_autoexpand {
    autoexpand    = true
    max_disk_size = 20
  }

  depends_on = [vkcs_networking_router_interface.pg]
}

resource "vkcs_db_database" "bananaflow" {
  name    = "bananaflow"
  dbms_id = vkcs_db_instance.pg.id
}

resource "vkcs_db_user" "banana" {
  name      = "banana"
  password  = var.db_password
  dbms_id   = vkcs_db_instance.pg.id
  databases = [vkcs_db_database.bananaflow.name]
}

resource "vkcs_backup_plan" "pg" {
  name               = "otus-pg-backup"
  provider_name      = "dbaas"
  incremental_backup = false
  instance_ids       = [vkcs_db_instance.pg.id]

  schedule = {
    date = ["Su"]
    time = "03:00"
  }

  full_retention = {
    max_full_backup = 7
  }
}

resource "vkcs_networking_secgroup_rule" "psql_subnet" {
  direction         = "ingress"
  protocol          = "tcp"
  port_range_min    = 5432
  port_range_max    = 5432
  remote_ip_prefix  = vkcs_networking_subnet.pg.cidr
  security_group_id = vkcs_networking_secgroup.pg.id
}

data "vkcs_images_image" "ubuntu" {
  name = "ubuntu-24-202607090925.gitd6f5e545"
}

data "vkcs_compute_flavor" "client" {
  name = "STD3-2-4"
}

resource "vkcs_compute_instance" "client" {
  name              = "otus-pg-client"
  availability_zone = var.availability_zone
  flavor_id         = data.vkcs_compute_flavor.client.id

  block_device {
    uuid                  = data.vkcs_images_image.ubuntu.id
    source_type           = "image"
    destination_type      = "volume"
    volume_type           = "ceph-ssd"
    volume_size           = 10
    boot_index            = 0
    delete_on_termination = true
  }

  network {
    uuid = vkcs_networking_network.pg.id
  }

  user_data = templatefile("${path.module}/../../cloud-init/user-data.yaml.tftpl", {
    cloud     = "vk"
    inventory = file("${path.module}/../../ansible/inventory/vk-vm.yml")
    conninfo  = file("${path.module}/../../ansible/conninfo.yml")
    playbook  = file("${path.module}/../../ansible/playbook.yml")
    pgbench   = file("${path.module}/../../ansible/pgbench.yml")
  })

  depends_on = [vkcs_networking_router_interface.pg, vkcs_networking_secgroup_rule.psql_subnet]
}
