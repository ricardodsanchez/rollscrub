# RollScrub

A macOS app and CLI that finds byte-identical duplicate photos and videos and
sets them aside for review. Swift Package Manager; `RollScrubCore` holds the
logic, `RollScrubApp` the SwiftUI app, `rollscrub` the CLI.

Sold for $25 through Lemon Squeezy. Distributed directly — Developer ID signed,
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

`swift test` — 69 tests, and they run in under a second. Keep it that way.

**Every bug fix needs a test that fails without the fix.** Prove it, don't
assume it:

```bash
git stash push -q Sources/RollScrubCore/TheFile.swift   # the fix only, not the test
swift test --filter TheTests                            # must FAIL, and for the right reason
git stash pop -q
```

Stashing both the fix and its test runs zero tests and reports success. Check
the failure count and the assertion message, not just the exit code.

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

Keys are Lemon Squeezy's, product `1358068`, three activations, never expiring.

- The licence API answers for the **whole platform**. "Valid" does not mean
  "bought from us" — `meta.product_id` must be checked, or any seller's key
  unlocks the app.
- Only an explicit server refusal may revoke a licence. A timeout, a 500 or a
  missing network must never lock someone out of software they bought; that is
  what the 30-day offline grace is for.
- Never gate undo.
