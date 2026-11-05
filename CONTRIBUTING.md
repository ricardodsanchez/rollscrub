# Contributing to RollScrub

Thank you for helping. RollScrub moves people's photographs around, so the
bar for changes is higher than usual. This page explains it. The full
reasoning is in [CLAUDE.md](CLAUDE.md).

## Reporting a bug

Open an issue and include:

- your macOS version and Mac (Apple silicon or Intel)
- what kind of drive was scanned: internal, external, network, or iCloud Drive
- what you expected, and what happened instead
- the report RollScrub wrote, if there is one (remove any paths you'd rather
  keep private)

If the bug could make RollScrub delete, damage or misplace a file, **don't
open a public issue**. Follow [SECURITY.md](SECURITY.md) instead.

## Before you open a pull request

1. **Run the tests.** `swift test` must pass and should still take under a
   second. If you touched `worker/`, also run `npm test`.
2. **Every bug fix needs a test that fails without the fix.** Prove it: stash
   only the fix, keep the test, run it, and check that it fails for the right
   reason before you put the fix back.
3. **Name tests as sentences about behaviour**, for example
   `testKeepsTheOriginalOverASiblingWithADashSuffix`. Each test gets a comment
   saying what goes wrong for a real person if it fails.
4. **Tests leave no trace.** Nothing may be written to Application Support,
   Preferences or the Keychain outside a test's own temp directory.
   `ScratchStateDirectory` shows how.
5. **If you touched the scan path, measure it** before and after on a real
   folder, and put both numbers in the pull request:

   ```bash
   swift build -c release --product rollscrub
   /usr/bin/time -p "$(swift build -c release --product rollscrub --show-bin-path)/rollscrub" \
     ~/Documents --out /tmp/report.txt
   ```

   The test fixtures are tiny, so a change that makes scanning 100 times
   slower still passes every test.

## Changes that need extra care

Any change to `Mover`, `DuplicateScanner`, `KeepSelector` or `SkipRules` is
treated as able to destroy data until a test shows it can't. Expect a slow
review. Explain in the pull request how each rule in the README's "What it
will never do" still holds.

## License

By contributing, you agree that your contribution is licensed under the
[GNU GPL v3](LICENSE), the same license as the rest of the project.
