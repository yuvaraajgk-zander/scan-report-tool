#!/bin/bash
# Scan Report CSV — standalone, no Node/HTTP server needed. Runs the same
# queries as scanner_report.sh and daily_gp_report.sh directly through
# `docker exec ... psql --csv`, and writes one combined CSV file. Copy this
# one file to any branch server and run it there.
#
# Usage:
#   ./scan_report_csv.sh                       -> today, schema radachnalp01
#   ./scan_report_csv.sh 13-08-2026            -> that date (DD-MM-YYYY)
#   SCHEMA=other_tenant ./scan_report_csv.sh   -> override schema
#   CONTAINER=other_pg ./scan_report_csv.sh    -> override container name
#
# Writes scan-report-<date>.csv in the current directory. That file is then
# opened directly in scan-report-tool/public/index.html (no server needed
# there either) via its "Open CSV" picker, where every value is editable
# before exporting a PDF.
#
# Requires PostgreSQL 12+ for `psql --csv` (this box runs 17, confirmed OK).
set -euo pipefail

CONTAINER="${CONTAINER:-zander-postgres}"
SCHEMA="${SCHEMA:-radachnalp01}"
PGUSER=$(docker exec "$CONTAINER" printenv POSTGRES_USER)
PGDB=$(docker exec "$CONTAINER" printenv POSTGRES_DB)

if [ -z "${1:-}" ]; then
    VDT=$(date +%F)
    DISPLAY_DATE=$(date +%d-%m-%Y)
else
    if [[ ! "$1" =~ ^[0-9]{2}-[0-9]{2}-[0-9]{4}$ ]]; then
        echo "Date must be DD-MM-YYYY, e.g. 13-08-2026" >&2
        exit 1
    fi
    DD="${1:0:2}"; MM="${1:3:2}"; YYYY="${1:6:4}"
    VDT="${YYYY}-${MM}-${DD}"
    DISPLAY_DATE="$1"
fi

OUT="scan-report-${VDT}.csv"

run_csv() {
    docker exec -i "$CONTAINER" psql -U "$PGUSER" -d "$PGDB" -q --csv
}

# A row's scan time as "1h 38m 49s" / "5m 20s" / "45s" - hours and minutes
# only appear when non-zero, matching how the report tool's UI formats it.
# Repeated inline (not a stored function) so this script makes no schema
# changes to whatever database it's pointed at.
CLOCK_CASE() {
    local col="$1"
    echo "CASE WHEN $col/3600 > 0 THEN ($col/3600)::text||'h '||(($col%3600)/60)::text||'m '||($col%60)::text||'s'
          WHEN ($col%3600)/60 > 0 THEN (($col%3600)/60)::text||'m '||($col%60)::text||'s'
          ELSE ($col%60)::text||'s' END"
}

{
    echo "SECTION,META"
    echo "key,value"
    echo "reportDate,${DISPLAY_DATE}"
    echo "schema,${SCHEMA}"
    echo
} > "$OUT"

