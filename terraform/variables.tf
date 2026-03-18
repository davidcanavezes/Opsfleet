variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "eu-central-1"
}

variable "cluster_name" {
  description = "Name of the EKS cluster and common prefix for related resources."
  type        = string
  default     = "opsfleet-eks"
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS cluster."
  type        = string
  default     = "1.35"
}

variable "vpc_cidr" {
  description = "CIDR block for the dedicated VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "environment" {
  description = "Environment label applied to all resources."
  type        = string
  default     = "dev"
}

variable "allowed_cidr_blocks" {
  description = "CIDR blocks allowed to reach the EKS public API endpoint. Example: [\"203.0.113.42/32\"]. Run: curl -s https://checkip.amazonaws.com"
  type        = list(string)
}

variable "developer_iam_arn" {
  description = "IAM role or user ARN mapped to the Kubernetes 'developers' group. Leave empty to skip the access entry."
  type        = string
  default     = ""
}

