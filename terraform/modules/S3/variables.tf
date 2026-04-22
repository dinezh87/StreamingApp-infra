variable "bucket_name" {
  description = "Globally unique S3 bucket name for media storage"
  type        = string
  default     = "streamingapp-media"
}

variable "domain" {
  description = "Application domain — used in CORS allowed origins"
  type        = string
  default     = "streamingapp.online"
}

variable "cloudfront_distribution_arn" {
  description = "ARN of the CloudFront distribution — used in the bucket policy OAC condition"
  type        = string
}

variable "streaming_irsa_role_arn" {
  description = "ARN of the streaming service IRSA role — granted s3:GetObject"
  type        = string
}

variable "admin_irsa_role_arn" {
  description = "ARN of the admin service IRSA role — granted s3:PutObject and s3:DeleteObject"
  type        = string
}
