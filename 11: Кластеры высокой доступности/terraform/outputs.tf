output "public_ips" {
  value = { for k, v in yandex_compute_instance.site : v.name => v.network_interface[0].nat_ip_address }
}

output "pg_endpoint" {
  value = "${trimsuffix(yandex_dns_recordset.pg.name, ".")}.${trimsuffix(yandex_dns_zone.internal.zone, ".")}:5432 -> ${local.nlb_ip}"
}
