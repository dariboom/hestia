output "alb_arn" {
  description = "ALB ARN."
  value       = aws_lb.this.arn
}

output "alb_dns_name" {
  description = "ALB DNS name; the live stack publishes it to SSM for the global edge."
  value       = aws_lb.this.dns_name
}

output "alb_zone_id" {
  description = "Route 53 zone ID of the ALB, for alias records."
  value       = aws_lb.this.zone_id
}

output "target_group_arn" {
  description = "IP target group for the LB Controller TargetGroupBinding."
  value       = aws_lb_target_group.this.arn
}

output "alb_security_group_id" {
  description = "ALB security group; workload security groups admit target_port from it."
  value       = aws_security_group.alb.id
}

output "web_acl_arn" {
  description = "Regional WAF web ACL associated with the ALB."
  value       = aws_wafv2_web_acl.this.arn
}
