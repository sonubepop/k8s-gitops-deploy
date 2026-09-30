"""release-info: a small HTTP service used to demonstrate a Kubernetes GitOps delivery pipeline.

Endpoints
  GET /          -> service, version, commit, environment and pod name (shows which release is live)
  GET /healthz   -> liveness probe
  GET /readyz    -> readiness probe (503 while draining / not ready)
  GET /metrics   -> Prometheus metrics
"""

from __future__ import annotations

import os
import socket
import time

from flask import Flask, Response, g, jsonify, request
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Gauge, Histogram, generate_latest

REQUESTS = Counter("http_requests_total", "HTTP requests", ["method", "endpoint", "status"])
LATENCY = Histogram("http_request_duration_seconds", "Request latency", ["endpoint"],
                    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5))
BUILD_INFO = Gauge("app_build_info", "Build information", ["version", "commit", "environment"])


def create_app() -> Flask:
    app = Flask(__name__)
    app.config.update(
        SERVICE_NAME=os.getenv("SERVICE_NAME", "release-info"),
        APP_VERSION=os.getenv("APP_VERSION", "dev"),
        GIT_COMMIT=os.getenv("GIT_COMMIT", "unknown"),
        ENVIRONMENT=os.getenv("ENVIRONMENT", "local"),
        READY=True,
    )
    BUILD_INFO.labels(app.config["APP_VERSION"], app.config["GIT_COMMIT"], app.config["ENVIRONMENT"]).set(1)

    @app.before_request
    def _start_timer() -> None:
        g.start = time.perf_counter()

    @app.after_request
    def _record(resp: Response) -> Response:
        endpoint = request.url_rule.rule if request.url_rule else "unmatched"
        if endpoint != "/metrics":
            LATENCY.labels(endpoint).observe(time.perf_counter() - g.start)
            REQUESTS.labels(request.method, endpoint, str(resp.status_code)).inc()
        return resp

    @app.get("/")
    def index():
        return jsonify(
            service=app.config["SERVICE_NAME"],
            version=app.config["APP_VERSION"],
            commit=app.config["GIT_COMMIT"],
            environment=app.config["ENVIRONMENT"],
            pod=socket.gethostname(),
        )

    @app.get("/healthz")
    def healthz():
        return jsonify(status="ok")

    @app.get("/readyz")
    def readyz():
        if not app.config["READY"]:
            return jsonify(status="not ready"), 503
        return jsonify(status="ready")

    @app.get("/metrics")
    def metrics():
        return Response(generate_latest(), mimetype=CONTENT_TYPE_LATEST)

    return app


app = create_app()
