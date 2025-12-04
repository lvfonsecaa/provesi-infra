output "ecs_cluster_name" {
  description = "Nombre del cluster ECS"
  value       = aws_ecs_cluster.cluster.name
}

output "rds_endpoint" {
  description = "Endpoint de la base de datos Postgres"
  value       = aws_db_instance.postgres.address
}
