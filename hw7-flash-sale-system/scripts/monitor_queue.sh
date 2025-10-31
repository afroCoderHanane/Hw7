#!/bin/bash

# Queue Monitoring Script
# Monitors SQS queue depth and processor metrics

# Get queue URL from Terraform
cd ../terraform
SQS_QUEUE_URL=$(terraform output -raw sqs_queue_url)
ALB_URL=$(terraform output -raw alb_url)
cd ../scripts

# Duration in seconds (default 5 minutes)
DURATION=${1:-300}

echo "Monitoring Queue and Processor Metrics"
echo "======================================"
echo "Queue: $SQS_QUEUE_URL"
echo "Duration: $DURATION seconds"
echo ""

START_TIME=$(date +%s)
END_TIME=$((START_TIME + DURATION))

# CSV header for logging
echo "Timestamp,QueueDepth,InFlight,ProcessorWorkers,ProcessedOrders" > queue_metrics.csv

while [ $(date +%s) -lt $END_TIME ]; do
    # Get queue metrics
    QUEUE_ATTRS=$(aws sqs get-queue-attributes \
        --queue-url $SQS_QUEUE_URL \
        --attribute-names ApproximateNumberOfMessages,ApproximateNumberOfMessagesNotVisible \
        --region us-west-2 \
        --output json)
    
    QUEUE_DEPTH=$(echo $QUEUE_ATTRS | jq -r '.Attributes.ApproximateNumberOfMessages // 0')
    IN_FLIGHT=$(echo $QUEUE_ATTRS | jq -r '.Attributes.ApproximateNumberOfMessagesNotVisible // 0')
    
    # Get processor metrics
    PROCESSOR_METRICS=$(curl -s ${ALB_URL}/processor/metrics 2>/dev/null || echo "{}")
    WORKERS=$(echo $PROCESSOR_METRICS | jq -r '.processor.workers_active // 0')
    PROCESSED=$(echo $PROCESSOR_METRICS | jq -r '.processor.orders_processed // 0')
    
    # Display
    TIMESTAMP=$(date +"%H:%M:%S")
    echo "$TIMESTAMP | Queue: $QUEUE_DEPTH | In-Flight: $IN_FLIGHT | Workers: $WORKERS | Processed: $PROCESSED"
    
    # Log to CSV
    echo "$TIMESTAMP,$QUEUE_DEPTH,$IN_FLIGHT,$WORKERS,$PROCESSED" >> queue_metrics.csv
    
    sleep 5
done

echo ""
echo "Monitoring complete. Results saved to queue_metrics.csv"

# Generate simple analysis
echo ""
echo "Queue Analysis:"
echo "==============="
MAX_QUEUE=$(tail -n +2 queue_metrics.csv | awk -F',' '{print $2}' | sort -n | tail -1)
AVG_QUEUE=$(tail -n +2 queue_metrics.csv | awk -F',' '{sum+=$2; count++} END {print sum/count}')
echo "Max Queue Depth: $MAX_QUEUE"
echo "Avg Queue Depth: $AVG_QUEUE"