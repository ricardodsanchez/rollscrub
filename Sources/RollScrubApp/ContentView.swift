import RollScrubCore
import SwiftUI
import UniformTypeIdentifiers

/// Menu commands live on the Scene and the panels they open live in the view,
/// so the two are bridged by name rather than by threading the whole session
/// and scanner up into the App.
extension Notification.Name {
    static let scanFolders = Notification.Name("RollScrub.scanFolders")
    static let openManifest = Notification.Name("RollScrub.openManifest")
}

struct ContentView: View {
    @ObservedObject var session: ReviewSession
    @ObservedObject var license: LicenseModel
    @Environment(\.openWindow) private var openWindow
    @StateObject private var scanner = ScanCoordinator()
    @State private var showApplyConfirmation = false
    /// Whether the alert on screen said files go to the Trash. Fixed when it
    /// opens: the alert is the consent, and confirming one that said nothing
    /// is removed must not remove anything, even if a licence was activated
    /// while it sat open.
    @State private var alertOffersRemoval = false
    /// Hidden until there is a review to show. Before a scan the sidebar holds
    /// an empty list under a filter reading "(0)", and it pushes the welcome
    /// screen off the window's centre for no gain.
    @State private var columns: NavigationSplitViewVisibility = .detailOnly

    /// A loaded scan is not the same as something to review: a scan that finds
    /// nothing loads a session with no pairs in it, and the sidebar and status
    /// bar then frame an empty list with "0 to review" and "Apply 0 decisions".
    private var hasReview: Bool {
        session.isLoaded && !session.items.isEmpty
    }

    /// Only removal is gated. Marking pairs "keep" is a decision to leave files
    /// exactly where they are, and charging for that would be indefensible.
    private var needsLicenceToApply: Bool {
        !license.isPro && !session.markedForDiscard.isEmpty
    }

    /// "1 files" in a button someone is about to press on their photographs
    /// undermines the care the rest of the app is arguing for.
    private static func count(_ n: Int, _ singular: String, _ plural: String) -> String {
        "\(n) \(n == 1 ? singular : plural)"
    }

