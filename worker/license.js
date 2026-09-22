/**
 * Licence proxy in front of Creem.
 *
 * Creem authenticates its licence endpoints with `x-api-key`, a store-wide
 * secret that can create and remove activations for every customer. It cannot
 * ship inside the app: a notarized binary is still a public file, and anyone
 * who extracts the key can deactivate licences wholesale. So the app talks to
 * this Worker, and only this Worker holds the key. (Lemon Squeezy's licence
 * API needed no credential, which is why the app used to call it directly.)
 *
 * Two checks live here rather than in the app, where a patched binary cannot
 * reach them:
 *
 *   - the key belongs to *our* product. Creem answers for the whole store, so
 *     without this any key for anything else we ever sell unlocks removal.
 *   - the key is a live key, not a test-mode one. Test keys are free.
 *
 * The reply is a small envelope of ours rather than Creem's, because the app
 * has to tell "the server says this licence is dead" apart from "the server
 * could not answer". Getting that backwards locks a paying customer out of
 * their own photographs, so the distinction is carried explicitly in
 * `verdict` instead of being re-derived from a status code at the far end.
 */

const CREEM_API = "https://api.creem.io/v1/licenses";

/**
 * The modes Creem stamps on a key that is not real money.
 *
 * A denylist rather than a check for "live", because the two directions fail
 * in very different ways. Creem's published examples only ever show `local`,
 * `test` and `sandbox`; no example shows whatever a live key says. Demanding
 * an exact live value we have guessed would turn every genuine key into a
 * refusal — and on a re-check, a refusal deletes a licence somebody paid for.
 * Naming the test modes instead means an unrecognised mode is allowed
 * through, and the worst case there is that a test key works on a machine
 * whose owner already has our dashboard credentials.
 */
const TEST_MODES = new Set(["local", "test", "sandbox"]);

/**
 * The statuses that mean a licence is genuinely dead, per Creem's documented
 * set (`active` | `inactive` | `expired` | `disabled`).
 *
 * Named explicitly for the same reason as TEST_MODES: revoking on "anything
 * that is not active" would hand a status string we have never seen — one
 * Creem adds next year, say — the power to delete a paid licence on the next
 * re-check. Anything outside both this set and "active" is something we do
 * not understand, and not understanding is `error`, never `refused`.
 */
const DEAD_STATUSES = new Set(["inactive", "expired", "disabled"]);

/** A refusal envelope for a dead licence, or null when it is not dead. */
function deadStatus(status, reason) {
  if (status === "active") return null;
  if (DEAD_STATUSES.has(String(status))) return envelope("refused", { reason: reason(status) });
  return envelope("error", { reason: CANNOT_TELL }, 502);
}

/**
 * What the app may conclude:
 *   "ok"      — the licence is live.
 *   "refused" — Creem positively said otherwise. The app may forget it.
 *   "error"   — we could not find out. The app must change nothing, and the
 *               offline grace window covers the gap.
 *
 * Every path that is not an authoritative answer about a real licence must
 * return "error". When in doubt, doubt.
 */
function envelope(verdict, fields = {}, status = 200) {
  return Response.json(
    { verdict, ...fields },
    { status, headers: { "cache-control": "no-store" } }
  );
}

const CANNOT_TELL = "The licence could not be checked right now.";

/** Trimmed, length-capped, and never empty — this is stored on our account. */
function instanceName(supplied) {
  const name = typeof supplied === "string" ? supplied.trim().slice(0, 80) : "";
  return name || "Unnamed Mac";
}

/**
 * The configured values, with surrounding whitespace removed.
 *
 * `wrangler secret put` stores what it is handed, and a value pasted from a
 * dashboard often arrives with a trailing newline. On the product id that is
 * invisible and merciless: every activation is refused as belonging to a
 * different product, and the message sends you looking at the wrong store.
 * On the API key a stray newline is an illegal header value, which throws
 * inside fetch and reads as "Creem is unreachable" forever.
 */
const apiKey = (env) => env.CREEM_API_KEY?.trim();
const ourProduct = (env) => env.CREEM_PRODUCT_ID?.trim();

async function callCreem(env, action, payload) {
  const response = await fetch(`${CREEM_API}/${action}`, {
    method: "POST",
    headers: {
      "x-api-key": apiKey(env),
      "content-type": "application/json",
      accept: "application/json",
    },
    body: JSON.stringify(payload),
  });
  // A body that is not JSON is not an answer about anybody's licence.
  const json = await response.json().catch(() => null);
  return { response, json };
}

/**
 * An activation we created on a licence that turned out not to be ours, undone.
 *
 * Checked after activating rather than before keeps the happy path to one
 * round trip, but it means a mistyped key belonging to another product has
 * already eaten one of that stranger's activation slots. Give it back.
 */
async function releaseInstance(env, key, instanceID) {
  if (!instanceID) return;
  try {
    await callCreem(env, "deactivate", { key, instance_id: instanceID });
  } catch {
    // Nothing useful to do, and it must not change what we tell the app.
  }
}

/**
 * Whether this caller is asking too often.
 *
 * Two deliberate choices, both of which favour the paying customer over the
 * abuser:
 *
 *   - Being throttled answers `error`, never `refused`. A refusal deletes a
 *     licence; someone sharing an office NAT with a script must not lose what
 *     they bought because a neighbour hammered the endpoint.
 *   - A missing or broken binding allows the request. Forgetting to configure
 *     a limiter should cost us money, not cost every customer their app.
 *
 * The limit is per address *and* per action, so a flood of activations cannot
 * starve the re-checks that keep existing customers working.
 */
