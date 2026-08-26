import SwiftUI

/// Formats seconds as "m:ss.t" (minutes:seconds.tenths). Shared across the
/// transport bar and the segment list.
func formatTime(_ t: Double) -> String {
    guard t.isFinite, t >= 0 else { return "0:00.0" }
    let totalTenths = Int((t * 10).rounded())
    let minutes = totalTenths / 600
    let seconds = (totalTenths / 10) % 60
    let tenths = totalTenths % 10
    return String(format: "%d:%02d.%d", minutes, seconds, tenths)
}

/// Playback transport: jump/prev/next/play controls, scrubber, time label.
struct TransportBar: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            if !appState.project.script.isEmpty {
                TimelineStrip()
                Divider()
            }

            HStack(spacing: 14) {
                HStack(spacing: 8) {
                    transportButton("backward.end.fill", help: "Jump to Start") {
                        appState.jumpToStart()
                    }
                    transportButton("backward.frame.fill", help: "Previous Segment") {
                        appState.prevSegment()
                    }

                    Button {
                        appState.togglePlay()
                    } label: {
                        Image(systemName: appState.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 30, height: 26)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.space, modifiers: [])
                    .disabled(appState.composition == nil)
                    .help("Play / Pause (Space)")

                    transportButton("forward.frame.fill", help: "Next Segment") {
                        appState.nextSegment()
                    }
                    transportButton("forward.end.fill", help: "Jump to End") {
                        appState.jumpToEnd()
                    }
                }

                Slider(
                    value: Binding(
                        get: { appState.playheadVideoTime },
                        set: { appState.seek(to: $0) }
                    ),
                    in: 0...max(appState.videoDuration, 0.001)
                )
                .disabled(appState.composition == nil)

                Text("\(formatTime(appState.playheadVideoTime)) / \(formatTime(appState.videoDuration))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 120, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.regularMaterial)
    }

    private func transportButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .disabled(appState.composition == nil)
        .help(help)
    }
}
