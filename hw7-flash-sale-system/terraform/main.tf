# terraform/main.tf
# Main infrastructure configuration for HW7 - Flash Sale System

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  required_version = ">= 1.0"
}

# Variables
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

# Provider Configuration
provider "aws" {
  region = var.aws_region
}

# Data Sources
data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_iam_role" "lab_role" {
  name = "LabRole"
}

# VPC and Networking
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name        = "${var.environment}-vpc"
    Environment = var.environment
  }
}

# Public Subnets for ALB
resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.${count.index + 1}.0/24"
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name        = "${var.environment}-public-subnet-${count.index + 1}"
    Type        = "public"
    Environment = var.environment
  }
}

# Private Subnets for ECS
resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.${count.index + 10}.0/24"
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name        = "${var.environment}-private-subnet-${count.index + 1}"
    Type        = "private"
    Environment = var.environment
  }
}

# Internet Gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name        = "${var.environment}-igw"
    Environment = var.environment
  }
}

# Elastic IP for NAT Gateway
resource "aws_eip" "nat" {
  domain = "vpc"
  
  tags = {
    Name        = "${var.environment}-nat-eip"
    Environment = var.environment
  }

  depends_on = [aws_internet_gateway.main]
}

# NAT Gateway for private subnets
resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = {
    Name        = "${var.environment}-nat"
    Environment = var.environment
  }

  depends_on = [aws_internet_gateway.main]
}

# Route Tables
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name        = "${var.environment}-public-rt"
    Environment = var.environment
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = {
    Name        = "${var.environment}-private-rt"
    Environment = var.environment
  }
}

# Route Table Associations
resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# Security Groups
resource "aws_security_group" "alb" {
  name        = "${var.environment}-alb-sg"
  description = "Security group for Application Load Balancer"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.environment}-alb-sg"
    Environment = var.environment
  }
}

resource "aws_security_group" "ecs" {
  name        = "${var.environment}-ecs-sg"
  description = "Security group for ECS tasks"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Traffic from ALB"
    from_port       = 8080
    to_port         = 8081
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.environment}-ecs-sg"
    Environment = var.environment
  }
}

# Application Load Balancer
resource "aws_lb" "main" {
  name               = "${var.environment}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  enable_deletion_protection = false
  enable_http2              = true

  tags = {
    Name        = "${var.environment}-alb"
    Environment = var.environment
  }
}

# Target Groups
resource "aws_lb_target_group" "order_service" {
  name        = "${var.environment}-order-service-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  health_check {
    enabled             = true
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 5
    interval            = 30
    path                = "/health"
    matcher             = "200"
  }

  deregistration_delay = 30

  tags = {
    Name        = "${var.environment}-order-service-tg"
    Environment = var.environment
  }
}

resource "aws_lb_target_group" "order_processor" {
  name        = "${var.environment}-processor-tg"
  port        = 8081
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  health_check {
    enabled             = true
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 5
    interval            = 30
    path                = "/health"
    matcher             = "200"
  }

  deregistration_delay = 30

  tags = {
    Name        = "${var.environment}-processor-tg"
    Environment = var.environment
  }
}

# ALB Listeners
resource "aws_lb_listener" "main" {
  load_balancer_arn = aws_lb.main.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.order_service.arn
  }
}

# Listener rule for processor metrics
resource "aws_lb_listener_rule" "processor" {
  listener_arn = aws_lb_listener.main.arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.order_processor.arn
  }

  condition {
    path_pattern {
      values = ["/processor/*"]
    }
  }
}

# SNS Topic for order processing events
resource "aws_sns_topic" "order_processing" {
  name = "${var.environment}-order-processing-events"
  
  tags = {
    Name        = "${var.environment}-order-processing-topic"
    Environment = var.environment
  }
}

# SQS Queue for order processing
resource "aws_sqs_queue" "order_processing" {
  name                       = "${var.environment}-order-processing-queue"
  visibility_timeout_seconds = 30
  message_retention_seconds  = 345600  # 4 days
  receive_wait_time_seconds  = 20      # Long polling
  
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.order_dlq.arn
    maxReceiveCount     = 3
  })

  tags = {
    Name        = "${var.environment}-order-queue"
    Environment = var.environment
  }
}

# Dead Letter Queue
resource "aws_sqs_queue" "order_dlq" {
  name                      = "${var.environment}-order-dlq"
  message_retention_seconds = 1209600  # 14 days

  tags = {
    Name        = "${var.environment}-order-dlq"
    Environment = var.environment
  }
}

# SNS Subscription to SQS
resource "aws_sns_topic_subscription" "order_queue" {
  topic_arn = aws_sns_topic.order_processing.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.order_processing.arn
}

# SQS Queue Policy
resource "aws_sqs_queue_policy" "order_processing" {
  queue_url = aws_sqs_queue.order_processing.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "sns.amazonaws.com"
        }
        Action   = "sqs:SendMessage"
        Resource = aws_sqs_queue.order_processing.arn
        Condition = {
          ArnEquals = {
            "aws:SourceArn" = aws_sns_topic.order_processing.arn
          }
        }
      }
    ]
  })
}

