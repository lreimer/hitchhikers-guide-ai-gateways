FROM golang:1.27.3 AS build

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download

COPY cmd ./cmd
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" \
  -o /out/byo-spike ./cmd/byo-spike

FROM gcr.io/distroless/static-debian12

COPY --from=build /out/byo-spike /usr/local/bin/byo-spike

EXPOSE 80 8081
ENTRYPOINT ["/usr/local/bin/byo-spike"]
