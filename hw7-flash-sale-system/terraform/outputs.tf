output "alb_url" {
  value = "http://${aws_lb.main.dns_name}"
  description = "URL of the Application Load Balancer"
}

output "sns_topic_arn" {
  value = aws_sns_topic.order_processing.arn
  description = "ARN of the SNS topic"
}

output "sqs_queue_url" {
  value = aws_sqs_queue.order_processing.url
  description = "URL of the SQS queue"
}

output "order_service_ecr_url" {
  value = aws_ecr_repository.order_service.repository_url
  description = "ECR repository URL for order service"
}

output "order_processor_ecr_url" {
  value = aws_ecr_repository.order_processor.repository_url
  description = "ECR repository URL for order processor"
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.main.name
  description = "Name of the ECS cluster"
}

output "order_service_name" {
  value = aws_ecs_service.order_service.name
  description = "Name of the order service"
}

output "order_processor_name" {
  value = aws_ecs_service.order_processor.name
  description = "Name of the order processor service"
}