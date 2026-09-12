import DupSweepCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var session: ReviewSession
    @StateObject private var scanner = ScanCoordinator()
    @State private var showApplyConfirmation = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 280, ideal: 330, max: 460)
        } detail: {
            detail
        }
        .toolbar { toolbarContent }
        .safeAreaInset(edge: .bottom) {
            if session.isLoaded && !scanner.isScanning { statusBar }
        }
        .alert("Move to Trash?", isPresented: $showApplyConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Trash", role: .destructive) {
                Task { await session.apply() }
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
            // or from the dupsweep CLI.
            if !session.isLoaded,
               let path = ProcessInfo.processInfo.environment["DUPSWEEP_MANIFEST"] {
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
            .padding(8)

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
                Label("Nothing in this filter", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text(session.undecidedCount == 0
                     ? "Every pair has a decision. Press Apply to carry them out."
                     : "\(session.undecidedCount) pair(s) still need a decision — "
                       + "switch the filter to \"To review\".")
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

    private var welcome: some View {
        VStack(spacing: 18) {
            Image(systemName: "square.on.square.dashed")
                .font(.system(size: 52))
                .foregroundStyle(.tertiary)
            Text("Find duplicate photos and videos").font(.title2.weight(.semibold))
            Text("Pick one or more folders or drives. DupSweep compares every\n"
                 + "candidate byte for byte across all of them, then shows you\n"
                 + "each pair side by side. Nothing is moved or deleted until you say so.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Text("To pick more than one: navigate to a folder that contains "
                 + "them (e.g. your home folder), then ⌘-click each one before "
                 + "choosing Scan.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: 360)

            Button("Scan Folders…") { chooseFolderToScan() }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)

            Button("Open an Earlier Scan's Manifest…") { chooseFolder() }
                .controlSize(.small)
                .buttonStyle(.link)
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
                Label("Scan Folder", systemImage: "magnifyingglass")
            }
            .disabled(scanner.isScanning)
        }
        ToolbarItemGroup {
            Button("Mark all for removal") { session.markAllPending(as: .discard) }
                .disabled(session.items.isEmpty)
            Button("Clear marks") { session.markAllPending(as: .undecided) }
                .disabled(session.items.isEmpty)
            Button("Retry failed") { session.retryFailed() }
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
                showApplyConfirmation = true
            } label: {
                Text(session.markedForDiscard.isEmpty
                     ? "Apply \(session.markedForKeep.count) decisions"
                     : "Remove \(session.markedForDiscard.count) files…")
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
        if !session.markedForDiscard.isEmpty {
            parts.append(
                "\(session.markedForDiscard.count) duplicate(s) — "
                + "\(ReportWriter.humanSize(session.reclaimableBytes)) — go to the Trash, "
                + "and stay recoverable from there until you empty it. "
                + "Each one is re-checked byte for byte against the copy being kept "
                + "immediately before it goes.")
        }
        let restores = session.markedForKeep.filter { $0.originalPath != nil }.count
        if restores > 0 {
            parts.append("\(restores) file(s) go back to their original folders.")
        }
        return parts.joined(separator: "\n\n")
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
        panel.message = "Choose the drive you scanned, or a DupSweep manifest."
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
