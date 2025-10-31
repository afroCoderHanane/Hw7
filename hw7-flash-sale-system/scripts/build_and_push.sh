

#!/usr/bin/env bash

set -euo pipefail

# --- Configuration ---
AWS_REGION="us-west-2"              # Default region
IMAGE_NAME="flash-sale-lambda"      # Default image name
TAG="latest"                        # Default tag

# --- Helper functions ---
function usage() {
  echo "Usage: $0 [-r <aws-region>] [-i <image-name>] [-t <tag>]" >&2
  exit 1
}

# --- Parse arguments ---
while getopts ":r:i:t:" opt; do
  case ${opt} in
    r) AWS_REGION="$OPTARG" ;;
    i) IMAGE_NAME="$OPTARG" ;;
    t) TAG="$OPTARG" ;;
    *) usage ;;
  esac
done

# --- Resolve AWS account ID ---
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
if [ -z "$AWS_ACCOUNT_ID" ]; then
  echo "❌ Failed to fetch AWS account ID. Make sure AWS CLI is configured." >&2
  exit 1
fi

# --- Compute ECR URI ---
ECR_URI="$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$IMAGE_NAME:$TAG"

# --- Ensure repository exists ---
if ! aws ecr describe-repositories --repository-names "$IMAGE_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  echo "📦 ECR repository not found, creating: $IMAGE_NAME"
  aws ecr create-repository --repository-name "$IMAGE_NAME" --region "$AWS_REGION" >/dev/null
else
  echo "✅ ECR repository already exists: $IMAGE_NAME"
fi

# --- Authenticate Docker to ECR ---
echo "🔐 Logging in to Amazon ECR..."
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"

# --- Build Docker image ---
echo "⚙️  Building Docker image: $IMAGE_NAME:$TAG"
DOCKER_BUILDKIT=1 docker build -t "$IMAGE_NAME:$TAG" .

# --- Tag and push image ---
echo "🏷️  Tagging image as: $ECR_URI"
docker tag "$IMAGE_NAME:$TAG" "$ECR_URI"

echo "🚀 Pushing image to ECR..."
docker push "$ECR_URI"

echo "✅ Successfully pushed image: $ECR_URI"