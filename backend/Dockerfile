
# =====================================
# Stage 1: Maven Build
# =====================================

FROM dhi.io/maven:3.9-jdk21-alpine3.22-dev AS builder

WORKDIR /app

COPY pom.xml ./

RUN mvn dependency:go-offline

COPY src ./src

RUN mvn clean package -DskipTests


# =====================================
# Stage 2: Application Runtime
# =====================================

FROM dhi.io/eclipse-temurin:21-alpine3.23

WORKDIR /app

# Copy application JAR
COPY --from=builder /app/target/*.jar app.jar

# Copy OpenTelemetry Java Agent
COPY otel/opentelemetry-javaagent.jar /app/opentelemetry-javaagent.jar


# Application configuration
ENV OTEL_SERVICE_NAME=nexabank

# service.version is a resource attribute (there is no OTEL_SERVICE_VERSION variable).
# Kubernetes overrides this whole variable, see the note below.
ENV OTEL_RESOURCE_ATTRIBUTES=deployment.environment=dev,service.version=1.0.0

# OpenTelemetry configuration
ENV OTEL_TRACES_EXPORTER=otlp

ENV OTEL_METRICS_EXPORTER=none

ENV OTEL_LOGS_EXPORTER=none

ENV OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf

# Application port
EXPOSE 8080

USER 65532

# Start application with OpenTelemetry
ENTRYPOINT ["java", "-javaagent:/app/opentelemetry-javaagent.jar", "-jar", "app.jar"]