# API Key Rate Limiting Implementation Plan

**Goal:** Implement robust rate limiting on all public FastAPI endpoints, ensuring fair usage and protecting the service from abuse based on individual API keys.

**Architecture:** We will integrate a middleware layer into the FastAPI application to intercept incoming requests. This middleware will utilize an API key extracted from the request headers (e.g., `X-API-Key`), check its current count against Redis, increment the counter, and reject the request with a 429 status code if the limit is exceeded for the defined time window.

**Tech Stack:** FastAPI, Python, Redis, python-jose

### Task 1: Initialize Redis Client Utility

**Files:**
- Create: `app/redis_client.py`
- Modify: `tests/conftest.py` (To handle shared resources for testing)

**Step 1: Write the failing test** — We need a utility function to connect and interact with Redis, which we will mock/test later. Let's write a basic connectivity check in the test suite setup.
```python
# tests/conftest.py
import pytest
import redis

@pytest.fixture(scope="session")
def redis_client():
    """Yield copiable Redis client connection."""
    # Assuming Redis is running on localhost:6379 for testing purposes
    r = redis.Redis(decode_responses=True)
    try:
        r.ping()
        yield r
    except redis.exceptions.ConnectionError as e:
        pytest.skip(f"Could not connect to Redis: {e}")
```

**Step 2: Run it to verify it fails** — Since this is setup, we assume the environment (Redis) must be available, but for TDD purposes, we ensure the basic structure exists. We run a placeholder test that depends on the fixture.
```bash
pytest tests/conftest.py
# Expected FAIL: Fixture definition only; no explicit failure expected here, just ensuring dependency setup is sound. (If running without Redis, it should skip gracefully due to the try/except block).
```

**Step 3: Write the minimal implementation** — Create `app/redis_client.py` to export a reusable connection object.
```python
# app/redis_client.py
import redis

def get_redis_connection():
    """Returns a Redis client instance."""
    # Using default host/port for simplicity, should ideally use environment variables
    return redis.Redis(decode_responses=True)
```

**Step 4: Run the test to verify it passes** — Verify that the fixture correctly initializes and yields the connection object when Redis is available. (Assuming a basic placeholder test uses this fixture). We'll just confirm the module structure works.
```bash
pytest tests/conftest.py
# Expected PASS: Tests run successfully, indicating redis_client fixture initialized correctly.
```

**Step 5: Commit**
```bash
git add app/redis_client.py tests/conftest.py
git commit Initialized Redis client utility and test fixture setup
```

### Task 2: Implement Rate Limiting Logic Dependency

**Files:**
- Create: `app/dependencies.py`
- Modify: `tests/test_rate_limiting.py` (New file)

**Step 1: Write the failing test** — We need a function that checks if a key has exceeded its allowed count within a time window, using Redis transactions (INCR/EXPIRE). This test assumes we have access to the `redis_client` fixture.
```python
# tests/test_rate_limiting.py
import pytest
from app.redis_client import get_redis_connection

@pytest.fixture
def redis_conn():
    """Provides a fresh Redis connection for testing."""
    return get_redis_connection()

def test_rate_limit_exceeded(redis_conn: redis.Redis):
    key = "test:api:key"
    limit = 3
    ttl = 10 # seconds

    # Manually set the key to ensure clean state before test
    redis_conn.delete(key)

    # Simulate reaching the limit (N times)
    for i in range(limit):
        # The current implementation must fail when attempting N+1 increment
        redis_conn.incr(key)
        redis_conn.expire(key, ttl) # Keep TTL active

    # Attempt to exceed the limit
    result = redis_conn.incr(key)
    
    # Assert that the counter is now 4 (if using simple INCR) or that a specific check fails.
    # Since we are implementing the logic, we expect the rate limiter dependency to handle this check and fail gracefully.
    # For testing the raw mechanism: The count should be limit + 1.
    assert result == limit + 1

    # Clean up
    redis_conn.delete(key)
```

**Step 2: Run it to verify it fails** — Currently, `app/dependencies.py` does not exist, and the logic is missing. We expect a `NameError` or `ImportError`.
```bash
pytest tests/test_rate_limiting.py
# Expected FAIL (Example): NameError: name 'get_redis_connection' is not defined (or similar import error)
```

**Step 3: Write the minimal implementation** — Create `app/dependencies.py` containing a dependency function that handles Redis interaction, checking limits, and returning True if allowed, or raising an exception otherwise.
```python
# app/dependencies.py
from fastapi import HTTPException
from redis_client import get_redis_connection

REDIS_KEY_PREFIX = "rate:limit:"
DEFAULT_LIMIT = 5
DEFAULT_TTL = 60 # seconds

async def rate_limit(api_key: str):
    """
    Dependency function to enforce rate limiting based on API key.
    Raises HTTPException if the limit is exceeded.
    """
    redis_client = get_redis_connection()
    key = f"{REDIS_KEY_PREFIX}{api_key}"

    # Use Redis pipeline/multi for atomic operations (INCR and EXPIRE)
    pipe = redis_client.pipeline()
    pipe.incr(key)
    pipe.expire(key, DEFAULT_TTL) # Ensure TTL is set even if key existed previously
    
    try:
        # Execute the increment operation
        current_count = pipe.execute()[0] 

        if current_count > DEFAULT_LIMIT:
            raise HTTPException(status_code=429, detail="Rate limit exceeded for this API Key.")
    except Exception as e:
        # Handle Redis connection failure gracefully
        print(f"Redis error during rate limiting check: {e}")
        # Depending on requirements, we might fail open or fail closed. Failing closed (raising) is safer.
        raise HTTPException(status_code=503, detail="Service Unavailable due to Rate Limiting Backend Error.")

    return True # Request allowed
```