    private var applyButtonTitle: String {
        let files = Self.count(session.markedForDiscard.count, "file", "files")
        if needsLicenceToApply {
            // Keep decisions in the same batch are not held back by the
            // licence, so the button offers them first; the unlock window
            // follows for the rest.
            return session.markedForKeep.isEmpty
                ? "Unlock to Remove \(files)…"
                : "Apply \(Self.count(session.markedForKeep.count, "decision", "decisions"))…"
        }
        return session.markedForDiscard.isEmpty
            ? "Apply \(Self.count(session.markedForKeep.count, "decision", "decisions"))"
            : "Remove \(files)…"
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            sidebar
                .navigationSplitViewColumnWidth(min: 280, ideal: 330, max: 460)
        } detail: {
            detail
        }
        .onChange(of: hasReview, initial: true) { _, review in
            columns = review ? .all : .detailOnly
        }
        .onChange(of: session.mediaFilter) { _, _ in session.reconcileSelection() }
        .onChange(of: session.filter) { _, _ in session.reconcileSelection() }
        .onReceive(NotificationCenter.default.publisher(for: .scanFolders)) { _ in
            guard !scanner.isScanning else { return }
            chooseFolderToScan()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openManifest)) { _ in
            guard !scanner.isScanning else { return }
            chooseFolder()
        }
        .toolbar { toolbarContent }
        .safeAreaInset(edge: .bottom) {
            if hasReview && !scanner.isScanning { statusBar }
        }
        .alert(
            alertOffersRemoval ? "Move to Trash?" : "Apply decisions?",
            isPresented: $showApplyConfirmation
        ) {
            Button("Cancel", role: .cancel) {}
            Button(alertOffersRemoval ? "Move to Trash" : "Apply",
                   role: alertOffersRemoval ? .destructive : nil) {
                // Checked again at the last moment, for the same reason as the
                // Remove button: the alert can sit open across the moment a
                // licence lapses. If it has, nothing is removed, and the keep
                // decisions still go through. The reverse never happens:
                // removal needs both the alert to have offered it and the
                // licence to still unlock it.
                license.refreshFromStore()
                let plan = session.applyPlan(removalUnlocked: license.isPro)
                let removing = alertOffersRemoval && plan.removes
                Task {
                    await session.apply(removing: removing)
                    if plan.opensUnlock { openUnlockWindow() }
                }
            }
        } message: {
            Text(applyMessage)
        }
        .alert(
            "Something went wrong",
            isPresented: .init(
                get: { session.errorMessage != nil },
                set: { if !$0 { session.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(session.errorMessage ?? "")
        }
        .frame(minWidth: 1080, minHeight: 680)
        .task {
            // Lets the app be opened straight onto a manifest, from a script
            // or from the rollscrub CLI.
            if !session.isLoaded,
               let path = ProcessInfo.processInfo.environment["ROLLSCRUB_MANIFEST"] {
                session.load(manifestURL: URL(fileURLWithPath: path))
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            // Counts in the labels, so an empty list never looks like the app
            // lost your files — it is obvious which bucket they moved to.
            Picker("Show", selection: $session.filter) {
                ForEach(ReviewSession.Filter.allCases) { filter in
                    Text("\(filter.rawValue)  (\(session.count(for: filter)))").tag(filter)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .padding(.horizontal, 8)
            .padding(.top, 8)

            // Always shown, even when the queue is all stills. Hiding it for a
            // uniform set spared a "Videos (0)" dead end but made the control
            // undiscoverable: someone who knows the filter exists and cannot
            // find it reasonably concludes it is broken. The counts make an
            // empty segment explain itself, which a missing control cannot.
            Picker("Media", selection: $session.mediaFilter) {
                ForEach(ReviewSession.MediaFilter.allCases) { media in
                    Label(
                        "\(media.rawValue)  (\(session.mediaCount(for: media)))",
                        systemImage: media.symbol
                    ).tag(media)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 8)
            .padding(.top, 6)

            Spacer().frame(height: 8)

            // No explicit .tag(): List already keys selection off Identifiable,
            // and adding one on top makes AppKit re-enter its table delegate
            // whenever the filtered contents and the selection change together.
            List(session.filtered, selection: $session.selection) { item in
                ReviewRow(item: item)
                    .contextMenu {
                        Button("Mark for removal") { session.mark(item.id, as: .discard) }
                        Button("Keep Both") { session.mark(item.id, as: .keep) }
                        Button("Clear Mark") { session.mark(item.id, as: .undecided) }
                        Divider()
                        Button("Show Duplicate in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([item.candidateURL])
                        }
                        Button("Show Original in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([item.keepURL])
                        }
                    }
            }
            .listStyle(.inset)
        }
    }

    // MARK: - Empty filter

    /// Two filters can empty the list, and saying "switch to To review" when
    /// To review is already selected — because it was the media filter that
    /// emptied it — sends someone hunting for a control that is not the
    /// problem. Whichever filter is actually responsible is the one named.
    private var mediaFilterIsResponsible: Bool {
        session.mediaFilter != .all
            && session.mediaCount(for: session.mediaFilter) == 0
    }

    private var emptyFilterTitle: String {
        guard mediaFilterIsResponsible else { return "Nothing in this filter" }
        return session.mediaFilter == .videos
            ? "No duplicate videos"
            : "No duplicate photos"
    }

    private var emptyFilterSymbol: String {
        mediaFilterIsResponsible
            ? session.mediaFilter.symbol
            : "line.3.horizontal.decrease.circle"
    }

    private var emptyFilterMessage: String {
        if mediaFilterIsResponsible {
            let lookedFor = session.mediaFilter == .videos ? "videos" : "photos"
            let found = session.mediaCount(for: .all)
            let other = session.mediaFilter == .videos
                ? (found == 1 ? "photo" : "photos")
                : (found == 1 ? "video" : "videos")
            return "This scan found no duplicate \(lookedFor) — only \(found) duplicate "
                + "\(other). Choose All media to see them."
        }
        if session.undecidedCount == 0 {
            return "Every pair has a decision. Press Apply to carry them out."
        }
        let n = session.undecidedCount
        return "\(n) pair\(n == 1 ? "" : "s") still need\(n == 1 ? "s" : "") a decision — "
            + "switch the filter to \"To review\"."
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if scanner.isScanning {
            scanningOverlay
        } else if !session.isLoaded {
            welcome
        } else if session.items.isEmpty {
            nothingFound
        } else if let item = session.item(id: session.selection) {
            ComparisonView(item: item, session: session)
                .id(item.id)
        } else if session.isComplete {
            completionSummary
        } else if session.filtered.isEmpty {
            ContentUnavailableView {
                Label(emptyFilterTitle, systemImage: emptyFilterSymbol)
            } description: {
                Text(emptyFilterMessage)
            }
        } else {
            Text("Select a pair").foregroundStyle(.secondary)
        }
    }

    /// A scan that finds nothing is a good outcome, not a failure — it says so
    /// plainly instead of raising an alert.
    private var nothingFound: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 52))
                .foregroundStyle(.green)
            Text("No duplicates found").font(.title2.weight(.semibold))

            if let summary = session.scanSummary {
                Text("Checked \(summary.filesScanned.formatted()) photos and videos in "
                     + "\(summary.folderName).")
                    .foregroundStyle(.secondary)
                Text(String(format: "Took %.1fs. Nothing was changed.", summary.duration))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("There is nothing to review here.").foregroundStyle(.secondary)
            }

            Button("Scan Another Folder…") { chooseFolderToScan() }
                .controlSize(.large)
                .padding(.top, 4)
        }
        .padding(40)
    }

    /// Shown once every pair in the manifest is dealt with. Without this the
    /// window just goes blank, which reads like the app lost track of things
    /// rather than like the job being finished.
    private var completionSummary: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(.green)
            Text("All done").font(.title2.weight(.semibold))
            Text("All \(session.items.count) duplicates from this scan have been dealt with.")
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                if session.trashedCount > 0 {
                    GridRow {
                        Text("Moved to Trash").foregroundStyle(.secondary)
                        Text("\(session.trashedCount)")
                    }
                }
                if session.goneCount > 0 {
                    GridRow {
                        Text("Removed outside the app").foregroundStyle(.secondary)
                        Text("\(session.goneCount)")
                    }
                }
                if session.restoredCount > 0 {
                    GridRow {
                        Text("Put back").foregroundStyle(.secondary)
                        Text("\(session.restoredCount)")
                    }
                }
                if session.failedCount > 0 {
                    GridRow {
                        Text("Left alone").foregroundStyle(.orange)
                        Button("\(session.failedCount) — see why") {
                            session.filter = .failed
                            session.selection = session.filtered.first?.id
                        }
                        .buttonStyle(.link)
                    }
                }
                GridRow {
                    Text("Space freed").foregroundStyle(.secondary)
                    Text(ReportWriter.humanSize(session.bytesCleared)).fontWeight(.semibold)
                }
            }
            .font(.callout)
            .padding(.vertical, 4)

            Text("This window covers only the folder(s) you scanned.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Button("Scan Another Folder…") { chooseFolderToScan() }
                .controlSize(.large)
                .padding(.top, 4)
        }
        .padding(40)
    }

    /// Width shared by every line of prose here, so the block reads as one
    /// centred column. Hard line breaks were doing this job before and got it
    /// wrong — they fix the ragged edge at whatever the author's window
    /// happened to be, and one line ran far wider than the two above it.
    private static let welcomeColumn: CGFloat = 430

    private var welcome: some View {
        VStack(spacing: 20) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 84, height: 84)

            VStack(spacing: 10) {
                Text("Find duplicate photos and videos")
                    .font(.title2.weight(.semibold))
                Text("Pick one or more folders or drives. RollScrub compares every "
                     + "candidate byte for byte across all of them, then shows you each "
                     + "pair side by side. Nothing is moved or deleted until you say so.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: Self.welcomeColumn)

            Text("To pick more than one: navigate to a folder that contains "
                 + "them (e.g. your home folder), then ⌘-click each one before "
                 + "choosing Scan.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: Self.welcomeColumn)

            VStack(spacing: 10) {
                Button("Scan Folders…") { chooseFolderToScan() }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)

                Button("Open an Earlier Scan's Manifest…") { chooseFolder() }
                    .controlSize(.small)
                    .buttonStyle(.link)
            }
            .padding(.top, 4)
        }
        .padding(40)
    }

    private var scanningOverlay: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text(scanner.headline).font(.headline)
            if !scanner.detail.isEmpty {
                Text(scanner.detail)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let fraction = scanner.fraction {
                ProgressView(value: fraction)
                    .frame(width: 320)
            }
            Text(scanner.elapsed < 1
                 ? "Read-only — nothing is changed by scanning."
                 : "\(Int(scanner.elapsed))s elapsed · read-only, nothing is changed")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }

    // MARK: - Toolbar and status

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                chooseFolderToScan()
            } label: {
                Label("Scan Folders", systemImage: "magnifyingglass")
            }
            .help("Scan other folders for duplicates (⌘O)")
            .disabled(scanner.isScanning)
        }
        // Symbols rather than text, the way Finder, Mail and Preview do it:
        // a text-only toolbar button renders as a wide capsule, and three of
        // them crowd the title bar. Each carries a help tag, because an icon
        // alone does not say what it does — and every one of these is also in
        // the Review menu, which is where the labels live.
        ToolbarItemGroup {
            Button {
                session.markAllPending(as: .discard)
            } label: {
                Label("Mark All for Removal", systemImage: "trash")
            }
            .help("Mark every remaining duplicate for removal")
            .disabled(session.items.isEmpty)

            Button {
                session.markAllPending(as: .undecided)
            } label: {
                Label("Clear Marks", systemImage: "arrow.uturn.backward")
            }
            .help("Clear every mark and start the review over")
            .disabled(session.items.isEmpty)

            Button {
                session.retryFailed()
            } label: {
                Label("Retry Failed", systemImage: "exclamationmark.arrow.circlepath")
            }
            .help("Put files that could not be removed back in the queue")
            .disabled(session.failedCount == 0)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 16) {
            Label("\(session.undecidedCount) to review", systemImage: "tray")
            Label("\(session.markedForDiscard.count) to delete", systemImage: "trash")
                .foregroundStyle(session.markedForDiscard.isEmpty ? .secondary : .primary)
            Label("\(session.markedForKeep.count) to keep", systemImage: "arrow.uturn.backward")
                .foregroundStyle(session.markedForKeep.isEmpty ? .secondary : .primary)
            Text(ReportWriter.humanSize(session.reclaimableBytes) + " reclaimable")
                .foregroundStyle(.secondary)

            Spacer()

            if session.isApplying {
                ProgressView().controlSize(.small)
            }
            Button {
                // Keeping files needs no licence — only removal is paid, and
                // a decision to leave something alone must never be blocked.
                // Read the licence fresh rather than trusting the value cached
                // at launch: a window left open for weeks can outlive the
                // offline grace window, and that must lock removal now, not
                // at the next relaunch. (A refund is noticed by the daily
                // re-check, not here; this reads only the keychain and clock.)
                license.refreshFromStore()
                let plan = session.applyPlan(removalUnlocked: license.isPro)
                if plan.confirms {
                    alertOffersRemoval = plan.removes
                    showApplyConfirmation = true
                } else if plan.opensUnlock {
                    openUnlockWindow()
                }
            } label: {
                Text(applyButtonTitle)
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                session.isApplying
                || (session.markedForDiscard.isEmpty && session.markedForKeep.isEmpty))
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var applyMessage: String {
        var parts: [String] = []
        // Follows what the alert's title and button were fixed to say when it
        // opened, so the three never disagree.
        if alertOffersRemoval && !session.markedForDiscard.isEmpty {
            parts.append(
                "\(session.markedForDiscard.count) duplicate(s) — "
                + "\(ReportWriter.humanSize(session.reclaimableBytes)) — go to the Trash, "
                + "and stay recoverable from there until you empty it. "
                + "Each one is re-checked byte for byte against the copy being kept "
                + "immediately before it goes.")
        }
        let restores = session.markedForKeep.filter { $0.originalPath != nil }.count
        if restores > 0 {
            parts.append(
                "\(Self.count(restores, "file", "files")) "
                + "\(restores == 1 ? "goes" : "go") back to "
                + "\(restores == 1 ? "its" : "their") original folder\(restores == 1 ? "" : "s").")
        }
        if !alertOffersRemoval && !session.markedForDiscard.isEmpty {
            let n = session.markedForDiscard.count
            parts.append(
                "\(Self.count(n, "duplicate", "duplicates")) marked for removal "
                + "\(n == 1 ? "stays where it is" : "stay where they are"). "
                + "Removing needs a licence, and the unlock window opens next.")
        }
        return parts.joined(separator: "\n\n")
    }

    private func openUnlockWindow() {
        license.unlockContext = UnlockContext(
            files: session.markedForDiscard.count,
            bytes: session.reclaimableBytes)
        openWindow(id: "license")
    }

    private func chooseFolderToScan() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = "Choose one or more folders or drives to scan together "
            + "for duplicate photos and videos."
        panel.prompt = "Scan"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls

        Task {
            guard let result = await scanner.scan(roots: urls) else { return }
            // A clean result is a result, not a failure — the empty state
            // below reports it. errorMessage is only for actual problems.
            session.load(scanResult: result, roots: urls)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.json]
        panel.allowsOtherFileTypes = true
        panel.message = "Choose the drive you scanned, or a RollScrub manifest."
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        if url.pathExtension.lowercased() == "json" {
            session.load(manifestURL: url)
        } else {
            session.loadManifest(inRoot: url)
        }
    }
}

