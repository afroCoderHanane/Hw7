package main

import (
	"encoding/json"
	"fmt"
	"log"
	"math/rand"
	"net/http"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/gorilla/mux"
)

// Order represents an e-commerce order
type Order struct {
	OrderID    string    `json:"order_id"`
	CustomerID int       `json:"customer_id"`
	Status     string    `json:"status"` // pending, processing, completed
	Items      []Item    `json:"items"`
	CreatedAt  time.Time `json:"created_at"`
}

// Item represents a product in an order
type Item struct {
	ProductID string  `json:"product_id"`
	Quantity  int     `json:"quantity"`
	Price     float64 `json:"price"`
}

// PaymentProcessor simulates payment verification with actual thread blocking
type PaymentProcessor struct {
	// Buffered channel with capacity of 1 creates actual bottleneck
	// Only 1 payment can be processed at a time
	processingSlot chan struct{}
	mu             sync.Mutex
	processedCount int
	failedCount    int
}

// NewPaymentProcessor creates a processor with limited throughput
func NewPaymentProcessor() *PaymentProcessor {
	return &PaymentProcessor{
		processingSlot: make(chan struct{}, 1), // Only 1 concurrent payment!
	}
}

// VerifyPayment simulates 3-second payment verification with actual blocking
func (pp *PaymentProcessor) VerifyPayment(orderID string) error {
	// Block until we can acquire the processing slot
	pp.processingSlot <- struct{}{}
	defer func() { <-pp.processingSlot }()

	// Simulate actual payment processing time
	time.Sleep(3 * time.Second)

	// 5% chance of payment failure (simulate real-world conditions)
	if rand.Float64() < 0.05 {
		pp.mu.Lock()
		pp.failedCount++
		pp.mu.Unlock()
		return fmt.Errorf("payment declined for order %s", orderID)
	}

	pp.mu.Lock()
	pp.processedCount++
	pp.mu.Unlock()

	return nil
}

// GetStats returns processing statistics
func (pp *PaymentProcessor) GetStats() (processed, failed int) {
	pp.mu.Lock()
	defer pp.mu.Unlock()
	return pp.processedCount, pp.failedCount
}

// OrderService handles order operations
type OrderService struct {
	processor *PaymentProcessor
	mu        sync.RWMutex
	orders    map[string]*Order
}

// NewOrderService creates a new order service
func NewOrderService() *OrderService {
	return &OrderService{
		processor: NewPaymentProcessor(),
		orders:    make(map[string]*Order),
	}
}

// CreateOrderSync processes order synchronously (blocks until payment verified)
func (os *OrderService) CreateOrderSync(w http.ResponseWriter, r *http.Request) {
	start := time.Now()

	var order Order
	if err := json.NewDecoder(r.Body).Decode(&order); err != nil {
		http.Error(w, "Invalid request body", http.StatusBadRequest)
		return
	}

	// Generate order ID if not provided
	if order.OrderID == "" {
		order.OrderID = uuid.New().String()
	}
	order.Status = "pending"
	order.CreatedAt = time.Now()

	// Store order
	os.mu.Lock()
	os.orders[order.OrderID] = &order
	os.mu.Unlock()

	log.Printf("[SYNC] Order %s received, starting payment verification...", order.OrderID)

	// THIS IS THE BOTTLENECK: Synchronous payment verification
	order.Status = "processing"
	if err := os.processor.VerifyPayment(order.OrderID); err != nil {
		order.Status = "failed"
		os.mu.Lock()
		os.orders[order.OrderID] = &order
		os.mu.Unlock()

		duration := time.Since(start)
		log.Printf("[SYNC] Order %s FAILED after %.2fs: %v", order.OrderID, duration.Seconds(), err)

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusPaymentRequired)
		json.NewEncoder(w).Encode(map[string]interface{}{
			"order_id": order.OrderID,
			"status":   "failed",
			"error":    err.Error(),
			"duration": duration.Seconds(),
		})
		return
	}

	// Payment succeeded
	order.Status = "completed"
	os.mu.Lock()
	os.orders[order.OrderID] = &order
	os.mu.Unlock()

	duration := time.Since(start)
	log.Printf("[SYNC] Order %s COMPLETED in %.2fs", order.OrderID, duration.Seconds())

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(map[string]interface{}{
		"order_id": order.OrderID,
		"status":   "completed",
		"duration": duration.Seconds(),
		"message":  "Order processed successfully",
	})
}

// GetOrder retrieves order status
func (os *OrderService) GetOrder(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	orderID := vars["id"]

	os.mu.RLock()
	order, exists := os.orders[orderID]
	os.mu.RUnlock()

	if !exists {
		http.Error(w, "Order not found", http.StatusNotFound)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(order)
}

// GetStats returns system statistics
func (os *OrderService) GetStats(w http.ResponseWriter, r *http.Request) {
	processed, failed := os.processor.GetStats()
	
	os.mu.RLock()
	totalOrders := len(os.orders)
	
	statusCounts := map[string]int{
		"pending":    0,
		"processing": 0,
		"completed":  0,
		"failed":     0,
	}
	
	for _, order := range os.orders {
		statusCounts[order.Status]++
	}
	os.mu.RUnlock()

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"total_orders":      totalOrders,
		"payments_processed": processed,
		"payments_failed":    failed,
		"status_breakdown":   statusCounts,
		"throughput_limit":   "~20 orders/minute (3s per payment)",
	})
}

// HealthCheck endpoint for ALB
func (os *OrderService) HealthCheck(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(map[string]string{
		"status": "healthy",
		"mode":   "synchronous",
	})
}

func main() {
	rand.Seed(time.Now().UnixNano())
	
	service := NewOrderService()
	router := mux.NewRouter()

	// Endpoints
	router.HandleFunc("/health", service.HealthCheck).Methods("GET")
	router.HandleFunc("/orders/sync", service.CreateOrderSync).Methods("POST")
	router.HandleFunc("/orders/{id}", service.GetOrder).Methods("GET")
	router.HandleFunc("/stats", service.GetStats).Methods("GET")

	port := ":8080"
	log.Printf("🚀 Synchronous Order Service starting on port %s", port)
	log.Printf("⚠️  Payment bottleneck: 3 seconds per order (max ~20 orders/minute)")
	log.Printf("📊 Test endpoints:")
	log.Printf("   POST /orders/sync - Create order (blocks until payment verified)")
	log.Printf("   GET  /orders/{id} - Check order status")
	log.Printf("   GET  /stats       - View system statistics")
	log.Printf("   GET  /health      - Health check")

	if err := http.ListenAndServe(port, router); err != nil {
		log.Fatal(err)
	}
}