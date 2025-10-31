# SNS Topic for order processing
resource "aws_sns_topic" "order_processing" {
  name = "${var.environment}-order-processing-events"
  
  tags = {
    Name = "${var.environment}-order-processing-topic"
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
    Name = "${var.environment}-order-queue"
  }
}

# Dead Letter Queue
resource "aws_sqs_queue" "order_dlq" {
  name                      = "${var.environment}-order-dlq"
  message_retention_seconds = 1209600  # 14 days

  tags = {
    Name = "${var.environment}-order-dlq"
  }
}

# SNS Subscription to SQS
resource "aws_sns_topic_subscription" "order_queue" {
  topic_arn = aws_sns_topic.order_processing.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.order_processing.arn
}

# SQS Queue Policy to allow SNS
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