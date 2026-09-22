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

import { license } from "./license.js";

const DAY = () => new Date().toISOString().slice(0, 10);

/** Sparkle sends "RollScrub/1.0 Sparkle/2.6.0"; keep only the app version. */
function appVersion(userAgent) {
  const m = /RollScrub\/(\d+(?:\.\d+){0,2})/.exec(userAgent ?? "");
  return m ? m[1] : "unknown";
}

/**
 * The site someone arrived from, host only — never the full URL, which can
 * carry search terms and other people's query strings. Same-origin and absent
 * referrers are both "direct".
 */
function referrerHost(request) {
  const referer = request.headers.get("referer");
  if (!referer) return null;
  try {
    const host = new URL(referer).hostname;
    return host === new URL(request.url).hostname ? null : host.slice(0, 80);
  } catch {
    return null;
  }
}

/** What kind of event a path represents, or null to count nothing. */
function classify(pathname, request) {
  if (pathname === "/appcast.xml") {
    // Sparkle polling for updates. One per install per check, so this tracks
    // roughly how many copies are alive — and which version each is on, which
    // is how you watch an update actually reach people.
    return {
      kind: "update-check",
      name: appVersion(request.headers.get("user-agent")),
    };
  }
  if (pathname.startsWith("/releases/") && pathname.endsWith(".zip")) {
    return { kind: "download", name: pathname.slice("/releases/".length) };
  }
  if (pathname === "/" || pathname === "/index.html") {
    return { kind: "pageview", name: "/" };
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

/**
 * Referrer hosts are chosen by whoever sends the request, so they reach the
 * stats page as untrusted text. Escaped on the way out — the one reader of
 * this page is the person with the token, and injecting script into their
 * session is exactly what an attacker would aim a crafted Referer at.
 */
function esc(value) {
  return String(value).replace(
    /[&<>"']/g,
    (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]
  );
}

// ---------- notify list ----------

/// Deliberately loose. The job is to catch a typo or a stray form post, not to
/// adjudicate RFC 5322 — a real address that a strict pattern rejects is a
/// customer turned away, which costs far more than a junk row.
function looksLikeEmail(value) {
  return typeof value === "string"
    && value.length >= 6 && value.length <= 254
    && /^[^\s@]+@[^\s@.]+\.[^\s@]+$/.test(value);
}

const NOTIFY_TABLE = `CREATE TABLE IF NOT EXISTS notify (
  email TEXT PRIMARY KEY, day TEXT NOT NULL, country TEXT NOT NULL)`;

async function addToNotifyList(env, email, request) {
  const insert = () =>
    env.STATS.prepare(
      `INSERT INTO notify (email, day, country) VALUES (?, ?, ?)
       ON CONFLICT(email) DO NOTHING`
    )
      .bind(email.toLowerCase(), DAY(), request.cf?.country ?? "??")
      .run();

  try {
    await insert();
  } catch (error) {
    // The table is created here rather than by a migration so that deploying
    // the Worker is all it takes; the alternative is a form that silently
    // fails until someone remembers to run wrangler.
    if (!/no such table/i.test(String(error))) throw error;
    await env.STATS.prepare(NOTIFY_TABLE).run();
    await insert();
  }
}

async function notify(request, env) {
  if (request.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }
  const type = request.headers.get("content-type") ?? "";
  const body = type.includes("application/json")
    ? await request.json().catch(() => ({}))
    : Object.fromEntries(await request.formData().catch(() => new FormData()));

  const wantsJSON = (request.headers.get("accept") ?? "").includes("application/json");
  const reply = (ok, message, status = ok ? 200 : 400) =>
    wantsJSON
      ? Response.json({ ok, message }, { status })
      : html(`<h1>${ok ? "You're on the list" : "That didn't work"}</h1>
              <p>${esc(message)}</p><p><a href="/">Back to RollScrub</a></p>`,
             { status });

  // A field no person sees and every naive bot fills in.
  if (body.company) return reply(true, "Thanks — we'll be in touch.");

  if (!looksLikeEmail(body.email)) {
    return reply(false, "That doesn't look like an email address. Try again?");
  }
  if (!env.STATS) return reply(false, "The list isn't available right now.");

  try {
    await addToNotifyList(env, body.email, request);
  } catch {
    return reply(false, "Something went wrong saving that. Try again in a minute.");
  }
  return reply(true, "Thanks — you'll get one email when the shop opens, and nothing else.");
}

function html(body, init = {}) {
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
    { ...init, headers: { "content-type": "text/html; charset=utf-8" } }
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
  const sources = await env.STATS.prepare(
    `SELECT name, SUM(count) AS n FROM events WHERE kind = 'referrer'
     GROUP BY name ORDER BY n DESC LIMIT 15`
  ).all();
  const versions = await env.STATS.prepare(
    `SELECT name, SUM(count) AS n FROM events WHERE kind = 'update-check'
     GROUP BY name ORDER BY n DESC`
  ).all();
  // Tolerates the table not existing yet: the stats page must still render
  // before anyone has ever signed up.
  const waiting = await env.STATS.prepare(
    `SELECT email, day, country FROM notify ORDER BY day DESC, email`
  ).all().catch(() => ({ results: [] }));

  const daily = await env.STATS.prepare(
    `SELECT day,
            SUM(CASE WHEN kind = 'pageview' THEN count ELSE 0 END) AS views,
            SUM(CASE WHEN kind = 'download' THEN count ELSE 0 END) AS downloads,
            SUM(CASE WHEN kind = 'update-check' THEN count ELSE 0 END) AS checks
     FROM events GROUP BY day ORDER BY day DESC LIMIT 30`
  ).all();

  const total = (k) =>
    totals.results.find((r) => r.kind === k)?.n ?? 0;
  const rows = (res, cols) =>
    res.results.map((r) => `<tr>${cols.map((c) => c(r)).join("")}</tr>`).join("") ||
    `<tr><td class="muted" colspan="9">Nothing yet.</td></tr>`;

  const views = total("pageview");
  const downloads = total("download");
  // The number the page is actually for: of everyone who read it, how many
  // wanted the app enough to fetch it.
  const rate = views ? `${((downloads / views) * 100).toFixed(1)}%` : "—";

  return html(`
<h1>RollScrub</h1>
<div class="row">
  <div><div class="big">${views}</div><div class="muted">page views</div></div>
  <div><div class="big">${downloads}</div><div class="muted">downloads</div></div>
  <div><div class="big">${rate}</div><div class="muted">of readers download</div></div>
  <div><div class="big">${total("update-check")}</div><div class="muted">update checks</div></div>
</div>

<h2>Waiting for the shop to open (${waiting.results.length})</h2>
<table><tr><th>Email</th><th>Signed up</th><th>From</th></tr>
${rows(waiting, [
  (r) => `<td>${esc(r.email)}</td>`,
  (r) => `<td>${esc(r.day)}</td>`,
  (r) => `<td>${esc(r.country)}</td>`,
])}</table>
<p class="muted">Mail these once, when the shop opens, then delete the list —
it has one purpose and no reason to outlive it.</p>

<h2>Where readers come from</h2>
<table><tr><th>Source</th><th class="n">Visits</th></tr>
${rows(sources, [(r) => `<td>${esc(r.name)}</td>`, (r) => `<td class="n">${r.n}</td>`])}</table>

<h2>Live installs by version</h2>
<table><tr><th>Version</th><th class="n">Update checks</th></tr>
${rows(versions, [(r) => `<td>${esc(r.name)}</td>`, (r) => `<td class="n">${r.n}</td>`])}</table>

<h2>By file</h2>
<table><tr><th>File</th><th class="n">Downloads</th></tr>
${rows(files, [(r) => `<td>${esc(r.name)}</td>`, (r) => `<td class="n">${r.n}</td>`])}</table>

<h2>By country</h2>
<table><tr><th>Country</th><th class="n">Downloads</th></tr>
${rows(countries, [(r) => `<td>${esc(r.country)}</td>`, (r) => `<td class="n">${r.n}</td>`])}</table>

<h2>Last 30 days</h2>
<table><tr><th>Day</th><th class="n">Views</th><th class="n">Downloads</th><th class="n">Update checks</th></tr>
${rows(daily, [
  (r) => `<td>${r.day}</td>`,
  (r) => `<td class="n">${r.views}</td>`,
  (r) => `<td class="n">${r.downloads}</td>`,
  (r) => `<td class="n">${r.checks}</td>`,
])}</table>

<p class="muted">Daily counts per file, version, source and country. No
addresses, user agents or cookies are recorded, and nothing here identifies a
person.</p>`);
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    if (url.pathname === "/stats") return stats(request, env);
    if (url.pathname === "/notify") return notify(request, env);

    // The app's licence calls. Proxied rather than made direct because the
    // Creem API key cannot ship inside a downloadable binary; see license.js.
    const licenceAction = url.pathname.startsWith("/license/")
      && url.pathname.slice("/license/".length);
    if (["activate", "validate", "deactivate"].includes(licenceAction)) {
      return license(request, env, licenceAction);
    }

    // Range requests are how a resumed or chunked download arrives, and
    // counting each one would report a single download several times over.
    // HEAD is a probe, not a download.
    const event = classify(url.pathname, request);
    if (event && request.method === "GET" && !request.headers.has("range")) {
      ctx.waitUntil(record(env, event, request));

      // Where a reader came from, counted alongside the visit itself.
      const from = event.kind === "pageview" ? referrerHost(request) : null;
      if (from) {
        ctx.waitUntil(record(env, { kind: "referrer", name: from }, request));
      }
    }

    return env.ASSETS.fetch(request);
  },
};
