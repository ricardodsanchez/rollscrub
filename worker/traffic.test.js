import { test } from "node:test";
import assert from "node:assert/strict";

import { readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";

import worker, { buySource, dayOf, isOutsideSite, looksAutomated } from "./index.js";

/**
 * Whether a request is counted as a person.
 *
 * This decides the only number the site is really watching — how many people
 * read the page — and the cost of getting it wrong is not a crash but a
 * wasted month: a conversion rate computed against crawlers reads as a broken
 * page, and sends you rewriting copy that nobody ever saw.
 */

const ua = (agent) =>
  new Request("https://rollscrub.com/", {
    headers: agent === null ? {} : { "user-agent": agent },
  });

/// Real strings from real browsers. If any of these are called a crawler,
/// page views collapse and every rate computed from them is nonsense.
test("browsers are counted as people", () => {
  const browsers = [
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:125.0) Gecko/20100101 Firefox/125.0",
  ];
  for (const agent of browsers) {
    assert.equal(looksAutomated(ua(agent)), false, agent);
  }
});

/// The traffic actually hitting this site: indexers, SEO tools, and the
/// WordPress vulnerability scanners that probe /xmlrpc.php all day.
test("crawlers and scanners are not counted as people", () => {
  const machines = [
    "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)",
    "Mozilla/5.0 (compatible; bingbot/2.0; +http://www.bing.com/bingbot.htm)",
    "Mozilla/5.0 (compatible; Baiduspider/2.0; +http://www.baidu.com/search/spider.html)",
    "Mozilla/5.0 (compatible; AhrefsBot/7.0; +http://ahrefs.com/robot/)",
    "Mozilla/5.0 (compatible; SemrushBot/7~bl)",
    "curl/8.4.0",
    "Wget/1.21.4",
    "python-requests/2.31.0",
    "Go-http-client/1.1",
    "zgrab/0.x",
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) HeadlessChrome/120.0.0.0 Safari/537.36",
  ];
  for (const agent of machines) {
    assert.equal(looksAutomated(ua(agent)), true, agent);
  }
});

/// A scanner that sends no agent at all, which is most of them.
test("a request with no user agent is not a person", () => {
  assert.equal(looksAutomated(ua(null)), true);
  assert.equal(looksAutomated(ua("")), true);
});

/// Sparkle fetching the zip for an automatic update is an install updating
/// itself, not somebody new deciding to try the app. Counting it as a
/// download would make the download number grow on its own.
test("Sparkle updating itself is not a new download", () => {
  assert.equal(looksAutomated(ua("RollScrub/1.0 Sparkle/2.6.0")), true);
});

/// Buy clicks are split by where they came from, so the stats page shows how
/// many people start checkout from the app rather than the site. The ref is
/// typed by whoever sends the request, so only known values may become a
/// row name; anything else counts as a click on the website.
test("a Buy click is filed under where it came from, and nothing else", () => {
  const src = (q) => buySource(new URL(`https://rollscrub.com/buy${q}`));
  assert.equal(src("?ref=app"), "app");
  assert.equal(src("?ref=cli"), "cli");
  assert.equal(src(""), "site");
  assert.equal(src("?ref="), "site");
  assert.equal(src("?ref=APP"), "site");
  assert.equal(src("?ref=<script>"), "site");
});

/**
 * What actually lands in the table, and what the stats page makes of it.
 *
 * These run the Worker itself against a real SQLite holding the real schema,
 * because every miscount found on the live page was in the wiring, not in a
 * helper: the right function called at the wrong moment, or a query that
 * summed rows it should not have.
 */

const SAFARI =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15";
const SPARKLE = "RollScrub/1.3 Sparkle/2.6.0";

