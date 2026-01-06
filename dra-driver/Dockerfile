# Build stage
FROM golang:1.24-alpine AS builder

WORKDIR /workspace

# Copy go mod files
COPY go.mod go.sum ./
RUN go mod download

# Copy source code
COPY cmd/ cmd/
COPY pkg/ pkg/

# Build
ARG VERSION=dev
ARG GIT_COMMIT=unknown
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
    -ldflags="-X 'github.com/fabiendupont/mock-device/dra-driver/pkg/version.Version=${VERSION}' \
              -X 'github.com/fabiendupont/mock-device/dra-driver/pkg/version.GitCommit=${GIT_COMMIT}'" \
    -o /dra-driver \
    ./cmd/dra-driver

# Runtime stage
FROM gcr.io/distroless/static:nonroot

COPY --from=builder /dra-driver /dra-driver

ENTRYPOINT ["/dra-driver"]
