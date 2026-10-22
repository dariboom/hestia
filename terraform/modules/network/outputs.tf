output "vpc_id" {
  description = "VPC ID."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "VPC CIDR."
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "Public subnet IDs, AZ order."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet IDs, AZ order."
  value       = aws_subnet.private[*].id
}

output "isolated_subnet_ids" {
  description = "Isolated subnet IDs, AZ order."
  value       = aws_subnet.isolated[*].id
}

output "private_route_table_ids" {
  description = "Private route table IDs (one per AZ); network-peering adds peer routes here."
  value       = aws_route_table.private[*].id
}

output "isolated_route_table_ids" {
  description = "Isolated route table IDs; network-peering adds peer routes here."
  value       = [aws_route_table.isolated.id]
}

output "endpoint_security_group_id" {
  description = "Security group on the interface endpoints."
  value       = aws_security_group.endpoints.id
}

output "flow_log_bucket_arn" {
  description = "Flow-log bucket ARN (Athena / security tooling)."
  value       = module.flow_log_bucket.arn
}
