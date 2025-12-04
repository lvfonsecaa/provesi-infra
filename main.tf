terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# ==============================
# VPC y subredes (default)
# ==============================
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# ==============================
# Security Group para ECS y RDS
# (abierto para pruebas; luego lo puedes cerrar)
# ==============================
resource "aws_security_group" "ecs_sg" {
  name        = "provesi-ecs-sg"
  description = "SG para servicios ECS y RDS"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # para pruebas
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ==============================
# RDS Postgres (BD principal)
# ==============================
resource "aws_db_subnet_group" "db_subnet_group" {
  name       = "provesi-db-subnets"
  subnet_ids = data.aws_subnets.default.ids
}

resource "aws_db_instance" "postgres" {
  identifier          = "provesi-postgres"
  allocated_storage   = 20
  engine              = "postgres"
  engine_version      = "16.1"
  instance_class      = "db.t3.micro"
  username            = "delta"
  password            = var.db_password
  db_name             = "provesi"
  skip_final_snapshot = true

  vpc_security_group_ids = [aws_security_group.ecs_sg.id]
  db_subnet_group_name   = aws_db_subnet_group.db_subnet_group.name

  publicly_accessible = false
}

# ==============================
# ECS Cluster (Fargate)
# ==============================
resource "aws_ecs_cluster" "cluster" {
  name = "provesi-cluster"
}

# ==============================
# IAM role para tareas ECS
# ==============================
data "aws_iam_policy_document" "ecs_task_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_task_execution_role" {
  name               = "provesi-ecs-task-execution-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume.json
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ==============================
# Task definition: order-service (Django)
# ==============================
resource "aws_ecs_task_definition" "order_service" {
  family                   = "order-service"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn

  container_definitions = jsonencode([
    {
      name      = "order-service"
      image     = var.order_service_image
      essential = true
      portMappings = [
        {
          containerPort = 8000
          protocol      = "tcp"
        }
      ]
      environment = [
        { name = "POSTGRES_HOST", value = aws_db_instance.postgres.address },
        { name = "POSTGRES_PORT", value = "5432" },
        { name = "POSTGRES_DB",   value = "provesi" },
        { name = "POSTGRES_USER", value = "delta" },
        { name = "POSTGRES_PASSWORD", value = var.db_password },
        { name = "DJANGO_DEBUG", value = "False" },
        { name = "DJANGO_ALLOWED_HOSTS", value = "*" }
      ]
    }
  ])
}

# ==============================
# Task definition: channel-registry-service (Node)
# ==============================
resource "aws_ecs_task_definition" "channel_registry" {
  family                   = "channel-registry-service"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn

  container_definitions = jsonencode([
    {
      name      = "channel-registry-service"
      image     = var.channel_registry_image
      essential = true
      portMappings = [
        {
          containerPort = 3002
          protocol      = "tcp"
        }
      ]
      environment = [
        { name = "POSTGRES_HOST", value = aws_db_instance.postgres.address },
        { name = "POSTGRES_PORT", value = "5432" },
        { name = "POSTGRES_DB",   value = "provesi" },
        { name = "POSTGRES_USER", value = "delta" },
        { name = "POSTGRES_PASSWORD", value = var.db_password }
      ]
    }
  ])
}

# ==============================
# Task definition: order-query-service (Node + Mongo)
# ==============================
resource "aws_ecs_task_definition" "order_query" {
  family                   = "order-query-service"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn

  container_definitions = jsonencode([
    {
      name      = "order-query-service"
      image     = var.order_query_image
      essential = true
      portMappings = [
        {
          containerPort = 3001
          protocol      = "tcp"
        }
      ]
      environment = [
        # IMPORTANTE: aquí luego deberías poner el URL real de order-service (ALB o Service Discovery)
        { name = "ORDER_SERVICE_BASE_URL", value = "http://order-service:8000" },
        { name = "MONGO_URL",              value = "mongodb://localhost:27017" },
        { name = "MONGO_DB_NAME",          value = "orders_read" },
        { name = "MONGO_COLLECTION",       value = "orders" }
      ]
    }
  ])
}

# ==============================
# Servicios ECS (uno por microservicio)
# ==============================
resource "aws_ecs_service" "order_service" {
  name            = "order-service"
  cluster         = aws_ecs_cluster.cluster.id
  task_definition = aws_ecs_task_definition.order_service.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.ecs_sg.id]
    assign_public_ip = true
  }
}

resource "aws_ecs_service" "channel_registry" {
  name            = "channel-registry-service"
  cluster         = aws_ecs_cluster.cluster.id
  task_definition = aws_ecs_task_definition.channel_registry.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.ecs_sg.id]
    assign_public_ip = true
  }
}

resource "aws_ecs_service" "order_query" {
  name            = "order-query-service"
  cluster         = aws_ecs_cluster.cluster.id
  task_definition = aws_ecs_task_definition.order_query.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.ecs_sg.id]
    assign_public_ip = true
  }
}
