#!/bin/bash

# HW7 Deployment Script
set -e

# Configuration
AWS_REGION="us-west-2"
ENVIRONMENT="hw7"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}HW7 Flash Sale System Deployment${NC}"
echo "================================="

# Step 1: Deploy Infrastructure
deploy_infrastructure() {
    echo -e "\n${YELLOW}Deploying AWS Infrastructure...${NC}"
    
    cd ../terraform
    terraform init
    terraform apply -auto-approve
    
    # Capture outputs
    export ALB_URL=$(terraform output -raw alb_url)
    export SNS_TOPIC_ARN=$(terraform output -raw sns_topic_arn)
    export SQS_QUEUE_URL=$(terraform output -raw sqs_queue_url)
    export ORDER_SERVICE_ECR=$(terraform output -raw order_service_ecr_url)
    export ORDER_PROCESSOR_ECR=$(terraform output -raw order_processor_ecr_url)
    export CLUSTER_NAME=$(terraform output -raw ecs_cluster_name)
    
    echo -e "${GREEN}Infrastructure deployed!${NC}"
    echo "ALB URL: $ALB_URL"
    cd ../scripts
}

# Step 2: Build and Push Docker Images
build_and_push() {
    echo -e "\n${YELLOW}Building and pushing Docker images...${NC}"
    
    # Login to ECR
    aws ecr get-login-password --region $AWS_REGION | \
        docker login --username AWS --password-stdin ${ORDER_SERVICE_ECR%/*}
    
    # Build Order Service
    echo "Building order service..."
    cd ../src/order_service
    docker build -t order-service .
    docker tag order-service:latest ${ORDER_SERVICE_ECR}:latest
    docker push ${ORDER_SERVICE_ECR}:latest
    
    # Build Order Processor
    echo "Building order processor..."
    cd ../order_processor
    docker build -t order-processor .
    docker tag order-processor:latest ${ORDER_PROCESSOR_ECR}:latest
    docker push ${ORDER_PROCESSOR_ECR}:latest
    
    cd ../../scripts
    echo -e "${GREEN}Images pushed successfully!${NC}"
}

# Step 3: Update ECS Services
update_ecs() {
    echo -e "\n${YELLOW}Updating ECS services...${NC}"
    
    aws ecs update-service \
        --cluster ${CLUSTER_NAME} \
        --service ${ENVIRONMENT}-order-service \
        --force-new-deployment \
        --region $AWS_REGION > /dev/null
    
    aws ecs update-service \
        --cluster ${CLUSTER_NAME} \
        --service ${ENVIRONMENT}-order-processor \
        --force-new-deployment \
        --region $AWS_REGION > /dev/null
    
    echo "Waiting for services to stabilize..."
    aws ecs wait services-stable \
        --cluster ${CLUSTER_NAME} \
        --services ${ENVIRONMENT}-order-service \
        --region $AWS_REGION
    
    echo -e "${GREEN}ECS services updated!${NC}"
}

# Step 4: Test Endpoints
test_endpoints() {
    echo -e "\n${YELLOW}Testing endpoints...${NC}"
    
    # Wait for ALB to be ready
    sleep 10
    
    # Test health
    echo "Testing health endpoint..."
    curl -s ${ALB_URL}/health | python3 -m json.tool
    
    echo -e "${GREEN}Endpoints ready!${NC}"
}

# Main execution
case "${1:-full}" in
    full)
        deploy_infrastructure
        build_and_push
        update_ecs
        test_endpoints
        echo -e "\n${GREEN}Deployment complete!${NC}"
        echo "ALB URL: $ALB_URL"
        ;;
    infra)
        deploy_infrastructure
        ;;
    build)
        # Load outputs
        cd ../terraform
        export ORDER_SERVICE_ECR=$(terraform output -raw order_service_ecr_url)
        export ORDER_PROCESSOR_ECR=$(terraform output -raw order_processor_ecr_url)
        cd ../scripts
        build_and_push
        ;;
    update)
        # Load outputs
        cd ../terraform
        export CLUSTER_NAME=$(terraform output -raw ecs_cluster_name)
        cd ../scripts
        update_ecs
        ;;
    test)
        cd ../terraform
        export ALB_URL=$(terraform output -raw alb_url)
        cd ../scripts
        test_endpoints
        ;;
    *)
        echo "Usage: $0 {full|infra|build|update|test}"
        exit 1
        ;;
esac