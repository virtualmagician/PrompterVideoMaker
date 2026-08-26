import SwiftUI
import AppKit

/// Right pane: grouped Form with every style/export knob.
struct InspectorView: View {
    @State private var defaultsSaved = false
    @State private var ollamaModels: [String] = []
    @State private var ollamaUnavailable = false
    @AppStorage("PVMOllamaModel") private var selectedOllamaModel: String = ""
    @EnvironmentObject private var appState: AppState

    /// Binding onto the whole style struct; SwiftUI's dynamic member lookup
    /// on `Binding` turns `style.someField` into `Binding<FieldType>`.
    private var style: Binding<StyleSettings> {
        Binding(
            get: { appState.project.style },
            set: { appState.project.style = $0 }
        )
    }

    var body: some View {
        Form {
            colorsSection
            emphasisSection
            textSection
            markerSection
            mirrorSection
            exportSection
            timingSection
            defaultsSection
        }
        .formStyle(.grouped)
    }

    // MARK: Colors

    private var colorsSection: some View {
        Section {
            ColorPicker("Background", selection: colorBinding(\.backgroundColor))
            ColorPicker("Primary Text", selection: colorBinding(\.primaryTextColor))
            ColorPicker("Secondary Text", selection: colorBinding(\.secondaryTextColor))
            Toggle("Alternating Colors", isOn: style.alternatingColors)
            if style.wrappedValue.alternatingColors {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Max Words per Chunk: \(style.wrappedValue.maxChunkWords)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: intBinding(\.maxChunkWords), in: 3...14, step: 1)
                }
            }
        } header: {
            Label("Colors", systemImage: "paintpalette")
        }
    }

    // MARK: Emphasis

    private var emphasisSection: some View {
        Section {
            ColorPicker("Accent Color", selection: emphasisColorBinding)

            VStack(alignment: .leading, spacing: 8) {
                Text("AI Suggestions (bold only)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !ollamaModels.isEmpty {
                    Picker("Model", selection: $selectedOllamaModel) {
                        ForEach(ollamaModels, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                } else if ollamaUnavailable {
                    Text("Ollama not running")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                switch appState.emphasisPhase {
                case .idle:
                    EmptyView()
                case .running(let progress):
                    HStack {
                        ProgressView(value: progress)
                        Button("Cancel") {
                            appState.cancelEmphasis()
                        }
                        .controlSize(.small)
                    }
                case .failed(let message):
                    VStack(alignment: .leading, spacing: 4) {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Button("Dismiss") {
                            appState.cancelEmphasis()
                        }
                        .controlSize(.small)
                    }
                }

                Button {
                    appState.suggestEmphasis(model: selectedOllamaModel)
                } label: {
                    Label("Suggest Emphasis", systemImage: "sparkles")
                }
                .disabled(appState.project.script.isEmpty || ollamaModels.isEmpty || appState.emphasisPhase != .idle)
            }

            Button(role: .destructive) {
                appState.clearEmphasis()
            } label: {
                Label("Clear All Emphasis", systemImage: "eraser")
            }
            .disabled(appState.project.script.isEmpty)
        } header: {
            Label("Emphasis", systemImage: "wand.and.stars")
        } footer: {
            Text(verbatim: "Type **bold**, __underline__ or ==accent== directly in any segment's text.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task {
            do {
                let names = try await OllamaClient().installedModels()
                ollamaModels = names
                if selectedOllamaModel.isEmpty || !names.contains(selectedOllamaModel) {
                    selectedOllamaModel = names.first { $0.lowercased().hasPrefix("gemma") } ?? names.first ?? ""
                }
                ollamaUnavailable = false
            } catch {
                ollamaUnavailable = true
            }
        }
    }

    // MARK: Text

    private var textSection: some View {
        Section {
            Picker("Font", selection: style.fontName) {
                ForEach(fontFamilies, id: \.self) { name in
                    Text(name).tag(name)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Size: \(Int(style.wrappedValue.fontSize)) pt")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: style.fontSize, in: 48...160, step: 1)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Line Height: \(String(format: "%.2f", style.wrappedValue.lineHeightMultiple))×")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: style.lineHeightMultiple, in: 1.1...2.2, step: 0.05)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Empty Line Height: \(String(format: "%.2f", style.wrappedValue.resolvedBlankLineHeight))×")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: blankLineHeightBinding, in: 0.2...2.0, step: 0.05)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Margin: \(Int(style.wrappedValue.horizontalMargin)) px")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: style.horizontalMargin, in: 40...300, step: 5)
            }

            Picker("Alignment", selection: style.alignment) {
                Text("Leading").tag(TextAlignmentSetting.leading)
                Text("Center").tag(TextAlignmentSetting.center)
            }
            .pickerStyle(.segmented)

            Text("≈ \(Int(style.wrappedValue.visibleLines)) lines visible")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Label("Text", systemImage: "textformat")
        }
    }

    // MARK: Marker

    private var markerSection: some View {
        Section {
            Toggle("Show Marker", isOn: style.markerEnabled)
            if style.wrappedValue.markerEnabled {
                ColorPicker("Marker Color", selection: colorBinding(\.markerColor))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Vertical Position: \(Int(style.wrappedValue.markerYFraction * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: style.markerYFraction, in: 0.15...0.6)
                }
            }
        } header: {
            Label("Marker", systemImage: "arrowtriangle.right.fill")
        }
    }

    // MARK: Mirror

    private var mirrorSection: some View {
        Section {
            Toggle("Mirror Horizontally", isOn: style.mirrored)
        } header: {
            Label("Prompter Glass", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
        }
    }

    // MARK: Export

    private var exportSection: some View {
        Section {
            Picker("Frame Rate", selection: style.fps) {
                Text("30 fps").tag(30)
                Text("60 fps").tag(60)
            }
            .pickerStyle(.segmented)

            Stepper(value: style.leadIn, in: 0...10, step: 0.5) {
                Text("Lead-in: \(String(format: "%.1f", style.wrappedValue.leadIn))s")
            }
            Stepper(value: style.leadOut, in: 0...10, step: 0.5) {
                Text("Lead-out: \(String(format: "%.1f", style.wrappedValue.leadOut))s")
            }
            Toggle("Include Audio", isOn: style.includeAudio)

            Picker("Codec", selection: Binding(
                get: { style.wrappedValue.resolvedCodec },
                set: { appState.project.style.videoCodec = $0 }
            )) {
                ForEach(VideoCodecSetting.allCases) { c in
                    Text(c.displayName).tag(c)
                }
            }

            Picker("Quality", selection: Binding(
                get: { style.wrappedValue.resolvedQuality },
                set: { appState.project.style.qualityPreset = $0 }
            )) {
                ForEach(QualityPresetSetting.allCases) { q in
                    Text(q.displayName).tag(q)
                }
            }

            if let estimate = estimatedSizeText {
                Text(estimate)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Label("Export", systemImage: "film")
        }
    }

    // MARK: Timing

    private var timingSection: some View {
        Section {
            HStack {
                Text("Global Offset")
                Spacer()
                Button {
                    appState.applyGlobalOffset(-0.5)
                } label: {
                    Text("-0.5s")
                }
                Text(globalOffsetLabel)
                    .font(.body.monospacedDigit().weight(.medium))
                    .frame(minWidth: 58)
                Button {
                    appState.applyGlobalOffset(0.5)
                } label: {
                    Text("+0.5s")
                }
            }
            .buttonStyle(.bordered)
        } header: {
            Label("Timing", systemImage: "clock.arrow.circlepath")
        }
    }

    private var estimatedSizeText: String? {
        guard let comp = appState.composition else { return nil }
        let withAudio = appState.project.style.includeAudio && appState.project.audioPath != nil
        let bytes = appState.project.style.estimatedFileSizeBytes(
            videoDuration: comp.videoDuration, withAudio: withAudio)
        let str = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        return "Estimated size: \u{2248} \(str)"
    }

    private var globalOffsetLabel: String {
        let v = appState.globalOffset
        if abs(v) < 0.001 { return "0.0s" }
        return String(format: "%+.1fs", v)
    }

    // MARK: Defaults

    private var defaultsSection: some View {
        Section {
            Button {
                appState.saveCurrentStyleAsDefault()
                defaultsSaved = true
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    defaultsSaved = false
                }
            } label: {
                if defaultsSaved {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                } else {
                    Label("Save Current Settings as Defaults", systemImage: "square.and.arrow.down")
                }
            }
            Button(role: .destructive) {
                appState.resetStyleToFactory()
            } label: {
                Label("Reset to Factory Settings", systemImage: "arrow.counterclockwise")
            }
        } header: {
            Label("Defaults", systemImage: "slider.horizontal.2.square")
        } footer: {
            Text("Saved defaults apply to new documents and future launches.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Helpers

    private func colorBinding(_ keyPath: WritableKeyPath<StyleSettings, RGBAColor>) -> Binding<Color> {
        Binding(
            get: { appState.project.style[keyPath: keyPath].color },
            set: { appState.project.style[keyPath: keyPath] = RGBAColor(color: $0) }
        )
    }

    private var emphasisColorBinding: Binding<Color> {
        Binding(
            get: { appState.project.style.resolvedEmphasisColor.color },
            set: { appState.project.style.emphasisColor = RGBAColor(color: $0) }
        )
    }

    private var blankLineHeightBinding: Binding<CGFloat> {
        Binding(
            get: { appState.project.style.resolvedBlankLineHeight },
            set: { appState.project.style.blankLineHeightMultiple = $0 }
        )
    }

    private func intBinding(_ keyPath: WritableKeyPath<StyleSettings, Int>) -> Binding<Double> {
        Binding(
            get: { Double(appState.project.style[keyPath: keyPath]) },
            set: { appState.project.style[keyPath: keyPath] = Int($0.rounded()) }
        )
    }

    private var fontFamilies: [String] {
        NSFontManager.shared.availableFontFamilies.sorted()
    }
}

private extension RGBAColor {
    var color: Color { Color(nsColor: nsColor) }
    init(color: Color) { self.init(nsColor: NSColor(color)) }
}
