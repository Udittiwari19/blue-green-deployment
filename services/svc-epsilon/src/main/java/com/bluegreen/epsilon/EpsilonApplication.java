package com.bluegreen.epsilon;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.client.RestTemplate;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.stream.Collectors;

/**
 * svc-epsilon — API Gateway / Aggregator
 *
 * Aggregates responses from all 4 backend microservices.
 * The health endpoint returns 503 if any upstream is unreachable
 * (feeds the Ansible health_gate role for auto-rollback decisions).
 *
 * Endpoints:
 *   GET /        → aggregated response from alpha, beta, gamma, delta
 *   GET /health  → gateway + all upstream health statuses
 */
@SpringBootApplication
@RestController
public class EpsilonApplication {

    private static final String COLOR   = env("COLOR",   "blue");
    private static final String VERSION = env("VERSION", "1.0");

    // Upstream URLs injected by Docker Compose env vars
    private static final Map<String, String> UPSTREAMS = Map.of(
        "alpha", env("ALPHA_URL", "http://alpha-blue:5000"),
        "beta",  env("BETA_URL",  "http://beta-blue:5000"),
        "gamma", env("GAMMA_URL", "http://gamma-blue:5000"),
        "delta", env("DELTA_URL", "http://delta-blue:5000")
    );

    // Dedicated I/O thread pool — sized for blocking HTTP calls.
    // ForkJoinPool.commonPool() is CPU-sized (cores-1 threads) and stalls
    // instantly when threads block on network I/O under sustained load.
    // 4 upstreams × 10 concurrent requests = 40 threads handles 200 req/s
    // cleanly without queuing, keeping p99 low.
    private static final ExecutorService IO_POOL =
        Executors.newFixedThreadPool(40);

    // Blocking HTTP client — timeout 2s connect / 2s read
    private final RestTemplate http;

    public EpsilonApplication() {
        var factory = new org.springframework.http.client.SimpleClientHttpRequestFactory();
        factory.setConnectTimeout(2_000);
        factory.setReadTimeout(2_000);
        this.http = new RestTemplate(factory);
    }

    public static void main(String[] args) {
        SpringApplication.run(EpsilonApplication.class, args);
    }

    // ── GET / ─────────────────────────────────────────────────────
    // Calls all 4 upstreams in PARALLEL using CompletableFuture.
    // Response time = max(upstream latencies), not sum — ~4x faster under load.
    @GetMapping("/")
    public ResponseEntity<Map<String, Object>> index() {
        Map<String, CompletableFuture<Map<String, Object>>> futures = UPSTREAMS.entrySet().stream()
            .collect(Collectors.toMap(
                Map.Entry::getKey,
                // IO_POOL: dedicated thread pool for blocking I/O — avoids
                // ForkJoinPool.commonPool() starvation under sustained load.
                e -> CompletableFuture.supplyAsync(() -> fetchJson(e.getValue() + "/"), IO_POOL)
            ));

        Map<String, Object> services = new LinkedHashMap<>();
        futures.forEach((k, f) -> services.put(k, f.join()));

        return ResponseEntity.ok(Map.of(
            "gateway",  Map.of("color", COLOR, "version", VERSION, "service", "epsilon"),
            "services", services
        ));
    }

    // ── GET /health ───────────────────────────────────────────────
    // Also parallelised — all 4 health checks fire simultaneously.
    @GetMapping("/health")
    public ResponseEntity<Map<String, Object>> health() {
        Map<String, CompletableFuture<Map<String, Object>>> futures = UPSTREAMS.entrySet().stream()
            .collect(Collectors.toMap(
                Map.Entry::getKey,
                e -> CompletableFuture.supplyAsync(() -> {
                    try {
                        @SuppressWarnings("unchecked")
                        Map<String, Object> upstream =
                            http.getForObject(e.getValue() + "/health", Map.class);
                        return upstream != null ? upstream
                            : Map.of("status", "error", "error", "null response");
                    } catch (Exception ex) {
                        return Map.<String, Object>of("status", "error", "error", ex.getMessage());
                    }
                }, IO_POOL)
            ));

        Map<String, Object> statuses = new LinkedHashMap<>();
        boolean allOk = true;
        for (var entry : futures.entrySet()) {
            Map<String, Object> result = entry.getValue().join();
            statuses.put(entry.getKey(), result);
            if (!"ok".equals(result.get("status"))) allOk = false;
        }

        Map<String, Object> body = new LinkedHashMap<>();
        body.put("status",    allOk ? "ok" : "degraded");
        body.put("service",   "epsilon");
        body.put("color",     COLOR);
        body.put("version",   VERSION);
        body.put("upstreams", statuses);

        return ResponseEntity.status(allOk ? 200 : 503).body(body);
    }

    // ── helpers ───────────────────────────────────────────────────

    @SuppressWarnings("unchecked")
    private Map<String, Object> fetchJson(String url) {
        try {
            return http.getForObject(url, Map.class);
        } catch (Exception ex) {
            return Map.of("error", ex.getMessage());
        }
    }

    private static String env(String key, String defaultValue) {
        String val = System.getenv(key);
        return (val != null && !val.isBlank()) ? val : defaultValue;
    }
}
