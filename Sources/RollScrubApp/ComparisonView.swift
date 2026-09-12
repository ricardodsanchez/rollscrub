import AVKit
import RollScrubCore
import SwiftUI

/// The two copies side by side. Left is the one being kept, right is the
/// duplicate awaiting a verdict.
struct ComparisonView: View {
    let item: ReviewItem
    @ObservedObject var session: ReviewSession

    // Present for the whole life of a video pair, so AVKit's own transport
    // controls are there and each clip can be played and scrubbed on its own.
    // AVPlayer streams rather than loading the file, so this is cheap even for
    // a 900 MB clip.
    @State private var leftPlayer: AVPlayer?
    @State private var rightPlayer: AVPlayer?

    var body: some View {
        VStack(spacing: 0) {
            header

            HStack(spacing: 1) {
                FilePane(
                    url: item.keepURL,
                    role: .kept,
                    player: leftPlayer)
                FilePane(
                    url: item.candidateURL,
                    role: .duplicate(originalPath: item.originalPath),
                    player: rightPlayer)
            }
            .background(Color(nsColor: .separatorColor))

            if item.isVideo {
                playbackBar
            }
            decisionBar
        }
        .task(id: item.id) { await preparePlayers() }
        .onDisappear { stopPlayers() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: item.isVideo ? "film" : "photo")
                .foregroundStyle(.secondary)
            Text(item.filename)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(ReportWriter.humanSize(item.sizeBytes))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Label("Verified identical", systemImage: "checkmark.seal.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .help("Every byte of these two files was compared and matched.")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - Video

    private var playbackBar: some View {
        HStack(spacing: 12) {
            Button {
                playBoth()
            } label: {
                Label("Play both", systemImage: "play.fill")
            }
            Button {
                pauseBoth()
            } label: {
                Label("Pause", systemImage: "pause.fill")
            }
            Text("Both clips start together so you can compare them frame for frame. "
                 + "Each player also has its own controls.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func preparePlayers() async {
        stopPlayers()
        guard item.isVideo else { return }
        leftPlayer = AVPlayer(url: item.keepURL)
        rightPlayer = AVPlayer(url: item.candidateURL)
    }

    /// Starts both clips together. Waits for each to report ready before
    /// seeking: seeking a player whose item is still loading is dropped, and
    /// playback then never starts.
    private func playBoth() {
        let players = [leftPlayer, rightPlayer].compactMap { $0 }
        guard !players.isEmpty else { return }

        Task { @MainActor in
            for player in players {
                var waited = 0
                while player.currentItem?.status != .readyToPlay, waited < 50 {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    waited += 1
                }
            }
            for player in players {
                await player.seek(to: .zero)
            }
            for player in players {
                player.play()
            }
        }
    }

    private func stopPlayers() {
        for player in [leftPlayer, rightPlayer] {
            player?.pause()
        }
        leftPlayer = nil
        rightPlayer = nil
    }

    private func pauseBoth() {
        for player in [leftPlayer, rightPlayer] {
            player?.pause()
        }
    }

    // MARK: - Decision

    private var decisionBar: some View {
        VStack(spacing: 10) {
            currentDecision

            HStack(spacing: 12) {
                Button {
                    session.markSelectionAndAdvance(.keep)
                } label: {
                    Label("Keep both  (K)", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .keyboardShortcut("k", modifiers: [])
                .help("Leave this file exactly where it is")

                Button {
                    session.markSelectionAndAdvance(.discard)
                } label: {
                    Label("Mark for removal  (D)", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .keyboardShortcut("d", modifiers: [])
                .help("Mark this copy to go to the Trash when you apply")
            }
            .controlSize(.large)

            Text("Marking changes nothing on disk. Files move to the Trash only "
                 + "when you press Remove at the bottom right.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.bar)
    }

    /// Shows what this pair is currently marked as, so a mark is visibly a
    /// state you can change rather than an action that already happened.
    @ViewBuilder
    private var currentDecision: some View {
        if let reason = item.failureReason {
            // The one state the user cannot act on blindly — say exactly what
            // happened and to which file.
            VStack(spacing: 4) {
                Label("Left alone — \(reason)", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.orange)
                Text(item.candidateURL.path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        } else {
            decisionLabel
        }
    }

    @ViewBuilder
    private var decisionLabel: some View {
        switch item.decision {
        case .discard:
            Label("Marked for removal — press K to change your mind",
                  systemImage: "trash.circle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.red)
        case .keep:
            Label(item.originalPath == nil
                  ? "Marked keep — this file stays where it is"
                  : "Marked keep — this copy goes back to the library",
                  systemImage: "checkmark.circle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.green)
        case .undecided:
            Text("Not yet marked")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - One side

struct FilePane: View {
    enum Role {
        case kept
        /// `originalPath` is set only for files an older `--move` run parked.
        case duplicate(originalPath: String?)

        var title: String {
            switch self {
            case .kept: return "Keeping this one"
            case .duplicate(let original):
                return original == nil ? "Duplicate" : "In the review folder"
            }
        }
        var tint: Color {
            switch self {
            case .kept: return .green
            case .duplicate: return .orange
            }
        }
        var symbol: String {
            switch self {
            case .kept: return "checkmark.circle.fill"
            case .duplicate: return "doc.on.doc.fill"
            }
        }
    }

    let url: URL
    let role: Role
    var player: AVPlayer?

    @State private var metadata = FileMetadata()
    @State private var exists = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: role.symbol).foregroundStyle(role.tint)
                Text(role.title).font(.caption.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Group {
                if !exists {
                    ContentUnavailableView(
                        "File not found", systemImage: "exclamationmark.triangle",
                        description: Text("It may have been moved or deleted outside RollScrub."))
                } else if let player {
                    VideoPlayer(player: player)
                } else {
                    PreviewImage(url: url, size: 900)
                        .padding(8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))

            // Fixed height keeps the two previews the same size: the parked
            // side carries an extra "Originally at" line, and without this the
            // panes end up visibly misaligned.
            details
                .frame(height: 132, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: url) {
            exists = FileManager.default.fileExists(atPath: url.path)
            metadata = await FileMetadata.load(for: url)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(url.lastPathComponent)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            // The full path, so it is obvious at a glance which copy sits in
            // _duplicates_review and which one is still in the library.
            Text(url.path)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(isInReviewFolder ? Color.orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if case .duplicate(.some(let originalPath)) = role {
                Text("Originally at  \(originalPath)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            HStack(spacing: 10) {
                if metadata.sizeBytes > 0 {
                    Text(ReportWriter.humanSize(metadata.sizeBytes))
                }
                if let dimensions = metadata.dimensionsText {
                    Text(dimensions)
                }
                if let duration = metadata.durationText {
                    Text(duration)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let captured = metadata.captured {
                Text("Captured \(captured.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                Button("Open") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.link)
            .font(.caption)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    private var isInReviewFolder: Bool {
        url.pathComponents.contains(SkipRules.reviewDirectoryName)
    }
}
