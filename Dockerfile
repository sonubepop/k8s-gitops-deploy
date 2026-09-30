# syntax=docker/dockerfile:1
FROM python:3.12-slim AS deps
WORKDIR /build
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

FROM python:3.12-slim
ARG APP_VERSION=dev
ARG GIT_COMMIT=unknown
LABEL org.opencontainers.image.source="https://github.com/sonubepop/k8s-gitops-deploy" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${GIT_COMMIT}" \
      org.opencontainers.image.licenses="MIT"
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    APP_VERSION=${APP_VERSION} \
    GIT_COMMIT=${GIT_COMMIT}
RUN useradd --create-home --uid 10001 app
COPY --from=deps /install /usr/local
WORKDIR /srv
COPY app ./app
USER 10001
EXPOSE 8080
# --worker-tmp-dir on /dev/shm keeps the root filesystem read-only in Kubernetes
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "--worker-tmp-dir", "/dev/shm", "--access-logfile", "-", "app.main:app"]
