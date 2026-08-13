import SwiftUI

struct MappingEditorView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    private let existing: PortMapping?
    private let serverID: UUID
    private let id: UUID

    @State private var name: String
    @State private var remoteHost: String
    @State private var remotePort: Int
    @State private var localHost: String
    @State private var localPort: Int
    @State private var errorMessage: String?

    init(serverID: UUID, existing: PortMapping?) {
        self.serverID = serverID
        self.existing = existing
        self.id = existing?.id ?? UUID()
        _name = State(initialValue: existing?.name ?? "")
        _remoteHost = State(initialValue: existing?.remoteHost ?? "127.0.0.1")
        _remotePort = State(initialValue: existing?.remotePort ?? 80)
        _localHost = State(initialValue: existing?.localHost ?? "127.0.0.1")
        _localPort = State(initialValue: existing?.localPort ?? 8080)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(existing == nil ? "添加端口映射" : "修改端口映射")
                        .font(.title2.weight(.semibold))
                    Text("流量将从本机监听地址转发到服务器一侧的目标地址")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(24)
            Divider()

            Form {
                TextField("名称", text: $name, prompt: Text("例如：Web 管理后台"))

                Section("远程目标") {
                    TextField("地址", text: $remoteHost, prompt: Text("通常为 127.0.0.1"))
                    TextField("端口", value: $remotePort, format: .number.grouping(.never))
                }

                Section("本地监听") {
                    Picker("地址", selection: $localHost) {
                        Text("仅本机 · 127.0.0.1").tag("127.0.0.1")
                        Text("所有网卡 · 0.0.0.0").tag("0.0.0.0")
                    }
                    TextField("端口", value: $localPort, format: .number.grouping(.never))
                    if localHost == "0.0.0.0" {
                        Label("同一网络中的其他设备也可能访问此端口，请确认防火墙设置。", systemImage: "exclamationmark.shield")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(existing == nil ? "添加" : "保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(18)
        }
        .frame(width: 520, height: 520)
    }

    private func save() {
        do {
            try store.saveMapping(PortMapping(
                id: id,
                serverID: serverID,
                name: name,
                remoteHost: remoteHost,
                remotePort: remotePort,
                localHost: localHost,
                localPort: localPort,
                isEnabled: existing?.isEnabled ?? false
            ))
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
