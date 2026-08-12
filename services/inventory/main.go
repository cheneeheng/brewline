package main

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetricgrpc"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/metric"
	"go.opentelemetry.io/otel/propagation"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.26.0"
	"go.opentelemetry.io/otel/trace"
)

var (
	db            *pgxpool.Pool
	rdb           *redis.Client
	tracer        = otel.Tracer("brewline.inventory")
	reserveCount  metric.Int64Counter
	shortageCount metric.Int64Counter
	cacheTTL      = 30 * time.Second
)

type reserveReq struct {
	OrderID string `json:"order_id"`
	Items   []struct {
		SKU string `json:"sku"`
		Qty int    `json:"qty"`
	} `json:"items"`
}

type shortage struct {
	SKU     string `json:"sku"`
	ShortBy int    `json:"short_by"`
}

func initTelemetry(ctx context.Context) func() {
	res, _ := resource.New(ctx,
		resource.WithFromEnv(), // picks up OTEL_SERVICE_NAME / OTEL_RESOURCE_ATTRIBUTES
		resource.WithAttributes(semconv.ServiceName(getenv("OTEL_SERVICE_NAME", "inventory"))),
	)

	traceExp, err := otlptracegrpc.New(ctx)
	if err != nil {
		log.Fatalf("trace exporter: %v", err)
	}
	tp := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(traceExp),
		sdktrace.WithResource(res),
	)
	otel.SetTracerProvider(tp)

	// CRITICAL: the Go SDK ships a no-op propagator by default, so the inbound
	// traceparent from the order service would be silently dropped and the trace
	// would fragment at this cross-language hop. Set W3C TraceContext explicitly.
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
		propagation.TraceContext{}, propagation.Baggage{},
	))

	metricExp, err := otlpmetricgrpc.New(ctx)
	if err != nil {
		log.Fatalf("metric exporter: %v", err)
	}
	mp := sdkmetric.NewMeterProvider(
		sdkmetric.WithReader(sdkmetric.NewPeriodicReader(metricExp)),
		sdkmetric.WithResource(res),
	)
	otel.SetMeterProvider(mp)

	meter := mp.Meter("brewline.inventory")
	reserveCount, _ = meter.Int64Counter("brewline.inventory.reserved",
		metric.WithDescription("Reservation attempts by outcome"))
	shortageCount, _ = meter.Int64Counter("brewline.inventory.shortages",
		metric.WithDescription("Per-SKU shortage events"))

	return func() {
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = tp.Shutdown(shutdownCtx)
		_ = mp.Shutdown(shutdownCtx)
	}
}

func getenv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func cacheKey(sku string) string { return "inv:" + sku }

// availableQty returns available_qty, cache-first.
//
// pgx and go-redis have no auto-instrumentation here, so the datastore hops carry
// hand-set span attributes (ITER_01 §03) — otherwise a cache hit and a Postgres
// read look identical in the waterfall.
func availableQty(ctx context.Context, sku string) (int, bool, error) {
	ctx, span := tracer.Start(ctx, "inventory.available_qty")
	defer span.End()
	span.SetAttributes(attribute.String("brewline.sku", sku))

	if v, err := rdb.Get(ctx, cacheKey(sku)).Int(); err == nil {
		span.SetAttributes(
			attribute.String("db.system", "redis"),
			attribute.Bool("brewline.cache_hit", true),
		)
		return v, true, nil
	}
	span.SetAttributes(
		attribute.String("db.system", "postgresql"),
		attribute.Bool("brewline.cache_hit", false),
	)
	var avail int
	err := db.QueryRow(ctx,
		"SELECT available_qty FROM inventory_items WHERE sku=$1", sku).Scan(&avail)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, false, nil
	}
	if err != nil {
		span.RecordError(err)
		return 0, false, err
	}
	rdb.Set(ctx, cacheKey(sku), avail, cacheTTL) // back-fill cache
	return avail, true, nil
}

