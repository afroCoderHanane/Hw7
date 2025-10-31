package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"sync"
	"sync/atomic"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/sns"
	"github.com/google/uuid"
	"github.com/gorilla/mux"
)

// Order represents an e-commerce order
type Order struct {
	OrderID     string    `json:"order_id"`
	CustomerID  int       `json:"customer_id"`
	Status      string    `json:"status"` // pending, processing, completed, failed
	Items       []Item    `json:"items"`
	CreatedAt   time.Time `json:"created_at"`
	ProcessedAt *time.Time `json:"processed_at,omitempty"`
}

// Item represents a product in an order
type Item struct {
	ProductID string  `json:"product_id"`
	Quantity  int     `json:"quantity"`
	Price     float64 `json:"price"`
}

// OrderService handles order processing
type OrderService struct {
	snsClient   *sns.Client
	snsTopicArn string
	
	// Payment processor with limited throughput (simulates bottleneck)
	paymentSemaphore chan struct{}
	
	// Metrics
	syncOrders      int64
	asyncOrders     int64
	failedOrders    int64
	processedOrders int64
	
	// Order storage
	orders sync.Map
}

// NewOrderService creates a new order service
func NewOrderService() (*OrderService, error) {
	// Initialize AWS config
	cfg, err := config.LoadDefaultConfig(context.TODO(),
		config.WithRegion(os.Getenv("AWS_REGION")),
	)
	if err != nil {
		log.Printf("Warning: Failed to load AWS config: %v", err)
	}
	
	service := &OrderService{
		snsTopicArn: os.Getenv("SNS_TOPIC_ARN"),
		// Payment processor can handle only 1 concurrent request (creates bottleneck)
		paymentSemaphore: make(chan struct{}, 1),
	}
	
	// Only initialize SNS client if we have AWS config
	if err == nil {
		service.snsClient = sns.NewFromConfig(cfg)
	}
	
	return service, nil
}

// ProcessPayment simulates payment verification with 3-second delay
func (s *OrderService) ProcessPayment(orderID string) error {
	// Acquire semaphore (blocks if at capacity)
	s.paymentSemaphore <- struct{}{}
	defer func() { <-s.paymentSemaphore }()
	
	log.Printf("Processing payment for order %s (3 second delay)...", orderID)
	
	// Simulate payment processing time
	time.Sleep(3 * time.Second)
	
	// Simulate 1% payment failures
	if time.Now().UnixNano()%100 == 0 {
		return fmt.Errorf("payment declined for order %s", orderID)
	}
	
	log.Printf("Payment processed successfully for order %s", orderID)
	return nil
}

// HandleSyncOrder processes orders synchronously (blocking)
func (s *OrderService) HandleSyncOrder(w http.ResponseWriter, r *http.Request) {
	atomic.AddInt64(&s.syncOrders, 1)
	
	// Parse order from request
	var order Order
	if err := json.NewDecoder(r.Body).Decode(&order); err != nil {
		http.Error(w, "Invalid order data", http.StatusBadRequest)
		return
	}
	
	// Generate order ID
	order.OrderID = uuid.New().String()
	order.Status = "processing"
	order.CreatedAt = time.Now()
	
	// Store order
	s.orders.Store(order.OrderID, &order)
	
	// Process payment synchronously (blocks for 3 seconds)
	startTime := time.Now()
	err := s.ProcessPayment(order.OrderID)
	processingTime := time.Since(startTime)
	
	if err != nil {
		order.Status = "failed"
		atomic.AddInt64(&s.failedOrders, 1)
		log.Printf("Sync order %s failed after %v: %v", order.OrderID, processingTime, err)
		http.Error(w, "Payment processing failed", http.StatusPaymentRequired)
		return
	}
	
	// Update order status
	now := time.Now()
	order.Status = "completed"
	order.ProcessedAt = &now
	atomic.AddInt64(&s.processedOrders, 1)
	
	// Return response
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	response := map[string]interface{}{
		"order_id": order.OrderID,
		"status": order.Status,
		"processing_time": processingTime.Seconds(),
		"message": "Order processed successfully",
	}
	json.NewEncoder(w).Encode(response)
	
	log.Printf("Sync order %s completed in %v", order.OrderID, processingTime)
}

