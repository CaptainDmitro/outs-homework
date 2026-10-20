output "instance_id" {
  value = vkcs_db_instance.pg.id
}

output "ip" {
  value = vkcs_db_instance.pg.ip
}

output "client_id" {
  value = vkcs_compute_instance.client.id
}
