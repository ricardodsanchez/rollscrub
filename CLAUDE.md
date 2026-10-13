# RollScrub

A macOS app and CLI that finds byte-identical duplicate photos and videos and
sets them aside for review. Swift Package Manager; `RollScrubCore` holds the
logic, `RollScrubApp` the SwiftUI app, `rollscrub` the CLI.

Sold for $19 through Creem. Distributed directly — Developer ID signed,
notarized, updated through Sparkle from `rollscrub.com`. There is no App Store
review standing between a mistake and a customer's photo library.

## What this program must never do

It points at irreplaceable files. Every rule below exists because the cost of
being wrong is somebody's photographs.

- **Never delete.** `--move` relocates files into `_duplicates_review/` on the
  same volume. The user deletes. Undo is never gated behind a licence.
- **Never move a file off the volume it was found on.**
- **Verify byte for byte immediately before moving**, not only during the scan.
  Files change between the two.
- **Never descend into a managed library** (`.photoslibrary`, `.fcpbundle`,
  `.lrlibrary`, `.aplibrary`). Their internal derivatives are legitimately
  identical to originals elsewhere; "deduplicating" them corrupts the catalogue
  silently, and the damage surfaces months later.
- **Never read an evicted iCloud file.** Reading one byte downloads the whole
  thing. Count and skip.

When a change touches `Mover`, `DuplicateScanner`, `KeepSelector` or
`SkipRules`, assume it can destroy data until a test says otherwise.

## Performance is a correctness property here

Scans walk entire home folders and external drives. A change that makes
enumeration 100× slower is as much a bug as a wrong answer, and it will not
show up in the test suite — the fixtures are tiny.

**Measure before and after, on a real tree, whenever you touch the scan path.**
The CLI is the instrument:

If `swift test` dies in `CodeSign` with *"resource fork, Finder information,
or similar detritus"*, the repo is in an iCloud-synced folder and sync has put
`com.apple.FinderInfo` back on `.build`. Build elsewhere —
`swift test --scratch-path /tmp/rollscrub-build` — or exclude `.build` from
sync. It is never the code.

```bash
swift build -c release --product rollscrub
/usr/bin/time -p "$(swift build -c release --product rollscrub --show-bin-path)/rollscrub" \
  ~/Documents --out /tmp/report.txt
```

Record the number in the commit message when it moved.

Specific traps, each of which has already happened:

- **`URLResourceKey`s are not all cheap.** `.isUbiquitousItemKey` and
  `.ubiquitousItemDownloadingStatusKey` are a round trip to the file provider
  daemon — ~1.2ms per item in an iCloud folder, against ~8µs for the keys that
  come off the directory entry. Requesting them for every entry the walk
  touches cost 73.6s per 60,000 items versus 0.46s without. Fetch expensive
  keys **after** the cheap filters, for candidates only.
- **A home folder is mostly not photos.** `node_modules`, `.git`, `.build` and
  friends hold more files than everything else combined. Prune, don't filter.
- **Progress must tick on work done, not results found.** Reporting only when a
  media file is appended leaves the UI frozen for minutes while the walk grinds
  through a build directory. Users read a frozen counter as a hang.

## Tests

`swift test` — 119 tests, and they run in under a second. Keep it that way.

`npm test` — 35 tests over the Worker: the licence proxy in
`worker/license.js`, and the person-or-crawler split in `worker/index.js`.
Node's own runner, no dependencies. Name the file explicitly
(`worker/*.test.js`), not the directory: `node --test worker/` reports one
passing test and runs none of them, which is the same green-on-nothing trap as
a `swift test` that filtered everything out.

The Worker tests stub `fetch` and assert on the *verdict* the proxy returns
for every way Creem can fail — 403, 404, 5xx, HTML from a captive portal, an
unrecognised status. Those cases are the point of the file: each one is a way
a customer could lose software they paid for.

**Every bug fix needs a test that fails without the fix.** Prove it, don't
assume it:

```bash
git stash push -q Sources/RollScrubCore/TheFile.swift   # the fix only, not the test
swift test --filter TheTests                            # must FAIL, and for the right reason
git stash pop -q
```

Stashing both the fix and its test runs zero tests and reports success. Check
the failure count and the assertion message, not just the exit code.

**A test run must leave no trace outside its own temp directory.** Anything
that writes to Application Support, Preferences, or the Keychain needs its
location injected — `ReviewSession.stateDirectoryOverride` is the pattern, and
`ScratchStateDirectory` wires it into `setUp`/`tearDown`. This kind of mess is
invisible, permanent and grows on every run, so it is caught by checking rather
than by noticing: count the files in the target directory before and after a
full `swift test`.

