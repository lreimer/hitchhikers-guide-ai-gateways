FROM golang:1.27.3 AS build

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" \
  -o /out/kagent-byo ./cmd/kagent-byo

FROM gcr.io/distroless/static-debian12

COPY --from=build /out/kagent-byo /usr/local/bin/kagent-byo

EXPOSE 80 8081
ENTRYPOINT ["/usr/local/bin/kagent-byo"]
