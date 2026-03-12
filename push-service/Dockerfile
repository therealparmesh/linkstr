FROM golang:1.26 AS build

WORKDIR /src

COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o /out/push-service .

FROM debian:bookworm-slim

WORKDIR /app

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates \
  && rm -rf /var/lib/apt/lists/* \
  && adduser --disabled-password --gecos "" appuser

COPY --from=build /out/push-service /usr/local/bin/push-service

USER appuser

EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/push-service"]