Tests are named as sentences about behaviour
(`testKeepsTheOriginalOverASiblingWithADashSuffix`), and each carries a comment
saying what breaks in the real world if it fails. A test whose comment is just
a restatement of its assertion is not earning its place.

## Review by a second model

The model that writes code is the worst judge of it — it re-reads its own
intent instead of what is on the page. Several of the serious defects in this
repo shipped through a confident self-review: a `grep -q` under `pipefail` that
failed *because* its pattern matched, a `.standardized` that silently skipped
every file behind a symlink, a dark-mode selector that made the download button
invisible.

**Before anything reaches a release, have a different model read it.** Do this
without being asked — it is a standing instruction, not an offer to make.

Spawn reviewers with the `Agent` tool, passing an explicit `model` that is
**not** the model that wrote the change. Available: `opus`, `sonnet`, `fable`,
`haiku`. Use two reviewers on different models for anything that can destroy
data; one is enough for copy, site and build-script changes.

Give each reviewer the diff and the constraints it is judging against —
a reviewer that has to guess the rules invents them:

```
Review this diff against RollScrub, a macOS duplicate-photo finder.
Read CLAUDE.md first for the invariants; they are not negotiable.

<diff>

Answer three questions, with file:line evidence for each claim:
1. Can this cause a file the user cannot get back to be deleted, moved
   off its volume, moved without a fresh byte-for-byte verification, or
   moved out of a managed photo library? Trace the actual code path.
2. What does this cost on a 200,000-file tree, most of it not media and
   much of it evicted to iCloud? Name any per-item filesystem or network
   call and say how many times it runs.
3. Where is it wrong in a way the tests would not catch? The fixtures are
   tiny and synthetic.

Do not summarise what the diff does — I wrote it. Report only defects,
ranked by what they cost the user. "No defects found" is a valid answer.
```

Then **verify every finding against the code before acting on it.** Reviewers
confabulate, especially about code they have only seen as a diff; a confident
wrong review that sends you rewriting correct code is worse than no review. If
a finding survives checking, fix it and say so. If it does not, say that too,
with the evidence — do not quietly discard it.

Anything touching data destruction, licensing, signing or notarization gets two
models without exception.

## Release

`./release.sh` builds into a temp dir, notarizes, staples, packages, and
regenerates the appcast. It never touches `/Applications` — replacing a running
bundle kills the app with no crash report, which looks exactly like a bug in
the app itself.

```bash
VERSION=1.0.1 BUILD=2 ./release.sh
```

`BUILD` must increase every release. Sparkle compares `CFBundleVersion` and
nothing else; shipping two different binaries with the same build number means
whoever has the first one never gets the second.

After pushing, verify against the live URL rather than the local file — compare
the sha256 of `https://rollscrub.com/releases/…` with what was built, and
confirm `spctl -a -vv` reports `Notarized Developer ID`. A broken appcast fails
silently, forever, for everyone.

## Licensing

Keys are Creem's, three activations, never expiring.

**The app never talks to Creem.** Creem's licence endpoints authenticate with
`x-api-key`, a store-wide secret that can remove any customer's activations,
and a downloadable binary cannot hold a secret. `worker/license.js` on
rollscrub.com holds the key and is the only thing that calls Creem. It needs
two secrets set, and refuses to answer at all without them:

```bash
npx wrangler secret put CREEM_API_KEY
npx wrangler secret put CREEM_PRODUCT_ID
```

**Both secrets must come from the same Creem mode, and for a real shop both
must be live.** Test and live are separate environments: a product created in
test mode has a different `prod_…` id, and that id does not exist as far as a
live key is concerned. Mixing them fails in the most confusing direction
available — Creem answers 404 for a product the key cannot see, the proxy
turns an unrecognised answer into `error`, and `error` is indistinguishable
from Creem being down. Swap them together, then deploy.

