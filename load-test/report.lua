-- ─────────────────────────────────────────────────────────
--  report.lua — Custom wrk2 Lua script
--  Tracks per-second 5xx counts and timestamps for Layer 2
-- ─────────────────────────────────────────────────────────

local errors_5xx = 0
local errors_total = 0
local requests_total = 0
local start_time = nil

function setup(thread)
  start_time = os.time()
end

function response(status, headers, body)
  requests_total = requests_total + 1
  if status >= 500 then
    errors_5xx = errors_5xx + 1
    -- Print timestamped 5xx event for Layer 2 downtime metric calculation
    io.write(string.format("[5xx] t=%ds status=%d\n",
      os.time() - (start_time or os.time()), status))
    io.flush()
  end
  if status < 200 or status >= 300 then
    errors_total = errors_total + 1
  end
end

function done(summary, latency, requests)
  io.write("\n─── Custom Report (report.lua) ───\n")
  io.write(string.format("Total requests    : %d\n", requests_total))
  io.write(string.format("5xx errors        : %d\n", errors_5xx))
  io.write(string.format("Non-2xx/3xx total : %d\n", errors_total))
  io.write(string.format("Latency p50       : %.2fms\n", latency:percentile(50)  / 1000))
  io.write(string.format("Latency p95       : %.2fms\n", latency:percentile(95)  / 1000))
  io.write(string.format("Latency p99       : %.2fms\n", latency:percentile(99)  / 1000))
  io.write(string.format("Latency p99.9     : %.2fms\n", latency:percentile(99.9)/ 1000))
  io.write(string.format("Max latency       : %.2fms\n", latency.max             / 1000))
  io.write("──────────────────────────────────\n")
end
