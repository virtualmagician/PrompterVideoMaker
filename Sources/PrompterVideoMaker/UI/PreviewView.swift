import SwiftUI

/// WYSIWYG 16:9 preview. Renders exactly what export would produce by asking
/// `PrompterComposition` for a raster frame at the current video time —
/// there is no separate "preview renderer".
struct PreviewView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        // The visible pane is locked to the video's exact 16:9 aspect, so
        // what you see is precisely the exported frame — no extra background
        // beyond the video bounds.
        Group {
            if appState.composition != nil {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !appState.isPlaying)) { context in
                    let time = appState.currentDisplayTime(at: context.date)
                    Canvas { ctx, canvasSize in
                        guard canvasSize.width > 0,
                              let cg = appState.composition?.image(
                                atVideoTime: time,
                                scale: canvasSize.width / StyleSettings.canvasWidth
                              ) else { return }
                        ctx.draw(
                            Image(decorative: cg, scale: 1, orientation: .up),
                            in: CGRect(origin: .zero, size: canvasSize)
                        )
                    }
                    .onChange(of: context.date) { _, newDate in
                        appState.tick(date: newDate)
                    }
                }
            } else {
                emptyHint
            }
        }
        .aspectRatio(StyleSettings.canvasWidth / StyleSettings.canvasHeight, contentMode: .fit)
        .background(Color.black)
        .clipped()
        .shadow(color: .black.opacity(0.4), radius: 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
        .contentShape(Rectangle())
        .onTapGesture { appState.togglePlay() }
    }

    private var emptyHint: some View {
        VStack(spacing: 14) {
            Image(systemName: "text.below.photo")
                .font(.system(size: 44))
                .foregroundStyle(.white.opacity(0.35))
            VStack(spacing: 4) {
                Text("No Script Loaded")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
                Text("Drop an SRT or audio file here, or use File → Open…")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .multilineTextAlignment(.center)
        .padding(40)
    }
}
