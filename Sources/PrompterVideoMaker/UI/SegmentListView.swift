import SwiftUI

/// Left pane: the ordered list of script segments. Editable text, per-row
/// timing nudges on the selected row, and playback-follow auto-scroll.
struct SegmentListView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if appState.project.script.isEmpty {
                emptyState
            } else {
                list
            }
        }
    }

    private var header: some View {
        HStack {
            Label("Script", systemImage: "list.bullet.rectangle")
                .font(.headline)
            Spacer()
            Text("\(appState.project.script.segments.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "text.badge.plus")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("No segments yet")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Open an SRT or audio file to get started.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    private var list: some View {
        ScrollViewReader { proxy in
            List(selection: Binding(
                get: { appState.selectedSegmentID },
                set: { if let id = $0 { appState.selectSegment(id) } }
            )) {
                ForEach($appState.project.script.segments) { $segment in
                    SegmentRow(segment: $segment)
                        .tag(segment.id)
                        .id(segment.id)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .onChange(of: appState.selectedSegmentID) { _, newValue in
                guard let newValue else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }
}

private struct SegmentRow: View {
    @EnvironmentObject private var appState: AppState
    @Binding var segment: Segment

    private var isSelected: Bool { appState.selectedSegmentID == segment.id }
    private var isCurrent: Bool {
        let t = appState.playheadVideoTime - appState.project.style.leadIn
        return t >= segment.start && t < segment.end
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if isCurrent {
                    Image(systemName: "play.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
                Text("\(formatTime(segment.start)) → \(formatTime(segment.end))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
            }

            TextField("Segment text", text: $segment.text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .font(.body)

            if isSelected {
                HStack(spacing: 16) {
                    Stepper("Start \(formatTime(segment.start))") {
                        appState.nudgeStart(segment.id, by: 0.1)
                    } onDecrement: {
                        appState.nudgeStart(segment.id, by: -0.1)
                    }
                    Stepper("End \(formatTime(segment.end))") {
                        appState.nudgeEnd(segment.id, by: 0.1)
                    } onDecrement: {
                        appState.nudgeEnd(segment.id, by: -0.1)
                    }
                }
                .font(.caption)
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button {
                appState.splitInHalf(segment.id)
            } label: {
                Label("Split in Half", systemImage: "square.split.2x1")
            }
            Button {
                appState.mergeWithNext(segment.id)
            } label: {
                Label("Merge with Next", systemImage: "arrow.triangle.merge")
            }
            Button {
                appState.insertEmptyLine(after: segment.id)
            } label: {
                Label("Insert Empty Line Below", systemImage: "text.insert")
            }
            Divider()
            Button(role: .destructive) {
                appState.deleteSegment(segment.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}
