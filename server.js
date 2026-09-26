// Local dev server for the Scan Report Tool - zero npm dependencies (Node
// core only), so `node server.js` works right after a clone.
//
// Serves index.html/vendor/ as static files, and runs the two report
// scripts on demand for /api/report and /api/report/weekly:
//   scripts/scan_report_csv.sh          (daily)
//   scripts/weekly_report_generator.sh  (weekly)
// Both scripts already take CONTAINER/SCHEMA (and, for the weekly one,
// START_DATE/END_DATE) as env var overrides - this server only ever sets
// those env vars from the request's query string and reads back the CSV
// file the script writes. No script logic is touched or duplicated here.
const http = require('http');
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

const ROOT = __dirname;
const PORT = process.env.PORT || 8080;

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.svg': 'image/svg+xml',
};

function send(res, status, body, contentType) {
  res.writeHead(status, { 'Content-Type': contentType || 'text/plain; charset=utf-8' });
  res.end(body);
}

function sendJson(res, status, obj) {
  send(res, status, JSON.stringify(obj), 'application/json; charset=utf-8');
}

// DD-MM-YYYY (what the toolbar's date field takes) -> YYYY-MM-DD (what both
// scripts expect).
function ddmmyyyyToIso(s) {
  const m = /^(\d{2})-(\d{2})-(\d{4})$/.exec((s || '').trim());
  if (!m) return null;
  return `${m[3]}-${m[2]}-${m[1]}`;
}

function isoMinusDays(iso, days) {
  const d = new Date(`${iso}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() - days);
  return d.toISOString().slice(0, 10);
}

// Runs a script with the given env overrides in a fresh scratch dir (so
// concurrent requests can't clobber each other's output file), waits for it
// to exit, then resolves with the named output file's contents.
function runScript(scriptPath, env, outFileName) {
  return new Promise((resolve, reject) => {
    const cwd = fs.mkdtempSync(path.join(require('os').tmpdir(), 'scan-report-'));
    const child = spawn(scriptPath, [], {
      cwd,
      env: { ...process.env, ...env },
      shell: false,
    });
    let stderr = '';
    child.stderr.on('data', (d) => { stderr += d.toString(); });
    child.on('error', (err) => reject(err));
    child.on('close', (code) => {
      const outPath = path.join(cwd, outFileName);
      if (code !== 0 || !fs.existsSync(outPath)) {
        reject(new Error(stderr.trim() || `Script exited with code ${code}`));
        return;
      }
      fs.readFile(outPath, 'utf8', (err, data) => {
        fs.rm(cwd, { recursive: true, force: true }, () => {});
        if (err) reject(err);
        else resolve(data);
      });
    });
  });
}

function serveStatic(req, res, urlPath) {
  const rel = urlPath === '/' ? '/index.html' : urlPath;
  const filePath = path.join(ROOT, path.normalize(rel).replace(/^(\.\.[/\\])+/, ''));
  if (!filePath.startsWith(ROOT)) { send(res, 403, 'Forbidden'); return; }
  fs.readFile(filePath, (err, data) => {
    if (err) { send(res, 404, 'Not found'); return; }
    send(res, 200, data, MIME[path.extname(filePath)] || 'application/octet-stream');
  });
}

const server = http.createServer(async (req, res) => {
  const u = new URL(req.url, `http://${req.headers.host}`);

  if (u.pathname === '/api/report' || u.pathname === '/api/report/weekly') {
    const container = (u.searchParams.get('container') || '').trim();
    const schema = (u.searchParams.get('schema') || '').trim();
    const dateStr = u.searchParams.get('date') || '';
    const env = {};
    if (container) env.CONTAINER = container;
    if (schema) env.SCHEMA = schema;

    try {
      if (u.pathname === '/api/report') {
        const iso = ddmmyyyyToIso(dateStr) || new Date().toISOString().slice(0, 10);
        const csv = await runScript(
          path.join(ROOT, 'scripts', 'scan_report_csv.sh'), env, `scan-report-${iso}.csv`,
        );
        send(res, 200, csv, 'text/csv; charset=utf-8');
      } else {
        const end = ddmmyyyyToIso(dateStr) || new Date().toISOString().slice(0, 10);
        const start = isoMinusDays(end, 6);
        env.START_DATE = start;
        env.END_DATE = end;
        const csv = await runScript(
          path.join(ROOT, 'scripts', 'weekly_report_generator.sh'), env, `weekly-report-${start}_to_${end}.csv`,
        );
        send(res, 200, csv, 'text/csv; charset=utf-8');
      }
    } catch (err) {
      sendJson(res, 502, { error: err.message || 'Script failed' });
    }
    return;
  }

  serveStatic(req, res, u.pathname);
});

server.listen(PORT, () => {
  console.log(`Scan Report Tool running at http://localhost:${PORT}`);
});