// MARK: - Row

struct ReviewRow: View {
    let item: ReviewItem

    var body: some View {
        HStack(spacing: 10) {
            PreviewImage(url: item.candidateURL, size: 128)
                .frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.filename)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.folderName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                HStack(spacing: 6) {
                    Text(ReportWriter.humanSize(item.sizeBytes))
                    if item.isVideo {
                        Image(systemName: "film").imageScale(.small)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()
            badge
        }
        // Every row must be the same height: with 1000s of rows, a size that
        // varies per row (here, with the folder-name line) forces the table
        // to measure each one individually instead of using one fixed row
        // height, which gets very slow at library scale.
        .frame(height: 52)
        .help(item.failureReason.map { "Left alone — \($0)" } ?? item.candidateURL.path)
    }

    @ViewBuilder
    private var badge: some View {
        switch item.state {
        case .trashed:
            Image(systemName: "trash.fill").foregroundStyle(.secondary)
        case .restored:
            Image(systemName: "arrow.uturn.backward").foregroundStyle(.secondary)
        case .kept:
            Image(systemName: "checkmark").foregroundStyle(.secondary)
        case .gone:
            Image(systemName: "minus.circle").foregroundStyle(.tertiary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .pending:
            switch item.decision {
            case .discard: Image(systemName: "trash.circle.fill").foregroundStyle(.red)
            case .keep: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .undecided: EmptyView()
            }
        }
    }
}
