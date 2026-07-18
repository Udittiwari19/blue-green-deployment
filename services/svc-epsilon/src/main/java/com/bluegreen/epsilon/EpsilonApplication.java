package com.bluegreen.epsilon;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.client.RestTemplate;

import java.util.LinkedHashMap;
import java.util.Map;

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

    // Simple blocking HTTP client — timeout 2s connect / 2s read
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
    @GetMapping("/")
    public ResponseEntity<Map<String, Object>> index() {
        Map<String, Object> services = new LinkedHashMap<>();
        for (var entry : UPSTREAMS.entrySet()) {
            services.put(entry.getKey(), fetchJson(entry.getValue() + "/"));
        }
        return ResponseEntity.ok(Map.of(
            "gateway",  Map.of("color", COLOR, "version", VERSION, "service", "epsilon"),
            "services", services
        ));
    }

    // ── GET /health ───────────────────────────────────────────────
    @GetMapping("/health")
    public ResponseEntity<Map<String, Object>> health() {
        Map<String, Object> statuses = new LinkedHashMap<>();
        boolean allOk = true;

        for (var entry : UPSTREAMS.entrySet()) {
            try {
                @SuppressWarnings("unchecked")
                Map<String, Object> upstream =
                    http.getForObject(entry.getValue() + "/health", Map.class);
                statuses.put(entry.getKey(), upstream);
                if (upstream == null || !"ok".equals(upstream.get("status"))) {
                    allOk = false;
                }
            } catch (Exception ex) {
                statuses.put(entry.getKey(), Map.of("status", "error", "error", ex.getMessage()));
                allOk = false;
            }
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
