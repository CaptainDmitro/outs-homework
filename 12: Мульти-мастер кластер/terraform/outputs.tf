output "public_ips" {
  value = { for k, v in yandex_compute_instance.node : v.name => v.network_interface[0].nat_ip_address }
}