/** Enough of D1's surface for the Worker: prepare, bind, run, all. */
function site() {
  const db = new DatabaseSync(":memory:");
  db.exec(readFileSync(new URL("./schema.sql", import.meta.url), "utf8"));
  const statement = (sql, args = []) => ({
    bind: (...bound) => statement(sql, bound),
    run: async () => void db.prepare(sql).run(...args),
    all: async () => ({ results: db.prepare(sql).all(...args) }),
  });
  const env = { STATS: { prepare: (sql) => statement(sql) }, STATS_TOKEN: "t" };

  return {
    /** One request through the Worker, with the asset handler answering `status`. */
    async hit(path, { agent = SAFARI, country = "US", status = 200, referer, body = null, etag, assetHeaders = {}, ...extra } = {}) {
      const headers = { "user-agent": agent, ...extra };
      if (referer) headers.referer = referer;
      const request = new Request(`https://rollscrub.com${path}`, { headers });
      Object.defineProperty(request, "cf", { value: { country } });
      env.ASSETS = {
        fetch: async () => {
          // No content-length, as on the live site: the asset handler does
          // not state one to the Worker.
          const sent = { ...(etag ? { etag } : {}), ...assetHeaders };
          return new Response(body, { status, headers: sent });
        },
      };
      const pending = [];
      const response = await worker.fetch(request, env, { waitUntil: (p) => pending.push(p) });
      await Promise.all(pending);
      return response;
    },
    /** A row as it would have been written before the rules changed. */
    past(day, kind, name, country, count) {
      db.prepare("INSERT INTO events VALUES (?, ?, ?, ?, ?)").run(day, kind, name, country, count);
    },
    /** Recorded counts as "kind name" -> n. */
    counts() {
      const rows = db
        .prepare("SELECT kind, name, SUM(count) AS n FROM events GROUP BY kind, name")
        .all();
      return Object.fromEntries(rows.map((r) => [`${r.kind} ${r.name}`, r.n]));
    },
    /** The stats page as text, one table cell or figure per line. */
    async page() {
      const response = await this.hit("/stats?token=t");
      return (await response.text())
        .replace(/<style>[\s\S]*?<\/style>/, "")
        .replace(/<[^>]+>/g, "\n")
        .split("\n")
        .map((line) => line.trim())
        .filter(Boolean);
    },
  };
}

/** The figure printed above a label on the stats page. */
const figure = (lines, label) => lines[lines.indexOf(label) - 1];

/// Fourteen "downloads" on the live page were requests for rollscrub-1.3.zip,
/// a name that does not exist: the count was taken before the file was
/// looked for. Counting those makes the download rate a measure of typos and
/// probing, not of people getting the app.
test("a request for a file that is not there is not a download", async () => {
  const s = site();
  await s.hit("/releases/rollscrub-1.3.zip", { status: 404 });
  await s.hit("/releases/RollScrub-1.3.zip", { status: 200 });
  assert.deepEqual(s.counts(), { "download RollScrub-1.3.zip": 1 });
});

/// /index.html answers with a redirect to /, and the browser then asks for /.
/// Counting both made one reader two, in the number every rate on the page
/// is divided by. A reload answered 304 is still somebody reading.
test("a page that redirects is counted once, where it lands", async () => {
  const s = site();
  await s.hit("/index.html", { status: 307 });
  await s.hit("/", { status: 200 });
  await s.hit("/", { status: 304 });
  await s.hit("/releases/RollScrub-1.3.zip", { status: 304 });
  assert.deepEqual(s.counts(), { "pageview /": 2 });
});

/// "Live installs by version" is how a release is watched reaching people.
/// Browsers and crawlers reading the appcast were its biggest row, which
/// overstated installs by half and hid which versions are really out there.
test("only Sparkle reading the appcast counts as an install checking in", async () => {
  const s = site();
  await s.hit("/appcast.xml", { agent: SPARKLE });
  await s.hit("/appcast.xml", { agent: SAFARI });
  await s.hit("/appcast.xml", { agent: "curl/8.4.0" });
  assert.deepEqual(s.counts(), {
    "update-check 1.3": 1,
    "update-check-bot appcast": 2,
  });
});

/// The referrer table answers "where should I post next". Our own domain and
/// scanners' IP addresses sat among the top rows, pushing real sources down a
/// list that only shows fifteen.
test("our own pages and bare addresses are not somewhere readers came from", async () => {
  const s = site();
  await s.hit("/", { referer: "https://www.rollscrub.com/changelog" });
  await s.hit("/", { referer: "https://rollscrub.com/" });
  await s.hit("/", { referer: "http://172.67.142.196/" });
  await s.hit("/", { referer: "http://[2606:4700::1]/" });
  await s.hit("/", { referer: "https://www.google.com/search?q=private" });
  assert.deepEqual(s.counts(), { "pageview /": 5, "referrer www.google.com": 1 });

  assert.equal(isOutsideSite("news.ycombinator.com"), true);
  assert.equal(isOutsideSite("rollscrub.app"), false);
  assert.equal(isOutsideSite("buy.rollscrub.com"), false);
  assert.equal(isOutsideSite("notrollscrub.com"), true);
  assert.equal(isOutsideSite(""), false);
});

