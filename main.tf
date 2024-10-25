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
  cidr_block = "10.0.1.0/24"
  availability_zone = "eu-north-1a"
}

resource "aws_subnet" "private_subnet_2" {
  vpc_id     = aws_vpc.my_vpc.id
  cidr_block = "10.0.2.0/24"
  availability_zone = "eu-north-1b"
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
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn
  container_definitions    = <<DEFINITION
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
  password               = "Pa$$w0rd"
  vpc_security_group_ids = [aws_security_group.db_sg.id]
  db_subnet_group_name   = aws_db_subnet_group.my_subnet_group.name
  skip_final_snapshot    = true
}

# DB subnet group
resource "aws_db_subnet_group" "my_subnet_group" {
  name       = "my-db-subnet-group"
  subnet_ids = [
    aws_subnet.private_subnet_1.id, 
    aws_subnet.private_subnet_2.id
    ]
}

# IAM role for ECS task execution
resource "aws_iam_role" "ecs_task_execution_role" {
  name               = "ecs-task-execution-role"
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ecs-tasks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

# IAM role for ECS task role
resource "aws_iam_role" "ecs_task_role" {
  name               = "ecs-task-role"
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ecs-tasks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

#Attach policy to allow ECS to interact with AWS resources
resource "aws_iam_role_policy_attachment" "ecs_execution_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Lambda function to invoke ECS task
resource "aws_lambda_function" "ecs_invoker_lambda" {
  function_name = "ecs_invoker_lambda"
  handler       = "index.handler"
  runtime       = "nodejs18.x"
  role          = aws_iam_role.lambda_exec_role.arn

  environment {
    variables = {
      CLUSTER_NAME    = aws_ecs_cluster.my_cluster.name
      TASK_DEFINITION = aws_ecs_task_definition.my_task.arn
      SUBNET_1        = aws_subnet.private_subnet_1.id
      SUBNET_2        = aws_subnet.private_subnet_2.id
      SECURITY_GROUP  = aws_security_group.fargate_sg.id
    }
  }

  # S3 bucket and key for Lambda function code
  s3_bucket = "lambdafunction-to-invoke-ecstask"
  s3_key    = "lambda-function.zip"
}

# IAM role for Lambda execution role
resource "aws_iam_role" "lambda_exec_role" {
  name               = "lambda-execution-role"
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

# Attach policies to allow Lambda to execute
resource "aws_iam_role_policy_attachment" "lambda_policy_attachment" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = "arn:aws:iam::aws:policy/AWSLambdaExecute"
}

# EventBridge rule to trigger Lambda
resource "aws_cloudwatch_event_rule" "ecs_task_trigger" {
  name          = "ecs-task-trigger"
  event_pattern = <<PATTERN
  {
    "source": ["custom.my-application"],
    "detail-type":["myDetaiType"]
  }
  PATTERN
}

# EventBridge target to invoke Lambda
resource "aws_cloudwatch_event_target" "ecs_invoker_target" {
  rule = aws_cloudwatch_event_rule.ecs_task_trigger.name
  arn  = aws_lambda_function.ecs_invoker_lambda.arn
}

# Lambda permission for EventBridge
resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ecs_invoker_lambda.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.ecs_task_trigger.arn
}

# CloudWatch log group for ECS
resource "aws_cloudwatch_log_group" "my_app_logs" {
  name              = "/ecs/myAppLogs"
  retention_in_days = 7
}
