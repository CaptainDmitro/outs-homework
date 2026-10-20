output "server_id" {
  value = vkcs_compute_instance.bench.id
}

output "ip" {
  value = vkcs_compute_instance.bench.access_ip_v4
}
