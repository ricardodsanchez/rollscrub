import { test } from "node:test";
import assert from "node:assert/strict";

import { buySource, looksAutomated } from "./index.js";

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
