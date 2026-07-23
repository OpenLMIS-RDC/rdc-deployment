output "public_ip" {
  value = module.dev.public_ip
}

output "private_ip" {
  value = module.dev.private_ip
}

output "db_address" {
  value = module.dev.db_address
}
