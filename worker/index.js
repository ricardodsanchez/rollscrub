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
 *
 * The user agent is *read* once, to decide whether a request is a person or a
 * crawler, and then discarded; only which of the two tallies to increment
 * survives. See looksAutomated().
 */

import { license } from "./license.js";

const DAY = () => new Date().toISOString().slice(0, 10);

/** Sparkle sends "RollScrub/1.0 Sparkle/2.6.0"; keep only the app version. */
function appVersion(userAgent) {
  const m = /RollScrub\/(\d+(?:\.\d+){0,2})/.exec(userAgent ?? "");
  return m ? m[1] : "unknown";
}

/**
 * Agents that announce themselves as machines, and the shapes lazy scanners
 * take. Matched case-insensitively against the user agent.
 */
const AUTOMATED =
  /bot|crawl|spider|slurp|scrape|scan|curl|wget|python|go-http|java\/|okhttp|libwww|httpclient|headless|phantom|puppeteer|playwright|monitor|uptime|fetcher|archiver|indexer|semrush|ahrefs|zgrab|masscan|censys/i;

/**
 * Whether a request looks automated.
 *
 * Deliberately crude, and deliberately only ever used to split a count in
 * two. The user agent is chosen by the caller and trivially forged, so this
 * catches honest crawlers and lazy scanners and nothing else — which is
 * enough, because the job here is not security (Cloudflare's managed rules do
 * that) but keeping one number honest: how many *people* read this page.
 *
 * Erring towards "automated" is the right direction. An overstated human
 * count is the one that leads somewhere expensive — rewriting a page that was
 * never being read, or reading a conversion rate that was never real.
 *
 * The agent string itself is never stored. Only this verdict is, as a count.
 */
export function looksAutomated(request) {
  const agent = request.headers.get("user-agent");
  // Every browser ever shipped sends one. Nothing that omits it is a reader.
  if (!agent) return true;
  if (AUTOMATED.test(agent)) return true;
  // No rendering engine named means nothing is being rendered. This also
  // catches Sparkle fetching the zip for an automatic update, which is the
  // right answer: that is an existing install updating itself, not somebody
  // new deciding to try the app.
  return !/mozilla|applewebkit|gecko|chrome|safari|firefox|opera|edge/i.test(agent);
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
    // rollscrub.app redirects here, so arrivals through it are direct, not a
    // referral from somebody else's site.
    const ours = new Set([new URL(request.url).hostname, "rollscrub.app", "www.rollscrub.app"]);
    return ours.has(host) ? null : host.slice(0, 80);
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
  if (pathname === "/thanks") {
    // Only the extensionless path: the asset handler's default html_handling
    // redirects /thanks.html to /thanks, and with run_worker_first this
    // Worker runs on both the original request and the redirected one, so
    // matching both paths here would count one visit twice. Every other link
    // on the site (changelog, privacy, terms) already points at the
    // extensionless form, so Creem's own success URL is almost certainly
    // this one — but if it were ever set to the .html form, that one hit
    // would go uncounted rather than double-counted, which is the safer
    // direction to be wrong in.
    //
    // Reached only after Creem sends a buyer back here, so a view here is the
    // closest thing to a confirmed sale this site can see without a webhook —
    // a proxy, not a ledger: nothing here confirms the payment actually
    // captured, only that the browser landed on the page Creem redirects to.
    return { kind: "purchase", name: "thanks" };
  }
  return null;
}