**Step 4: Run the test to verify it passes** — Now that the logic exists, we modify the test setup slightly (or assume a simple structure) to validate the core functionality. We must adjust `test_rate_limiting.py` to use the dependency function correctly. *Self-Correction: I need to ensure the test file reflects how the dependency is used.*

Let's update the test logic in `tests/test_rate_limiting.py` to simulate the flow using a mock key, ensuring it hits 429 after 5 successful calls. (Since we are testing the mechanism, we must check for the specific HTTP exception).

*Modification to tests/test_rate_limiting.py:*
```python
# ... imports ...
from fastapi import HTTPException # Must be available in test scope

@pytest.fixture
def redis_conn():
    return get_redis_connection()

async def test_rate_limit_successful(redis_conn: redis.Redis):
    key = "test:api:success"
    redis_conn.delete(key)
    
    # Test 1 call (should pass)
    try:
        await rate_limit("success")
    except HTTPException as e:
        pytest.fail(f"Expected success but got exception: {e}")

    # Clean up
    redis_conn.delete(key)

async def test_rate_limit_exceeded(redis_conn: redis.Redis):
    key = "test:api:fail"
    redis_conn.delete(key)
    
    # Simulate 5 successful calls (should pass, count reaches 5)
    for _ in range(5):
        try:
            await rate_limit("fail")
        except HTTPException as e:
            pytest.fail(f"Expected success but got exception on iteration {_}: {e}")

    # The 6th call must fail (count reaches 6)
    with pytest.raises(HTTPException, match="Rate limit exceeded"):
        await rate_limit("fail")

    # Clean up (We cannot delete the key easily here as the test relies on it being present/modified)
```
*(Note: Assuming FastAPI dependencies are `async`, requiring async tests.)*

```bash
pytest -v tests/test_rate_limiting.py
# Expected PASS: All rate limiting scenarios pass, confirming limit enforcement and exception raising.
```

**Step 5: Commit**
```bash
git add app/dependencies.py tests/test_rate_limiting.py
git commit Implemented async rate limiting dependency using Redis for API keys
```

### Task 3: Integrate Rate Limiting Middleware into FastAPI App

**Files:**
- Modify: `app/main.py` (Assuming this file exists and initializes the app)
- Test: No new test required, modification to existing application testing approach is sufficient if we assume endpoint tests exist.

*Assumption:* We need a basic `app/main.py` setup for FastAPI that handles endpoints.

**Step 1: Write the failing test** — We will write a conceptual test demonstrating that without rate limiting, an endpoint can be called excessively, and thus needs middleware protection. Since we cannot modify existing application tests easily, we assume we need to ensure the dependency is used globally or per-router.

Let's assume `app/main.py` has a simple `/data` endpoint:
```python
# app/main.py (Assumed initial state)
from fastapi import FastAPI
app = FastAPI()

@app.get("/data")
def read_data():
    return {"message": "Data accessed successfully"}
```
We need to modify this file using the dependency from `app/dependencies.py`. We will test by running a simulated request that should fail with 429 if rate limiting is correctly applied via middleware/dependency injection path.

*Self-Correction:* FastAPI dependencies are usually injected at the route level (`@app.get("/data", dependencies=[rate_limit("key")])`). Implementing it as a global dependency or middleware requires careful handling of API keys. Since the key comes from headers, applying it directly to the endpoint is cleanest for testing specific keys.

**Step 2: Run it to verify it fails** — If we fail to inject the rate limit dependency into `/data`, the test will pass trivially (always succeeding) even if abuse occurs. We simulate running an endpoint call that should fail but currently succeeds.
```bash
# Placeholder command simulating a successful request regardless of key usage/limit
curl -X GET "http://localhost:8000/data" -H "X-API-Key: test_key" 
# Expected FAIL (Conceptual): If rate limiting fails, the system should eventually return HTTP 429. Currently, it will always return 200 OK.
```

**Step 3: Write the minimal implementation** — Modify `app/main.py` to use FastAPI's dependency injection system and apply `rate_limit`. We must also ensure we extract the API key from headers correctly.

```python
# app/main.py (Modified)
from fastapi import FastAPI, Depends, Header
from app.dependencies import rate_limit # Import our new dependency

app = FastAPI()

@app.get("/data")
async def read_data(x_api_key: str = Header(...)): 
    # The FastAPI header injection handles key extraction and passes it to the dependency chain first.
    await rate_limit(api_key=x_api_key) # Apply rate limiting check
    return {"message": f"Data accessed successfully for key {x_api_key}"}

```

**Step 4: Run the test to verify it passes** — We confirm that calling the endpoint multiple times with the same key eventually triggers a 429 error, proving middleware integration. (This requires running FastAPI in development mode and making sequential requests).
```bash
# First request (Success)
curl -X GET "http://localhost:8000/data" -H "X-API-Key: test_key"

# Second through 5th request (Success, if limit is 5)
for i in {2..5}; do curl -s -o /dev/null -w "%{http.status}" -X GET "http://localhost:8000/data" -H "X-API-Key: test_key"; done

# Sixth request (Failure, expecting 429)
curl -X GET "http://localhost:8000/data" -H "X-API-Key: test_key"
# Expected PASS: The first five calls return HTTP 200. The sixth call returns HTTP 429.
```

**Step 5: Commit**
```bash
git add app/main.py
git commit Integrated rate limiting dependency into main FastAPI endpoint using header injection
```
