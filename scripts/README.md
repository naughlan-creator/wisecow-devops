# Scripts

## `app_health_check.sh`
determines whether an application is functioning by inspecting the HTTP status code it returns, and exits with a code suitable for cron, CI or a monitoring system.

## Status classication
The script distinguishes 3 outcomes rather than 2 because "not working" covers 2 diagnostically different problems - a network failure and an application failure are not the same incident and collapsing them loses the information you need first at 03h00

| Result | Condition | Exit Code |
|---|---|---|
| `UP` | HTTP 2xx / 3xx | `0` |
| `DOWN` | HTTP 4xx / 5xx | `1` |
| `UNREACHABLE` | connection refused, DNS failure, timeout, TLS failure | `2` |
| usage error | bad or missing arguments | `3` |

For `UNREACHABLE`, curl's exit status is translated into a plain-language reason (`could not resolve host`, `connection refused`, `timed out after 10s`, `TLS handshake failed`, `certificate verification failed`) rather than being reported as a random number.

### Usage

```
Usage: app_health_check.sh [OPTIONS]

    -u, --url URL        URL to check (default: https://wisecow.local)
    -t, --timeout SECS   Request timeout in seconds (default: 10)
    -l, --log FILE       Append results to a log file as well as stdout
    -k, --insecure       Skip TLS verification (for self-signed certificates)
    -r, --resolve SPEC   Force DNS resolution. for example: wisecow.local:443:127.0.0.1
    -h, --help           Show help and exit
```

### Examples

```bash
# Check the deployed Wisecow application (self-signed cert)
./app_health_check.sh -u https://wisecow.local -k
 
# Log to a file as well as the console
./app_health_check.sh -u https://wisecow.local -k -l /var/log/wisecow-health.log
 
# Bypass DNS entirely (for CI workflow or when /etc/hosts isn't set up)
./app_health_check.sh -u https://wisecow.local -k -r wisecow.local:443:127.0.0.1
 
# Use in automation
if ./app_health_check.sh -u https://wisecow.local -k; then
    echo "healthy"
fi
```

### Sample output
```
2026-08-04 14:57:19 [INFO]     UP           https://wisecow.local  — HTTP 200 in 0.014223s
2026-08-04 14:58:02 [ERROR]    DOWN         https://httpbin.org/status/503  — HTTP 503 in 0.512s
2026-08-04 14:58:12 [CRITICAL] UNREACHABLE  http://localhost:9999  — connection refused
```

### Note on demonstrating the `DOWN` state
The Wisecow Ingress uses `pathType: Prefix` on `/`, so every path routes to the application — and the application itself discards the request line entirely (`get_api` reads one line and ignores it), returning a cow regardless of what was asked for. It therefore cannot produce a 4xx or 5xx of its own.
 
The `DOWN` classification is demonstrated against an external endpoint returning a controlled error status, which also shows the script works against arbitrary applications rather than only this one.
 
---

## `system_health_monitor.py`
 
Monitors CPU, memory, disk, and process count against configurable thresholds, alerting to console and log file when any is breached.

### Setup
```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
```

### Exit codes

| Code | Meaning |
| --- | --- |
| `0` | all metrics within thresholds |
| `1` | one or more thresholds breached |
| `2` | the check itself failed to run |

### Usage

```
--cpu FLOAT         CPU usage threshold, percent        (default: 80.0)
--memory FLOAT      Memory usage threshold, percent     (default: 80.0)
--disk FLOAT        Disk usage threshold, percent       (default: 85.0)
--processes INT     Running process count threshold     (default: 300)
--path PATH         Filesystem path to check            (default: /)
--log FILE          Append output to a log file
```

```bash
# Default thresholds
python3 system_health_monitor.py

# Custom thresholds, logging to file
python3 system_health_monitor.py --cpu 70 --memory 75 --log /var/log/sys-health.log

# Hourly cron entry
0 * * * * /path/to/.venv/bin/python3 /path/to/system_health_monitor.py --log /var/log/sys-health.log
```

### Implementation notes
**`psutil.cpu_percent(interval=1)` blocks for one second by design.** CPU percentage is derived from the delta between two samples; a non-blocking call has no prior sample and returns a meaningless `0.0`.

**Each check returns `(breached, message)`.** Keeping the checks free of logging and exit code logic means `main()` handles both uniformly instead of repeating the pattern four times.

**Log calls use deferred `%s` formatting** rather than f-strings, so filtered-out messages cost nothing to construct.

**`psutil.NoSuchProcess` is caught during process iteration** — processes exit mid-scan, which is normal rather than an error condition.

**Screenshot:** `docs/screenshots/system-health-monitor.png` — shows the healthy path (exit 0), a forced breach with alerts and top-process context (exit 1) and a failed check against an invalid path (exit 2).