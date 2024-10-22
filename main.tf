provider "aws" {
  region = "eu-north-1"
}

# VPC setup
resource "aws_vpc" "my_vpc" {
  cidr_block = "10.0.0.0/16"
}

# Subnets for the VPC
resource "aws_subnet" "private_subnet_1" {
  vpc_id     = aws_vpc.my_vpc.id
  cidr_block = "10.0.1.0"
}

resource "aws_subnet" "private_subnet_2" {
  vpc_id     = aws_vpc.my_vpc.id
  cidr_block = "10.0.2.0"
}

# Security groups
resource "aws_security_group" "fargate_sg" {
  vpc_id = aws_vpc.my_vpc.id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "db_sg" {
  vpc_id = aws_vpc.my_vpc.id
  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.fargate_sg.id] # Allow traffic from ECS tasks
  }
}

# ECS cluster
resource "aws_ecs_cluster" "my_cluster" {
  name = "my-cluster"
}

# ECR repository for container images
resource "aws_ecr_repository" "my_repo" {
  name = "message-logger"
}

# ECS task definition
resource "aws_ecs_task_definition" "my_task" {
  family                   = "my-task-family"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  memory                   = "512"
  cpu                      = "256"
  #execution_role_arn = 
  #task_role_arn = 
  container_definitions = <<DEFINITION
    [
        {
            "name": "my-container",
            "image": "${aws_ecr_repository.my_repo.repository_url}:latest",
            "memory": 512,
            "cpu": 256,    
            "essential": true,
            "logConfiguration": {
                "logDriver": "awslogs",
                "options": {
                    "awslogs-group": "/ecs/myAppLogs",
                    "awslogs-region": "eu-north-1",
                    "awslogs-stream-prefix": "ecs"
                }
            },
            "environment": [
                { "name": "PG_HOST", "value": "${aws_db_instance.my_postgresql.endpoint}" },
                { "name": "PG_USER", "value": "dbadmin" },
                { "name": "PG_DB", "value": "mydatabase" },
                { "name": "PG_PORT", "value": "5432" }
            ]
        }
    ]
    DEFINITION
}

# RDS PostgreSQL instance 
resource "aws_db_instance" "my_postgresql" {
  engine                 = "postgres"
  instance_class         = "db.t3.micro"
  allocated_storage      = 20
  db_name                = "mydatabase"
  username               = "dbadmin"
  password               = "P@ssw0rd"
  vpc_security_group_ids = [aws_security_group.db_sg.id]
  db_subnet_group_name = aws_db_subnet_group.my_subnet_group.name
  skip_final_snapshot = true
}

# DB subnet group
resource "aws_db_subnet_group" "my_subnet_group" {
  name = "my-db-subnet-group"
  subnet_ids = [aws_subnet.private_subnet_1.id, aws_subnet.private_subnet_2.id]
}