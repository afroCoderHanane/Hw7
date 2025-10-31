package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/sqs"
	"github.com/aws/aws-sdk-go-v2/service/sqs/types"
	"github.com/gorilla/mux"
)

// Order represents an e-commerce order
type Order struct {
	OrderID     string    `json:"order_id"`
	CustomerID  int       `json:"customer_id"`
	Status      string    `json:"status"`
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

// SQSMessage represents the structure of SNS->SQS messages
type SQSMessage struct {
	Type      string `json:"Type"`
	MessageId string `json:"MessageId"`
	Message   string `json:"Message"`
	Timestamp string `json:"Timestamp"`
}

// OrderProcessor processes orders from SQS queue
type OrderProcessor struct {
	sqsClient   *sqs.Client
	queueURL    string
	workerCount int
	
	// Metrics
	messagesReceived int64
	ordersProcessed  int64
	ordersFailed     int64
	currentWorkers   int32
	startTime        time.Time
	
	// Control
	stopChan chan struct{}
	wg       sync.WaitGroup
	mu       sync.RWMutex
}

// NewOrderProcessor creates a new processor
func NewOrderProcessor(workerCount int) (*OrderProcessor, error) {
	cfg, err := config.LoadDefaultConfig(context.TODO(),
		config.WithRegion(os.Getenv("AWS_REGION")),
	)
	if err != nil {
		return nil, fmt.Errorf("failed to load AWS config: %w", err)
	}
	
	queueURL := os.Getenv("SQS_QUEUE_URL")
	if queueURL == "" {
		log.Println("Warning: SQS_QUEUE_URL not set, running in demo mode")
	}
	
	return &OrderProcessor{
		sqsClient:   sqs.NewFromConfig(cfg),
		queueURL:    queueURL,
		workerCount: workerCount,
		stopChan:    make(chan struct{}),
		startTime:   time.Now(),
	}, nil
}

// Start begins processing messages with specified number of workers
func (p *OrderProcessor) Start() {
	log.Printf("Starting order processor with %d workers", p.workerCount)
	
	// Start worker goroutines
	for i := 0; i < p.workerCount; i++ {
		p.wg.Add(1)
		go p.worker(i)
	}
	
	log.Printf("All %d workers started", p.workerCount)
}

// worker continuously polls SQS and processes messages
func (p *OrderProcessor) worker(id int) {
	defer p.wg.Done()
	atomic.AddInt32(&p.currentWorkers, 1)
	defer atomic.AddInt32(&p.currentWorkers, -1)
	
	log.Printf("Worker %d started", id)
	
	for {
		select {
		case <-p.stopChan:
			log.Printf("Worker %d stopping", id)
			return
		default:
			// Skip if no queue URL
			if p.queueURL == "" {
				time.Sleep(5 * time.Second)
				continue
			}
			
			// Poll SQS for messages
			messages, err := p.pollMessages()
			if err != nil {
				log.Printf("Worker %d: Error polling messages: %v", id, err)
				time.Sleep(5 * time.Second)
				continue
			}
			
			// Process each message
			for _, msg := range messages {
				atomic.AddInt64(&p.messagesReceived, 1)
				
				// Process the order
				if err := p.processMessage(msg); err != nil {
					log.Printf("Worker %d: Failed to process message: %v", id, err)
					atomic.AddInt64(&p.ordersFailed, 1)
					continue
				}
				
				// Delete message from queue after successful processing
				if err := p.deleteMessage(msg); err != nil {
					log.Printf("Worker %d: Failed to delete message: %v", id, err)
				}
				
				atomic.AddInt64(&p.ordersProcessed, 1)
			}
		}
	}
}

// pollMessages receives messages from SQS
func (p *OrderProcessor) pollMessages() ([]types.Message, error) {
	result, err := p.sqsClient.ReceiveMessage(context.TODO(), &sqs.ReceiveMessageInput{
		QueueUrl:            aws.String(p.queueURL),
		MaxNumberOfMessages: 10,
		WaitTimeSeconds:     20,
		VisibilityTimeout:   30,
	})
	
	if err != nil {
		return nil, fmt.Errorf("failed to receive messages: %w", err)
	}
	
	return result.Messages, nil
}

// processMessage processes a single order message
func (p *OrderProcessor) processMessage(msg types.Message) error {
	// Parse SNS message wrapper
	var snsMessage SQSMessage
	if err := json.Unmarshal([]byte(*msg.Body), &snsMessage); err != nil {
		return fmt.Errorf("failed to parse SNS message: %w", err)
	}
	
	// Parse the actual order
	var order Order
	if err := json.Unmarshal([]byte(snsMessage.Message), &order); err != nil {
		return fmt.Errorf("failed to parse order: %w", err)
	}
	
	log.Printf("Processing order %s for customer %d", order.OrderID, order.CustomerID)
	
	// Simulate payment processing (3 second delay)
	startTime := time.Now()
	time.Sleep(3 * time.Second)
	processingTime := time.Since(startTime)
	
	// Simulate 1% payment failures
	if time.Now().UnixNano()%100 == 0 {
		return fmt.Errorf("payment failed for order %s", order.OrderID)
	}
	
	log.Printf("Order %s processed successfully in %v", order.OrderID, processingTime)
	return nil
}

// deleteMessage removes a message from the queue
func (p *OrderProcessor) deleteMessage(msg types.Message) error {
	_, err := p.sqsClient.DeleteMessage(context.TODO(), &sqs.DeleteMessageInput{
		QueueUrl:      aws.String(p.queueURL),
		ReceiptHandle: msg.ReceiptHandle,
	})
	return err
}

// UpdateWorkerCount dynamically adjusts the number of workers
func (p *OrderProcessor) UpdateWorkerCount(newCount int) {
	p.mu.Lock()
	defer p.mu.Unlock()
	
	currentCount := int(atomic.LoadInt32(&p.currentWorkers))
	
	if newCount > currentCount {
		diff := newCount - currentCount
		log.Printf("Scaling up: adding %d workers", diff)
		for i := 0; i < diff; i++ {
			p.wg.Add(1)
			go p.worker(currentCount + i)
		}
		p.workerCount = newCount
	} else {
		log.Printf("Scaling down not implemented")
	}
}

// HandleHealth returns processor health
func (p *OrderProcessor) HandleHealth(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	health := map[string]interface{}{
		"status": "healthy",
		"timestamp": time.Now().Unix(),
		"workers": map[string]interface{}{
			"configured": p.workerCount,
			"active": atomic.LoadInt32(&p.currentWorkers),
		},
		"metrics": map[string]int64{
			"messages_received": atomic.LoadInt64(&p.messagesReceived),
			"orders_processed": atomic.LoadInt64(&p.ordersProcessed),
			"orders_failed": atomic.LoadInt64(&p.ordersFailed),
		},
	}
	json.NewEncoder(w).Encode(health)
}

// HandleMetrics returns detailed metrics
func (p *OrderProcessor) HandleMetrics(w http.ResponseWriter, r *http.Request) {
	// Get queue attributes if available
	queueMetrics := map[string]interface{}{}
	if p.queueURL != "" {
		queueAttrs, err := p.sqsClient.GetQueueAttributes(context.TODO(), &sqs.GetQueueAttributesInput{
			QueueUrl: aws.String(p.queueURL),
			AttributeNames: []types.QueueAttributeName{
				"ApproximateNumberOfMessages",
				"ApproximateNumberOfMessagesNotVisible",
			},
		})
		if err == nil {
			queueMetrics["queue_depth"] = queueAttrs.Attributes["ApproximateNumberOfMessages"]
			queueMetrics["in_flight"] = queueAttrs.Attributes["ApproximateNumberOfMessagesNotVisible"]
		}
	}
	
	uptime := time.Since(p.startTime).Seconds()
	processed := atomic.LoadInt64(&p.ordersProcessed)
	processingRate := float64(processed) / uptime
	
	w.Header().Set("Content-Type", "application/json")
	metrics := map[string]interface{}{
		"timestamp": time.Now().Unix(),
		"processor": map[string]interface{}{
			"messages_received": atomic.LoadInt64(&p.messagesReceived),
			"orders_processed": processed,
			"orders_failed": atomic.LoadInt64(&p.ordersFailed),
			"workers_active": atomic.LoadInt32(&p.currentWorkers),
			"processing_rate": processingRate,
			"uptime_seconds": uptime,
		},
		"queue": queueMetrics,
	}
	json.NewEncoder(w).Encode(metrics)
}

// HandleScaleWorkers allows dynamic scaling
func (p *OrderProcessor) HandleScaleWorkers(w http.ResponseWriter, r *http.Request) {
	var request struct {
		Workers int `json:"workers"`
	}
	
	if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
		http.Error(w, "Invalid request", http.StatusBadRequest)
		return
	}
	
	if request.Workers < 1 || request.Workers > 100 {
		http.Error(w, "Workers must be between 1 and 100", http.StatusBadRequest)
		return
	}
	
	p.UpdateWorkerCount(request.Workers)
	
	w.Header().Set("Content-Type", "application/json")
	response := map[string]interface{}{
		"message": "Worker count updated",
		"workers": request.Workers,
	}
	json.NewEncoder(w).Encode(response)
}

func main() {
	// Get worker count from environment
	workerCount := 1
	if count := os.Getenv("WORKER_COUNT"); count != "" {
		workerCount, _ = strconv.Atoi(count)
	}
	
	// Create processor
	processor, err := NewOrderProcessor(workerCount)
	if err != nil {
		log.Printf("Warning: Processor created with limited functionality: %v", err)
	}
	
	// Start processing
	processor.Start()
	
	// Setup HTTP server
	router := mux.NewRouter()
	router.HandleFunc("/health", processor.HandleHealth).Methods("GET")
	router.HandleFunc("/metrics", processor.HandleMetrics).Methods("GET")
	router.HandleFunc("/scale", processor.HandleScaleWorkers).Methods("POST")
	
	port := os.Getenv("PORT")
	if port == "" {
		port = "8081"
	}
	
	log.Printf("Order Processor started on port %s", port)
	log.Printf("Worker count: %d", workerCount)
	
	if err := http.ListenAndServe(":"+port, router); err != nil {
		log.Fatalf("Server failed: %v", err)
	}
}