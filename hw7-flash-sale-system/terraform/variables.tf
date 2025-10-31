variable "aws_region" {
  description = "AWS region for deployment"
  type        = string
  default     = "us-west-2"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "hw7"
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "order_service_cpu" {
  description = "CPU units for order service"
  type        = string
  default     = "256"
}

variable "order_service_memory" {
  description = "Memory for order service"
  type        = string
  default     = "512"
}

variable "order_processor_cpu" {
  description = "CPU units for order processor"
  type        = string
  default     = "256"
}

variable "order_processor_memory" {
  description = "Memory for order processor"
  type        = string
  default     = "512"
}

variable "initial_worker_count" {
  description = "Initial number of workers for order processor"
  type        = string
  default     = "1"
}