{
    echo "SECTION,SUMMARY"
    run_csv <<SQL
SET search_path TO $SCHEMA;
WITH target_groups AS (
    SELECT group_picklist_number, status
    FROM tbl_pick_list_group
    WHERE v_dt = '$VDT' AND status IN ('ASSIGNED', 'CHECKED', 'COMPLETED')
),
line_stats AS (
    SELECT group_picklist_number, COUNT(*) AS line_items, SUM(quantity) AS total_quantity
    FROM tbl_invoice_line_item
    WHERE group_picklist_number IN (SELECT group_picklist_number FROM target_groups)
    GROUP BY group_picklist_number
),
time_stats AS (
    SELECT group_picklist_number, status,
           EXTRACT(EPOCH FROM (end_time - start_time))::bigint AS total_duration_seconds,
           GREATEST(EXTRACT(EPOCH FROM (end_time - start_time))::bigint - COALESCE(idle_time_seconds, 0), 0) AS idle_adjusted_seconds
    FROM tbl_pick_list_group
    WHERE group_picklist_number IN (SELECT group_picklist_number FROM target_groups)
),
-- If the idle-time-adjusted duration makes this picklist's rate implausibly
-- high (idle_time_seconds is likely bad/missing for that row), fall back to
-- the raw, un-adjusted duration instead of trusting the subtraction.
combined AS (
    SELECT l.group_picklist_number, l.line_items, l.total_quantity,
           CASE
             WHEN t.idle_adjusted_seconds > 0
                  AND (
                    l.total_quantity::numeric / (t.idle_adjusted_seconds::numeric / 60.0) > 150
                    OR l.line_items::numeric / (t.idle_adjusted_seconds::numeric / 60.0) > 40
                  )
             THEN t.total_duration_seconds
             ELSE t.idle_adjusted_seconds
           END AS scan_seconds
    FROM line_stats l JOIN time_stats t USING (group_picklist_number)
    WHERE t.status = 'COMPLETED'
),
rates AS (
    SELECT group_picklist_number, line_items, total_quantity, scan_seconds,
           CASE WHEN scan_seconds > 0 THEN ROUND(line_items::numeric / (scan_seconds::numeric / 60.0), 2) ELSE 0 END AS items_per_min,
           CASE WHEN scan_seconds > 0 THEN ROUND(total_quantity::numeric / (scan_seconds::numeric / 60.0), 2) ELSE 0 END AS units_per_min
    FROM combined
),
agg AS (
    SELECT COUNT(*) AS picklists,
           COALESCE(SUM(line_items), 0) AS line_items,
           COALESCE(SUM(total_quantity), 0) AS total_units,
           COALESCE(SUM(scan_seconds), 0)::bigint AS total_scan_seconds,
           COALESCE(MAX(items_per_min), 0) AS highest_items_per_min,
           COALESCE(MAX(units_per_min), 0) AS highest_units_per_min
    FROM rates
)
SELECT 'totalUnits' AS key, total_units::text AS value FROM agg
UNION ALL SELECT 'picklists', picklists::text FROM agg
UNION ALL SELECT 'lineItems', line_items::text FROM agg
UNION ALL SELECT 'unitsPerMin', CASE WHEN total_scan_seconds > 0 THEN ROUND(total_units::numeric / (total_scan_seconds::numeric / 60.0), 2)::text ELSE '0' END FROM agg
UNION ALL SELECT 'itemsPerMin', CASE WHEN total_scan_seconds > 0 THEN ROUND(line_items::numeric / (total_scan_seconds::numeric / 60.0), 2)::text ELSE '0' END FROM agg
UNION ALL SELECT 'activeScanTime', $(CLOCK_CASE total_scan_seconds) FROM agg
UNION ALL SELECT 'highestItemsPerMin', highest_items_per_min::text FROM agg
UNION ALL SELECT 'highestUnitsPerMin', highest_units_per_min::text FROM agg;
SQL
    echo
} >> "$OUT"

{
    echo "SECTION,PICKLIST_DETAILS"
    run_csv <<SQL
SET search_path TO $SCHEMA;
WITH target_groups AS (
    SELECT group_picklist_number, status
    FROM tbl_pick_list_group
    WHERE v_dt = '$VDT' AND status IN ('ASSIGNED', 'CHECKED', 'COMPLETED')
),
line_stats AS (
    SELECT group_picklist_number, COUNT(*) AS line_items, SUM(quantity) AS total_quantity
    FROM tbl_invoice_line_item
    WHERE group_picklist_number IN (SELECT group_picklist_number FROM target_groups)
    GROUP BY group_picklist_number
),
time_stats AS (
    SELECT group_picklist_number, status,
           EXTRACT(EPOCH FROM (end_time - start_time))::bigint AS total_duration_seconds,
           GREATEST(EXTRACT(EPOCH FROM (end_time - start_time))::bigint - COALESCE(idle_time_seconds, 0), 0) AS idle_adjusted_seconds
    FROM tbl_pick_list_group
    WHERE group_picklist_number IN (SELECT group_picklist_number FROM target_groups)
),
-- If the idle-time-adjusted duration makes this picklist's rate implausibly
-- high (idle_time_seconds is likely bad/missing for that row), fall back to
-- the raw, un-adjusted duration instead of trusting the subtraction. This
-- becomes the row's effective scan time for both the "Scan Time" column and
-- the /min rates, so they always agree with each other.
combined AS (
    SELECT l.group_picklist_number, l.line_items, l.total_quantity,
           CASE
             WHEN t.idle_adjusted_seconds > 0
                  AND (
                    l.total_quantity::numeric / (t.idle_adjusted_seconds::numeric / 60.0) > 150
                    OR l.line_items::numeric / (t.idle_adjusted_seconds::numeric / 60.0) > 40
                  )
             THEN t.total_duration_seconds
             ELSE t.idle_adjusted_seconds
           END AS scan_seconds
    FROM line_stats l JOIN time_stats t USING (group_picklist_number)
    WHERE t.status = 'COMPLETED'
)
SELECT
    ROW_NUMBER() OVER (ORDER BY group_picklist_number) AS "#",
    group_picklist_number AS "Picklist Number",
    line_items AS "Line items",
    total_quantity AS "Total Unit",
    $(CLOCK_CASE scan_seconds) AS "Scan Time",
    CASE WHEN scan_seconds > 0 THEN ROUND(line_items::numeric / (scan_seconds::numeric / 60.0), 2) ELSE 0 END AS "Line item/ Min",
    CASE WHEN scan_seconds > 0 THEN ROUND(total_quantity::numeric / (scan_seconds::numeric / 60.0), 2) ELSE 0 END AS "units/ min"
FROM combined
ORDER BY group_picklist_number;
SQL
    echo
} >> "$OUT"

