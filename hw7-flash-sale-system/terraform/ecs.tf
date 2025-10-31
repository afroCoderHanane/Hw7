# ECR Repositories
resource "aws_ecr_repository" "order_service" {
  name = "${var.environment}-order-service"
  
  image_scanning_configuration {
    scan_on_push = true
  }
  
  tags = {
    Name = "${var.environment}-order-service-repo"
  }
}

resource "aws_ecr_repository" "order_processor" {
  name = "${var.environment}-order-processor"
  
  image_scanning_configuration {
    scan_on_push = true
  }
  
  tags = {
    Name = "${var.environment}-order-processor-repo"
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
    Name = "${var.environment}-cluster"
  }
}

# CloudWatch Log Groups
resource "aws_cloudwatch_log_group" "order_service" {
  name              = "/ecs/${var.environment}-order-service"
  retention_in_days = 7

  tags = {
    Name = "${var.environment}-order-service-logs"
  }
}

resource "aws_cloudwatch_log_group" "order_processor" {
  name              = "/ecs/${var.environment}-order-processor"
  retention_in_days = 7

  tags = {
    Name = "${var.environment}-order-processor-logs"
  }
}

# ECS Task Definitions
resource "aws_ecs_task_definition" "order_service" {
  family                   = "${var.environment}-order-service"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.order_service_cpu
  memory                   = var.order_service_memory
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
    }
  ])

  tags = {
    Name = "${var.environment}-order-service-task"
  }
}

resource "aws_ecs_task_definition" "order_processor" {
  family                   = "${var.environment}-order-processor"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.order_processor_cpu
  memory                   = var.order_processor_memory
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
          value = var.initial_worker_count
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
    }
  ])

  tags = {
    Name = "${var.environment}-order-processor-task"
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
    Name = "${var.environment}-order-service"
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
    Name = "${var.environment}-order-processor"
  }
}