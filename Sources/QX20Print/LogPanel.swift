import SwiftUI

struct LogPanel: View {
    @EnvironmentObject var model: PrintModel

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Log").font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                Button("Copy") {
                    let text = model.log.map { "[\(Self.timeFormat.string(from: $0.time))] \($0.text)" }
                        .joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .disabled(model.log.isEmpty)
                Button("Clear") { model.clearLog() }
                    .disabled(model.log.isEmpty)
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(model.log) { line in
                            Text("[\(Self.timeFormat.string(from: line.time))] \(line.text)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(line.text.contains("[debug]") ? .tertiary : .primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
                .onChange(of: model.log.count) {
                    if let last = model.log.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}