`wrangler secret put` refuses while the Worker's newest uploaded version is
not the deployed one ("the latest version of your Worker isn't currently
deployed"). Deploy first, then set the secret. Do **not** reach for
`wrangler versions secret put` to get around it: that writes the secret into a
new *undeployed* version, reports success, and leaves the live Worker without
it — which reads as `error` on every activation.

- **Only an explicit server refusal may revoke a licence.** A timeout, a 500,
  a rotated API key or a missing network must never lock someone out of
  software they bought; that is what the 30-day offline grace is for.

  This is why the Worker replies with a `verdict` of `ok`, `refused` or
  `error` rather than letting the app read meaning out of a status code.
  Creem returns 403 when *our* key is wrong and 404 when a key is unknown —
  both indistinguishable from a misconfigured deploy. So only an
  authoritative 200 may refuse a re-check, and anything unrecognised is
  `error`, which changes nothing. `License.verdict(from:)` is the single
  place that decides, and `LicenseTests` exists to keep `refused` and
  `error` apart.
- The licence API answers for the **whole store**. "Valid" does not mean
  "bought from us" — the Worker checks `product_id` against
  `CREEM_PRODUCT_ID`, because a key for any other product we ever sell would
  otherwise unlock removal. That check is server-side on purpose: in the app,
  a patched binary skips it.
- **Every refusal names the values it refuses on. None is spelled "not the
  value I expected".** A key is rejected as test-mode because its `mode` is
  one of `local`/`test`/`sandbox`, and as dead because its `status` is one of
  `inactive`/`expired`/`disabled` — never because the field failed to match a
  value we guessed. Creem publishes no example of what a live key's `mode`
  says, and demanding a guessed one would refuse every real key, which on a
  re-check *deletes* a paid licence. A field value we do not recognise is
  `error`, and `error` changes nothing.

  The mode check also runs at activation only: a key's mode cannot change
  afterwards, so re-checking it risks everything and catches nothing.
- **Ownership is confirmed before anything is removed.** `/license/deactivate`
  reads first and deletes second. The other order would make the route a free
  deactivation service for every other seller on Creem: anyone holding any key
  and instance id could spend it against a stranger's product.
- An activation created on a key that turns out not to be ours is released
  again, so a mistyped key does not eat a stranger's activation slot.
- **Being throttled is `error`, and a missing limiter lets the request
  through.** The proxy is unauthenticated by nature and forwards to an API we
  are billed on, so it is rate limited per address per action — but a limiter
  that could answer `refused`, or one whose absence closed the door, would
  cost a customer their licence to save us money. That trade never goes that
  way.
- **A re-check confirms that a licence is alive, and nothing else.** Which
  product a key belongs to, and whether it is a live key, are settled at
  activation and cannot change afterwards — so those checks are scoped to the
  activation path. Re-asking them daily could only ever confirm what we
  already knew, while betting every customer's licence on Creem shaping a
  field the same way in two different replies. Deactivation still checks
  ownership in `confirmOurs()`, because it removes something.
- **The app re-checks at most once a day** (`License.recheckInterval`), not on
  every launch. The grace window is thirty days; spending a customer's network
  and Creem's rate limit dozens of times a day to re-learn the same answer
  buys nothing.
- **Activation and the daily re-check are verified against live Creem**,
  23 September 2026: a real key passes the product-id and live-mode checks,
  and `validate` returns `ok` — so Creem shapes `status` and `instance.status`
  in its validate reply the way `license.js` reads them. Worth having checked:
  had it differed, every re-check would answer `error`, which changes nothing
  for thirty days and then locks out every paying customer at once. The
  removal half of `/license/deactivate` is still unexercised live.
- **A refund revokes.** Verified on a test purchase, 22 September 2026: after
  refunding, Creem shows the licence as `inactive`, which the proxy already
  treats as dead — so the app drops back to locked on its next daily
  re-check. No webhook is needed for this. Still taken on trust: that the API
  reports the same word the dashboard displays, and that live mode behaves as
  test mode did. Confirm both on the first real refund — a 100%-off order may
  not be refundable at all, so this one cannot be settled before a real sale.
- Never gate undo.
- **The CLI's file inside the bundle is named `rollscrub-cli`, not
  `rollscrub`.** The default macOS volume is case-insensitive APFS, where
  `rollscrub` and the app's own `RollScrub` executable are the same directory
  entry — building the CLI into the bundle under that name overwrote the app
  binary with the CLI's bytes instead of creating a second file. lipo and
  codesign --verify still passed, since each was validating a real, validly
  signed binary, just not the one intended. Caught two ways the same night,
  through two different paths: run through `release.sh`, its developer-unlock
  check (below) counts every file in `Contents/MacOS` and refuses under 2 —
  a collision leaves only 1 — which stopped it before notarization. Run
  through `make-app.sh` directly (as when reproducing this to debug it),
  nothing stopped it, and only launching the installed result showed the
  problem, printing the CLI's own `--help` instead of opening a window.
  `make-app.sh` now checks for this directly, so a bare build is no longer
  the unguarded path: every filename actually present in `Contents/MacOS` is
  lowercased and checked for a duplicate, which catches a collision
  regardless of what either binary is named at the time — a fixed
  byte-comparison between two hardcoded paths was tried first and rejected,
  since it goes silently unreachable the moment either name changes
  elsewhere and the comparison is not updated to match. The external command
  is still `rollscrub` — `CommandLineTool.swift` symlinks
  `/usr/local/bin/rollscrub` to the renamed path, so nobody types the bundle
  name.
- **The CLI is a separate binary, so the keychain is not silently shared.**
  It ships inside the bundle at `Contents/MacOS/rollscrub-cli` and is signed
  with its own identifier, `com.rollscrub.cli`. A macOS keychain item created
  by `SecItemAdd` with no access group is ACL'd to the creating code signature
  alone, so the CLI's first read is expected to raise the system permission
  dialog rather than succeed silently — and a headless run, which is the
  CLI's whole purpose, cannot answer it. **Unverified on hardware**: confirm
  before the site claims the CLI again, by activating in the app and running
  the bundled binary from a fresh login.

  The supported fix is a shared `keychain-access-group` entitlement on both
  binaries (Team `R398R96429`) plus `kSecAttrAccessGroup` on all three
  keychain queries in `License.swift`, likely with the data-protection
  keychain. It is deliberately *not* done yet: getting it wrong means every
  customer's stored licence becomes unreadable, which is the one failure this
  file exists to prevent, and it cannot be tested anywhere but a real Mac.
  Until then, Help and the CLI's own refusal both name the prompt and say to
  choose Always Allow.

**A junk-key smoke test proves less than it looks like.** This is the check
worth running after any secret or deploy change:

```bash
curl -s -X POST https://rollscrub.com/license/activate \
  -H 'content-type: application/json' \
  -d '{"key":"definitely-not-a-key","instance_name":"smoke test"}'
```

`{"verdict":"refused",…}` means both secrets are non-empty and Creem answered
— an empty secret returns `error` with a 503 before Creem is called, and a
wrong API key gets a 403 that also becomes `error`. But it says **nothing**
about whether `CREEM_PRODUCT_ID` is right: that refusal comes from the
`!response.ok` branch on Creem's 404, which returns before the `product_id`
comparison is ever reached. A stale test-mode id passes this test. Only a real
key through a real checkout settles it.

**Checking the re-check path by hand:** the keychain item spells the field
`instanceID` (the Swift property name, via `Codable`'s default keys) while the
route expects `instance_id`. Hand it the Swift spelling — or a licence id,
which is a different thing from the activation's instance id — and the reply
is `error`, which looks exactly like the failure being tested for.

```bash
security find-generic-password -s RollScrub -a com.rollscrub.license -w \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps({"key":d["key"],"instance_id":d["instanceID"]}))' \
  | curl -s -X POST https://rollscrub.com/license/validate \
      -H 'content-type: application/json' --data-binary @-
```

`error` is deliberately the same envelope for a missing secret, an unreachable
Creem, a rate-limit trip and a malformed request — right for the app, unhelpful
for diagnosis. It never says *which* thing went wrong, only that nothing was
concluded.

**There is a developer unlock, and it is debug-only.** `ROLLSCRUB_DEVELOPER_UNLOCK=1`
makes `License.isPro()` true in a debug build, so the paid path can be worked
on without spending a real activation:

```bash
ROLLSCRUB_DEVELOPER_UNLOCK=1 swift run RollScrubApp
```

- It is `#if DEBUG` only, so `swift build -c release` does not compile it —
  and `release.sh` greps the built binary for the variable's name and refuses
  to notarize if it is there. That check is not belt-and-braces theatre: a
  release carrying this ships the paid feature to everybody, and is
  indistinguishable from a correct build by looking at it or using it.
- It writes nothing to the keychain. A forged stored licence would outlive the
  debug build that made it, would read as genuine, and the daily re-check
  would ask Creem about a key that does not exist — whose answer is a
  refusal, and refusals delete licences.
- It must be exactly `1`. `swift test` runs in debug too, and a lenient
  reading risks the whole suite running unlocked, asserting nothing about the
  gate it exists to protect. `LicenseTests` pins this, and fails loudly if the
  variable is set in the shell running the tests.
- The licence window names it on screen, so a demo from a debug build cannot
  be mistaken for what a customer gets.

**Before opening the shop, swap the Creem test key for a live one.** Creem
infers test or live from the key itself, and the proxy refuses test-mode keys
at activation — so a live store running on a test key refuses every real
buyer, with a message about the key not being live. It is the most likely way
for launch day to fail.

```bash
npx wrangler secret put CREEM_API_KEY   # the live key, Licenses read+write
```
