#!/bin/bash
# Energy and processes started over the last N minutes, per app, from the macOS power log. Read-only.
# Compares Rocky with Conductor. The log flushes lazily: the last few minutes may be missing.
# Usage: scripts/energy-report.sh [minutes=30] [bundle-id=dev.jhzl.rocky]
set -euo pipefail
minutes="${1:-30}"
bundle="${2:-dev.jhzl.rocky}"
db="file:/private/var/db/powerlog/Library/BatteryLife/CurrentPowerlog.PLSQL?mode=ro"
end=$(date +%s)
start=$((end - minutes * 60))
# energy and cpu_time are per interval (summed); tasks_started is cumulative (max - min).
sqlite3 -readonly -column -header "$db" "
SELECT BundleId AS app,
       ROUND(SUM(energy) / 1e9, 1) AS energy,
       ROUND(SUM(cpu_time), 1) AS cpu_s,
       MAX(tasks_started) - MIN(tasks_started) AS processes_started,
       ROUND((MAX(tasks_started) - MIN(tasks_started)) * 1.0 / $minutes, 1) AS processes_per_min
FROM PLCoalitionAgent_EventInterval_CoalitionInterval
WHERE BundleId IN ('$bundle', 'com.conductor.app') AND timestamp BETWEEN $start AND $end
GROUP BY BundleId;"
