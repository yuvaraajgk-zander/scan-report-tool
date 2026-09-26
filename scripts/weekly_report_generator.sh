#!/bin/bash
# Weekly Checking report — COMPLETED trays only, ordered quantity (not
# scanned quantity). One combined CSV with multiple SECTION blocks, same
# convention as scan_report_csv.sh. Includes a Weekly Summary section and a
# Scanner-wise Units Completed section (grouped by device_id) alongside the
# original daily/checker/product/hourly breakdown. All fetch logic, joins,
# and formulas are unchanged from the original script this was built from -
# only CONTAINER/SCHEMA/START_DATE/END_DATE are configurable, all the same
# way (env vars with a default), so nothing about how a number is derived
# ever depends on how you invoke it.
#
# Usage (no file edits needed - everything below is an env var override):
#   ./weekly_report_generator.sh                                    -> defaults: zander-postgres / palepumyp / 2026-09-14..2026-09-19
#   SCHEMA=palepu ./weekly_report_generator.sh                      -> another tenant on the same main db
#   START_DATE=2026-09-20 END_DATE=2026-09-26 ./weekly_report_generator.sh   -> a different week
#   CONTAINER=other_pg SCHEMA=other_tenant START_DATE=... END_DATE=... ./weekly_report_generator.sh   -> all four at once
#   (check container names with: docker ps --format "{{.Names}}\t{{.Image}}")
set -euo pipefail

CONTAINER="${CONTAINER:-zander-postgres}"
SCHEMA="${SCHEMA:-palepumyp}"
START_DATE="${START_DATE:-2026-09-14}"
END_DATE="${END_DATE:-2026-09-19}"
OUT="weekly-report-${START_DATE}_to_${END_DATE}.csv"

PGUSER=$(docker exec "$CONTAINER" printenv POSTGRES_USER)
PGDB=$(docker exec "$CONTAINER" printenv POSTGRES_DB)

run_csv() {
    docker exec -i "$CONTAINER" psql -U "$PGUSER" -d "$PGDB" -q --csv
}
run_scalar() {
    docker exec -i "$CONTAINER" psql -U "$PGUSER" -d "$PGDB" -t -A -q
}

echo "Schema:  $SCHEMA"
echo "Period:  $START_DATE to $END_DATE (COMPLETED trays only)"
echo "Output:  $OUT"

# ---------------------------------------------------------------------------
# Meta - pure labeling (schema/date range/generation date), no computed
# metric here, so it can't affect any number derived below.
{
    echo "SECTION,META"
    echo "key,value"
    echo "schema,$SCHEMA"
    echo "weekStart,$START_DATE"
    echo "weekEnd,$END_DATE"
    echo "reportDate,$(date +%Y-%m-%d)"
    echo
} > "$OUT"

echo "[1/10] Summary"
{
    echo "SECTION,SUMMARY"
    run_csv <<SQL
SET search_path TO $SCHEMA;
WITH tray AS (
    SELECT group_picklist_number
    FROM tbl_pick_list_group
    WHERE v_dt BETWEEN '$START_DATE' AND '$END_DATE' AND status = 'COMPLETED'
),
line AS (
    SELECT li.quantity, li.mrp
    FROM tbl_invoice inv
    JOIN tray t ON t.group_picklist_number = inv.group_picklist_number
    JOIN tbl_invoice_line_item li ON li.transno = inv.invoice_number
)
SELECT 'completedTrays' AS key, (SELECT COUNT(*) FROM tray)::text AS value
UNION ALL SELECT 'unitsBilled', COALESCE(SUM(quantity), 0)::text FROM line
UNION ALL SELECT 'totalValueMRP', ROUND(COALESCE(SUM(quantity * NULLIF(mrp, '')::numeric), 0), 2)::text FROM line;
SQL
    echo
} >> "$OUT"