{
    echo "SECTION,SCANNER_METRICS"
    run_csv <<SQL
SET search_path TO $SCHEMA;
WITH tray_agg AS (
    SELECT g.group_picklist_number, g.device_id, g.scanned_by,
           EXTRACT(EPOCH FROM (g.end_time - g.start_time))::BIGINT AS duration_seconds,
           COALESCE(g.idle_time_seconds, 0) AS idle_time_seconds
    FROM tbl_pick_list_group g
    WHERE g.v_dt = '$VDT' AND g.device_id IS NOT NULL
          AND g.status IN ('ASSIGNED', 'CHECKED', 'COMPLETED', 'INVOICED')
),
line_item_agg AS (
    SELECT inv.group_picklist_number,
           COUNT(li.invoice_line_item_id)::INT AS line_items,
           SUM(li.quantity)::INT AS total_quantity
    FROM tbl_invoice inv
    JOIN tray_agg t ON t.group_picklist_number = inv.group_picklist_number
    LEFT JOIN tbl_invoice_line_item li ON li.transno = inv.invoice_number
    GROUP BY inv.group_picklist_number
),
agg AS (
    SELECT t.device_id,
           COALESCE(d.device_name, t.device_id) AS device_name,
           COALESCE(TRIM(CONCAT(u.first_name, ' ', u.last_name)), t.scanned_by) AS checker_name,
           SUM(COALESCE(la.line_items, 0))::int AS total_line_items,
           SUM(COALESCE(la.total_quantity, 0))::int AS total_quantity,
           COALESCE(SUM(t.duration_seconds), 0)::bigint AS raw_duration_seconds,
           GREATEST(COALESCE(SUM(t.duration_seconds), 0) - COALESCE(SUM(t.idle_time_seconds), 0), 0)::bigint AS idle_adjusted_seconds
    FROM tray_agg t
    LEFT JOIN line_item_agg la ON la.group_picklist_number = t.group_picklist_number
    LEFT JOIN tbl_device d ON d.device_id = t.device_id
    LEFT JOIN tbl_user u ON u.user_id = t.scanned_by
    GROUP BY t.device_id, d.device_name, t.scanned_by, u.first_name, u.last_name
),
-- If the idle-time-adjusted duration makes this scanner's rate implausibly
-- high (idle_time_seconds is likely bad/missing for that data), fall back
-- to the raw, un-adjusted duration instead of trusting the subtraction.
corrected AS (
    SELECT device_id, device_name, checker_name, total_line_items, total_quantity,
           CASE
             WHEN idle_adjusted_seconds > 0
                  AND (
                    total_quantity::numeric / (idle_adjusted_seconds::numeric / 60.0) > 150
                    OR total_line_items::numeric / (idle_adjusted_seconds::numeric / 60.0) > 40
                  )
             THEN raw_duration_seconds
             ELSE idle_adjusted_seconds
           END AS net_duration_seconds
    FROM agg
)
SELECT
    ROW_NUMBER() OVER (ORDER BY device_id, total_line_items DESC) AS "#",
    device_name AS "Scanner name",
    checker_name AS "Checker name",
    total_quantity AS "Total Units",
    total_line_items AS "Line Items",
    $(CLOCK_CASE net_duration_seconds) AS "Scan Time",
    CASE WHEN net_duration_seconds > 0 THEN ROUND(total_quantity::numeric / (net_duration_seconds::numeric / 60.0), 2) ELSE 0 END AS "Units / Min",
    CASE WHEN net_duration_seconds > 0 THEN ROUND(total_line_items::numeric / (net_duration_seconds::numeric / 60.0), 2) ELSE 0 END AS "Line Items / Min"
FROM corrected
ORDER BY device_id, total_line_items DESC;
SQL
    echo
} >> "$OUT"

