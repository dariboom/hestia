output "private_zone_id" {
  description = "Private hosted zone shared by the regional VPCs."
  value       = aws_route53_zone.private.zone_id
}

output "public_zone_id" {
  description = "Public hosted zone, or null when enable_public_ingress = false."
  value       = one(aws_route53_zone.public[*].zone_id)
}
