output "peering_connection_id" {
  description = "VPC peering connection ID (active once accepted)."
  value       = aws_vpc_peering_connection_accepter.this.id
}
