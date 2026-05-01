import os, time, uuid, logging, random
from datetime import datetime
from flask import Flask, request, jsonify
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST

logging.basicConfig(
    format='{"time": "%(asctime)s", "level": "%(levelname)s", "service": "payment-processor", "message": "%(message)s"}',
    level=logging.INFO
)
logger = logging.getLogger(__name__)
app = Flask(__name__)

REQUEST_COUNT = Counter("payment_processor_requests_total", "Total requests", ["method", "endpoint", "status"])
REQUEST_LATENCY = Histogram("payment_processor_request_duration_seconds", "Latency", ["endpoint"])
PAYMENT_PROCESSED = Counter("payment_processor_payments_processed_total", "Payments processed", ["status"])
START_TIME = time.time()

@app.route("/healthz")
def healthz():
    return jsonify({"status": "ok", "service": "payment-processor", "uptime_seconds": round(time.time() - START_TIME, 2)}), 200

@app.route("/metrics")
def metrics():
    return generate_latest(), 200, {"Content-Type": CONTENT_TYPE_LATEST}

@app.route("/process", methods=["POST"])
def process_payment():
    start = time.time()
    request_id = request.headers.get("X-Request-ID", str(uuid.uuid4()))
    try:
        data = request.get_json(force=True)
        if not data:
            REQUEST_COUNT.labels(method="POST", endpoint="/process", status="400").inc()
            return jsonify({"error": "Invalid JSON", "request_id": request_id}), 400

        required = ["amount", "currency", "payer_id", "payee_id"]
        missing = [f for f in required if f not in data]
        if missing:
            REQUEST_COUNT.labels(method="POST", endpoint="/process", status="422").inc()
            return jsonify({"error": f"Missing fields: {missing}", "request_id": request_id}), 422

        time.sleep(random.uniform(0.05, 0.2))

        if random.random() < 0.05:
            PAYMENT_PROCESSED.labels(status="failed").inc()
            REQUEST_COUNT.labels(method="POST", endpoint="/process", status="500").inc()
            return jsonify({"status": "failed", "request_id": request_id}), 500

        txn_id = str(uuid.uuid4())
        PAYMENT_PROCESSED.labels(status="success").inc()
        REQUEST_COUNT.labels(method="POST", endpoint="/process", status="200").inc()
        logger.info(f"request_id={request_id} transaction_id={txn_id}")
        return jsonify({"status": "success", "transaction_id": txn_id, "request_id": request_id,
                        "amount": data["amount"], "currency": data["currency"],
                        "processed_at": datetime.utcnow().isoformat() + "Z"}), 200
    except Exception as e:
        logger.exception(str(e))
        REQUEST_COUNT.labels(method="POST", endpoint="/process", status="500").inc()
        return jsonify({"error": "Internal server error", "request_id": request_id}), 500
    finally:
        REQUEST_LATENCY.labels(endpoint="/process").observe(time.time() - start)

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.getenv("PORT", 8080)))
