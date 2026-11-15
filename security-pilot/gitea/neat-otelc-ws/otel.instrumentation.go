//go:build tools

package tools

import (
	_ "go.opentelemetry.io/otelc/instrumentation/net/http/server"
	_ "go.opentelemetry.io/otelc/instrumentation/net/http/client"
	_ "go.opentelemetry.io/otelc/instrumentation/database/sql"
	_ "go.opentelemetry.io/otelc/instrumentation/go.opentelemetry.io/otel/sdk/trace"
	_ "go.opentelemetry.io/otelc/instrumentation/go.opentelemetry.io/otel"
	_ "go.opentelemetry.io/otelc/instrumentation/go.opentelemetry.io/otel/trace"
	_ "go.opentelemetry.io/otelc/instrumentation/go.opentelemetry.io/otel/init"
	_ "go.opentelemetry.io/otelc/instrumentation/runtime"
	_ "go.opentelemetry.io/otelc/instrumentation/log"
	_ "go.opentelemetry.io/otelc/instrumentation/log/slog"
	_ "neat.local/otelcws/rules"
)