func reserveHandler(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	var req reserveReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "bad request"})
		return
	}

	// High-cardinality identifiers belong on spans, never on metric labels
	// (ITER_03 cardinality discipline); order_id is what makes a reservation
	// findable from the Loki log line.
	span := trace.SpanFromContext(ctx)
	span.SetAttributes(
		attribute.String("brewline.order_id", req.OrderID),
		attribute.Int("brewline.item_count", len(req.Items)),
		attribute.String("db.system", "postgresql"),
	)

	tx, err := db.Begin(ctx)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "tx"})
		return
	}
	defer tx.Rollback(ctx) //nolint:errcheck // no-op after commit

	var shortages []shortage
	for _, it := range req.Items {
		// Atomic conditional update — two concurrent reservations can't oversell.
		ct, err := tx.Exec(ctx,
			`UPDATE inventory_items
			   SET reserved_qty = reserved_qty + $1, updated_at = now()
			 WHERE sku = $2 AND available_qty - reserved_qty >= $1`,
			it.Qty, it.SKU)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "db"})
			return
		}
		if ct.RowsAffected() == 0 {
			var free int // available_qty - reserved_qty; 0 if the SKU is unknown
			_ = tx.QueryRow(ctx,
				"SELECT available_qty - reserved_qty FROM inventory_items WHERE sku=$1",
				it.SKU).Scan(&free)
			if free < 0 {
				free = 0
			}
			shortages = append(shortages, shortage{SKU: it.SKU, ShortBy: it.Qty - free})
			shortageCount.Add(ctx, 1, metric.WithAttributes(attribute.String("sku", it.SKU)))
		}
	}

	if len(shortages) > 0 {
		_ = tx.Rollback(ctx) // do not partially reserve
		reserveCount.Add(ctx, 1, metric.WithAttributes(attribute.String("outcome", "short")))
		writeJSON(w, http.StatusOK, map[string]any{"reserved": false, "shortages": shortages})
		return
	}

	if err := tx.Commit(ctx); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "commit"})
		return
	}
	for _, it := range req.Items {
		rdb.Del(ctx, cacheKey(it.SKU)) // invalidate stale availability
	}
	reserveCount.Add(ctx, 1, metric.WithAttributes(attribute.String("outcome", "reserved")))
	writeJSON(w, http.StatusOK, map[string]any{"reserved": true, "shortages": []shortage{}})
}

func inventoryHandler(w http.ResponseWriter, r *http.Request) {
	sku := chi.URLParam(r, "sku")
	avail, found, err := availableQty(r.Context(), sku)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "db"})
		return
	}
	if !found {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "unknown sku"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"sku": sku, "available_qty": avail})
}

func main() {
	ctx := context.Background()
	shutdown := initTelemetry(ctx)
	defer shutdown()

	var err error
	db, err = pgxpool.New(ctx, getenv("DATABASE_URL", "postgres://brewline:brewline@postgres:5432/brewline"))
	if err != nil {
		log.Fatalf("pg pool: %v", err)
	}
	defer db.Close()

	opt, err := redis.ParseURL(getenv("REDIS_URL", "redis://redis:6379"))
	if err != nil {
		log.Fatalf("redis url: %v", err)
	}
	rdb = redis.NewClient(opt)
	defer rdb.Close()

	r := chi.NewRouter()
	// otelhttp names every span with the one string passed to NewHandler, so all
	// three routes arrive as "inventory" and the waterfall cannot tell a reserve
	// from an availability read. chi resolves the pattern during routing, so rename
	// the server span on the way back out. The pattern, never r.URL.Path: the raw
	// path would make /inventory/{sku} one span name per SKU.
	r.Use(func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
			next.ServeHTTP(w, req)
			if p := chi.RouteContext(req.Context()).RoutePattern(); p != "" {
				span := trace.SpanFromContext(req.Context())
				span.SetName(req.Method + " " + p)
				span.SetAttributes(semconv.HTTPRoute(p))
			}
		})
	})
	r.Get("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
	})
	r.Post("/reserve", reserveHandler)
	r.Get("/inventory/{sku}", inventoryHandler)

	// otelhttp wraps the router so the inbound traceparent is extracted (via the
	// propagator set above) and inventory's spans attach under the order trace.
	handler := otelhttp.NewHandler(r, "inventory")
	log.Println("inventory listening on :8080")
	if err := http.ListenAndServe(":8080", handler); err != nil {
		log.Fatal(err)
	}
}
