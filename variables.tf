variable "aws_region" {
  description = "Región de AWS"
  type        = string
  default     = "us-east-1"
}

variable "db_password" {
  description = "Password del usuario delta de Postgres"
  type        = string
  sensitive   = true
}

variable "order_service_image" {
  description = "Imagen ECR para order-service (Django)"
  type        = string
}

variable "channel_registry_image" {
  description = "Imagen ECR para channel-registry-service"
  type        = string
}

variable "order_query_image" {
  description = "Imagen ECR para order-query-service"
  type        = string
}