// Creem's checkout, served on our own domain (buy. is a DNS-only CNAME to
// Creem). Kept as a redirect target rather than linked to directly so a click
// can be counted before the browser leaves the site — there is no page load
// on rollscrub.com after this to count it from.
const BUY_URL = "https://buy.rollscrub.com/payment/prod_53G0PoiZ59pjRrJKuXN6Rj";

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

  const daily = await env.STATS.prepare(
    `SELECT day,
            SUM(CASE WHEN kind = 'pageview' THEN count ELSE 0 END) AS views,
            SUM(CASE WHEN kind = 'download' THEN count ELSE 0 END) AS downloads,
            SUM(CASE WHEN kind = 'buy-click' THEN count ELSE 0 END) AS buys,
            SUM(CASE WHEN kind = 'purchase' THEN count ELSE 0 END) AS purchases,
            SUM(CASE WHEN kind = 'update-check' THEN count ELSE 0 END) AS checks
     FROM events GROUP BY day ORDER BY day DESC LIMIT 30`
  ).all();

  const total = (k) =>
    totals.results.find((r) => r.kind === k)?.n ?? 0;
  const rows = (res, cols) =>
    res.results.map((r) => `<tr>${cols.map((c) => c(r)).join("")}</tr>`).join("") ||
    `<tr><td class="muted" colspan="9">Nothing yet.</td></tr>`;

  // People, not crawlers. Everything below counts only requests that looked
  // like a browser; the automated half is kept and shown separately rather
  // than thrown away, because "how much of this is real" is itself a number
  // worth watching.
  const views = total("pageview");
  const downloads = total("download");
  const buyClicks = total("buy-click");
  const purchases = total("purchase");
  const botViews = total("pageview-bot");
  const botDownloads = total("download-bot");
  // The number the page is actually for: of everyone who read it, how many
  // wanted the app enough to fetch it.
  const rate = views ? `${((downloads / views) * 100).toFixed(1)}%` : "—";
  // "Bought" here means "clicked Buy" — Creem, not this site, knows whether
  // the card actually went through, and there's no webhook wired up to ask.
  // buyRate is the honest number; checkoutRate is only a rough proxy on top
  // of it, and can read over 100% (see the caveat printed below it).
  const buyRate = views ? `${((buyClicks / views) * 100).toFixed(1)}%` : "—";
  const checkoutRate = buyClicks ? `${((purchases / buyClicks) * 100).toFixed(0)}%` : "—";
  const noise = views + botViews
    ? `${((botViews / (views + botViews)) * 100).toFixed(0)}%`
    : "—";

  return html(`
<h1>RollScrub</h1>
<div class="row">
  <div><div class="big">${views}</div><div class="muted">page views</div></div>
  <div><div class="big">${downloads}</div><div class="muted">downloads</div></div>
  <div><div class="big">${rate}</div><div class="muted">of readers download</div></div>
  <div><div class="big">${total("update-check")}</div><div class="muted">update checks</div></div>
</div>
<div class="row">
  <div><div class="big">${buyClicks}</div><div class="muted">Buy clicks</div></div>
  <div><div class="big">${buyRate}</div><div class="muted">of readers click Buy</div></div>
  <div><div class="big">${purchases}</div><div class="muted">reached /thanks</div></div>
  <div><div class="big">${checkoutRate}</div><div class="muted">of Buy clicks finish checkout</div></div>
</div>
<p class="muted">Counts above are requests that looked like a browser. Set aside as
automated: <strong>${botViews}</strong> page views and <strong>${botDownloads}</strong>
downloads &mdash; ${noise} of all traffic. Judged from the user agent alone, which is
forgeable, so read it as a floor on the noise rather than a measurement of it.</p>
<p class="muted">"Reached /thanks" counts browsers landing on the page Creem
sends buyers back to — the closest thing to a sale count this site can see
without a webhook. It is a proxy, not a ledger: it can run <em>higher</em>
than actual sales, since a buyer reloading the page or returning to it (it
carries its own download link) counts again each time, and it never runs
lower for a refund, since nothing here hears about those either.</p>

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
<table><tr><th>Day</th><th class="n">Views</th><th class="n">Downloads</th>
<th class="n">Buy clicks</th><th class="n">/thanks</th><th class="n">Update checks</th></tr>
${rows(daily, [
  (r) => `<td>${r.day}</td>`,
  (r) => `<td class="n">${r.views}</td>`,
  (r) => `<td class="n">${r.downloads}</td>`,
  (r) => `<td class="n">${r.buys}</td>`,
  (r) => `<td class="n">${r.purchases}</td>`,
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

    if (url.pathname === "/buy") {
      // Only a GET is a click landing here; HEAD comes from link checkers
      // and unfurlers with otherwise browser-shaped user agents, and
      // recording it would sit the same tally next to page views and
      // downloads, which both already exclude it.
      if (request.method === "GET") {
        const automated = looksAutomated(request);
        ctx.waitUntil(
          record(env, { kind: automated ? "buy-click-bot" : "buy-click", name: "buy" }, request)
        );
      }
      return Response.redirect(BUY_URL, 302);
    }

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
      // Update checks are machine traffic by definition and already counted
      // on their own; splitting them would say nothing. Everything else is
      // recorded under its own kind or a "-bot" twin, so that "page views"
      // means people and the crawlers stay visible rather than hidden.
      const automated = event.kind !== "update-check" && looksAutomated(request);
      const kind = automated ? `${event.kind}-bot` : event.kind;
      ctx.waitUntil(record(env, { kind, name: event.name }, request));

      // Where a reader came from, counted alongside the visit itself. Not
      // worth recording for crawlers: it is their own noise, fed back.
      const from =
        !automated && event.kind === "pageview" ? referrerHost(request) : null;
      if (from) {
        ctx.waitUntil(record(env, { kind: "referrer", name: from }, request));
      }
    }

    return env.ASSETS.fetch(request);
  },
};