# ---------------------------------------------------------------------------
echo "[2/10] Daily summary"
{
    echo "SECTION,DAILY_SUMMARY"
    run_csv <<SQL
SET search_path TO $SCHEMA;
WITH tray_base AS (
    SELECT g.group_picklist_number, g.v_dt,
           GREATEST(EXTRACT(EPOCH FROM (g.end_time - g.start_time))::BIGINT - COALESCE(g.idle_time_seconds, 0), 0) AS net_seconds
    FROM tbl_pick_list_group g
    WHERE g.v_dt BETWEEN '$START_DATE' AND '$END_DATE' AND g.status = 'COMPLETED'
),
line_agg AS (
    SELECT inv.group_picklist_number,
           COUNT(li.invoice_line_item_id)::INT AS lines,
           SUM(li.quantity)::INT AS units,
           SUM(li.quantity * NULLIF(li.mrp, '')::numeric) AS value
    FROM tbl_invoice inv
    JOIN tray_base t ON t.group_picklist_number = inv.group_picklist_number
    LEFT JOIN tbl_invoice_line_item li ON li.transno = inv.invoice_number
    GROUP BY inv.group_picklist_number
)
SELECT
    t.v_dt AS "Date",
    COUNT(*)::int AS "Trays",
    SUM(COALESCE(la.units, 0))::int AS "Total Units",
    SUM(COALESCE(la.lines, 0))::int AS "Total Lines",
    ROUND(SUM(COALESCE(la.value, 0)), 2) AS "Value (Rs)",
    ROUND(SUM(COALESCE(la.units, 0))::numeric / NULLIF(SUM(t.net_seconds) / 60.0, 0), 2) AS "Net Units per Min",
    ROUND(SUM(t.net_seconds) / 60.0, 2) AS "Net Min",
    ROUND(SUM(COALESCE(la.lines, 0))::numeric / NULLIF(SUM(t.net_seconds) / 60.0, 0), 2) AS "Items per Min"
FROM tray_base t
LEFT JOIN line_agg la ON la.group_picklist_number = t.group_picklist_number
GROUP BY t.v_dt
ORDER BY t.v_dt;
SQL
    echo
} >> "$OUT"

# ---------------------------------------------------------------------------
echo "[3/10] Time and speed by checker"
{
    echo "SECTION,TIME_AND_SPEED_BY_CHECKER"
    run_csv <<SQL
SET search_path TO $SCHEMA;
WITH tray_base AS (
    SELECT g.group_picklist_number, g.scanned_by,
           GREATEST(EXTRACT(EPOCH FROM (g.end_time - g.start_time))::BIGINT - COALESCE(g.idle_time_seconds, 0), 0) AS net_seconds
    FROM tbl_pick_list_group g
    WHERE g.v_dt BETWEEN '$START_DATE' AND '$END_DATE' AND g.status = 'COMPLETED'
),
line_agg AS (
    SELECT inv.group_picklist_number,
           COUNT(li.invoice_line_item_id)::INT AS lines,
           SUM(li.quantity)::INT AS units
    FROM tbl_invoice inv
    JOIN tray_base t ON t.group_picklist_number = inv.group_picklist_number
    LEFT JOIN tbl_invoice_line_item li ON li.transno = inv.invoice_number
    GROUP BY inv.group_picklist_number
)
SELECT
    COALESCE(TRIM(CONCAT(u.first_name, ' ', u.last_name)), t.scanned_by) AS "Checker Name",
    COUNT(*)::int AS "Trays",
    SUM(COALESCE(la.lines, 0))::int AS "Line Items",
    ROUND(SUM(COALESCE(la.units, 0))::numeric / NULLIF(SUM(t.net_seconds) / 60.0, 0), 2) AS "Net Units per Min",
    ROUND(SUM(t.net_seconds) / 60.0, 2) AS "Net Min",
    ROUND(SUM(COALESCE(la.lines, 0))::numeric / NULLIF(SUM(t.net_seconds) / 60.0, 0), 2) AS "Items per Min"
FROM tray_base t
LEFT JOIN line_agg la ON la.group_picklist_number = t.group_picklist_number
LEFT JOIN tbl_user u ON u.user_id = t.scanned_by
GROUP BY t.scanned_by, u.first_name, u.last_name
ORDER BY "Line Items" DESC;
SQL
    echo
} >> "$OUT"

# ---------------------------------------------------------------------------
echo "[4/10] Average time to complete by flow (uses scanned_time as epoch ms - verify)"
{
    echo "SECTION,AVG_TIME_BY_FLOW"
    run_csv <<SQL
SET search_path TO $SCHEMA;
WITH tray AS (
    SELECT group_picklist_number
    FROM tbl_pick_list_group
    WHERE v_dt BETWEEN '$START_DATE' AND '$END_DATE' AND status = 'COMPLETED'
),
lines AS (
    SELECT li.scan_flow_status,
           li.scanned_time - LAG(li.scanned_time) OVER (PARTITION BY li.group_picklist_number ORDER BY li.scanned_time) AS delta_ms
    FROM tbl_invoice_line_item li
    JOIN tray t ON t.group_picklist_number = li.group_picklist_number
    WHERE li.scanned_time IS NOT NULL
)
SELECT
    scan_flow_status AS "Scan Flow Status",
    COUNT(*) AS "Count (n)",
    ROUND(AVG(delta_ms) / 1000.0, 1) AS "Avg Time (sec)"
FROM lines
WHERE delta_ms IS NOT NULL AND delta_ms >= 0
GROUP BY scan_flow_status
ORDER BY "Count (n)" DESC;
SQL
    echo
} >> "$OUT"