/// A quarter of all Buy clicks came through Tor and none reached checkout.
/// Counted as people, they drag the checkout rate down and make the Buy
/// button look worse than it is, which is the number most likely to send
/// somebody rewriting a page that works.
test("a Buy click through Tor is set aside with the crawlers", async () => {
  const s = site();
  await s.hit("/buy", { country: "T1" });
  await s.hit("/buy?ref=app", { country: "US" });
  assert.deepEqual(s.counts(), { "buy-click-bot site": 1, "buy-click app": 1 });
});

/// The page has a month of rows written under the old rules. If it summed
/// them as stored, every figure would stay wrong until they aged out, and the
/// daily table would show a false drop on the day of the fix.
test("the stats page reads rows from before the fixes under the same rules", async () => {
  const s = site();
  s.past("2026-10-01", "pageview", "/", "US", 100);
  s.past("2026-10-01", "pageview", "/", "T1", 7);
  s.past("2026-10-01", "download", "RollScrub-1.3.zip", "US", 10);
  s.past("2026-10-01", "download", "rollscrub-1.3.zip", "US", 4);
  s.past("2026-10-01", "buy-click", "buy", "US", 5);
  s.past("2026-10-01", "buy-click", "buy", "T1", 18);
  s.past("2026-10-01", "update-check", "1.3", "US", 3);
  s.past("2026-10-01", "update-check", "unknown", "US", 26);
  s.past("2026-10-01", "referrer", "rollscrub.com", "US", 14);
  s.past("2026-10-01", "referrer", "172.67.142.196", "US", 3);
  s.past("2026-10-01", "referrer", "www.google.com", "US", 16);

  const lines = await s.page();
  assert.equal(figure(lines, "page views"), "100");
  assert.equal(figure(lines, "downloads"), "10");
  assert.equal(figure(lines, "Buy clicks"), "5");
  assert.equal(figure(lines, "update checks"), "3");
  assert.equal(figure(lines, "of readers click Buy on the site"), "5.0%");
  for (const gone of ["unknown", "rollscrub-1.3.zip", "rollscrub.com", "172.67.142.196"]) {
    assert.equal(lines.includes(gone), false, `${gone} is still on the page`);
  }
  assert.equal(lines.includes("www.google.com"), true);
  // The daily row: views, downloads, Buy clicks, /thanks, update checks.
  const day = lines.indexOf("2026-10-01");
  assert.deepEqual(lines.slice(day + 1, day + 6), ["100", "10", "5", "0", "3"]);
});

/// The rule that hides old misspelt downloads names the release file. It is
/// bounded by date so that renaming the zip one day does not silently zero
/// the download count: after the fix a row only exists if the file was served.
test("a release zip under a new name still counts after the fix", async () => {
  const s = site();
  s.past("2026-11-01", "download", "Scrub-2.0.zip", "US", 9);
  assert.equal(figure(await s.page(), "downloads"), "9");
});

/// The asset handler answers a Range request with the whole file and a 200.
/// A browser resuming a download that dropped at 90% then either restarts
/// from nothing or, worse, keeps a file that will not open. On a hotel
/// connection that is somebody who never gets the app.
test("a resumed download gets the bytes it asked for, and only those", async () => {
  const s = site();
  const file = { body: "0123456789", etag: '"v1"' };
  const get = (range, more = {}) =>
    s.hit("/releases/RollScrub-1.4.zip", { ...file, range, ...more });

  const middle = await get("bytes=2-5");
  assert.equal(middle.status, 206);
  assert.equal(middle.headers.get("content-range"), "bytes 2-5/10");
  assert.equal(middle.headers.get("content-length"), "4");
  assert.equal(await middle.text(), "2345");

  assert.equal(await (await get("bytes=7-")).text(), "789");
  assert.equal(await (await get("bytes=-3")).text(), "789");
  // Past the end is clamped, as a client that guessed the size expects.
  const clamped = await get("bytes=8-99");
  assert.equal(clamped.headers.get("content-range"), "bytes 8-9/10");
  assert.equal(await clamped.text(), "89");

  for (const range of ["bytes=10-", "bytes=-0", "bytes=99999999999999999999999-"]) {
    const beyond = await get(range);
    assert.equal(beyond.status, 416, range);
    assert.equal(beyond.headers.get("content-range"), "bytes */10");
  }

  // A browser only offers to resume if the first response said it could.
  const plain = await s.hit("/releases/RollScrub-1.4.zip", file);
  assert.equal(plain.status, 200);
  assert.equal(plain.headers.get("accept-ranges"), "bytes");
  assert.equal(await plain.text(), "0123456789");
});

