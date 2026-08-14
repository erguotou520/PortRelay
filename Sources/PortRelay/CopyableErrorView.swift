import AppKit
import SwiftUI

struct CopyableErrorView: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(message, forType: .string)
            } label: {
                Label("复制错误", systemImage: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("复制完整错误信息")
        }
    }
}