# ---------------------------------------------------------------------------
echo "[5/10] Top products by volume"
{
    echo "SECTION,TOP_PRODUCTS_BY_VOLUME"
    run_csv <<SQL
SET search_path TO $SCHEMA;
WITH tray AS (
    SELECT group_picklist_number
    FROM tbl_pick_list_group
    WHERE v_dt BETWEEN '$START_DATE' AND '$END_DATE' AND status = 'COMPLETED'
)
SELECT
    li.product_name AS "Product",
    COUNT(*) AS "Lines",
    SUM(li.quantity)::int AS "Total Units",
    ROUND(SUM(li.quantity * NULLIF(li.mrp, '')::numeric), 2) AS "Value (Rs)"
FROM tbl_invoice_line_item li
JOIN tray t ON t.group_picklist_number = li.group_picklist_number
GROUP BY li.product_name
ORDER BY "Total Units" DESC
LIMIT 25;
SQL
    echo
} >> "$OUT"

# ---------------------------------------------------------------------------
echo "[6/10] Hourly activity profile (uses scanned_time as epoch ms - verify)"
{
    echo "SECTION,HOURLY_ACTIVITY_PROFILE"
    run_csv <<SQL
SET search_path TO $SCHEMA;
WITH tray AS (
    SELECT group_picklist_number, v_dt
    FROM tbl_pick_list_group
    WHERE v_dt BETWEEN '$START_DATE' AND '$END_DATE' AND status = 'COMPLETED'
),
scans AS (
    SELECT t.v_dt, EXTRACT(HOUR FROM (to_timestamp(li.scanned_time / 1000.0) AT TIME ZONE 'Asia/Kolkata'))::int AS hr
    FROM tbl_invoice_line_item li
    JOIN tray t ON t.group_picklist_number = li.group_picklist_number
    WHERE li.scanned_time IS NOT NULL
),
per_day_hour AS (
    SELECT v_dt, hr, COUNT(*) AS items FROM scans GROUP BY v_dt, hr
),
per_hour AS (
    SELECT hr, SUM(items) AS total_items, COUNT(DISTINCT v_dt) AS days_seen
    FROM per_day_hour GROUP BY hr
),
peak AS (
    SELECT DISTINCT ON (hr) hr, v_dt AS peak_date, items AS peak_items
    FROM per_day_hour ORDER BY hr, items DESC
)
SELECT
    to_char(make_time(ph.hr, 0, 0), 'HH12 AM') || ' - ' || to_char(make_time((ph.hr + 1) % 24, 0, 0), 'HH12 AM') AS "Time Slot",
    ph.total_items AS "Total Items",
    ROUND(ph.total_items::numeric / NULLIF(ph.days_seen, 0), 1) AS "Avg Items per Day",
    pk.peak_items AS "Peak Single Day",
    pk.peak_date AS "Peak Date"
FROM per_hour ph
JOIN peak pk ON pk.hr = ph.hr
ORDER BY ph.hr;
SQL
    echo
} >> "$OUT"

# ---------------------------------------------------------------------------
echo "[7/10] Finding best day (highest total lines)"
BEST_DAY=$(docker exec -i "$CONTAINER" psql -U "$PGUSER" -d "$PGDB" -t -A -q <<SQL
SET search_path TO $SCHEMA;
WITH tray AS (
    SELECT g.group_picklist_number, g.v_dt
    FROM tbl_pick_list_group g
    WHERE g.v_dt BETWEEN '$START_DATE' AND '$END_DATE' AND g.status = 'COMPLETED'
),
line_agg AS (
    SELECT inv.group_picklist_number, COUNT(li.invoice_line_item_id) AS lines
    FROM tbl_invoice inv
    JOIN tray t ON t.group_picklist_number = inv.group_picklist_number
    LEFT JOIN tbl_invoice_line_item li ON li.transno = inv.invoice_number
    GROUP BY inv.group_picklist_number
)
SELECT t.v_dt
FROM tray t
LEFT JOIN line_agg la ON la.group_picklist_number = t.group_picklist_number
GROUP BY t.v_dt
ORDER BY SUM(COALESCE(la.lines, 0)) DESC
LIMIT 1;
SQL
)
echo "      Best day = $BEST_DAY"

