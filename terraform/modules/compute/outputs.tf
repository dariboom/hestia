output "cluster_name" {
  description = "EKS cluster name."
  value       = aws_eks_cluster.this.name
}

output "cluster_arn" {
  description = "EKS cluster ARN."
  value       = aws_eks_cluster.this.arn
}

output "oidc_provider_arn" {
  description = "IAM OIDC provider ARN, the input of compute/irsa-role."
  value       = aws_iam_openid_connect_provider.this.arn
}

output "cluster_security_group_id" {
  description = "EKS-managed cluster security group (control plane <-> nodes)."
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "node_security_group_id" {
  description = "Worker-node identity security group (reference it to admit pods' traffic, e.g. into RDS)."
  value       = aws_security_group.node.id
}

output "node_role_arn" {
  description = "Worker-node IAM role ARN."
  value       = aws_iam_role.node.arn
}
