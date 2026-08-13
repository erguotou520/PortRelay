import AppKit
import SwiftUI

struct SessionPanelView: View {
    @ObservedObject var manager: GlobalSessionManager
    @Binding var isCollapsed: Bool

    private var selectedSession: CommandSession? {
        manager.sessions.first { $0.id == manager.selectedSessionID } ?? manager.sessions.last
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .foregroundStyle(.blue)
                Text("会话")
                    .font(.caption.weight(.semibold))

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(manager.sessions) { session in
                            Button {
                                manager.selectedSessionID = session.id
                                isCollapsed = false
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: sessionIcon(session.kind))
                                        .foregroundStyle(session.kind.isKubernetes ? .purple : .blue)
                                    Circle()
                                        .fill(statusColor(session.status))
                                        .frame(width: 6, height: 6)
                                    Text(session.title).lineLimit(1)
                                }
                                .font(.caption)
                                .padding(.horizontal, 9)
                                .frame(height: 25)
                                .background(
                                    selectedSession?.id == session.id
                                        ? Color.accentColor.opacity(0.13)
                                        : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 5)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Spacer(minLength: 8)
                if let selectedSession {
                    Button {
                        manager.close(selectedSession)
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .help("停止并关闭当前会话")
                }
                Button {
                    isCollapsed.toggle()
                } label: {
                    Image(systemName: isCollapsed ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.borderless)
                .help(isCollapsed ? "展开面板" : "收起面板")
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(.bar)

            if !isCollapsed, let selectedSession {
                Divider()
                CommandSessionView(session: selectedSession)
            }
        }
        .frame(height: isCollapsed ? 34 : 270)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func sessionIcon(_ kind: SessionKind) -> String {
        switch kind {
        case .sshShell, .kubernetesShell: "terminal"
        case .kubernetesLogs: "doc.text"
        }
    }

    private func statusColor(_ status: SessionStatus) -> Color {
        switch status {
        case .connecting: .orange
        case .running: .green
        case .stopped: .secondary
        case .failed: .red
        }
    }
}

private struct CommandSessionView: View {
    @ObservedObject var session: CommandSession
    @State private var searchText = ""

    private var displayedOutput: String {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard session.kind == .kubernetesLogs, !query.isEmpty else { return session.output }
        return session.output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.localizedCaseInsensitiveContains(query) }
            .joined(separator: "\n")
    }

    private var matchCount: Int {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return 0 }
        return session.output.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.localizedCaseInsensitiveContains(query) }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(session.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if session.kind == .kubernetesLogs {
                    TextField("搜索日志", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 210)
                    if !searchText.isEmpty {
                        Text("\(matchCount) 行")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(session.status.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(statusColor)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            Divider()

            if session.kind.isInteractive {
                InteractiveTerminalView(session: session)
                    .id(session.id)
            } else {
                LogOutputView(
                    output: displayedOutput,
                    placeholder: placeholder,
                    autoScroll: searchText.isEmpty
                )
            }
        }
    }

    private var placeholder: String {
        switch session.status {
        case .connecting: "正在建立连接…"
        case .running: "正在等待日志…"
        case .stopped: "会话已结束"
        case .failed(let message): message
        }
    }

    private var statusColor: Color {
        switch session.status {
        case .connecting: .orange
        case .running: .green
        case .stopped: .secondary
        case .failed: .red
        }
    }
}

private struct LogOutputView: View {
    let output: String
    let placeholder: String
    let autoScroll: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(output.isEmpty ? placeholder : output)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(output.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(10)
                Color.clear.frame(height: 1).id("session-output-end")
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: output) { _, _ in
                guard autoScroll else { return }
                proxy.scrollTo("session-output-end", anchor: .bottom)
            }
        }
    }
}

