# Configure the AWS provider
provider "aws" {
  region = "eu-north-1"
}

# VPC Module configuration
module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = "my-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["eu-north-1a", "eu-north-1b"] # Availability zones to span
  public_subnets  = ["10.0.1.0/24", "10.0.2.0/24"] # Public subnets for NAT and public resources
  private_subnets = ["10.0.3.0/24", "10.0.4.0/24"] # Private subnets for ECS and RDS

  enable_nat_gateway = true
  enable_vpn_gateway = false

  tags = {
    Terraform   = "true"
    Environment = "dev"
  }
}

# Security group for ECS
resource "aws_security_group" "fargate_sg" {
  #vpc_id = aws_vpc.my_vpc.id
  vpc_id = module.vpc.vpc_id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Security group for RDS
resource "aws_security_group" "db_sg" {
  #vpc_id = aws_vpc.my_vpc.id
  vpc_id = module.vpc.vpc_id
  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.fargate_sg.id] # Allow traffic from ECS tasks
    description     = "Allow PostgreSQL access from ECS tasks"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
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

# Secrets Manager for PostgreSQL Password
resource "aws_secretsmanager_secret" "db_password_secret" {
  name = "db_password_secret"
}

resource "aws_secretsmanager_secret_version" "db_password_secret_version" {
  secret_id = aws_secretsmanager_secret.db_password_secret.id
  secret_string = jsonencode({
    username = "dbadmin"
    password = "Pa$$w0rd"
    host     = aws_db_instance.my_postgresql.address
    dbname   = "mydatabase"
    port     = "5432"
  })
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
  container_definitions = jsonencode([
    {
      name      = "my-container",
      image     = "${aws_ecr_repository.my_repo.repository_url}:latest",
      memory    = 512,
      cpu       = 256,
      essential = true,
      logConfiguration = {
        logDriver = "awslogs",
        options = {
          "awslogs-group"         = "/ecs/myAppLogs",
          "awslogs-region"        = "eu-north-1",
          "awslogs-stream-prefix" = "ecs"
        }
      },
      environment = [
        { name = "PG_HOST", value = "${replace(aws_db_instance.my_postgresql.endpoint, ":5432", "")}" },
        { name = "PG_USER", value = "dbadmin" },
        { name = "PG_DB", value = "mydatabase" },
        { name = "PG_PORT", value = "5432" }
      ],
      secrets = [
        { name = "PG_PASSWORD", valueFrom = "${aws_secretsmanager_secret.db_password_secret.arn}" }
      ]

    }
  ])
}


# RDS PostgreSQL instance 
resource "aws_db_instance" "my_postgresql" {
  engine                 = "postgres"
  instance_class         = "db.t3.micro"
  allocated_storage      = 20
  db_name                = "mydatabase"
  #username               = "dbadmin"
  #password               = "Pa$$w0rd"
  vpc_security_group_ids = [aws_security_group.db_sg.id]
  db_subnet_group_name   = aws_db_subnet_group.my_subnet_group.name
  skip_final_snapshot    = true
}

# DB subnet group
resource "aws_db_subnet_group" "my_subnet_group" {
  name = "my-db-subnet-group"
  #subnet_ids = [ aws_subnet.private_subnet_1.id, aws_subnet.private_subnet_2.id]
  subnet_ids = module.vpc.private_subnets
  tags = {
    Name = "my-db-subnet-group"
  }
}

# IAM Roles and Policies
# IAM role for ECS task execution
resource "aws_iam_role" "ecs_task_execution_role" {
  name = "ecs-task-execution-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        },
        Action = "sts:AssumeRole"
      }
    ]
  })
}

#Attach policy to allow ECS to interact with AWS resources
resource "aws_iam_role_policy_attachment" "ecs_execution_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# IAM role for ECS task role
resource "aws_iam_role" "ecs_task_role" {
  name = "ecs-task-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        },
        Action = "sts:AssumeRole"
      }
    ]
  })
}

# IAM policy for accessing Secrets Manager from ECS task role
resource "aws_iam_role_policy" "ecs_task_secrets_policy" {
  name = "ecs-task-secrets-policy"
  role = aws_iam_role.ecs_task_execution_role.name

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "secretsmanager:GetSecretValue",
        ],
        Resource = aws_secretsmanager_secret.db_password_secret.arn
      }
    ]
  })
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
      SUBNET_1        = module.vpc.private_subnets[0]
      SUBNET_2        = module.vpc.private_subnets[1]
      SECURITY_GROUP  = aws_security_group.fargate_sg.id
    }
  }

  # S3 bucket and key for Lambda function code
  s3_bucket = "lambdafunction-to-invoke-ecstask"
  s3_key    = "lambda-function.zip"
}

# IAM role for Lambda execution role
resource "aws_iam_role" "lambda_exec_role" {
  name = "lambda-execution-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "lambda.amazonaws.com"
        },
        Action = "sts:AssumeRole"
      }
    ]
  })
}

# IAM policy to allow Lambda to run ECS tasks
resource "aws_iam_policy" "lambda_invoke_ecs_policy" {
  name = "lambda-invoke-ecs-policy"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "ecs:RunTask",
          "iam:PassRole"
        ],
        Resource = [
          aws_ecs_task_definition.my_task.arn,
          aws_iam_role.ecs_task_execution_role.arn,
          aws_iam_role.ecs_task_role.arn
        ]
      }
    ]
  })
}

# Attach policy to the Lambda execution role
resource "aws_iam_role_policy_attachment" "lambda_invoke_ecs_policy_attachment" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = aws_iam_policy.lambda_invoke_ecs_policy.arn
}

# EventBridge rule to trigger Lambda
resource "aws_cloudwatch_event_rule" "ecs_task_trigger" {
  name = "ecs-task-trigger"
  event_pattern = jsonencode({
    source        = ["custom.my-application"],
    "detail-type" = ["myDetailType"]
  })
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