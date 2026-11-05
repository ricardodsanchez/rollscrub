# RollScrub

RollScrub finds duplicate photos and videos on your Mac and helps you clear
them out safely.

It only calls two files duplicates when every byte matches. It never guesses
from file names, dates or how the pictures look.

**[Download RollScrub](https://rollscrub.com)** · free · macOS 14 or later ·
Apple silicon and Intel

## How it works

1. Choose the folders and drives to scan.
2. RollScrub finds every photo and video that has an identical copy.
3. You review each pair side by side and decide what goes.
4. The duplicates you chose go to the Trash. Nothing is deleted.

## Safe by design

- **Nothing is deleted.** Duplicates go to the Trash, where you can put them
  back.
- **Every byte is checked again before a file moves**, in case it changed
  after the scan.
- **Photos, Final Cut, Aperture and Lightroom libraries are skipped.** These
  are the single-file libraries those apps manage for you. They keep copies of
  your originals on purpose, and removing one would break the library.
  Lightroom Classic is different: its photos sit in ordinary folders, and
  RollScrub scans them like any others.
- **iCloud files that aren't on your Mac are skipped**, so a scan never
  downloads your whole photo library.

## Command line

The app includes a command line tool for large or scripted cleanups. To set
it up, choose **RollScrub → Install Command Line Tool…**. It usually gives you
a command to paste into Terminal.

```bash
rollscrub ~/Pictures "/Volumes/Backup"
```

This writes a report of every duplicate to the current folder and leaves your
files alone. Add `--move` to set the duplicates aside in a `_duplicates_review`
folder inside each folder you scanned. It asks you to confirm first, and
prints the `--undo` command that puts everything back. Run `rollscrub --help`
for everything else.

## Build it yourself

You need Xcode 15 or later.

```bash
swift test
./make-app.sh ~/Applications
```

`make-app.sh` builds `RollScrub.app` and installs it in the folder you give
it, replacing any copy already there.

## Contributing

Bug reports and fixes are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md)
first.

If you find a way RollScrub could lose or damage someone's files, please
report it privately. See [SECURITY.md](SECURITY.md).

## License

RollScrub is free software under the [GNU GPL v3](LICENSE), with no warranty.
Copyright © 2026 Ricardo Sanchez.

The RollScrub name and icon aren't covered by the license. If you share a
changed version, give it a name of its own.