echo "[8/10] Best-day deep dive ($BEST_DAY)"
{
    echo "SECTION,BEST_DAY_SUMMARY"
    echo "key,value"
    echo "bestDay,${BEST_DAY}"
    run_csv <<SQL
SET search_path TO $SCHEMA;
WITH tray_base AS (
    SELECT g.group_picklist_number,
           GREATEST(EXTRACT(EPOCH FROM (g.end_time - g.start_time))::BIGINT - COALESCE(g.idle_time_seconds, 0), 0) AS net_seconds
    FROM tbl_pick_list_group g
    WHERE g.v_dt = '$BEST_DAY' AND g.status = 'COMPLETED'
),
line_agg AS (
    SELECT inv.group_picklist_number,
           COUNT(li.invoice_line_item_id)::INT AS lines,
           SUM(li.quantity)::INT AS units,
           SUM(li.quantity * NULLIF(li.mrp, '')::numeric) AS value
    FROM tbl_invoice inv
    JOIN tray_base t ON t.group_picklist_number = inv.group_picklist_number
    LEFT JOIN tbl_invoice_line_item li ON li.transno = inv.invoice_number
    GROUP BY inv.group_picklist_number
),
agg AS (
    SELECT COUNT(*) AS trays, SUM(COALESCE(la.units,0)) AS units, SUM(COALESCE(la.lines,0)) AS lines,
           SUM(COALESCE(la.value,0)) AS value, SUM(t.net_seconds) AS net_seconds
    FROM tray_base t LEFT JOIN line_agg la ON la.group_picklist_number = t.group_picklist_number
)
SELECT 'trays' AS key, trays::text AS value FROM agg
UNION ALL SELECT 'units', units::text FROM agg
UNION ALL SELECT 'lines', lines::text FROM agg
UNION ALL SELECT 'valueRs', ROUND(value,2)::text FROM agg
UNION ALL SELECT 'netMin', ROUND(net_seconds/60.0,2)::text FROM agg
UNION ALL SELECT 'itemsPerMin', ROUND(lines::numeric/NULLIF(net_seconds/60.0,0),2)::text FROM agg
UNION ALL SELECT 'unitsPerMin', ROUND(units::numeric/NULLIF(net_seconds/60.0,0),2)::text FROM agg;
SQL
    echo
    echo "SECTION,BEST_DAY_CHECKERS"
    run_csv <<SQL
SET search_path TO $SCHEMA;
WITH tray_base AS (
    SELECT g.group_picklist_number, g.scanned_by,
           GREATEST(EXTRACT(EPOCH FROM (g.end_time - g.start_time))::BIGINT - COALESCE(g.idle_time_seconds, 0), 0) AS net_seconds
    FROM tbl_pick_list_group g
    WHERE g.v_dt = '$BEST_DAY' AND g.status = 'COMPLETED'
),
line_agg AS (
    SELECT inv.group_picklist_number,
           COUNT(li.invoice_line_item_id)::INT AS lines,
           SUM(li.quantity)::INT AS units
    FROM tbl_invoice inv
    JOIN tray_base t ON t.group_picklist_number = inv.group_picklist_number
    LEFT JOIN tbl_invoice_line_item li ON li.transno = inv.invoice_number
    GROUP BY inv.group_picklist_number
)
SELECT
    COALESCE(TRIM(CONCAT(u.first_name, ' ', u.last_name)), t.scanned_by) AS "Checker Name",
    COUNT(*)::int AS "Trays",
    SUM(COALESCE(la.lines, 0))::int AS "Line Items",
    ROUND(SUM(COALESCE(la.units, 0))::numeric / NULLIF(SUM(t.net_seconds) / 60.0, 0), 2) AS "Net Units per Min",
    ROUND(SUM(t.net_seconds) / 60.0, 2) AS "Net Min",
    ROUND(SUM(COALESCE(la.lines, 0))::numeric / NULLIF(SUM(t.net_seconds) / 60.0, 0), 2) AS "Items per Min"
FROM tray_base t
LEFT JOIN line_agg la ON la.group_picklist_number = t.group_picklist_number
LEFT JOIN tbl_user u ON u.user_id = t.scanned_by
GROUP BY t.scanned_by, u.first_name, u.last_name
ORDER BY "Line Items" DESC;
SQL
} >> "$OUT"

