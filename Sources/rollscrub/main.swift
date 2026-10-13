import RollScrubCore
import Foundation

let usage = """
rollscrub — find duplicate photos and videos (read-only)

USAGE
  rollscrub <folder> [<folder> ...] [options]
  rollscrub --undo <manifest.json>

OPTIONS
  --include <subdir>   Scan only this subdirectory of each folder given.
                       Repeatable. Omit to scan each whole folder.
  --out <path>         Report path. Default: ./rollscrub_report.txt
                       The CSV sidecar is written alongside it as <name>.csv
  --move               After scanning, move every REMOVE file into
                       _duplicates_review/ inside whichever folder it was
                       found under, keeping its folder structure. Each file
                       is re-checked byte for byte against the copy that
                       stays behind, immediately before it is moved. Nothing
                       is ever deleted, and a file never has to leave the
                       drive it started on.
  --yes                Skip the confirmation prompt for --move.
  --undo <manifest>    Put every file in a manifest back where it was.
  --quiet              No progress output.
  -h, --help           This message.

EXAMPLES
  rollscrub "/Volumes/Extreme Pro" --include Photos --include Video --include 2026
  rollscrub "/Volumes/Extreme Pro" "/Volumes/Backup" --move
  rollscrub ~/Pictures "/Volumes/Extreme Pro" ~/Library/Mobile\\ Documents/com~apple~CloudDocs
  rollscrub --undo "/Volumes/Extreme Pro/_duplicates_review/_rollscrub_manifest_*.json"

Passing more than one folder finds duplicates across all of them, not just
within each one on its own. Without --move the scan is read-only. With
--move, each file is relocated within the drive it was found on — never
deleted, and never moved to a different volume — and the move is reversible.
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n\n\(usage)\n".utf8))
    exit(2)
}

// MARK: - Argument parsing

var roots: [String] = []
var includes: [String] = []
var outPath = "rollscrub_report.txt"
var quiet = false
var shouldMove = false
var assumeYes = false
var undoManifest: String?

var args = Array(CommandLine.arguments.dropFirst())
var index = 0
while index < args.count {
    let arg = args[index]
    switch arg {
    case "-h", "--help":
        print(usage)
        exit(0)
    case "--move":
        shouldMove = true
    case "--yes":
        assumeYes = true
    case "--undo":
        index += 1
        guard index < args.count else { fail("--undo needs a manifest path") }
        undoManifest = args[index]
    case "--include":
        index += 1
        guard index < args.count else { fail("--include needs a subdirectory name") }
        includes.append(args[index])
    case "--out":
        index += 1
        guard index < args.count else { fail("--out needs a path") }
        outPath = args[index]
    case "--quiet":
        quiet = true
    default:
        guard !arg.hasPrefix("-") else { fail("unknown option \(arg)") }
        roots.append(arg)
    }
    index += 1
}

// MARK: - Undo mode

if let manifestPath = undoManifest {
    let url = URL(fileURLWithPath: (manifestPath as NSString).expandingTildeInPath)
    guard FileManager.default.fileExists(atPath: url.path) else {
        fail("no such manifest: \(url.path)")
    }
    do {
        let outcome = try Mover.undo(manifestURL: url)
        print("Restored \(outcome.restored) file(s) to their original locations.")
        if !outcome.skipped.isEmpty {
            print("Skipped \(outcome.skipped.count):")
            for skip in outcome.skipped.prefix(20) {
                print("  \(skip.path)\n    \(skip.reason)")
            }
        }
        exit(outcome.skipped.isEmpty ? 0 : 1)
    } catch {
        fail("could not read manifest: \(error.localizedDescription)")
    }
}

guard !roots.isEmpty else { fail("no folder given") }

let rootURLs: [URL] = roots.map {
    URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardized
}
for rootURL in rootURLs {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory),
          isDirectory.boolValue
    else {
        fail("not a folder: \(rootURL.path)")
    }
}

for rootURL in rootURLs {
    for include in includes {
        let url = rootURL.appendingPathComponent(include)
        guard FileManager.default.fileExists(atPath: url.path) else {
            fail("--include path does not exist: \(url.path)")
        }
    }
}

// MARK: - Scan

func log(_ message: String) {
    guard !quiet else { return }
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func status(_ message: String) {
    guard !quiet else { return }
    FileHandle.standardError.write(Data("\r\u{1B}[K\(message)".utf8))
}

log("Scanning \(rootURLs.map(\.path).joined(separator: ", "))")
if !includes.isEmpty { log("Included: \(includes.joined(separator: ", "))") }

var lastPhaseWasProgress = false
let scanner = DuplicateScanner(config: ScanConfig(roots: rootURLs, includes: includes)) { phase in
    switch phase {
    case .enumerating(let found):
        status("  enumerating… \(found) media files")
        lastPhaseWasProgress = true
    case .hashing(let done, let total):
        let percent = total == 0 ? 100 : done * 100 / total
        status("  hashing candidates… \(done)/\(total) (\(percent)%)")
        lastPhaseWasProgress = true
    case .grouping:
        if lastPhaseWasProgress { status("") ; log("") }
        log("  grouping…")
        lastPhaseWasProgress = false
    case .verifying(let done, let total):
        let percent = total == 0 ? 100 : done * 100 / total
        status("  verifying byte for byte… \(done)/\(total) groups (\(percent)%)")
        lastPhaseWasProgress = true
    }
}

let result = scanner.scan()
if lastPhaseWasProgress { log("") }

// MARK: - Write reports

let reportURL = URL(fileURLWithPath: (outPath as NSString).expandingTildeInPath)
let csvURL = reportURL.deletingPathExtension().appendingPathExtension("csv")

do {
    try ReportWriter.text(for: result).write(to: reportURL, atomically: true, encoding: .utf8)
    try ReportWriter.csv(for: result).write(to: csvURL, atomically: true, encoding: .utf8)
} catch {
    fail("could not write report: \(error.localizedDescription)")
}

// MARK: - Summary

print("")
print("Media files scanned : \(result.filesScanned)")
print("Duplicate groups    : \(result.groups.count)")
print("Redundant files     : \(result.redundantFileCount)")
print("Reclaimable         : \(ReportWriter.humanSize(result.reclaimableBytes))")
if result.unreadableFiles > 0 {
    print("Unreadable (skipped): \(result.unreadableFiles)")
}
if result.notDownloadedFiles > 0 {
    print("In iCloud, not here : \(result.notDownloadedFiles) (skipped, reading downloads them)")
}
if result.filesRejectedByVerification > 0 {
    print("Rejected by verify  : \(result.filesRejectedByVerification)")
}
print("")
print("Report : \(reportURL.path)")
print("CSV    : \(csvURL.path)")
print("")

// MARK: - Optional move

final class ResultBox<T>: @unchecked Sendable { var value: T? }

/// Runs one async call to completion from this synchronous script. A top-level
/// `await` would do the same job, but it turns every global in this file into
/// main-actor state, and the scan's progress callback reads them from worker
/// threads.
func blocking<T: Sendable>(_ work: @escaping @Sendable () async -> T) -> T {
    let box = ResultBox<T>()
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        box.value = await work()
        done.signal()
    }
    done.wait()
    return box.value!
}

guard shouldMove else {
    print("Nothing was moved or deleted. Re-run with --move to set the")
    print("REMOVE files aside in \(SkipRules.reviewDirectoryName)/ inside whichever")
    print("folder each one was found under.")
    exit(0)
}

// Scanning and the reports are free; setting files aside is the paid action.
// The licence lives in the keychain, so activating in the app covers this too.
// --undo is deliberately never gated: reversing a move must always work.
//
// The app re-checks a licence daily and records the answer. This tool only
// reads. A licence the app confirmed within thirty days is taken as it stands.
// Past that, which is where someone who only ever runs the tool ends up, it
// asks the server once per run and goes ahead on a yes. It saves nothing
// either way: the keychain item belongs to the app's signature, and one this
// binary re-created would not.
switch License.standing() {
case .licensed, .developerUnlocked:
    break

case .needsRecheck:
    let recheck = blocking { await License.revalidate(saving: false) }
    if recheck == .confirmed { break }
    if case .revoked(let reason) = recheck {
        print("""
        --move could not go ahead: the licence server no longer accepts the
        licence saved on this Mac. \(reason)

        Open the RollScrub app to see the licence's state. Nothing was moved.
        """)
        exit(3)
    }
    print("""
    --move could not confirm your licence.

    A licence is saved on this Mac, but it has not reached the licence server
    for over 30 days. \(recheck.explanation ?? "Connect to the internet and re-run this.")

    Nothing needs to be bought. Nothing was moved.
    """)
    exit(3)

case .unreadable:
    print("""
    --move could not read your licence.

    macOS would not let this tool read the keychain, so it cannot tell whether
    this Mac has a licence. This tool is a separate binary from the app, so the
    first time it reads the licence the system asks permission. Run it once
    from a Terminal window you can see, and choose Always Allow. A run with no
    one watching cannot answer that prompt, and lands here instead.

    Nothing needs to be bought. Nothing was moved.
    """)
    exit(3)

case .unlicensed:
    print("""
    --move needs a licence.

    Scanning, the report and the CSV are free, and the report above already
    lists every file that would be set aside. Activate a licence in the
    RollScrub app — Menu → RollScrub → Unlock Removal — and re-run this.

    If you have already activated one there, macOS may be withholding it:
    this tool is a separate binary from the app, so the first time it reads
    the licence the system asks permission. Run it once from a Terminal
    window you can see, and choose Always Allow. A run with no one watching
    cannot answer that prompt, and lands here instead.

    \(License.purchaseURL(from: .cli).absoluteString)
    """)
    exit(3)
}

guard !result.groups.isEmpty else {
    print("No duplicates to move.")
    exit(0)
}

print("About to move \(result.redundantFileCount) file(s)")
print("  into : \(SkipRules.reviewDirectoryName)/ inside whichever folder each was found under")
print("  total: \(ReportWriter.humanSize(result.reclaimableBytes))")
print("")
print("Each file is re-checked byte for byte against the copy that stays")
print("behind, immediately before it is moved. Nothing is deleted, and the")
print("move can be reversed with --undo.")
print("")

if !assumeYes {
    guard isatty(FileHandle.standardInput.fileDescriptor) == 1 else {
        fail("--move needs confirmation; re-run with --yes in a non-interactive shell")
    }
    print("Type 'yes' to continue: ", terminator: "")
    guard let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased(),
          answer == "yes"
    else {
        print("Cancelled. Nothing was moved.")
        exit(1)
    }
}

let mover = Mover(roots: rootURLs) { phase in
    switch phase {
    case .verifying(let done, let total):
        status("  verifying before move… \(done)/\(total)")
    case .moving(let done, let total):
        status("  moving… \(done)/\(total)")
    }
}

do {
    let outcome = try mover.move(groups: result.groups)
    if !quiet { log("") }
    print("")
    print("Moved   : \(outcome.moved.count) file(s), \(ReportWriter.humanSize(outcome.bytesMoved))")
    if !outcome.skipped.isEmpty {
        print("Skipped : \(outcome.skipped.count) (left exactly where they were)")
        for skip in outcome.skipped.prefix(20) {
            print("  \(skip.path)\n    \(skip.reason)")
        }
        if outcome.skipped.count > 20 {
            print("  …and \(outcome.skipped.count - 20) more")
        }
    }
    if !outcome.manifestURLs.isEmpty {
        print("")
        for manifest in outcome.manifestURLs {
            print("Manifest: \(manifest.path)")
            print("Undo    : rollscrub --undo \"\(manifest.path)\"")
        }
    }
    print("")
    print("Nothing was deleted. Review each folder's \(SkipRules.reviewDirectoryName)/")
    print("and delete it yourself once you are satisfied, to actually reclaim the space.")
} catch {
    fail("move failed: \(error.localizedDescription)")
}
