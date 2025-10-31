"""
HW7 Load Testing - Flash Sale Simulation
Tests synchronous vs asynchronous order processing
"""

from locust import HttpUser, FastHttpUser, task, between, events
import random
import json
import time
from datetime import datetime

# Sample order data
CUSTOMER_IDS = list(range(1000, 2000))
PRODUCTS = [
    {"product_id": "FLASH-001", "quantity": 1, "price": 29.99},
    {"product_id": "FLASH-002", "quantity": 2, "price": 49.99},
    {"product_id": "FLASH-003", "quantity": 1, "price": 99.99},
]

class SyncOrderUser(HttpUser):
    """Normal operations with synchronous processing"""
    wait_time = between(0.1, 0.5)
    
    @task
    def place_sync_order(self):
        order = {
            "customer_id": random.choice(CUSTOMER_IDS),
            "items": random.sample(PRODUCTS, k=random.randint(1, 2))
        }
        
        with self.client.post(
            "/orders/sync",
            json=order,
            catch_response=True,
            timeout=10
        ) as response:
            if response.status_code == 200:
                response.success()
            else:
                response.failure(f"Status {response.status_code}")


class AsyncOrderUser(HttpUser):
    """Flash sale with asynchronous processing"""
    wait_time = between(0.1, 0.5)
    
    @task
    def place_async_order(self):
        order = {
            "customer_id": random.choice(CUSTOMER_IDS),
            "items": random.sample(PRODUCTS, k=random.randint(1, 2))
        }
        
        with self.client.post(
            "/orders/async",
            json=order,
            catch_response=True,
            timeout=2
        ) as response:
            if response.status_code == 202:
                response.success()
            else:
                response.failure(f"Status {response.status_code}")


class FlashSaleSync(FastHttpUser):
    """Phase 2: Flash sale with sync processing (will fail)"""
    wait_time = between(0.1, 0.3)
    
    @task
    def flash_order(self):
        order = {
            "customer_id": random.choice(CUSTOMER_IDS),
            "items": [random.choice(PRODUCTS)]
        }
        
        with self.client.post(
            "/orders/sync",
            json=order,
            catch_response=True,
            timeout=10
        ) as response:
            if response.status_code == 200:
                response.success()
            else:
                response.failure(f"Failed: {response.status_code}")


class FlashSaleAsync(FastHttpUser):
    """Phase 3: Flash sale with async processing (will succeed)"""
    wait_time = between(0.1, 0.3)
    
    @task
    def flash_order(self):
        order = {
            "customer_id": random.choice(CUSTOMER_IDS),
            "items": [random.choice(PRODUCTS)]
        }
        
        with self.client.post(
            "/orders/async",
            json=order,
            catch_response=True,
            timeout=2
        ) as response:
            if response.status_code == 202:
                response.success()
            else:
                response.failure(f"Failed: {response.status_code}")


@events.test_start.add_listener
def on_test_start(environment, **kwargs):
    print("=" * 60)
    print("FLASH SALE LOAD TEST STARTING")
    print(f"Host: {environment.host}")
    print("=" * 60)


@events.test_stop.add_listener
def on_test_stop(environment, **kwargs):
    print("=" * 60)
    print("TEST COMPLETED")
    stats = environment.stats
    
    if stats.total.num_requests > 0:
        print(f"Total Requests: {stats.total.num_requests}")
        print(f"Total Failures: {stats.total.num_failures}")
        print(f"Failure Rate: {(stats.total.num_failures/stats.total.num_requests)*100:.2f}%")
        print(f"Median Response: {stats.total.median_response_time}ms")
        print(f"95th Percentile: {stats.total.get_response_time_percentile(0.95)}ms")
    print("=" * 60)