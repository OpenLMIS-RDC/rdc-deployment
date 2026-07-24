output "nlb_ip" {
  description = "Public entry IP held by the NLB (the DNS A record target)"
  value       = aws_eip.nlb.public_ip
}

output "alb_arn" {
  value = aws_lb.app.arn
}

output "alb_security_group_id" {
  value = aws_security_group.alb.id
}
