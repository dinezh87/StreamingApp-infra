variable "project" {
  description = "Project name prefix for all resource names"
  type        = string
  default     = "streamingapp"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "streamingapp"
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.29"
}

variable "private_app_subnet_ids" {
  description = "Private app subnet IDs from the VPC module — app node group is placed here"
  type        = list(string)
}

variable "private_data_subnet_id" {
  description = "Private data subnet ID from the VPC module — MongoDB node group is placed here"
  type        = string
}

variable "node_instance_type" {
  description = "EC2 instance type for app worker nodes"
  type        = string
  default     = "t3.medium"
}

variable "data_node_instance_type" {
  description = "EC2 instance type for the data node group (MongoDB)"
  type        = string
  default     = "t3.medium"
}

variable "node_min" {
  description = "Minimum number of app worker nodes"
  type        = number
  default     = 2
}

variable "node_max" {
  description = "Maximum number of app worker nodes (HPA headroom)"
  type        = number
  default     = 6
}

variable "node_desired" {
  description = "Initial desired number of app worker nodes"
  type        = number
  default     = 2
}
