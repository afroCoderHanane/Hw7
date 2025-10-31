FROM public.ecr.aws/lambda/provided:al2 AS build

# Install Go
RUN yum install -y golang

# Set working directory
WORKDIR /app

# Copy and build
COPY order_processor_lambda.go .
COPY go.mod .
COPY go.sum .

RUN go mod download
RUN GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o main order_processor_lambda.go

# Final stage
FROM public.ecr.aws/lambda/provided:al2

COPY --from=build /app/main /var/runtime/bootstrap

CMD ["bootstrap"]