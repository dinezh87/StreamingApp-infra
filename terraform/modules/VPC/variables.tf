variable "project" {
  description = "Project name prefix for all resource names"
  type        = string
  default     = "streamingapp"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDRs for public subnets (ALB + NAT) — one per AZ"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_app_subnet_cidrs" {
  description = "CIDRs for private app subnets (EKS nodes) — one per AZ"
  type        = list(string)
  default     = ["10.0.3.0/24", "10.0.4.0/24"]
}

variable "private_data_subnet_cidr" {
  description = "CIDR for private data subnet (MongoDB + ElastiCache) — single AZ us-east-1a"
  type        = string
  default     = "10.0.5.0/24"
}
