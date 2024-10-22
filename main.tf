provider "aws" {
  region = "eu-north-1"
}

# VPC setup
resource "aws_vpc" "my_vpc" {
  cidr_block = "10.0.0.0/16"
}

# Subnets for the VPC
resource "aws_subnet" "private_subnet_1" {
  vpc_id = aws_vpc.my_vpc.id
  cidr_block = "10.0.1.0"
}

resource "aws_subnet" "private_subnet_2" {
  vpc_id = aws_vpc.my_vpc.id
  cidr_block = "10.0.2.0"
}

# Security groups
resource "aws_security_group" "fargate_sg" {
  vpc_id = aws_vpc.my_vpc.id
  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = [ "0.0.0.0/0" ]
  }
}

resource "aws_security_group" "db_sg" {
  vpc_id = aws_vpc.my_vpc.id
  ingress {
    from_port = 5432
    to_port = 5432
    protocol = "tcp"
    security_groups = [ aws_security_group.fargate_sg.id ] # Allow traffic from ECS tasks
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
  family = "my-task-family"
  network_mode = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  memory = "512"
  cpu = "256"
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
            #"environment": [
            #    { "name": "PG_HOST", "value": },
            #    { "name": "PG_USER", "value": },
            #    { "name": "PG_DB", "value": },
            #    { "name": "PG_PORT", "value": }
            ]
        }
    ]
    DEFINITION
}