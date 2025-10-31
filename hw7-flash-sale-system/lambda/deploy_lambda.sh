#!/bin/bash

# Deploy Lambda function for Part III

AWS_REGION="us-west-2"
FUNCTION_NAME="hw7-order-processor-lambda"

echo "Deploying Lambda Function"
echo "========================"

# Get SNS topic ARN from Terraform
cd ../terraform
SNS_TOPIC_ARN=$(terraform output -raw sns_topic_arn)
cd ../lambda

# Create deployment package
echo "Building Lambda function..."
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o main order_processor_lambda.go
zip deployment.zip main

# Create Lambda function
echo "Creating Lambda function..."
aws lambda create-function \
    --function-name ${FUNCTION_NAME} \
    --runtime go1.x \
    --role arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):role/LabRole \
    --handler main \
    --zip-file fileb://deployment.zip \
    --memory-size 512 \
    --timeout 10 \
    --region ${AWS_REGION}

# Add SNS trigger
echo "Adding SNS trigger..."
aws sns subscribe \
    --topic-arn ${SNS_TOPIC_ARN} \
    --protocol lambda \
    --notification-endpoint arn:aws:lambda:${AWS_REGION}:$(aws sts get-caller-identity --query Account --output text):function:${FUNCTION_NAME} \
    --region ${AWS_REGION}

# Grant SNS permission to invoke Lambda
aws lambda add-permission \
    --function-name ${FUNCTION_NAME} \
    --statement-id sns-trigger \
    --action lambda:InvokeFunction \
    --principal sns.amazonaws.com \
    --source-arn ${SNS_TOPIC_ARN} \
    --region ${AWS_REGION}

echo "Lambda function deployed!"

# Clean up
rm main deployment.zip