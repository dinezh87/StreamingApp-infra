output "cluster_name" {
  value = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.main.endpoint
}

output "cluster_ca_certificate" {
  value = aws_eks_cluster.main.certificate_authority[0].data
}

output "app_node_security_group_id" {
  description = "Security group ID for app worker nodes — used by ElastiCache SG rules"
  value       = aws_eks_node_group.app.resources[0].remote_access_security_group_id
}

output "data_node_security_group_id" {
  description = "Security group ID for data worker node — used by MongoDB pod SG rules"
  value       = aws_eks_node_group.data.resources[0].remote_access_security_group_id
}

output "oidc_provider_arn" {
  description = "OIDC provider ARN — used when creating IRSA roles for each service"
  value       = aws_iam_openid_connect_provider.oidc.arn
}

output "oidc_provider_url" {
  description = "OIDC provider URL (without https://) — used in IRSA trust policy conditions"
  value       = replace(aws_iam_openid_connect_provider.oidc.url, "https://", "")
}
