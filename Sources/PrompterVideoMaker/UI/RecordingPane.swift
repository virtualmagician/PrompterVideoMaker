import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Full center-pane view shown INSTEAD of `PreviewView` while recording or
/// aligning a take (`appState.recordPaneVisible`). Entirely driven by
/// `appState.recordPhase`; the recorder is passed in explicitly (rather than
/// reached through `appState.recorder`) so this view's `@ObservedObject`
/// actually re-renders on the recorder's own `@Published` changes
/// (elapsed/level), which a nested object wouldn't otherwise forward through
/// `AppState`'s `objectWillChange`.
struct RecordingPane: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var recorder: AudioRecorder

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            readView
            Divider()
            controlBar
        }
        .background(Color.black)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Label("Record Timing", systemImage: "mic.circle")
                .font(.headline)
                .foregroundStyle(.white)
            Spacer()
            Button {
                appState.closeRecordPane()
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 18))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.white.opacity(0.7))
            .keyboardShortcut(.cancelAction)
            .help("Close")
        }
        .padding(16)
        .background(Color.black)
    }

    // MARK: - Read view

    /// The script in a large readable ScrollView, matching the old
    /// RecordSheet's read view. Emphasis markers are stripped for reading —
    /// this pane is for reading aloud, not previewing the styled render.
    private var readView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ForEach(appState.project.script.segments) { seg in
                    let plain = EmphasisMarkup.strip(seg.text)
                    if !plain.isEmpty {
                        Text(plain)
                            .font(.system(size: 26))
                            .lineSpacing(10)
                            .foregroundStyle(.white)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.black)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Control bar

    @ViewBuilder
    private var controlBar: some View {
        switch appState.recordPhase {
        case .idle:
            idleBar
        case .recording:
            recordingBar
        case .aligning(let progress):
            aligningBar(progress: progress)
        case .done(let matchRate, let audioURL):
            doneBar(matchRate: matchRate, audioURL: audioURL)
        case .failed(let message):
            failedBar(message: message)
        }
    }

    private var idleBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 16) {
                Button {
                    appState.startRecording()
                } label: {
                    Label("Start Recording", systemImage: "record.circle")
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)

                Button {
                    appState.presentAlignAudioPanel()
                } label: {
                    Label("Use Audio File\u{2026}", systemImage: "folder.badge.plus")
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(white: 0.32))
                .foregroundStyle(.white)
            }

            Text("Recording keeps your script text; only the timings (and the audio) come from the take.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .padding(20)
    }

    private var recordingBar: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 10, height: 10)
                Text(formatElapsed(recorder.elapsed))
                    .font(.body.monospacedDigit().weight(.medium))
                    .foregroundStyle(.white)
                    .frame(width: 52, alignment: .leading)
                LevelMeterView(level: recorder.level)
                    .frame(height: 8)
            }
            .padding(.horizontal, 40)

            Button {
                appState.stopRecordingAndAlign()
            } label: {
                Label("Stop & Align", systemImage: "stop.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(20)
    }

    private func aligningBar(progress: Double) -> some View {
        VStack(spacing: 10) {
            ProgressView(value: progress)
                .frame(width: 260)
            Text("Aligning\u{2026}")
                .font(.headline)
                .foregroundStyle(.white)
            Text("\(Int((progress * 100).rounded()))%")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(20)
    }

    private func doneBar(matchRate: Double, audioURL: URL) -> some View {
        let percent = Int((matchRate * 100).rounded())
        let low = matchRate < 0.6
        return VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: low ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(low ? .orange : .green)
                Text("Timings applied \u{2014} matched \(percent)% of the script.")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white)
            }
            Text("The recording is attached to the project \u{2014} leave \u{201C}Include Audio\u{201D} on to export it with the video.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            if low {
                Text("That match rate is lower than usual. Consider re-recording somewhere quieter, speaking closer to the script, or checking your microphone in System Settings, then use Record Timing again.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
            Button {
                appState.closeRecordPane()
            } label: {
                Text("Done")
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
        .padding(20)
    }

    private func failedBar(message: String) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
            Button {
                appState.closeRecordPane()
            } label: {
                Text("Close")
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(20)
    }

    private func formatElapsed(_ t: TimeInterval) -> String {
        let total = Int(t.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// A simple horizontal input-level meter: a track with a proportional fill.
private struct LevelMeterView: View {
    let level: Float

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.2))
                Capsule()
                    .fill(Color.green)
                    .frame(width: proxy.size.width * CGFloat(min(1, max(0, level))))
                    .animation(.easeOut(duration: 0.08), value: level)
            }
        }
    }
}