async function throttled(env, request, action) {
  if (!env.LICENSE_RATE_LIMIT) return false;
  const address = request.headers.get("cf-connecting-ip") ?? "unknown";
  try {
    const { success } = await env.LICENSE_RATE_LIMIT.limit({ key: `${address}:${action}` });
    return !success;
  } catch {
    return false;
  }
}

/**
 * Establishes, without changing anything, that a key is one of ours.
 *
 * Returns null when it is, and the envelope to send back when it is not or
 * when we could not find out. Every uncertain path is `error`, so failing to
 * confirm ownership never destroys an activation.
 */
async function confirmOurs(env, key, instanceID) {
  let response, json;
  try {
    ({ response, json } = await callCreem(env, "validate", {
      key,
      instance_id: instanceID,
    }));
  } catch {
    return envelope("error", { reason: CANNOT_TELL }, 502);
  }
  if (!response.ok || !json || typeof json !== "object") {
    return envelope("error", { reason: CANNOT_TELL }, 502);
  }
  if (json.product_id !== ourProduct(env)) {
    return envelope("refused", {
      reason: "That key is for a different product, not RollScrub.",
    });
  }
  return null;
}

/**
 * @param action "activate" | "validate" | "deactivate"
 */
export async function license(request, env, action) {
  if (request.method !== "POST") {
    return envelope("error", { reason: "Method not allowed." }, 405);
  }

  if (await throttled(env, request, action)) {
    return envelope("error", { reason: CANNOT_TELL }, 429);
  }

  // A missing binding is our mistake, and it must read as "could not find
  // out". Were it a refusal, one bad deploy would revoke every licence in the
  // field the first time each copy re-checked itself.
  if (!apiKey(env) || !ourProduct(env)) {
    return envelope("error", { reason: CANNOT_TELL }, 503);
  }

  const body = await request.json().catch(() => null);
  const key = typeof body?.key === "string" ? body.key.trim() : "";
  if (!key) {
    return envelope("refused", { reason: "Enter the licence key from your purchase email." });
  }

  const payload = { key };
  if (action === "activate") {
    payload.instance_name = instanceName(body?.instance_name);
  } else {
    const instanceID = typeof body?.instance_id === "string" ? body.instance_id : "";
    if (!instanceID) return envelope("error", { reason: CANNOT_TELL }, 400);
    payload.instance_id = instanceID;
  }

  // Deactivation is the one destructive call here, and it cannot be taken
  // back: the activation is gone from Creem the moment the request lands.
  // Checking afterwards that the key was ours would be checking after the
  // harm, and would make this route a free deactivation service for every
  // other seller on Creem — anyone holding any key and instance id could
  // spend it against a stranger's product. So ownership is established first,
  // with a read, and only then is anything removed.
  if (action === "deactivate") {
    const owned = await confirmOurs(env, key, payload.instance_id);
    if (owned !== null) return owned;
  }

  let response, json;
  try {
    ({ response, json } = await callCreem(env, action, payload));
  } catch {
    return envelope("error", { reason: CANNOT_TELL }, 502);
  }

  if (!response.ok) {
    // Only an *activation* may be refused on an HTTP error, because there the
    // person is sitting in front of the app having just typed something and a
    // 400 or 404 means they typed it wrong. A re-check of a licence that
    // already worked is never refused this way: 403 is our own API key being
    // rotated, 404 is indistinguishable from us pointing at the wrong store,
    // and 5xx is Creem being unwell. None of those is evidence about the
    // customer.
    if (action === "activate" && (response.status === 400 || response.status === 404)) {
      return envelope("refused", { reason: "That licence key was not accepted." });
    }
    return envelope("error", { reason: CANNOT_TELL }, 502);
  }

  // A 200 describes a real licence, so from here refusals are authoritative.
  if (!json || typeof json !== "object") {
    return envelope("error", { reason: CANNOT_TELL }, 502);
  }

  if (action === "deactivate") return envelope("ok");

  const created = action === "activate" ? json.instance?.id : null;

  // Activation only, for the same reason as the mode check below: a key's
  // product cannot change after it is activated, so a re-check can only ever
  // confirm what we already established — while carrying the full cost of
  // being wrong. If Creem's validate reply ever shaped this field differently
  // from its activate reply, an unguarded check here would delete every
  // customer's licence on their next daily re-check, silently, with nobody
  // having done anything. Deactivation does its own check in confirmOurs(),
  // before it removes anything.
  if (action === "activate" && json.product_id !== ourProduct(env)) {
    await releaseInstance(env, key, created);
    return envelope("refused", {
      reason: "That key is for a different product, not RollScrub.",
    });
  }

  // Only at activation, where the person is sitting in front of the app and a
  // wrong reading of this field shows up immediately. On a re-check it is
  // worse than useless: a key's mode never changes after it is activated, so
  // there is nothing to catch, and a surprise value here would revoke a
  // working licence.
  if (action === "activate" && TEST_MODES.has(String(json.mode))) {
    await releaseInstance(env, key, created);
    return envelope("refused", { reason: "That licence key is not a live key." });
  }

  const dead = deadStatus(json.status, (s) => `That licence is ${s}.`);
  if (dead !== null) return dead;

  if (action === "activate") {
    if (typeof created !== "string" || !created) {
      return envelope("error", { reason: CANNOT_TELL }, 502);
    }
    return envelope("ok", { instance_id: created });
  }

  // Re-check. The licence can be live while *this* Mac's activation is not —
  // someone deactivated it from another machine, or moved their three
  // activations elsewhere. An absent instance tells us nothing, so it is an
  // error rather than a refusal.
  const gone = deadStatus(json.instance?.status, () => "This Mac's activation was removed.");
  if (gone !== null) return gone;
  return envelope("ok", { instance_id: payload.instance_id });
}
