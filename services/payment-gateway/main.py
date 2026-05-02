import os, time, uuid, logging
from datetime import datetime
import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry
from flask import Flask, request, jsonify
from flask_cors import CORS
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST

logging.basicConfig(
    format='{"time": "%(asctime)s", "level": "%(levelname)s", "service": "payment-gateway", "message": "%(message)s"}',
    level=logging.INFO
)
logger = logging.getLogger(__name__)
app = Flask(__name__)
CORS(app)

PROCESSOR_URL = os.getenv("PROCESSOR_URL", "http://payment-processor:8080")
REQUEST_TIMEOUT = int(os.getenv("REQUEST_TIMEOUT_SECONDS", 10))

REQUEST_COUNT = Counter("payment_gateway_requests_total", "Total requests", ["method", "endpoint", "status"])
REQUEST_LATENCY = Histogram("payment_gateway_request_duration_seconds", "Latency", ["endpoint"])
UPSTREAM_ERRORS = Counter("payment_gateway_upstream_errors_total", "Upstream errors", ["error_type"])
START_TIME = time.time()

session = requests.Session()
retry = Retry(total=3, backoff_factor=0.5, status_forcelist=[502, 503, 504], allowed_methods=["POST"])
session.mount("http://", HTTPAdapter(max_retries=retry))

@app.route("/healthz")
def healthz():
    try:
        r = session.get(f"{PROCESSOR_URL}/healthz", timeout=3)
        proc_status = "ok" if r.status_code == 200 else "degraded"
    except Exception:
        proc_status = "unreachable"
    status = "ok" if proc_status == "ok" else "degraded"
    return jsonify({"status": status, "service": "payment-gateway",
                    "uptime_seconds": round(time.time() - START_TIME, 2),
                    "dependencies": {"payment-processor": proc_status}}), 200 if status == "ok" else 503

@app.route("/metrics")
def metrics():
    return generate_latest(), 200, {"Content-Type": CONTENT_TYPE_LATEST}

@app.route("/pay", methods=["POST"])
def pay():
    start = time.time()
    request_id = request.headers.get("X-Request-ID", str(uuid.uuid4()))
    try:
        data = request.get_json(force=True)
        if not data:
            REQUEST_COUNT.labels(method="POST", endpoint="/pay", status="400").inc()
            return jsonify({"error": "Invalid JSON", "request_id": request_id}), 400

        required = ["amount", "currency", "payer_id", "payee_id"]
        missing = [f for f in required if f not in data]
        if missing:
            REQUEST_COUNT.labels(method="POST", endpoint="/pay", status="422").inc()
            return jsonify({"error": f"Missing fields: {missing}", "request_id": request_id}), 422

        logger.info(f"request_id={request_id} Forwarding payment amount={data.get('amount')}")
        resp = session.post(f"{PROCESSOR_URL}/process", json=data,
                            headers={"X-Request-ID": request_id}, timeout=REQUEST_TIMEOUT)
        body = resp.json()
        REQUEST_COUNT.labels(method="POST", endpoint="/pay", status=str(resp.status_code)).inc()
        return jsonify(body), resp.status_code

    except requests.exceptions.Timeout:
        UPSTREAM_ERRORS.labels(error_type="timeout").inc()
        REQUEST_COUNT.labels(method="POST", endpoint="/pay", status="504").inc()
        return jsonify({"error": "Processor timed out", "request_id": request_id}), 504
    except requests.exceptions.ConnectionError:
        UPSTREAM_ERRORS.labels(error_type="connection_error").inc()
        REQUEST_COUNT.labels(method="POST", endpoint="/pay", status="503").inc()
        return jsonify({"error": "Processor unavailable", "request_id": request_id}), 503
    except Exception as e:
        logger.exception(str(e))
        REQUEST_COUNT.labels(method="POST", endpoint="/pay", status="500").inc()
        return jsonify({"error": "Internal server error", "request_id": request_id}), 500
    finally:
        REQUEST_LATENCY.labels(endpoint="/pay").observe(time.time() - start)

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.getenv("PORT", 8080)))
