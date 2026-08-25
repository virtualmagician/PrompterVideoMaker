import SwiftUI

/// Sheet for the "read the script aloud and record yourself" flow. Entirely
/// driven by `appState.recordPhase`; the recorder is passed in explicitly
/// (rather than reached through `appState.recorder`) so this view's
/// `@ObservedObject` actually re-renders on the recorder's own `@Published`
/// changes (elapsed/level), which a nested object wouldn't otherwise forward
/// through `AppState`'s `objectWillChange`.
struct RecordSheet: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var recorder: AudioRecorder

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 640, height: 540)
    }

    private var header: some View {
        HStack {
            Label("Record Yourself Reading", systemImage: "mic.circle")
                .font(.headline)
            Spacer()
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        switch appState.recordPhase {
        case .idle:
            idleView
        case .recording:
            recordingView
        case .aligning(let progress):
            aligningView(progress: progress)
        case .done(let matchRate, let audioURL):
            doneView(matchRate: matchRate, audioURL: audioURL)
        case .failed(let message):
            failedView(message: message)
        }
    }

    // MARK: - Idle

    private var idleView: some View {
        VStack(spacing: 0) {
            readView
            Divider()
            VStack(spacing: 14) {
                LevelMeterView(level: 0)
                    .frame(height: 8)
                    .padding(.horizontal, 40)

                HStack(spacing: 16) {
                    Button {
                        appState.cancelRecording()
                    } label: {
                        Text("Cancel")
                    }
                    .keyboardShortcut(.cancelAction)

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
                }
            }
            .padding(20)
        }
    }

    // MARK: - Recording

    private var recordingView: some View {
        VStack(spacing: 0) {
            readView
            Divider()
            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 10, height: 10)
                    Text(formatElapsed(recorder.elapsed))
                        .font(.body.monospacedDigit().weight(.medium))
                        .frame(width: 52, alignment: .leading)
                    LevelMeterView(level: recorder.level)
                        .frame(height: 8)
                }
                .padding(.horizontal, 40)

                HStack(spacing: 16) {
                    Button {
                        appState.cancelRecording()
                    } label: {
                        Text("Cancel")
                    }

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
            }
            .padding(20)
        }
    }

    // MARK: - Aligning

    private func aligningView(progress: Double) -> some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView(value: progress)
                .frame(width: 260)
            Text("Aligning Recording\u{2026}")
                .font(.headline)
            Text("\(Int((progress * 100).rounded()))%")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Done

    private func doneView(matchRate: Double, audioURL: URL) -> some View {
        let percent = Int((matchRate * 100).rounded())
        let low = matchRate < 0.6
        return VStack(spacing: 16) {
            Spacer()
            Image(systemName: low ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(low ? .orange : .green)
            Text("Timings Applied")
                .font(.headline)
            Text("Matched \(percent)% of the script")
                .font(.callout)
                .foregroundStyle(.secondary)
            if low {
                Text("That match rate is lower than usual. Consider re-recording somewhere quieter, speaking closer to the script, or checking your microphone in System Settings, then use Record Timing again.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            Spacer()
            Button {
                appState.recordPhase = .idle
                appState.showRecordSheet = false
            } label: {
                Text("Done")
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Failed

    private func failedView(message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text("Recording Failed")
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Spacer()
            Button {
                appState.recordPhase = .idle
                appState.showRecordSheet = false
            } label: {
                Text("Close")
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Shared read view

    private var readView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ForEach(appState.project.script.segments) { seg in
                    if !seg.text.isEmpty {
                        Text(seg.text)
                            .font(.system(size: 20))
                            .lineSpacing(8)
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
                Capsule().fill(Color.secondary.opacity(0.25))
                Capsule()
                    .fill(Color.green)
                    .frame(width: proxy.size.width * CGFloat(min(1, max(0, level))))
                    .animation(.easeOut(duration: 0.08), value: level)
            }
        }
    }
}
