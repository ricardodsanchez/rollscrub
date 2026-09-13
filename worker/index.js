/**
 * Counts downloads and update checks, then serves the static site.
 *
 * site/ is served by Cloudflare's asset handler, so a download normally runs
 * no code at all and lands nowhere countable. This Worker sits in front of it:
 * it records the hit and hands the request straight to ASSETS, which still
 * does the actual serving — range requests, caching and all.
 *
 * What is stored is a daily count per file per country. No IP address, no user
 * agent, no per-request timestamp, no cookie, nothing that identifies a person
 * — this counts copies, and a site that promises not to touch your photos has
 * no business fingerprinting the people reading about it.
 */

const DAY = () => new Date().toISOString().slice(0, 10);

/** What kind of event a path represents, or null to count nothing. */
function classify(pathname) {
  if (pathname === "/appcast.xml") {
    // Sparkle polling for updates. One per install per check, so this tracks
    // roughly how many copies are alive, not how many were ever downloaded.
    return { kind: "update-check", name: "appcast" };
  }
  if (pathname.startsWith("/releases/") && pathname.endsWith(".zip")) {
    return { kind: "download", name: pathname.slice("/releases/".length) };
  }
  return null;
}

async function record(env, event, request) {
  if (!env.STATS) return; // binding absent: never break serving over telemetry
  const country = request.cf?.country ?? "??";
  try {
    await env.STATS.prepare(
      `INSERT INTO events (day, kind, name, country, count) VALUES (?, ?, ?, ?, 1)
       ON CONFLICT(day, kind, name, country) DO UPDATE SET count = count + 1`
    )
      .bind(DAY(), event.kind, event.name, country)
      .run();
  } catch {
    // A failed write must never cost somebody their download.
  }
}

function html(body) {
  return new Response(
    `<!doctype html><meta charset="utf-8"><title>RollScrub stats</title>
<meta name="robots" content="noindex">
<style>
  :root { color-scheme: light dark; }
  body { font: 14px/1.5 -apple-system, system-ui, sans-serif; margin: 2rem auto;
         max-width: 46rem; padding: 0 1rem; }
  h1 { font-size: 1.3rem; margin: 0 0 1.5rem; }
  h2 { font-size: .8rem; text-transform: uppercase; letter-spacing: .08em;
       opacity: .6; margin: 2rem 0 .5rem; }
  table { border-collapse: collapse; width: 100%; font-variant-numeric: tabular-nums; }
  th, td { text-align: left; padding: .35rem .6rem .35rem 0;
           border-bottom: 1px solid color-mix(in srgb, currentColor 12%, transparent); }
  td.n, th.n { text-align: right; }
  .big { font-size: 2rem; font-weight: 600; font-variant-numeric: tabular-nums; }
  .row { display: flex; gap: 3rem; }
  .muted { opacity: .6; }
</style>${body}`,
    { headers: { "content-type": "text/html; charset=utf-8" } }
  );
}

async function stats(request, env) {
  const token = new URL(request.url).searchParams.get("token");
  if (!env.STATS_TOKEN || token !== env.STATS_TOKEN) {
    return new Response("Not found", { status: 404 });
  }
  if (!env.STATS) return html("<h1>No database bound yet.</h1>");

  const totals = await env.STATS.prepare(
    `SELECT kind, SUM(count) AS n FROM events GROUP BY kind`
  ).all();
  const files = await env.STATS.prepare(
    `SELECT name, SUM(count) AS n FROM events WHERE kind = 'download'
     GROUP BY name ORDER BY n DESC`
  ).all();
  const countries = await env.STATS.prepare(
    `SELECT country, SUM(count) AS n FROM events WHERE kind = 'download'
     GROUP BY country ORDER BY n DESC LIMIT 10`
  ).all();
  const daily = await env.STATS.prepare(
    `SELECT day,
            SUM(CASE WHEN kind = 'download' THEN count ELSE 0 END) AS downloads,
            SUM(CASE WHEN kind = 'update-check' THEN count ELSE 0 END) AS checks
     FROM events GROUP BY day ORDER BY day DESC LIMIT 30`
  ).all();

  const total = (k) =>
    totals.results.find((r) => r.kind === k)?.n ?? 0;
  const rows = (res, cols) =>
    res.results.map((r) => `<tr>${cols.map((c) => c(r)).join("")}</tr>`).join("") ||
    `<tr><td class="muted" colspan="9">Nothing yet.</td></tr>`;

  return html(`
<h1>RollScrub</h1>
<div class="row">
  <div><div class="big">${total("download")}</div><div class="muted">downloads</div></div>
  <div><div class="big">${total("update-check")}</div><div class="muted">update checks</div></div>
</div>

<h2>By file</h2>
<table><tr><th>File</th><th class="n">Downloads</th></tr>
${rows(files, [(r) => `<td>${r.name}</td>`, (r) => `<td class="n">${r.n}</td>`])}</table>

<h2>By country</h2>
<table><tr><th>Country</th><th class="n">Downloads</th></tr>
${rows(countries, [(r) => `<td>${r.country}</td>`, (r) => `<td class="n">${r.n}</td>`])}</table>

<h2>Last 30 days</h2>
<table><tr><th>Day</th><th class="n">Downloads</th><th class="n">Update checks</th></tr>
${rows(daily, [
  (r) => `<td>${r.day}</td>`,
  (r) => `<td class="n">${r.downloads}</td>`,
  (r) => `<td class="n">${r.checks}</td>`,
])}</table>

<p class="muted">Daily counts per file and country. No addresses, agents or
cookies are recorded.</p>`);
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    if (url.pathname === "/stats") return stats(request, env);

    // Range requests are how a resumed or chunked download arrives, and
    // counting each one would report a single download several times over.
    // HEAD is a probe, not a download.
    const event = classify(url.pathname);
    if (event && request.method === "GET" && !request.headers.has("range")) {
      ctx.waitUntil(record(env, event, request));
    }

    return env.ASSETS.fetch(request);
  },
};