struct TerminalKeyEncoder {
    static func data(
        keyCode: UInt16,
        characters: String?,
        modifiers: NSEvent.ModifierFlags
    ) -> Data? {
        switch keyCode {
        case 36, 76: return Data([0x0D])
        case 48: return Data([0x09])
        case 51, 117: return Data([0x7F])
        case 53: return Data([0x1B])
        case 123: return Data("\u{001B}[D".utf8)
        case 124: return Data("\u{001B}[C".utf8)
        case 125: return Data("\u{001B}[B".utf8)
        case 126: return Data("\u{001B}[A".utf8)
        case 115: return Data("\u{001B}[H".utf8)
        case 119: return Data("\u{001B}[F".utf8)
        case 116: return Data("\u{001B}[5~".utf8)
        case 121: return Data("\u{001B}[6~".utf8)
        default: break
        }

        guard let characters, !characters.isEmpty else { return nil }
        if modifiers.contains(.control), let scalar = characters.lowercased().unicodeScalars.first {
            let value = scalar.value
            if value >= 97, value <= 122 { return Data([UInt8(value - 96)]) }
            if value == 32 { return Data([0]) }
        }
        return characters.data(using: .utf8)
    }
}

private struct InteractiveTerminalView: NSViewRepresentable {
    @ObservedObject var session: CommandSession

    func makeNSView(context: Context) -> TerminalScrollView {
        let view = TerminalScrollView()
        view.onInput = { [weak session] data in
            Task { @MainActor in session?.send(data) }
        }
        view.update(output: session.output, isEnabled: session.status == .running)
        DispatchQueue.main.async { view.focusTerminal() }
        return view
    }

    func updateNSView(_ view: TerminalScrollView, context: Context) {
        view.update(output: session.output, isEnabled: session.status == .running)
    }
}

private final class TerminalScrollView: NSScrollView {
    var onInput: ((Data) -> Void)?
    private let terminalView = TerminalTextView()
    private var renderedOutput = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        borderType = .noBorder
        hasVerticalScroller = true
        autohidesScrollers = true

        terminalView.isRichText = false
        terminalView.isEditable = true
        terminalView.isSelectable = true
        terminalView.drawsBackground = true
        terminalView.backgroundColor = backgroundColor
        terminalView.textColor = .textColor
        terminalView.insertionPointColor = .controlAccentColor
        terminalView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        terminalView.textContainerInset = NSSize(width: 10, height: 8)
        terminalView.autoresizingMask = [.width]
        terminalView.onInput = { [weak self] data in self?.onInput?(data) }
        documentView = terminalView
    }

    required init?(coder: NSCoder) { nil }

    func update(output: String, isEnabled: Bool) {
        terminalView.acceptsInput = isEnabled
        terminalView.isEditable = isEnabled
        guard output != renderedOutput else { return }
        let wasAtBottom = contentView.bounds.maxY >= terminalView.bounds.maxY - 24
        renderedOutput = output
        terminalView.string = output
        terminalView.setSelectedRange(NSRange(location: (output as NSString).length, length: 0))
        if wasAtBottom || output.count < 2_000 {
            terminalView.scrollToEndOfDocument(nil)
        }
    }

    func focusTerminal() {
        window?.makeFirstResponder(terminalView)
    }
}

private final class TerminalTextView: NSTextView {
    var onInput: ((Data) -> Void)?
    var acceptsInput = true

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        guard acceptsInput else { return }
        let value: String
        if let attributed = insertString as? NSAttributedString {
            value = attributed.string
        } else {
            value = String(describing: insertString)
        }
        guard let data = value.data(using: .utf8) else { return }
        onInput?(data)
    }

    override func keyDown(with event: NSEvent) {
        guard acceptsInput else {
            NSSound.beep()
            return
        }
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }
        if let data = TerminalKeyEncoder.data(
            keyCode: event.keyCode,
            characters: event.characters,
            modifiers: event.modifierFlags
        ) {
            onInput?(data)
        }
    }

    override func paste(_ sender: Any?) {
        guard acceptsInput,
              let value = NSPasteboard.general.string(forType: .string),
              let data = value.data(using: .utf8) else { return }
        onInput?(data)
    }

    override func cut(_ sender: Any?) {
        copy(sender)
    }

    override func deleteBackward(_ sender: Any?) {
        guard acceptsInput else { return }
        onInput?(Data([0x7F]))
    }
}