# ECR Repositories
resource "aws_ecr_repository" "order_service" {
  name                 = "${var.environment}-order-service"
  image_tag_mutability = "MUTABLE"
  
  image_scanning_configuration {
    scan_on_push = true
  }
  
  tags = {
    Name        = "${var.environment}-order-service-repo"
    Environment = var.environment
  }
}

resource "aws_ecr_repository" "order_processor" {
  name                 = "${var.environment}-order-processor"
  image_tag_mutability = "MUTABLE"
  
  image_scanning_configuration {
    scan_on_push = true
  }
  
  tags = {
    Name        = "${var.environment}-order-processor-repo"
    Environment = var.environment
  }
}

# ECS Cluster
resource "aws_ecs_cluster" "main" {
  name = "${var.environment}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = {
    Name        = "${var.environment}-cluster"
    Environment = var.environment
  }
}

# CloudWatch Log Groups
resource "aws_cloudwatch_log_group" "order_service" {
  name              = "/ecs/${var.environment}-order-service"
  retention_in_days = 7

  tags = {
    Name        = "${var.environment}-order-service-logs"
    Environment = var.environment
  }
}

resource "aws_cloudwatch_log_group" "order_processor" {
  name              = "/ecs/${var.environment}-order-processor"
  retention_in_days = 7

  tags = {
    Name        = "${var.environment}-order-processor-logs"
    Environment = var.environment
  }
}

# ECS Task Definitions
resource "aws_ecs_task_definition" "order_service" {
  family                   = "${var.environment}-order-service"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = data.aws_iam_role.lab_role.arn
  task_role_arn            = data.aws_iam_role.lab_role.arn

  container_definitions = jsonencode([
    {
      name  = "order-service"
      image = "${aws_ecr_repository.order_service.repository_url}:latest"
      
      portMappings = [
        {
          containerPort = 8080
          protocol      = "tcp"
        }
      ]

      environment = [
        {
          name  = "AWS_REGION"
          value = var.aws_region
        },
        {
          name  = "SNS_TOPIC_ARN"
          value = aws_sns_topic.order_processing.arn
        },
        {
          name  = "PORT"
          value = "8080"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.order_service.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "ecs"
        }
      }

      essential = true
    }
  ])

  tags = {
    Name        = "${var.environment}-order-service-task"
    Environment = var.environment
  }
}

resource "aws_ecs_task_definition" "order_processor" {
  family                   = "${var.environment}-order-processor"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = data.aws_iam_role.lab_role.arn
  task_role_arn            = data.aws_iam_role.lab_role.arn

  container_definitions = jsonencode([
    {
      name  = "order-processor"
      image = "${aws_ecr_repository.order_processor.repository_url}:latest"
      
      portMappings = [
        {
          containerPort = 8081
          protocol      = "tcp"
        }
      ]

      environment = [
        {
          name  = "AWS_REGION"
          value = var.aws_region
        },
        {
          name  = "SQS_QUEUE_URL"
          value = aws_sqs_queue.order_processing.url
        },
        {
          name  = "PORT"
          value = "8081"
        },
        {
          name  = "WORKER_COUNT"
          value = "1"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.order_processor.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "ecs"
        }
      }

      essential = true
    }
  ])

  tags = {
    Name        = "${var.environment}-order-processor-task"
    Environment = var.environment
  }
}

# ECS Services
resource "aws_ecs_service" "order_service" {
  name            = "${var.environment}-order-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.order_service.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.order_service.arn
    container_name   = "order-service"
    container_port   = 8080
  }

  depends_on = [aws_lb_listener.main]

  tags = {
    Name        = "${var.environment}-order-service"
    Environment = var.environment
  }
}

resource "aws_ecs_service" "order_processor" {
  name            = "${var.environment}-order-processor"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.order_processor.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.order_processor.arn
    container_name   = "order-processor"
    container_port   = 8081
  }

  depends_on = [aws_lb_listener.main]

  tags = {
    Name        = "${var.environment}-order-processor"
    Environment = var.environment
  }
}

# Outputs
output "alb_url" {
  value       = "http://${aws_lb.main.dns_name}"
  description = "URL of the Application Load Balancer"
}

output "sns_topic_arn" {
  value       = aws_sns_topic.order_processing.arn
  description = "ARN of the SNS topic for order processing"
}

output "sqs_queue_url" {
  value       = aws_sqs_queue.order_processing.url
  description = "URL of the SQS queue for order processing"
}

output "sqs_queue_name" {
  value       = aws_sqs_queue.order_processing.name
  description = "Name of the SQS queue"
}

output "order_service_ecr_url" {
  value       = aws_ecr_repository.order_service.repository_url
  description = "ECR repository URL for order service"
}

output "order_processor_ecr_url" {
  value       = aws_ecr_repository.order_processor.repository_url
  description = "ECR repository URL for order processor"
}

output "ecs_cluster_name" {
  value       = aws_ecs_cluster.main.name
  description = "Name of the ECS cluster"
}

output "vpc_id" {
  value       = aws_vpc.main.id
  description = "ID of the VPC"
}