// HandleAsyncOrder accepts orders and queues them for async processing
func (s *OrderService) HandleAsyncOrder(w http.ResponseWriter, r *http.Request) {
	atomic.AddInt64(&s.asyncOrders, 1)
	
	// Parse order from request
	var order Order
	if err := json.NewDecoder(r.Body).Decode(&order); err != nil {
		http.Error(w, "Invalid order data", http.StatusBadRequest)
		return
	}
	
	// Generate order ID
	order.OrderID = uuid.New().String()
	order.Status = "pending"
	order.CreatedAt = time.Now()
	
	// Store order
	s.orders.Store(order.OrderID, &order)
	
	// Publish to SNS for async processing
	if s.snsClient != nil && s.snsTopicArn != "" {
		orderJSON, _ := json.Marshal(order)
		_, err := s.snsClient.Publish(context.TODO(), &sns.PublishInput{
			TopicArn: aws.String(s.snsTopicArn),
			Message:  aws.String(string(orderJSON)),
		})
		
		if err != nil {
			log.Printf("Failed to publish order %s to SNS: %v", order.OrderID, err)
			http.Error(w, "Failed to queue order", http.StatusInternalServerError)
			return
		}
		
		log.Printf("Async order %s published to SNS", order.OrderID)
	} else {
		log.Printf("Async order %s accepted (SNS not configured)", order.OrderID)
	}
	
	// Return immediate response (202 Accepted)
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusAccepted)
	response := map[string]interface{}{
		"order_id": order.OrderID,
		"status": "accepted",
		"message": "Order accepted for processing",
	}
	json.NewEncoder(w).Encode(response)
}

// HandleHealth returns service health status
func (s *OrderService) HandleHealth(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	health := map[string]interface{}{
		"status": "healthy",
		"timestamp": time.Now().Unix(),
		"metrics": map[string]int64{
			"sync_orders": atomic.LoadInt64(&s.syncOrders),
			"async_orders": atomic.LoadInt64(&s.asyncOrders),
			"processed_orders": atomic.LoadInt64(&s.processedOrders),
			"failed_orders": atomic.LoadInt64(&s.failedOrders),
		},
	}
	json.NewEncoder(w).Encode(health)
}

// HandleMetrics returns detailed metrics
func (s *OrderService) HandleMetrics(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	
	// Count orders by status
	statusCounts := map[string]int{
		"pending": 0,
		"processing": 0,
		"completed": 0,
		"failed": 0,
	}
	
	s.orders.Range(func(key, value interface{}) bool {
		order := value.(*Order)
		statusCounts[order.Status]++
		return true
	})
	
	metrics := map[string]interface{}{
		"timestamp": time.Now().Unix(),
		"totals": map[string]int64{
			"sync_requests": atomic.LoadInt64(&s.syncOrders),
			"async_requests": atomic.LoadInt64(&s.asyncOrders),
			"processed": atomic.LoadInt64(&s.processedOrders),
			"failed": atomic.LoadInt64(&s.failedOrders),
		},
		"order_status": statusCounts,
		"payment_processor": map[string]interface{}{
			"max_concurrent": 1,
			"bottleneck": "3 seconds per payment",
		},
	}
	
	json.NewEncoder(w).Encode(metrics)
}

// HandleGetOrder retrieves order details
func (s *OrderService) HandleGetOrder(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	orderID := vars["orderId"]
	
	value, exists := s.orders.Load(orderID)
	if !exists {
		http.Error(w, "Order not found", http.StatusNotFound)
		return
	}
	
	order := value.(*Order)
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(order)
}

func main() {
	// Create service
	service, err := NewOrderService()
	if err != nil {
		log.Printf("Warning: Service created with limited functionality: %v", err)
	}
	
	// Setup routes
	router := mux.NewRouter()
	
	// Order endpoints
	router.HandleFunc("/orders/sync", service.HandleSyncOrder).Methods("POST")
	router.HandleFunc("/orders/async", service.HandleAsyncOrder).Methods("POST")
	router.HandleFunc("/orders/{orderId}", service.HandleGetOrder).Methods("GET")
	
	// Monitoring endpoints
	router.HandleFunc("/health", service.HandleHealth).Methods("GET")
	router.HandleFunc("/metrics", service.HandleMetrics).Methods("GET")
	
	// Start server
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	
	log.Printf("Starting Order Service on port %s", port)
	log.Printf("Endpoints:")
	log.Printf("  POST /orders/sync  - Synchronous processing (3s delay)")
	log.Printf("  POST /orders/async - Asynchronous processing (immediate response)")
	log.Printf("  GET  /orders/{id}  - Get order status")
	log.Printf("  GET  /health       - Health check")
	log.Printf("  GET  /metrics      - Service metrics")
	
	if err := http.ListenAndServe(":"+port, router); err != nil {
		log.Fatalf("Server failed: %v", err)
	}
}