# ---------------------------------------------------------------------------
echo "[9/10] Weekly summary"
{
    echo "SECTION,WEEKLY_SUMMARY"
    run_csv <<SQL
SET search_path TO $SCHEMA;
WITH tray_base AS (
    SELECT g.group_picklist_number, g.v_dt,
           GREATEST(EXTRACT(EPOCH FROM (g.end_time - g.start_time))::BIGINT - COALESCE(g.idle_time_seconds, 0), 0) AS net_seconds
    FROM tbl_pick_list_group g
    WHERE g.v_dt BETWEEN '$START_DATE' AND '$END_DATE' AND g.status = 'COMPLETED'
),
line_agg AS (
    SELECT inv.group_picklist_number,
           COUNT(li.invoice_line_item_id)::INT AS lines,
           SUM(li.quantity)::INT AS units,
           SUM(li.quantity * NULLIF(li.mrp, '')::numeric) AS value
    FROM tbl_invoice inv
    JOIN tray_base t ON t.group_picklist_number = inv.group_picklist_number
    LEFT JOIN tbl_invoice_line_item li ON li.transno = inv.invoice_number
    GROUP BY inv.group_picklist_number
)
SELECT
    date_trunc('week', t.v_dt::date)::date AS "Week Starting",
    (date_trunc('week', t.v_dt::date)::date + 6) AS "Week Ending",
    COUNT(*)::int AS "Trays",
    SUM(COALESCE(la.units, 0))::int AS "Total Units",
    SUM(COALESCE(la.lines, 0))::int AS "Total Lines",
    ROUND(SUM(COALESCE(la.value, 0)), 2) AS "Value (Rs)",
    ROUND(SUM(COALESCE(la.units, 0))::numeric / NULLIF(SUM(t.net_seconds) / 60.0, 0), 2) AS "Net Units per Min",
    ROUND(SUM(t.net_seconds) / 60.0, 2) AS "Net Min",
    ROUND(SUM(COALESCE(la.lines, 0))::numeric / NULLIF(SUM(t.net_seconds) / 60.0, 0), 2) AS "Items per Min"
FROM tray_base t
LEFT JOIN line_agg la ON la.group_picklist_number = t.group_picklist_number
GROUP BY date_trunc('week', t.v_dt::date)
ORDER BY "Week Starting";
SQL
    echo
} >> "$OUT"

# ---------------------------------------------------------------------------
echo "[10/10] Scanner-wise units completed"
{
    echo "SECTION,SCANNER_WISE_UNITS"
    run_csv <<SQL
SET search_path TO $SCHEMA;
-- device_id (the physical scanner) is a different dimension from
-- scanned_by/checker (the person) - one device can be used by several
-- checkers over the period and vice versa. Plain GROUP BY device_id, so
-- this returns exactly as many rows as there are distinct scanners with
-- completed trays that period - no hardcoded scanner list or count.
WITH tray_base AS (
    SELECT g.group_picklist_number, g.device_id,
           GREATEST(EXTRACT(EPOCH FROM (g.end_time - g.start_time))::BIGINT - COALESCE(g.idle_time_seconds, 0), 0) AS net_seconds
    FROM tbl_pick_list_group g
    WHERE g.v_dt BETWEEN '$START_DATE' AND '$END_DATE' AND g.status = 'COMPLETED'
      AND g.device_id IS NOT NULL AND g.device_id <> ''
),
line_agg AS (
    SELECT inv.group_picklist_number,
           COUNT(li.invoice_line_item_id)::INT AS lines,
           SUM(li.quantity)::INT AS units
    FROM tbl_invoice inv
    JOIN tray_base t ON t.group_picklist_number = inv.group_picklist_number
    LEFT JOIN tbl_invoice_line_item li ON li.transno = inv.invoice_number
    GROUP BY inv.group_picklist_number
)
SELECT
    t.device_id AS "Scanner",
    COUNT(*)::int AS "Trays",
    SUM(COALESCE(la.units, 0))::int AS "Units Completed",
    SUM(COALESCE(la.lines, 0))::int AS "Lines",
    ROUND(SUM(t.net_seconds) / 60.0, 2) AS "Net Min",
    ROUND(SUM(COALESCE(la.units, 0))::numeric / NULLIF(SUM(t.net_seconds) / 60.0, 0), 2) AS "Units per Min"
FROM tray_base t
LEFT JOIN line_agg la ON la.group_picklist_number = t.group_picklist_number
GROUP BY t.device_id
ORDER BY "Units Completed" DESC;
SQL
    echo
} >> "$OUT"

echo "Wrote $OUT"
