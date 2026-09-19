#!/bin/bash
# Weekly Scan Report CSV — standalone, no Node/HTTP server needed. Sibling
# to scan_report_csv.sh (daily); same container/schema conventions, same
# "SECTION,<name>" CSV format, same idle-time scan-time correction rule.
#
# "Weekly" = the 7 calendar days ending on the given date. Whatever subset
# of those actually has data becomes "operational days" - no assumption
# about which day(s) a branch is closed.
#
# Every section that depends on branch size (station chart, split ranked
# tables, bench tiers) is driven by the REAL counts this branch has, not a
# fixed assumption - a 3-scanner branch and a 50-scanner branch both get a
# report shaped to what they actually have, never a broken/empty section.
#
# Usage:
#   ./scan_report_weekly_csv.sh                       -> week ending today
#   ./scan_report_weekly_csv.sh 08-08-2026            -> week ending that date
#   SCHEMA=other_tenant ./scan_report_weekly_csv.sh   -> override schema
#   CONTAINER=other_pg ./scan_report_weekly_csv.sh    -> override container
#
# Writes scan-report-weekly-<start>-to-<end>.csv in the current directory.
# Requires PostgreSQL 12+ for `psql --csv`.
set -euo pipefail

CONTAINER="${CONTAINER:-zander-postgres}"
SCHEMA="${SCHEMA:-radachnalp01}"
PGUSER=$(docker exec "$CONTAINER" printenv POSTGRES_USER)
PGDB=$(docker exec "$CONTAINER" printenv POSTGRES_DB)

if [ -z "${1:-}" ]; then
    VDT_END=$(date +%F)
    DISPLAY_DATE_END=$(date +%d-%m-%Y)
else
    if [[ ! "$1" =~ ^[0-9]{2}-[0-9]{2}-[0-9]{4}$ ]]; then
        echo "Date must be DD-MM-YYYY, e.g. 08-08-2026" >&2
        exit 1
    fi
    DD="${1:0:2}"; MM="${1:3:2}"; YYYY="${1:6:4}"
    VDT_END="${YYYY}-${MM}-${DD}"
    DISPLAY_DATE_END="$1"
fi

# Portable "6 days before" - GNU date (Linux branch servers) and BSD date
# (macOS dev machines) take this differently.
if date -d "$VDT_END - 6 days" +%F >/dev/null 2>&1; then
    VDT_START=$(date -d "$VDT_END - 6 days" +%F)
else
    VDT_START=$(date -j -v-6d -f "%Y-%m-%d" "$VDT_END" +%F)
fi

OUT="scan-report-weekly-${VDT_START}-to-${VDT_END}.csv"

run_csv() {
    docker exec -i "$CONTAINER" psql -U "$PGUSER" -d "$PGDB" -q --csv
}
run_scalar() {
    docker exec -i "$CONTAINER" psql -U "$PGUSER" -d "$PGDB" -q -t -A -F','
}

CLOCK_CASE() {
    local col="$1"
    echo "CASE WHEN $col/3600 > 0 THEN ($col/3600)::text||'h '||(($col%3600)/60)::text||'m '||($col%60)::text||'s'
          WHEN ($col%3600)/60 > 0 THEN (($col%3600)/60)::text||'m '||($col%60)::text||'s'
          ELSE ($col%60)::text||'s' END"
}

# One shared correction rule, referenced inline everywhere: if the idle-
# adjusted rate looks implausible (idle_time_seconds likely bad/missing for
# that data), fall back to raw duration instead of trusting the subtraction.
CORRECTED_SECS() {
    local lines="$1" units="$2" idle_adj="$3" raw="$4"
    echo "CASE WHEN $idle_adj > 0 AND ($units::numeric/($idle_adj::numeric/60) > 150 OR $lines::numeric/($idle_adj::numeric/60) > 40)
          THEN $raw ELSE $idle_adj END"
}

# Real counts up front, driving every size-adaptive decision below.
COUNTS=$(docker exec -i "$CONTAINER" psql -U "$PGUSER" -d "$PGDB" -q -t -A -F',' <<SQL
SET search_path TO $SCHEMA;
WITH week_groups AS (
    SELECT DISTINCT v_dt, device_id, scanned_by
    FROM tbl_pick_list_group
    WHERE v_dt BETWEEN '$VDT_START' AND '$VDT_END' AND status = 'COMPLETED'
)
SELECT COUNT(DISTINCT v_dt), COUNT(DISTINCT device_id), COUNT(DISTINCT scanned_by) FROM week_groups;
SQL
)
IFS=',' read -r OPERATIONAL_DAYS SCANNER_COUNT CHECKER_COUNT <<< "$COUNTS"

