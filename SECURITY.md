# Reporting a problem that could cost someone their files

For RollScrub, the worst kind of bug is one that loses data. Please report
any way it could do one of these things:

- delete a file, or move one somewhere it can't be put back from
- move a file to a different drive
- move a file without checking every byte against the copy being kept
- read or change anything inside a Photos, Lightroom, Aperture or Final Cut
  library
- download an iCloud file that wasn't on the Mac

Any of these is serious. Report it the same way you would a security hole.

## How to report

Email **support@rollscrub.com** with "Data safety" in the subject. If you
can, include the steps to reproduce it, your macOS version, and the kind of
drive involved.

Please don't open a public issue until a fix has shipped. People run the
current version against their only copies, and a public write-up before the
fix tells everyone how to trigger the bug, with no way to avoid it.

You'll get a reply within a few days. Once the fix is released, you'll be
credited in the changelog if you'd like.

## Supported versions

Only the latest release gets fixes. The app updates itself, so the latest
release is what nearly everyone is running.
