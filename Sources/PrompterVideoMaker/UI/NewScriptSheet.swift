import SwiftUI

/// Sheet to create a script by pasting/typing text directly, instead of
/// importing an SRT. Timings are estimated (see `ScriptImporter`) and get
/// replaced with real ones by the record-and-align flow.
struct NewScriptSheet: View {
    @EnvironmentObject private var appState: AppState
    @State private var text: String = ""
    @State private var granularity: ScriptGranularity = .sentences

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("New Script", systemImage: "square.and.pencil")
                .font(.headline)

            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                .frame(minWidth: 380, minHeight: 260)

            Picker("Cue Granularity", selection: $granularity) {
                ForEach(ScriptGranularity.allCases) { g in
                    Text(g.rawValue).tag(g)
                }
            }
            .pickerStyle(.segmented)

            Text(footerText)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button {
                    appState.showNewScriptSheet = false
                } label: {
                    Text("Cancel")
                }
                .keyboardShortcut(.cancelAction)

                Button {
                    appState.createScript(fromText: text, granularity: granularity)
                } label: {
                    Text("Create")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var footerText: String {
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        let cues = ScriptImporter.split(text: text, granularity: granularity).count
        return "\(words) words \u{00B7} ~\(cues) cues"
    }
}
