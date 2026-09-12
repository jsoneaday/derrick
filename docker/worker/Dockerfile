# Unified Go worker image: web crawl, file extract (plugin guest binaries are copied per invoke).
# Build: docker build -f docker/worker/Dockerfile -t derrick-worker:go-v1 .
FROM golang:1.27.1 AS build

WORKDIR /src
COPY workers/go/go.mod workers/go/go.sum ./
RUN go mod download
COPY workers/go ./

RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/derrick-web-crawler ./cmd/derrick-crawler
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/derrick-file-extractor ./cmd/derrick-file-extractor

FROM debian:bookworm-slim

LABEL derrick.worker.binaries="crawler,extractor"

RUN apt-get update \
    && apt-get install -y --no-install-recommends poppler-utils ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 10001 worker

COPY --from=build /usr/local/go /usr/local/go
COPY --from=build /out/derrick-web-crawler /usr/local/bin/derrick-web-crawler
COPY --from=build /out/derrick-file-extractor /usr/local/bin/derrick-file-extractor
RUN mkdir -p /data/in /data/out && chown -R worker:worker /data

ENV PATH=/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ENV GOROOT=/usr/local/go
ENV GOTOOLCHAIN=local
ENV CGO_ENABLED=0

USER worker
WORKDIR /home/worker
