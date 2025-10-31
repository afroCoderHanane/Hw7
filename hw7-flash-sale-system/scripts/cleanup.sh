#!/bin/bash

# Cleanup Script - Destroys all HW7 infrastructure

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${RED}WARNING: This will destroy all HW7 infrastructure!${NC}"
read -p "Are you sure? (yes/no): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    echo "Cleanup cancelled"
    exit 0
fi

echo -e "\n${YELLOW}Starting cleanup...${NC}"

# Destroy Terraform infrastructure
cd ../terraform
terraform destroy -auto-approve

# Clean up local files
cd ..
rm -rf testing/results/*.csv
rm -rf testing/results/*.html
rm -f scripts/queue_metrics.csv

echo -e "${GREEN}Cleanup complete!${NC}"