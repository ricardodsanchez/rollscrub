# RollScrub

RollScrub finds duplicate photos and videos on a Mac and sets them aside for
you to review. It only calls two files duplicates when every byte matches. It
never guesses from names, dates or how the pictures look.

It is a SwiftUI app and a command line tool, for macOS 14 or later on Apple
silicon and Intel. It is free, and licensed under the
[GNU GPL v3](LICENSE).

Download the signed, notarized app from [rollscrub.com](https://rollscrub.com).
It updates itself.

## What it will never do

RollScrub is pointed at files people cannot replace. These rules are the
reason it exists, and a change that breaks one will not be merged:

- **It never deletes.** The app moves files to the Trash. The CLI moves them
  into a `_duplicates_review/` folder. Emptying either is up to you, and every
  move can be undone.
- **It never moves a file to a different drive.**
- **It checks every byte again just before it moves a file**, not only during
  the scan. Files can change in between.
- **It never looks inside an app's photo or video library**: Photos, iPhoto,
  Lightroom, Aperture, Final Cut, iMovie, Capture One, TV or Music. Those
  libraries keep copies of your originals on purpose, and removing one breaks
  the library without any warning. Pointing RollScrub at a folder inside one
  is refused too.
- **It never reads a cloud file that isn't downloaded.** Reading one byte
  downloads the whole file, so those files are counted and skipped, and
  previews say "Not downloaded" instead of showing them. Checked with iCloud
  Drive. Dropbox and OneDrive use the same macOS system for online-only
  files, so they are expected to work the same way, but have not been tested.
  RollScrub also tells macOS to refuse any download it might trigger.

## Building

You need Xcode 15 or later (or the Swift 5.9 toolchain).

```bash
swift build
swift test
```

Run the app from the build:

```bash
swift run RollScrubApp
```

Run the command line tool:

```bash
swift run rollscrub ~/Pictures --out /tmp/report.txt
```

Without `--move`, the CLI only reads files. Run `rollscrub --help` for every
option.

To build a full `RollScrub.app`, run:

```bash
./make-app.sh ~/Applications
```

Without a Developer ID certificate it signs the app ad hoc. That works on
your own Mac, but the app can't be shared with anyone else.

If `swift test` fails in `CodeSign` with "resource fork, Finder information,
or similar detritus", the repo is in an iCloud-synced folder. Build somewhere
else:

```bash
swift test --scratch-path /tmp/rollscrub-build
```

## Layout

| Path | What it is |
| --- | --- |
| `Sources/RollScrubCore` | Scanning, comparing, choosing which copy to keep, and moving files |
| `Sources/RollScrubApp` | The SwiftUI app |
| `Sources/rollscrub` | The command line tool |
| `Tests/RollScrubCoreTests` | The test suite, which runs in under a second |
| `site/`, `worker/` | rollscrub.com and the Cloudflare Worker that serves it |

[CLAUDE.md](CLAUDE.md) is the project's working notes: why each rule exists,
the performance traps that have already been hit, and how releases are made.
Read it before changing anything in `RollScrubCore`.

## Contributing

Bug reports and fixes are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

If you find a way RollScrub could lose or damage someone's files, please
report it privately first. See [SECURITY.md](SECURITY.md).

## Forks and the name

The GPL covers the code. It doesn't cover the RollScrub name or icon. If you
share a changed version, give it a name and icon of its own. That way nobody
confuses it with this project, or blames this project for its bugs.

A fork should also change `SUFeedURL` and `SUPublicEDKey` in `make-app.sh`.
Otherwise its builds look for updates on rollscrub.com and replace themselves
with the official app.

## License

Copyright © 2026 Ricardo Sanchez.

RollScrub is free software: you can redistribute it and/or modify it under the
terms of the GNU General Public License as published by the Free Software
Foundation, version 3. It is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
or FITNESS FOR A PARTICULAR PURPOSE. See [LICENSE](LICENSE) for the full text.

[Sparkle](https://sparkle-project.org), which handles updates, is used under
the MIT license. Its notice ships inside the app as
`Contents/Resources/Sparkle-LICENSE.txt`, next to a copy of the GPL.
