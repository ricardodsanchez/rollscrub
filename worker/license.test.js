import { test, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";

import { license } from "./license.js";

/**
 * The licence proxy decides, for every customer, whether the app they paid for
 * keeps working. One word of its vocabulary — `refused` — deletes a licence
 * from a keychain, and the other two must never be able to.
 *
 * So these tests are overwhelmingly about the boundary rather than the happy
 * path: every way Creem can fail to answer clearly has to come back `error`,
 * because `error` changes nothing and `refused` cannot be undone by the person
 * it happens to. The fixtures in LicenseTests.swift cover the app's side of
 * the same contract; nothing else covers this file.
 */

const ENV = { CREEM_API_KEY: "creem_test_key", CREEM_PRODUCT_ID: "prod_ours" };

/** A licence object shaped like Creem's, overridable field by field. */
const licence = (over = {}) => ({
  id: "lic_1",
  object: "license",
  product_id: "prod_ours",
  // Deliberately a value we have never seen documented: Creem publishes no
  // example of a live key's mode, so anything that is not a known test mode
  // has to be treated as live.
  mode: "live",
  status: "active",
  key: "ABCDE-FGHIJ",
  instance: { id: "inst_1", object: "license-instance", status: "active" },
  ...over,
});

let calls;
const realFetch = globalThis.fetch;

/** Queues replies for successive calls to Creem and records what we sent. */
function creemReplies(...replies) {
  globalThis.fetch = async (url, init) => {
    calls.push({ url: String(url), body: JSON.parse(init.body) });
    const next = replies.shift();
    assert.ok(next, `unexpected extra call to ${url}`);
    if (next.network === "down") throw new Error("connection reset");
    return new Response(next.text ?? JSON.stringify(next.json ?? {}), {
      status: next.status ?? 200,
      headers: { "content-type": "application/json" },
    });
  };
}

function post(action, body = { key: "ABCDE-FGHIJ", instance_id: "inst_1" }, headers = {}) {
  return new Request(`https://rollscrub.com/license/${action}`, {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: JSON.stringify(body),
  });
}

const verdictOf = async (response) => (await response.json()).verdict;

beforeEach(() => {
  calls = [];
});
afterEach(() => {
  globalThis.fetch = realFetch;
});

// ---------- the boundary: nothing ambiguous may ever revoke ----------

/// Our own Creem API key being rotated, revoked or mistyped has nothing to do
/// with whether a customer paid. Reading 403 as a refusal would empty the
/// keychain of every customer in the field the first time each re-checked.
test("a rotated API key does not revoke anybody", async () => {
  creemReplies({ status: 403, json: { error: "Forbidden" } });
  assert.equal(await verdictOf(await license(post("validate"), ENV, "validate")), "error");
});

/// A key Creem does not recognise is indistinguishable from us pointing at the
/// wrong store, or sending a malformed body. On a re-check of a licence that
/// already worked, that ambiguity must not cost the customer anything.
test("an unrecognised key does not revoke on a re-check", async () => {
  creemReplies({ status: 404, json: { error: "Not Found" } });
  assert.equal(await verdictOf(await license(post("validate"), ENV, "validate")), "error");
});

/// Creem having a bad day is not evidence about a licence.
test("a Creem outage does not revoke anybody", async () => {
  creemReplies({ status: 500, json: { error: "Internal" } });
  assert.equal(await verdictOf(await license(post("validate"), ENV, "validate")), "error");
});

/// A captive portal answers every request with an HTML login page. Somebody
/// opening their laptop in a hotel must not lose the software they bought.
test("a captive portal does not revoke anybody", async () => {
  creemReplies({ status: 200, text: "<html>Sign in to WiFi</html>" });
  assert.equal(await verdictOf(await license(post("validate"), ENV, "validate")), "error");
});

/// The network simply not being there.
test("an unreachable licence API does not revoke anybody", async () => {
  creemReplies({ network: "down" });
  assert.equal(await verdictOf(await license(post("validate"), ENV, "validate")), "error");
});

/// A deploy that forgot the secrets answers every re-check. If that read as a
/// refusal, one bad deploy would destroy every licence we have ever sold.
test("a Worker deployed without its secrets does not revoke anybody", async () => {
  creemReplies();
  assert.equal(await verdictOf(await license(post("validate"), {}, "validate")), "error");
  assert.equal(calls.length, 0, "must not call Creem without credentials");
});

/// Someone sharing an office address with a script must not be thrown out of
/// software they paid for because a neighbour hammered the endpoint.
test("being rate limited does not revoke anybody", async () => {
  creemReplies();
  const env = { ...ENV, LICENSE_RATE_LIMIT: { limit: async () => ({ success: false }) } };
  const response = await license(post("validate"), env, "validate");
  assert.equal(response.status, 429);
  assert.equal(await verdictOf(response), "error");
  assert.equal(calls.length, 0, "a throttled request must not reach Creem");
});

/// Forgetting to configure the limiter should cost us money, not cost every
/// customer their app.
test("a missing rate limiter lets the request through", async () => {
  creemReplies({ json: licence() });
  assert.equal(await verdictOf(await license(post("validate"), ENV, "validate")), "ok");
});

/// A status string Creem adds after this code ships — "trialing", "paused",
/// anything — is something we do not understand, and not understanding must
/// never be a reason to delete a licence.
test("an unrecognised licence status does not revoke anybody", async () => {
  creemReplies({ json: licence({ status: "trialing" }) });
  assert.equal(await verdictOf(await license(post("validate"), ENV, "validate")), "error");
});

test("an unrecognised activation status does not revoke anybody", async () => {
  creemReplies({ json: licence({ instance: { id: "inst_1", status: "suspended" } }) });
  assert.equal(await verdictOf(await license(post("validate"), ENV, "validate")), "error");
});

/// A re-check must not re-litigate which product a key belongs to. That was
/// settled at activation and cannot change afterwards, so the only thing this
/// check could still do on a re-check is destroy a working licence if Creem
/// ever shapes the field differently here than it does at activation.
test("a re-check does not re-decide which product a key belongs to", async () => {
  creemReplies({ json: licence({ product_id: "prod_something_else" }) });
  assert.equal(await verdictOf(await license(post("validate"), ENV, "validate")), "ok");
});

/// Same reasoning for mode. The guard that keeps this check on the activation
/// path is one word long; if it is ever dropped, this fails.
test("a re-check does not re-decide whether a key is live", async () => {
  creemReplies({ json: licence({ mode: "test" }) });
  assert.equal(await verdictOf(await license(post("validate"), ENV, "validate")), "ok");
});

/// A limiter that throws is a limiter we cannot consult. Refusing to serve
/// because our own throttle broke would cost a customer the app.
test("a rate limiter that throws lets the request through", async () => {
  creemReplies({ json: licence() });
  const env = {
    ...ENV,
    LICENSE_RATE_LIMIT: {
      limit: async () => {
        throw new Error("limiter unavailable");
      },
    },
  };
  assert.equal(await verdictOf(await license(post("validate"), env, "validate")), "ok");
});

/// The same HTML-from-a-captive-portal case, on the path where somebody is
/// sitting there having just pasted their key.
test("a captive portal during activation does not read as a refusal", async () => {
  creemReplies({ status: 200, text: "<html>Sign in to WiFi</html>" });
  assert.equal(
    await verdictOf(await license(post("activate", { key: "K" }), ENV, "activate")),
    "error"
  );
});

/// This name is stored on our Creem account and shown to the customer as the
/// machine they can deactivate. A blank or absurd one makes that list useless.
test("a missing or oversized Mac name is made sane before it is stored", async () => {
  creemReplies({ json: licence() });
  await license(post("activate", { key: "K", instance_name: "   " }), ENV, "activate");
  assert.equal(calls[0].body.instance_name, "Unnamed Mac");

  calls = [];
  creemReplies({ json: licence() });
  await license(post("activate", { key: "K", instance_name: "M".repeat(500) }), ENV, "activate");
  assert.equal(calls[0].body.instance_name.length, 80);
});

/// Giving back a stranger's activation slot is best-effort. If that call
/// fails we still owe the person in front of us a straight answer, and we
/// must not fall through to pretending the key worked.
test("a failed release still refuses the stranger's key", async () => {
  creemReplies(
    { json: licence({ product_id: "prod_someone_else" }) },
    { network: "down" }
  );
  assert.equal(
    await verdictOf(await license(post("activate", { key: "K" }), ENV, "activate")),
    "refused"
  );
  assert.equal(calls.length, 2);
});

// ---------- refusals that must still happen ----------

/// The whole point of re-checking. A refunded or revoked key has to stop
/// working, or the refund policy is unenforceable.
test("a dead licence is refused", async () => {
  for (const status of ["inactive", "expired", "disabled"]) {
    calls = [];
    creemReplies({ json: licence({ status }) });
    assert.equal(
      await verdictOf(await license(post("validate"), ENV, "validate")),
      "refused",
      `status ${status} must revoke`
    );
  }
});

/// Someone moved their three activations to other machines. This Mac loses
/// removal; their licence does not.
test("an activation removed from another machine is refused", async () => {
  creemReplies({ json: licence({ instance: { id: "inst_1", status: "inactive" } }) });
  assert.equal(await verdictOf(await license(post("validate"), ENV, "validate")), "refused");
});

// ---------- activation ----------

test("a good key activates and returns the new activation id", async () => {
  creemReplies({ json: licence() });
  const response = await license(
    post("activate", { key: "ABCDE-FGHIJ", instance_name: "Ricardo's MacBook Pro" }),
    ENV,
    "activate"
  );
  const body = await response.json();
  assert.equal(body.verdict, "ok");
  assert.equal(body.instance_id, "inst_1");
  assert.equal(calls[0].body.instance_name, "Ricardo's MacBook Pro");
});

/// Creem's licence API answers for the whole store. Without this check, a key
/// for anything else we ever sell unlocks removal in RollScrub.
test("a valid key for another product is refused, and its activation given back", async () => {
  creemReplies({ json: licence({ product_id: "prod_someone_else" }) }, { json: {} });
  assert.equal(
    await verdictOf(await license(post("activate", { key: "K" }), ENV, "activate")),
    "refused"
  );
  assert.equal(calls.length, 2, "the instance we created must be released");
  assert.match(calls[1].url, /deactivate$/);
  assert.equal(calls[1].body.instance_id, "inst_1");
});

/// Test-mode keys are free to mint. One must never unlock a shipped copy.
test("a test-mode key is refused, and its activation given back", async () => {
  for (const mode of ["test", "sandbox", "local"]) {
    calls = [];
    creemReplies({ json: licence({ mode }) }, { json: {} });
    assert.equal(
      await verdictOf(await license(post("activate", { key: "K" }), ENV, "activate")),
      "refused",
      `mode ${mode} must be refused`
    );
    assert.match(calls[1].url, /deactivate$/);
  }
});

/// The regression that nearly shipped: the live mode was guessed as "prod",
/// and Creem documents no live example. Demanding an exact guessed value
/// refuses every real key — and on a re-check, refusing deletes a paid
/// licence. Anything that is not a known test mode has to work.
test("a live key whose mode we have never seen still activates", async () => {
  for (const mode of ["live", "prod", "production", undefined]) {
    calls = [];
    creemReplies({ json: licence({ mode }) });
    assert.equal(
      await verdictOf(await license(post("activate", { key: "K" }), ENV, "activate")),
      "ok",
      `mode ${mode} must be treated as live`
    );
  }
});

/// A mistyped key belonging to a stranger would otherwise silently eat one of
/// their three activations.
test("a key Creem rejects at activation is refused without burning a slot", async () => {
  creemReplies({ status: 404, json: { error: "Not Found" } });
  assert.equal(
    await verdictOf(await license(post("activate", { key: "typo" }), ENV, "activate")),
    "refused"
  );
  assert.equal(calls.length, 1);
});

// ---------- deactivation: the destructive one ----------

/// This route reaches a real, irreversible action on Creem's side, and it is
/// open to anyone. If ownership were checked after the call rather than
/// before, it would be a free deactivation service for every other seller on
/// Creem: anybody holding any key and activation id could spend it against a
/// stranger's product.
test("deactivating a key for another product removes nothing", async () => {
  creemReplies({ json: licence({ product_id: "prod_someone_else" }) });
  assert.equal(
    await verdictOf(await license(post("deactivate"), ENV, "deactivate")),
    "refused"
  );
  assert.equal(calls.length, 1, "ownership is read before anything is removed");
  assert.match(calls[0].url, /validate$/);
});

/// Same reasoning: if we cannot establish ownership, we remove nothing.
test("deactivating removes nothing when Creem cannot be reached", async () => {
  creemReplies({ network: "down" });
  assert.equal(await verdictOf(await license(post("deactivate"), ENV, "deactivate")), "error");
  assert.equal(calls.length, 1);
});

test("deactivating our own key reads first, then removes", async () => {
  creemReplies({ json: licence() }, { json: licence({ status: "inactive" }) });
  assert.equal(await verdictOf(await license(post("deactivate"), ENV, "deactivate")), "ok");
  assert.equal(calls.length, 2);
  assert.match(calls[0].url, /validate$/);
  assert.match(calls[1].url, /deactivate$/);
});

// ---------- shape of the request itself ----------

/// A GET is not a licence operation. Answering one would let a link in an
/// email deactivate somebody's Mac.
test("only POST is answered", async () => {
  creemReplies();
  const response = await license(
    new Request("https://rollscrub.com/license/deactivate"),
    ENV,
    "deactivate"
  );
  assert.equal(response.status, 405);
  assert.equal(calls.length, 0);
});

/// The reply decides whether paid software keeps working; a cache between us
/// and the customer must never answer it.
test("replies are never cached", async () => {
  creemReplies({ json: licence() });
  const response = await license(post("validate"), ENV, "validate");
  assert.equal(response.headers.get("cache-control"), "no-store");
});

/// `wrangler secret put` stores exactly what it is given, and a value pasted
/// from a dashboard frequently carries a trailing newline. Untrimmed, that
/// makes every activation fail as "a different product" — a failure with no
/// visible cause, pointing at the wrong thing.
test("a secret pasted with stray whitespace still matches", async () => {
  creemReplies({ json: licence() });
  const env = { CREEM_API_KEY: "creem_test_key\n", CREEM_PRODUCT_ID: " prod_ours\n" };
  const response = await license(post("activate", { key: "K" }), env, "activate");
  assert.equal(await verdictOf(response), "ok");
});

/// A secret set to nothing but whitespace is not configured. It has to read
/// as "could not check", not as a refusal.
test("a whitespace-only secret counts as missing, not as a refusal", async () => {
  creemReplies();
  const env = { CREEM_API_KEY: "  ", CREEM_PRODUCT_ID: "prod_ours" };
  const response = await license(post("validate"), env, "validate");
  assert.equal(await verdictOf(response), "error");
  assert.equal(calls.length, 0);
});
