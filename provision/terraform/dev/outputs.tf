output "public_ip" {
  value = module.dev.public_ip
}

output "private_ip" {
  value = module.dev.private_ip
}

output "db_address" {
  value = module.dev.db_address
}

output "nlb_ip" {
  description = "Public entry IP held by the NLB (the DNS A record target)"
  value       = aws_eip.nlb.public_ip
}
