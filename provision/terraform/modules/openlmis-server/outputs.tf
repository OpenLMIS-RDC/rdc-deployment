output "public_ip" {
  description = "Elastic IP of the application host (point the DNS A record here)"
  value       = aws_eip.app.public_ip
}

output "private_ip" {
  description = "Private IP of the application host (use in rdc-configuration env.conf)"
  value       = aws_instance.app.private_ip
}

output "instance_id" {
  value = aws_instance.app.id
}

output "app_security_group_id" {
  value = aws_security_group.app.id
}

output "db_address" {
  description = "RDS endpoint hostname for DATABASE_URL in settings.env"
  value       = var.create_db ? aws_db_instance.db[0].address : null
}
