package com.bluegreen;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Generic backend microservice — identity (name, color, version)
 * is injected at runtime via Docker Compose environment variables.
 *
 * Endpoints:
 *   GET /        → service info + sample data
 *   GET /health  → health check (consumed by health_gate Ansible role)
 */
@SpringBootApplication
@RestController
public class ServiceApplication {

    private static final String SERVICE_NAME = env("SERVICE_NAME", "alpha");
    private static final String COLOR        = env("COLOR",        "blue");
    private static final String VERSION      = env("VERSION",      "1.0");

    public static void main(String[] args) {
        SpringApplication.run(ServiceApplication.class, args);
    }

    @GetMapping("/")
    public ResponseEntity<Map<String, Object>> index() {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("service", SERVICE_NAME);
        body.put("color",   COLOR);
        body.put("version", VERSION);
        body.put("data",    sampleData());
        return ResponseEntity.ok(body);
    }

    @GetMapping("/health")
    public ResponseEntity<Map<String, String>> health() {
        return ResponseEntity.ok(Map.of(
            "status",  "ok",
            "service", SERVICE_NAME,
            "color",   COLOR,
            "version", VERSION
        ));
    }

    // ── helpers ───────────────────────────────────────────────────

    private List<Map<String, Object>> sampleData() {
        if ("1.0".equals(VERSION)) {
            return List.of(
                Map.of("id", 1, "name", SERVICE_NAME + "_item_1", "status", "active"),
                Map.of("id", 2, "name", SERVICE_NAME + "_item_2", "status", "active")
            );
        }
        // v2.0 — extra item added in green release
        return List.of(
            Map.of("id", 1, "name", SERVICE_NAME + "_item_1_v2", "status", "active"),
            Map.of("id", 2, "name", SERVICE_NAME + "_item_2_v2", "status", "active"),
            Map.of("id", 3, "name", SERVICE_NAME + "_item_3_v2", "status", "active")
        );
    }

    private static String env(String key, String defaultValue) {
        String val = System.getenv(key);
        return (val != null && !val.isBlank()) ? val : defaultValue;
    }
}
