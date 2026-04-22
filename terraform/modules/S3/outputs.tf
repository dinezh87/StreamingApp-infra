output "bucket_name" {
  description = "S3 bucket name — used in Helm values as the S3_BUCKET env var for streaming and admin pods"
  value       = aws_s3_bucket.media.id
}

output "bucket_arn" {
  description = "S3 bucket ARN — used when creating IRSA IAM policies for streaming and admin roles"
  value       = aws_s3_bucket.media.arn
}

output "bucket_regional_domain_name" {
  description = "Regional domain name of the bucket — used as the S3 origin in the CloudFront module"
  value       = aws_s3_bucket.media.bucket_regional_domain_name
}

output "oac_id" {
  description = "CloudFront OAC ID — referenced in the CloudFront module when attaching OAC to the S3 origin"
  value       = aws_cloudfront_origin_access_control.media.id
}
