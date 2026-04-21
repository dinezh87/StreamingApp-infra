output "repository_urls" {
  description = "Map of service name to ECR repository URL — used in Helm values as the image registry base"
  value       = { for k, v in aws_ecr_repository.repos : k => v.repository_url }
}

output "repository_arns" {
  description = "Map of service name to ECR repository ARN — used in IAM policies for EKS node ECR pull access"
  value       = { for k, v in aws_ecr_repository.repos : k => v.arn }
}
