from locust import HttpUser, task, between, events
import random
import json
import time

class OrderUser(HttpUser):
    """Simulates a customer placing orders"""
    
    # Wait time between requests (100-500ms as specified)
    wait_time = between(0.1, 0.5)
    
    def on_start(self):
        """Called when a simulated user starts"""
        self.customer_id = random.randint(1000, 9999)
        print(f"👤 Customer {self.customer_id} started shopping")
    
    @task
    def create_order_sync(self):
        """Place an order using synchronous endpoint"""
        
        # Generate random order
        order = {
            "customer_id": self.customer_id,
            "items": [
                {
                    "product_id": f"PROD-{random.randint(100, 999)}",
                    "quantity": random.randint(1, 5),
                    "price": round(random.uniform(10.0, 100.0), 2)
                }
                for _ in range(random.randint(1, 3))
            ]
        }
        
        start_time = time.time()
        
        # Make request with timeout to catch hung requests
        with self.client.post(
            "/orders/sync",
            json=order,
            catch_response=True,
            timeout=10  # 10 second timeout
        ) as response:
            
            duration = time.time() - start_time
            
            if response.status_code == 200:
                result = response.json()
                print(f"✅ Order {result.get('order_id', 'unknown')} completed in {duration:.2f}s")
                response.success()
            
            elif response.status_code == 402:  # Payment failed
                result = response.json()
                print(f"❌ Payment declined: {result.get('order_id', 'unknown')}")
                response.failure(f"Payment declined")
            
            elif response.status_code == 504 or duration > 9:  # Timeout
                print(f"⏱️  Request timeout after {duration:.2f}s - system overloaded!")
                response.failure("Request timeout - system overloaded")
            
            else:
                print(f"⚠️  Unexpected response: {response.status_code}")
                response.failure(f"Unexpected status: {response.status_code}")


# Custom event handlers for better reporting
@events.test_start.add_listener
def on_test_start(environment, **kwargs):
    print("\n" + "="*60)
    print("🚀 LOAD TEST STARTING")
    print("="*60)
    print(f"Target: {environment.host}")
    print(f"Users will spawn at configured rate")
    print("\n📋 What to watch for:")
    print("  - Response times (should be ~3s during normal load)")
    print("  - Timeout errors (system breaking under load)")
    print("  - Queue buildup (visible in /stats endpoint)")
    print("="*60 + "\n")


@events.test_stop.add_listener
def on_test_stop(environment, **kwargs):
    print("\n" + "="*60)
    print("🏁 LOAD TEST COMPLETE")
    print("="*60)
    
    stats = environment.stats.total
    print(f"\n📊 Summary:")
    print(f"  Total Requests:    {stats.num_requests}")
    print(f"  Failures:          {stats.num_failures} ({stats.fail_ratio*100:.1f}%)")
    print(f"  Average Response:  {stats.avg_response_time:.0f}ms")
    print(f"  Min Response:      {stats.min_response_time:.0f}ms")
    print(f"  Max Response:      {stats.max_response_time:.0f}ms")
    print(f"  RPS:               {stats.total_rps:.2f}")
    
    if stats.num_failures > 0:
        print(f"\n⚠️  {stats.num_failures} requests failed!")
        print("This is expected during flash sale simulation.")
        print("The synchronous system cannot handle 60 orders/second.")
    
    print("="*60 + "\n")


# Test scenario configurations
"""
TESTING SCENARIOS:

1. NORMAL OPERATIONS (Baseline):
   Command: locust -f locustfile.py --host=http://localhost:8080 --users=5 --spawn-rate=1 --run-time=30s --headless
   
   Expected Results:
   - All requests succeed
   - Response time: ~3 seconds per request
   - No timeouts
   - Throughput: ~5 orders/second
   - System processes: ~150 orders in 30 seconds

2. FLASH SALE (System Breaking Point):
   Command: locust -f locustfile.py --host=http://localhost:8080 --users=20 --spawn-rate=10 --run-time=60s --headless
   
   Expected Results:
   - HIGH failure rate (60-80%)
   - Many timeout errors
   - Response times spike to 10+ seconds
   - Target: 60 orders/second (1200 total)
   - Actual: ~20 orders/second (system bottleneck)
   - 💥 SYSTEM BREAKS: Cannot handle the load!

3. WEB UI MODE (Interactive):
   Command: locust -f locustfile.py --host=http://localhost:8080
   
   Then open: http://localhost:8089
   - Set users to 5 for normal, 20 for flash sale
   - Watch real-time charts
   - See the system collapse under load

WHAT BREAKS?
------------
During flash sale, you'll see:
1. Request queue builds up faster than processing
2. Timeouts increase exponentially
3. Customer experience degrades (10+ second waits)
4. Some requests never complete
5. System reputation damaged (customers leave bad reviews)

The bottleneck: Payment processor can only handle 1 payment at a time (3s each)
= Maximum throughput: 20 orders/minute regardless of incoming traffic

This is why we need async processing! 🎯
"""