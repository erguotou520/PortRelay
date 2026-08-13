import SwiftUI

struct KubernetesMappingEditorView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let clusterID: UUID
    let namespace: String
    let port: KubernetesPort
    let existing: KubernetesPortMapping?

    @State private var localHost: String
    @State private var remotePort: Int
    @State private var localPort: Int
    @State private var errorMessage: String?

    init(
        clusterID: UUID,
        namespace: String,
        port: KubernetesPort,
        existing: KubernetesPortMapping?
    ) {
        self.clusterID = clusterID
        self.namespace = namespace
        self.port = port
        self.existing = existing
        _localHost = State(initialValue: existing?.localHost ?? "127.0.0.1")
        _remotePort = State(initialValue: existing?.remotePort ?? port.remotePort ?? 0)
        _localPort = State(initialValue: existing?.localPort ?? port.remotePort ?? 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(existing == nil ? "设置本地端口" : "修改本地端口")
                        .font(.title2.weight(.semibold))
                    Text("\(port.resourceDisplayName) · \(namespace)")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(24)
            Divider()

            Form {
                Section("集群端口") {
                    LabeledContent("资源", value: port.resourceDisplayName)
                    if port.remotePort == nil {
                        TextField("远程端口", value: $remotePort, format: .number.grouping(.never))
                    } else {
                        LabeledContent("端口", value: String(remotePort))
                    }
                    if let portName = port.portName, !portName.isEmpty {
                        LabeledContent("端口名称", value: portName)
                    }
                }

                Section("本地监听") {
                    Picker("地址", selection: $localHost) {
                        Text("仅本机 · 127.0.0.1").tag("127.0.0.1")
                        Text("所有网卡 · 0.0.0.0").tag("0.0.0.0")
                    }
                    TextField("端口", value: $localPort, format: .number.grouping(.never))
                    if localHost == "0.0.0.0" {
                        Label("同一网络中的其他设备也可能访问此端口。", systemImage: "exclamationmark.shield")
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
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(18)
        }
        .frame(width: 520, height: 500)
    }

    private func save() {
        do {
            try store.saveKubernetesMapping(KubernetesPortMapping(
                id: existing?.id ?? UUID(),
                clusterID: clusterID,
                namespace: namespace,
                resourceKind: port.kind,
                resourceName: port.resourceName,
                portName: port.portName,
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
