package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"time"

	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-lambda-go/lambda"
)

// Order represents an e-commerce order
type Order struct {
	OrderID     string    `json:"order_id"`
	CustomerID  int       `json:"customer_id"`
	Status      string    `json:"status"`
	Items       []Item    `json:"items"`
	CreatedAt   time.Time `json:"created_at"`
	ProcessedAt time.Time `json:"processed_at"`
}

// Item represents a product in an order
type Item struct {
	ProductID string  `json:"product_id"`
	Quantity  int     `json:"quantity"`
	Price     float64 `json:"price"`
}

// ProcessOrder handles SNS events directly (no SQS needed)
func ProcessOrder(ctx context.Context, snsEvent events.SNSEvent) error {
	for _, record := range snsEvent.Records {
		// Parse order from SNS message
		var order Order
		err := json.Unmarshal([]byte(record.SNS.Message), &order)
		if err != nil {
			log.Printf("Failed to parse order: %v", err)
			return err
		}
		
		log.Printf("Processing order %s for customer %d", order.OrderID, order.CustomerID)
		
		// Simulate 3-second payment processing
		startTime := time.Now()
		time.Sleep(3 * time.Second)
		processingTime := time.Since(startTime)
		
		// Simulate 1% payment failures
		if time.Now().UnixNano()%100 == 0 {
			return fmt.Errorf("payment failed for order %s", order.OrderID)
		}
		
		log.Printf("Order %s processed successfully in %v", order.OrderID, processingTime)
	}
	
	return nil
}

func main() {
	lambda.Start(ProcessOrder)
}