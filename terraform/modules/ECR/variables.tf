variable "project" {
  description = "Project name prefix — repositories are named <project>/<service>"
  type        = string
  default     = "streamingapp"
}

variable "repos" {
  description = "List of service names — one ECR repository is created for each"
  type        = list(string)
  default     = ["auth", "streaming", "admin", "chat", "frontend"]
}