/// Every case here is one where cutting a slice could hand back the wrong
/// bytes: a file that changed since the first half was fetched, a request
/// shape this code does not parse. The whole file is always a correct answer
/// to a Range request; a wrong slice is a corrupt download.
test("a range this cannot answer exactly gets the whole file instead", async () => {
  const s = site();
  const file = { body: "0123456789", etag: '"v2"' };
  const whole = async (options) => {
    const response = await s.hit("/releases/RollScrub-1.4.zip", { ...file, ...options });
    assert.equal(response.status, 200, JSON.stringify(options));
    assert.equal(await response.text(), "0123456789");
  };
  await whole({ range: "bytes=0-1,4-5" });
  await whole({ range: "bytes=-" });
  await whole({ range: "lines=0-1" });
  await whole({ range: "bytes=2-5", "if-range": '"v1"' });
  await whole({ range: "bytes=2-5", "if-range": 'W/"v2"', etag: 'W/"v2"' });
  await whole({ range: "bytes=5-2" });
  // Offsets into a compressed body are not offsets into the file.
  await whole({ range: "bytes=2-5", assetHeaders: { "content-encoding": "gzip" } });
  // A stated size too large to cut from memory is never read into it.
  await whole({ range: "bytes=2-5", assetHeaders: { "content-length": "999999999" } });

  // And one that turns out too large while being read still arrives whole,
  // including the part already looked at.
  const big = "abcdefgh".repeat(1024 * 1024 + 1);
  const huge = await s.hit("/releases/RollScrub-9.zip", { body: big, range: "bytes=2-5" });
  assert.equal(huge.status, 200);
  assert.equal((await huge.text()) === big, true);

  const fresh = await s.hit("/releases/RollScrub-1.4.zip", {
    ...file,
    range: "bytes=2-5",
    "if-range": '"v2"',
  });
  assert.equal(fresh.status, 206);

  // And none of it is a download: one file fetched in pieces is one download,
  // counted by the request that carried no Range.
  assert.deepEqual(s.counts(), {});
});

/// The version in a row name is typed by whoever sends the request. Left
/// unbounded, one script could fill the stats page with thousands of rows of
/// its own choosing.
test("a made-up version cannot become a row on the stats page", async () => {
  const s = site();
  await s.hit("/appcast.xml", { agent: `RollScrub/${"9".repeat(40)} Sparkle/2.6.0` });
  await s.hit("/appcast.xml", { agent: "RollScrub/1.2.3.4.5 Sparkle/2.6.0" });
  await s.hit("/appcast.xml", { agent: "RollScrub/1.4 Sparkle/2.6.0" });
  assert.deepEqual(s.counts(), { "update-check-bot appcast": 2, "update-check 1.4": 1 });
});

/// The page has one reader, on the US west coast. Filed by UTC, everything
/// after five in the afternoon landed on tomorrow's row, so "today" was
/// always short and a release shipped in the evening appeared a day late.
test("a request is filed under the day it is in California", () => {
  assert.equal(dayOf(new Date("2026-10-14T00:45:00Z")), "2026-10-13");
  assert.equal(dayOf(new Date("2026-10-14T06:59:59Z")), "2026-10-13");
  assert.equal(dayOf(new Date("2026-10-14T07:00:00Z")), "2026-10-14");
  // Winter, when the offset is eight hours rather than seven.
  assert.equal(dayOf(new Date("2026-12-01T07:30:00Z")), "2026-11-30");
  assert.equal(dayOf(new Date("2026-12-01T08:00:00Z")), "2026-12-01");
});

/// Updating a licensed copy to 1.4 left no trace on the page: Sparkle took
/// the .delta, which nothing counted, and the new version does not check the
/// appcast until its next scheduled check. Without this a release looks like
/// it reached nobody for a day, which is when a broken appcast would look
/// exactly the same.
test("Sparkle fetching a release is counted as an update being installed", async () => {
  const s = site();
  await s.hit("/releases/RollScrub5-4.delta", { agent: SPARKLE });
  await s.hit("/releases/RollScrub-1.4.zip", { agent: SPARKLE });
  // A browser has no use for a delta, and a missing file updated nobody.
  await s.hit("/releases/RollScrub5-4.delta", { agent: SAFARI });
  await s.hit("/releases/RollScrub5-9.delta", { agent: SPARKLE, status: 404 });
  assert.deepEqual(s.counts(), {
    "update-fetch RollScrub5-4.delta from 1.3": 1,
    "update-fetch RollScrub-1.4.zip from 1.3": 1,
  });

  const lines = await s.page();
  assert.equal(lines.includes("RollScrub5-4.delta from 1.3"), true);
  // Not a new person downloading the app.
  assert.equal(figure(lines, "downloads"), "0");
});