{
    echo "SECTION,COVERAGE"
    run_csv <<SQL
SET search_path TO $SCHEMA;
WITH target_groups AS (
    SELECT group_picklist_number, status
    FROM tbl_pick_list_group
    WHERE v_dt = '$VDT' AND status IN ('ASSIGNED', 'CHECKED', 'COMPLETED', 'INVOICED')
),
line_stats AS (
    SELECT tg.status, COUNT(li.*) AS line_items, SUM(li.quantity) AS total_quantity
    FROM target_groups tg
    JOIN tbl_invoice_line_item li ON li.group_picklist_number = tg.group_picklist_number
    GROUP BY tg.status
),
group_counts AS (
    SELECT COUNT(*) AS picklists_assigned,
           COUNT(*) FILTER (WHERE status = 'COMPLETED') AS picklists_completed
    FROM target_groups
),
agg AS (
    SELECT
        gc.picklists_assigned, gc.picklists_completed,
        COALESCE(SUM(ls.line_items), 0) AS lines_assigned,
        COALESCE(SUM(ls.line_items) FILTER (WHERE ls.status = 'COMPLETED'), 0) AS lines_completed,
        COALESCE(SUM(ls.total_quantity), 0) AS units_assigned,
        COALESCE(SUM(ls.total_quantity) FILTER (WHERE ls.status = 'COMPLETED'), 0) AS units_completed
    FROM line_stats ls, group_counts gc
    GROUP BY gc.picklists_assigned, gc.picklists_completed
)
SELECT 'totalLinesAssigned' AS key, lines_assigned::text AS value FROM agg
UNION ALL SELECT 'linesCompleted', lines_completed::text FROM agg
UNION ALL SELECT 'remainingLines', (lines_assigned - lines_completed)::text FROM agg
UNION ALL SELECT 'lineCoveragePct', CASE WHEN lines_assigned > 0 THEN ROUND((lines_completed::numeric / lines_assigned) * 100, 1)::text ELSE '0' END FROM agg
UNION ALL SELECT 'totalUnitsAssigned', units_assigned::text FROM agg
UNION ALL SELECT 'unitsCompleted', units_completed::text FROM agg
UNION ALL SELECT 'remainingUnits', (units_assigned - units_completed)::text FROM agg
UNION ALL SELECT 'unitCoveragePct', CASE WHEN units_assigned > 0 THEN ROUND((units_completed::numeric / units_assigned) * 100, 1)::text ELSE '0' END FROM agg
UNION ALL SELECT 'picklistsAssigned', picklists_assigned::text FROM agg
UNION ALL SELECT 'picklistsCompleted', picklists_completed::text FROM agg;
SQL
    echo
} >> "$OUT"

{
    echo "SECTION,WORKLOAD"
    run_csv <<SQL
SET search_path TO $SCHEMA;
WITH target_groups AS (
    SELECT group_picklist_number, status
    FROM tbl_pick_list_group
    WHERE v_dt = '$VDT' AND status IN ('ASSIGNED', 'CHECKED', 'COMPLETED')
),
line_stats AS (
    SELECT group_picklist_number, COUNT(*) AS line_items, SUM(quantity) AS total_quantity
    FROM tbl_invoice_line_item
    WHERE group_picklist_number IN (SELECT group_picklist_number FROM target_groups)
    GROUP BY group_picklist_number
),
combined AS (
    SELECT l.group_picklist_number, l.line_items, l.total_quantity
    FROM line_stats l
    JOIN target_groups t USING (group_picklist_number)
    WHERE t.status = 'COMPLETED'
),
largest AS (SELECT group_picklist_number, total_quantity FROM combined ORDER BY total_quantity DESC LIMIT 1),
most_lines AS (SELECT group_picklist_number, line_items FROM combined ORDER BY line_items DESC LIMIT 1)
SELECT 'largestPicklistNumber' AS key, group_picklist_number::text AS value FROM largest
UNION ALL SELECT 'largestPicklistUnits', total_quantity::text FROM largest
UNION ALL SELECT 'mostLineItemsPicklistNumber', group_picklist_number::text FROM most_lines
UNION ALL SELECT 'mostLineItemsCount', line_items::text FROM most_lines;
SQL
} >> "$OUT"

echo "Wrote $OUT"