echo "Week: $VDT_START to $VDT_END - $OPERATIONAL_DAYS operational day(s), $SCANNER_COUNT scanner(s), $CHECKER_COUNT checker(s)"

{
    echo "SECTION,META"
    echo "key,value"
    echo "reportDate,${DISPLAY_DATE_END}"
    echo "schema,${SCHEMA}"
    echo "weekStart,${VDT_START}"
    echo "weekEnd,${VDT_END}"
    echo
} > "$OUT"

{
    echo "SECTION,SUMMARY"
    run_csv <<SQL
SET search_path TO $SCHEMA;
WITH target_groups AS (
    SELECT group_picklist_number, status
    FROM tbl_pick_list_group
    WHERE v_dt BETWEEN '$VDT_START' AND '$VDT_END' AND status IN ('ASSIGNED', 'CHECKED', 'COMPLETED')
),
line_stats AS (
    SELECT group_picklist_number, COUNT(*) AS line_items, SUM(quantity) AS total_quantity,
           SUM(quantity * NULLIF(mrp, '')::numeric) AS mrp_value
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
combined AS (
    SELECT l.group_picklist_number, l.line_items, l.total_quantity, l.mrp_value, t.status,
           $(CORRECTED_SECS l.line_items l.total_quantity t.idle_adjusted_seconds t.total_duration_seconds) AS scan_seconds
    FROM line_stats l JOIN time_stats t USING (group_picklist_number)
),
completed AS (SELECT * FROM combined WHERE status = 'COMPLETED'),
rates AS (
    SELECT group_picklist_number, line_items, total_quantity,
           CASE WHEN scan_seconds > 0 THEN ROUND(line_items::numeric / (scan_seconds::numeric / 60.0), 2) ELSE 0 END AS items_per_min,
           CASE WHEN scan_seconds > 0 THEN ROUND(total_quantity::numeric / (scan_seconds::numeric / 60.0), 2) ELSE 0 END AS units_per_min
    FROM completed
),
totals AS (
    SELECT COUNT(*) AS trays, COALESCE(SUM(line_items), 0) AS lines, COALESCE(SUM(total_quantity), 0) AS units,
           COALESCE(SUM(mrp_value), 0) AS mrp
    FROM completed
),
best_items AS (SELECT items_per_min FROM rates ORDER BY items_per_min DESC LIMIT 1),
best_items_pl AS (SELECT group_picklist_number FROM rates ORDER BY items_per_min DESC LIMIT 1),
best_units AS (SELECT units_per_min FROM rates ORDER BY units_per_min DESC LIMIT 1),
best_units_pl AS (SELECT group_picklist_number FROM rates ORDER BY units_per_min DESC LIMIT 1),
window_row AS (
    SELECT
        to_char(percentile_cont(0.05) WITHIN GROUP (ORDER BY start_time::time), 'HH24:MI') AS open_time,
        to_char(percentile_cont(0.95) WITHIN GROUP (ORDER BY end_time::time), 'HH24:MI') AS close_time
    FROM tbl_pick_list_group
    WHERE v_dt BETWEEN '$VDT_START' AND '$VDT_END' AND status = 'COMPLETED'
),
day_checkers AS (
    SELECT v_dt, COUNT(DISTINCT scanned_by) AS checkers
    FROM tbl_pick_list_group
    WHERE v_dt BETWEEN '$VDT_START' AND '$VDT_END' AND status = 'COMPLETED'
    GROUP BY v_dt
)
SELECT 'operationalDays' AS key, '$OPERATIONAL_DAYS' AS value
UNION ALL SELECT 'totalLines', lines::text FROM totals
UNION ALL SELECT 'totalUnits', units::text FROM totals
UNION ALL SELECT 'totalTrays', trays::text FROM totals
UNION ALL SELECT 'totalMrp', ROUND(mrp,0)::text FROM totals
UNION ALL SELECT 'avgLinesPerDay', CASE WHEN $OPERATIONAL_DAYS>0 THEN ROUND(lines::numeric/$OPERATIONAL_DAYS,0)::text ELSE '0' END FROM totals
UNION ALL SELECT 'avgUnitsPerDay', CASE WHEN $OPERATIONAL_DAYS>0 THEN ROUND(units::numeric/$OPERATIONAL_DAYS,0)::text ELSE '0' END FROM totals
UNION ALL SELECT 'avgLinesPerTray', CASE WHEN trays>0 THEN ROUND(lines::numeric/trays,0)::text ELSE '0' END FROM totals
UNION ALL SELECT 'avgUnitsPerTray', CASE WHEN trays>0 THEN ROUND(units::numeric/trays,0)::text ELSE '0' END FROM totals
UNION ALL SELECT 'avgCheckersPerDay', COALESCE((SELECT ROUND(AVG(checkers),0)::text FROM day_checkers),'0')
UNION ALL SELECT 'activeScanners', '$SCANNER_COUNT'
UNION ALL SELECT 'highestItemsPerMin', COALESCE((SELECT items_per_min FROM best_items),0)::text
UNION ALL SELECT 'highestUnitsPerMin', COALESCE((SELECT units_per_min FROM best_units),0)::text
UNION ALL SELECT 'highestItemsPicklist', COALESCE((SELECT group_picklist_number FROM best_items_pl),'')
UNION ALL SELECT 'highestUnitsPicklist', COALESCE((SELECT group_picklist_number FROM best_units_pl),'')
UNION ALL SELECT 'operatingWindowOpen', COALESCE((SELECT open_time FROM window_row),'')
UNION ALL SELECT 'operatingWindowClose', COALESCE((SELECT close_time FROM window_row),'');
SQL
    echo
} >> "$OUT"

{
    echo "SECTION,HIGHEST_DAY"
    echo "key,value"
    run_scalar <<SQL | { IFS=',' read -r D T L U C M; echo "date,${D}"; echo "trays,${T}"; echo "lines,${L}"; echo "units,${U}"; echo "checkers,${C}"; echo "mrp,${M}"; }
SET search_path TO $SCHEMA;
WITH week_groups AS (
    SELECT group_picklist_number, v_dt, scanned_by
    FROM tbl_pick_list_group
    WHERE v_dt BETWEEN '$VDT_START' AND '$VDT_END' AND status = 'COMPLETED'
),
line_stats AS (
    SELECT group_picklist_number, COUNT(*) AS line_items, SUM(quantity) AS qty,
           SUM(quantity * NULLIF(mrp, '')::numeric) AS mrp_value
    FROM tbl_invoice_line_item
    WHERE group_picklist_number IN (SELECT group_picklist_number FROM week_groups)
    GROUP BY group_picklist_number
)
SELECT wg.v_dt, COUNT(*), SUM(ls.line_items), SUM(ls.qty), COUNT(DISTINCT wg.scanned_by), ROUND(COALESCE(SUM(ls.mrp_value),0),2)
FROM week_groups wg JOIN line_stats ls USING (group_picklist_number)
GROUP BY wg.v_dt
ORDER BY SUM(ls.line_items) DESC LIMIT 1;
SQL
    echo
} >> "$OUT"

{
    echo "SECTION,DAYS_RANKED"
    run_csv <<SQL
SET search_path TO $SCHEMA;
WITH week_groups AS (
    SELECT group_picklist_number, v_dt, scanned_by
    FROM tbl_pick_list_group
    WHERE v_dt BETWEEN '$VDT_START' AND '$VDT_END' AND status = 'COMPLETED'
),
line_stats AS (
    SELECT group_picklist_number, COUNT(*) AS line_items, SUM(quantity) AS qty,
           SUM(quantity * NULLIF(mrp, '')::numeric) AS mrp_value
    FROM tbl_invoice_line_item
    WHERE group_picklist_number IN (SELECT group_picklist_number FROM week_groups)
    GROUP BY group_picklist_number
)
SELECT wg.v_dt AS "Date", COUNT(*) AS "Trays", SUM(ls.line_items) AS "Lines", SUM(ls.qty) AS "Units",
       COUNT(DISTINCT wg.scanned_by) AS "Checkers", ROUND(COALESCE(SUM(ls.mrp_value),0),2) AS "MRP"
FROM week_groups wg JOIN line_stats ls USING (group_picklist_number)
GROUP BY wg.v_dt
ORDER BY SUM(ls.line_items) DESC;
SQL
    echo
} >> "$OUT"

{
    echo "SECTION,SCANNERS"
    run_csv <<SQL
SET search_path TO $SCHEMA;
WITH week_groups AS (
    SELECT group_picklist_number, v_dt, device_id, scanned_by,
           EXTRACT(EPOCH FROM (end_time - start_time))::bigint AS dur,
           COALESCE(idle_time_seconds, 0) AS idle
    FROM tbl_pick_list_group
    WHERE v_dt BETWEEN '$VDT_START' AND '$VDT_END' AND status = 'COMPLETED' AND device_id IS NOT NULL
),
line_stats AS (
    SELECT group_picklist_number, COUNT(*) AS line_items, SUM(quantity) AS qty,
           SUM(quantity * NULLIF(mrp, '')::numeric) AS mrp_value
    FROM tbl_invoice_line_item
    WHERE group_picklist_number IN (SELECT group_picklist_number FROM week_groups)
    GROUP BY group_picklist_number
),
per_day AS (
    SELECT wg.device_id, wg.v_dt, SUM(ls.line_items) AS lines, SUM(ls.qty) AS units,
           GREATEST(SUM(wg.dur) - SUM(wg.idle), 0)::bigint AS idle_adj, SUM(wg.dur)::bigint AS raw_dur
    FROM week_groups wg JOIN line_stats ls USING (group_picklist_number)
    GROUP BY wg.device_id, wg.v_dt
),
per_day_rate AS (
    SELECT device_id, v_dt, lines, units,
           $(CORRECTED_SECS lines units idle_adj raw_dur) AS secs
    FROM per_day
),
peak AS (
    SELECT device_id,
      MAX(CASE WHEN secs > 0 THEN ROUND(lines::numeric / (secs::numeric / 60), 2) ELSE 0 END) AS peak_items,
      MAX(CASE WHEN secs > 0 THEN ROUND(units::numeric / (secs::numeric / 60), 2) ELSE 0 END) AS peak_units
    FROM per_day_rate GROUP BY device_id
),
week_agg AS (
    SELECT wg.device_id, COALESCE(d.device_name, wg.device_id) AS device_name,
           SUM(ls.line_items) AS lines, SUM(ls.qty) AS units, COALESCE(SUM(ls.mrp_value), 0) AS mrp,
           GREATEST(SUM(wg.dur) - SUM(wg.idle), 0)::bigint AS idle_adj, SUM(wg.dur)::bigint AS raw_dur,
           STRING_AGG(DISTINCT COALESCE(TRIM(CONCAT(u.first_name, ' ', u.last_name)), wg.scanned_by), ', '
                      ORDER BY COALESCE(TRIM(CONCAT(u.first_name, ' ', u.last_name)), wg.scanned_by)) AS checkers
    FROM week_groups wg JOIN line_stats ls USING (group_picklist_number)
    LEFT JOIN tbl_device d ON d.device_id = wg.device_id
    LEFT JOIN tbl_user u ON u.user_id = wg.scanned_by
    GROUP BY wg.device_id, d.device_name
),
avg_rate AS (
    SELECT device_id, device_name, lines, units, mrp, checkers,
           $(CORRECTED_SECS lines units idle_adj raw_dur) AS secs
    FROM week_agg
)
SELECT a.device_name AS "Scanner name", a.checkers AS "Checkers operated", a.lines AS "Lines", a.units AS "Units",
       CASE WHEN a.secs > 0 THEN ROUND(a.lines::numeric / (a.secs::numeric / 60), 2) ELSE 0 END AS "Avg items/min",
       CASE WHEN a.secs > 0 THEN ROUND(a.units::numeric / (a.secs::numeric / 60), 2) ELSE 0 END AS "Avg units/min",
       p.peak_items AS "Peak items/min", p.peak_units AS "Peak units/min", ROUND(a.mrp,0) AS "MRP"
FROM avg_rate a JOIN peak p USING (device_id)
ORDER BY "Avg items/min" DESC;
SQL
    echo
} >> "$OUT"

{
    echo "SECTION,STATIONS"
    if [ "$SCANNER_COUNT" -ge 5 ]; then
        run_csv <<SQL
SET search_path TO $SCHEMA;
WITH week_groups AS (
    SELECT group_picklist_number, device_id
    FROM tbl_pick_list_group
    WHERE v_dt BETWEEN '$VDT_START' AND '$VDT_END' AND status = 'COMPLETED' AND device_id IS NOT NULL
),
line_stats AS (
    SELECT group_picklist_number, SUM(quantity) AS qty, COUNT(*) AS lines
    FROM tbl_invoice_line_item
    WHERE group_picklist_number IN (SELECT group_picklist_number FROM week_groups)
    GROUP BY group_picklist_number
),
scanner_agg AS (
    SELECT COALESCE(d.device_name, wg.device_id) AS device_name, SUM(ls.qty) AS units, SUM(ls.lines) AS lines
    FROM week_groups wg
    JOIN line_stats ls USING (group_picklist_number)
    LEFT JOIN tbl_device d ON d.device_id = wg.device_id
    GROUP BY COALESCE(d.device_name, wg.device_id)
),
numbered AS (
    SELECT (regexp_match(device_name, '(\d+)\$'))[1]::int AS scanner_no, units, lines
    FROM scanner_agg
)
SELECT CEIL(scanner_no::numeric / 5)::int AS "Station", SUM(lines) AS "Lines", SUM(units) AS "Units"
FROM numbered GROUP BY "Station" ORDER BY "Station";
SQL
    else
        echo "Station,Lines,Units"
    fi
    echo
} >> "$OUT"

{
    echo "SECTION,TOP_PICKLISTS"
    run_csv <<SQL
SET search_path TO $SCHEMA;
WITH target_groups AS (
    SELECT group_picklist_number, status
    FROM tbl_pick_list_group
    WHERE v_dt BETWEEN '$VDT_START' AND '$VDT_END' AND status IN ('ASSIGNED', 'CHECKED', 'COMPLETED')
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
combined AS (
    SELECT l.group_picklist_number, l.line_items, l.total_quantity, t.status,
           $(CORRECTED_SECS l.line_items l.total_quantity t.idle_adjusted_seconds t.total_duration_seconds) AS scan_seconds
    FROM line_stats l JOIN time_stats t USING (group_picklist_number)
),
rates AS (
    SELECT group_picklist_number, line_items, total_quantity,
           CASE WHEN scan_seconds > 0 THEN ROUND(line_items::numeric / (scan_seconds::numeric / 60.0), 2) ELSE 0 END AS items_per_min,
           CASE WHEN scan_seconds > 0 THEN ROUND(total_quantity::numeric / (scan_seconds::numeric / 60.0), 2) ELSE 0 END AS units_per_min
    FROM combined WHERE status = 'COMPLETED'
),
maxes AS (
    SELECT GREATEST(MAX(line_items), 1) AS max_lines,
           GREATEST(MAX(items_per_min), 1) AS max_items_per_min,
           GREATEST(MAX(units_per_min), 1) AS max_units_per_min
    FROM rates
)
SELECT r.group_picklist_number AS "Picklist", r.line_items AS "Lines", r.total_quantity AS "Units",
       r.items_per_min AS "Items/min", r.units_per_min AS "Units/min",
       ROUND((((r.line_items::numeric / m.max_lines) + (r.items_per_min / m.max_items_per_min) + (r.units_per_min / m.max_units_per_min)) / 3) * 100, 1) AS "Score"
FROM rates r, maxes m
ORDER BY "Score" DESC
LIMIT 10;
SQL
    echo
} >> "$OUT"

{
    echo "SECTION,TOP_LINES_DAYS"
    run_csv <<SQL
SET search_path TO $SCHEMA;
WITH week_groups AS (
    SELECT group_picklist_number, v_dt, scanned_by
    FROM tbl_pick_list_group
    WHERE v_dt BETWEEN '$VDT_START' AND '$VDT_END' AND status = 'COMPLETED'
),
line_stats AS (
    SELECT group_picklist_number, COUNT(*) AS line_items, SUM(quantity) AS qty
    FROM tbl_invoice_line_item
    WHERE group_picklist_number IN (SELECT group_picklist_number FROM week_groups)
    GROUP BY group_picklist_number
)
SELECT wg.v_dt AS "Date", COALESCE(TRIM(CONCAT(u.first_name, ' ', u.last_name)), wg.scanned_by) AS "Checker",
       SUM(ls.line_items) AS "Lines", SUM(ls.qty) AS "Units"
FROM week_groups wg JOIN line_stats ls USING (group_picklist_number)
LEFT JOIN tbl_user u ON u.user_id = wg.scanned_by
GROUP BY wg.v_dt, wg.scanned_by, u.first_name, u.last_name
ORDER BY SUM(ls.line_items) DESC LIMIT 10;
SQL
    echo
} >> "$OUT"

{
    echo "SECTION,TOP_UNITS_DAYS"
    run_csv <<SQL
SET search_path TO $SCHEMA;
WITH week_groups AS (
    SELECT group_picklist_number, v_dt, scanned_by
    FROM tbl_pick_list_group
    WHERE v_dt BETWEEN '$VDT_START' AND '$VDT_END' AND status = 'COMPLETED'
),
line_stats AS (
    SELECT group_picklist_number, COUNT(*) AS line_items, SUM(quantity) AS qty
    FROM tbl_invoice_line_item
    WHERE group_picklist_number IN (SELECT group_picklist_number FROM week_groups)
    GROUP BY group_picklist_number
)
SELECT wg.v_dt AS "Date", COALESCE(TRIM(CONCAT(u.first_name, ' ', u.last_name)), wg.scanned_by) AS "Checker",
       SUM(ls.line_items) AS "Lines", SUM(ls.qty) AS "Units"
FROM week_groups wg JOIN line_stats ls USING (group_picklist_number)
LEFT JOIN tbl_user u ON u.user_id = wg.scanned_by
GROUP BY wg.v_dt, wg.scanned_by, u.first_name, u.last_name
ORDER BY SUM(ls.qty) DESC LIMIT 10;
SQL
    echo
} >> "$OUT"

# Shared per-checker aggregate (days, lines, units, mrp, corrected active
# scan time + rates) - reused by CHECKER_SUMMARY, BENCH, FASTEST_CHECKERS
# and HIGHEST_VOLUME_CHECKERS so those four sections never disagree.
CHECKER_AGG_CTE="
WITH week_groups AS (
    SELECT group_picklist_number, v_dt, scanned_by,
           EXTRACT(EPOCH FROM (end_time - start_time))::bigint AS dur,
           COALESCE(idle_time_seconds, 0) AS idle
    FROM tbl_pick_list_group
    WHERE v_dt BETWEEN '$VDT_START' AND '$VDT_END' AND status = 'COMPLETED'
),
line_stats AS (
    SELECT group_picklist_number, COUNT(*) AS line_items, SUM(quantity) AS qty,
           SUM(quantity * NULLIF(mrp, '')::numeric) AS mrp_value
    FROM tbl_invoice_line_item
    WHERE group_picklist_number IN (SELECT group_picklist_number FROM week_groups)
    GROUP BY group_picklist_number
),
per_checker AS (
    SELECT wg.scanned_by, COALESCE(TRIM(CONCAT(u.first_name, ' ', u.last_name)), wg.scanned_by) AS checker_name,
           COUNT(DISTINCT wg.v_dt) AS days,
           SUM(ls.line_items) AS lines, SUM(ls.qty) AS units, COALESCE(SUM(ls.mrp_value), 0) AS mrp,
           GREATEST(SUM(wg.dur) - SUM(wg.idle), 0)::bigint AS idle_adj, SUM(wg.dur)::bigint AS raw_dur
    FROM week_groups wg JOIN line_stats ls USING (group_picklist_number)
    LEFT JOIN tbl_user u ON u.user_id = wg.scanned_by
    GROUP BY wg.scanned_by, u.first_name, u.last_name
),
checker_agg AS (
    SELECT checker_name, days, lines, units, mrp,
           $(CORRECTED_SECS lines units idle_adj raw_dur) AS secs
    FROM per_checker
)
"

{
    echo "SECTION,CHECKER_SUMMARY"
    echo "key,value"
    echo "checkersSeen,${CHECKER_COUNT}"
    run_scalar <<SQL | { IFS=',' read -r PRESENT_ALL AVG_L AVG_U; echo "presentAllDays,${PRESENT_ALL}"; echo "avgLinesPerCheckerDay,${AVG_L}"; echo "avgUnitsPerCheckerDay,${AVG_U}"; }
SET search_path TO $SCHEMA;
WITH week_groups AS (
    SELECT group_picklist_number, v_dt, scanned_by
    FROM tbl_pick_list_group
    WHERE v_dt BETWEEN '$VDT_START' AND '$VDT_END' AND status = 'COMPLETED'
),
line_stats AS (
    SELECT group_picklist_number, COUNT(*) AS line_items, SUM(quantity) AS qty
    FROM tbl_invoice_line_item
    WHERE group_picklist_number IN (SELECT group_picklist_number FROM week_groups)
    GROUP BY group_picklist_number
),
per_day AS (
    SELECT wg.scanned_by, wg.v_dt, SUM(ls.line_items) AS lines, SUM(ls.qty) AS units
    FROM week_groups wg JOIN line_stats ls USING (group_picklist_number)
    GROUP BY wg.scanned_by, wg.v_dt
),
per_checker_days AS (
    SELECT scanned_by, COUNT(DISTINCT v_dt) AS days FROM per_day GROUP BY scanned_by
)
SELECT (SELECT COUNT(DISTINCT scanned_by) FROM per_checker_days WHERE days = $OPERATIONAL_DAYS),
       COALESCE(ROUND(AVG(pd.lines),0),0), COALESCE(ROUND(AVG(pd.units),0),0)
FROM per_day pd;
SQL
    run_scalar <<SQL | { IFS=',' read -r D CN L U; echo "bestLineDayDate,${D}"; echo "bestLineDayChecker,${CN}"; echo "bestLineDayLines,${L}"; }
SET search_path TO $SCHEMA;
WITH week_groups AS (
    SELECT group_picklist_number, v_dt, scanned_by
    FROM tbl_pick_list_group
    WHERE v_dt BETWEEN '$VDT_START' AND '$VDT_END' AND status = 'COMPLETED'
),
line_stats AS (
    SELECT group_picklist_number, COUNT(*) AS line_items, SUM(quantity) AS qty
    FROM tbl_invoice_line_item
    WHERE group_picklist_number IN (SELECT group_picklist_number FROM week_groups)
    GROUP BY group_picklist_number
)
SELECT wg.v_dt, COALESCE(TRIM(CONCAT(u.first_name, ' ', u.last_name)), wg.scanned_by), SUM(ls.line_items), SUM(ls.qty)
FROM week_groups wg JOIN line_stats ls USING (group_picklist_number)
LEFT JOIN tbl_user u ON u.user_id = wg.scanned_by
GROUP BY wg.v_dt, wg.scanned_by, u.first_name, u.last_name
ORDER BY SUM(ls.line_items) DESC LIMIT 1;
SQL
    run_scalar <<SQL | { IFS=',' read -r D CN L U; echo "bestUnitDayDate,${D}"; echo "bestUnitDayChecker,${CN}"; echo "bestUnitDayUnits,${U}"; }
SET search_path TO $SCHEMA;
WITH week_groups AS (
    SELECT group_picklist_number, v_dt, scanned_by
    FROM tbl_pick_list_group
    WHERE v_dt BETWEEN '$VDT_START' AND '$VDT_END' AND status = 'COMPLETED'
),
line_stats AS (
    SELECT group_picklist_number, COUNT(*) AS line_items, SUM(quantity) AS qty
    FROM tbl_invoice_line_item
    WHERE group_picklist_number IN (SELECT group_picklist_number FROM week_groups)
    GROUP BY group_picklist_number
)
SELECT wg.v_dt, COALESCE(TRIM(CONCAT(u.first_name, ' ', u.last_name)), wg.scanned_by), SUM(ls.line_items), SUM(ls.qty)
FROM week_groups wg JOIN line_stats ls USING (group_picklist_number)
LEFT JOIN tbl_user u ON u.user_id = wg.scanned_by
GROUP BY wg.v_dt, wg.scanned_by, u.first_name, u.last_name
ORDER BY SUM(ls.qty) DESC LIMIT 1;
SQL
    echo
} >> "$OUT"

{
    echo "SECTION,BENCH"
    echo "Bench,Total lines,Avg lines/checker/day,Total units,Avg units/checker/day,Share of lines"
    for TIER in 5 10 15 20; do
        if [ "$TIER" -lt "$CHECKER_COUNT" ]; then
            docker exec -i "$CONTAINER" psql -U "$PGUSER" -d "$PGDB" -q -t -A -F',' <<SQL
SET search_path TO $SCHEMA;
$CHECKER_AGG_CTE,
ranked AS (SELECT *, ROUND(lines::numeric/days,0) AS lines_per_day, ROUND(units::numeric/days,0) AS units_per_day,
                  ROW_NUMBER() OVER (ORDER BY lines DESC) AS rn FROM checker_agg)
SELECT 'Top $TIER checkers', SUM(lines), ROUND(AVG(lines_per_day),0),
       SUM(units), ROUND(AVG(units_per_day),0),
       ROUND(SUM(lines)*100.0/NULLIF((SELECT SUM(lines) FROM checker_agg),0),0)::text || '%'
FROM ranked WHERE rn <= $TIER;
SQL
        fi
    done
    docker exec -i "$CONTAINER" psql -U "$PGUSER" -d "$PGDB" -q -t -A -F',' <<SQL
SET search_path TO $SCHEMA;
$CHECKER_AGG_CTE
SELECT 'All checkers', SUM(lines), ROUND(AVG(ROUND(lines::numeric/days,0)),0),
       SUM(units), ROUND(AVG(ROUND(units::numeric/days,0)),0), '100%'
FROM checker_agg;
SQL
    echo
} >> "$OUT"

{
    echo "SECTION,FASTEST_CHECKERS"
    MIN_DAYS=3
    if [ "$OPERATIONAL_DAYS" -lt 3 ]; then MIN_DAYS=$OPERATIONAL_DAYS; fi
    docker exec -i "$CONTAINER" psql -U "$PGUSER" -d "$PGDB" -q --csv <<SQL
SET search_path TO $SCHEMA;
$CHECKER_AGG_CTE
SELECT checker_name AS "Checker", days AS "Days",
       CASE WHEN secs>0 THEN ROUND(lines::numeric/(secs::numeric/60),2) ELSE 0 END AS "Items/min",
       CASE WHEN secs>0 THEN ROUND(units::numeric/(secs::numeric/60),2) ELSE 0 END AS "Units/min"
FROM checker_agg WHERE days >= $MIN_DAYS
ORDER BY "Items/min" DESC;
SQL
    echo
} >> "$OUT"

{
    echo "SECTION,HIGHEST_VOLUME_CHECKERS"
    docker exec -i "$CONTAINER" psql -U "$PGUSER" -d "$PGDB" -q --csv <<SQL
SET search_path TO $SCHEMA;
$CHECKER_AGG_CTE
SELECT checker_name AS "Checker", days AS "Days", lines AS "Lines", units AS "Units",
       ROUND(lines::numeric/days,0) AS "Lines/day", ROUND(mrp,0) AS "MRP",
       $(CLOCK_CASE secs) AS "Active scan time"
FROM checker_agg ORDER BY lines DESC;
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
    WHERE v_dt BETWEEN '$VDT_START' AND '$VDT_END' AND status IN ('ASSIGNED', 'CHECKED', 'COMPLETED', 'INVOICED')
),
line_stats AS (
    SELECT tg.status, COUNT(li.*) AS line_items, SUM(li.quantity) AS total_quantity
    FROM target_groups tg
    JOIN tbl_invoice_line_item li ON li.group_picklist_number = tg.group_picklist_number
    GROUP BY tg.status
),
agg AS (
    SELECT COALESCE(SUM(line_items), 0) AS assigned, COALESCE(SUM(line_items) FILTER (WHERE status='COMPLETED'), 0) AS completed,
           COALESCE(SUM(total_quantity), 0) AS units_assigned, COALESCE(SUM(total_quantity) FILTER (WHERE status='COMPLETED'), 0) AS units_completed
    FROM line_stats
)
SELECT 'totalLinesAssigned' AS key, assigned::text AS value FROM agg
UNION ALL SELECT 'linesCompleted', completed::text FROM agg
UNION ALL SELECT 'lineCoveragePct', CASE WHEN assigned>0 THEN ROUND((completed::numeric/assigned)*100,1)::text ELSE '0' END FROM agg
UNION ALL SELECT 'totalUnitsAssigned', units_assigned::text FROM agg
UNION ALL SELECT 'unitsCompleted', units_completed::text FROM agg
UNION ALL SELECT 'unitCoveragePct', CASE WHEN units_assigned>0 THEN ROUND((units_completed::numeric/units_assigned)*100,1)::text ELSE '0' END FROM agg;
SQL
} >> "$OUT"

echo "Wrote $OUT"
