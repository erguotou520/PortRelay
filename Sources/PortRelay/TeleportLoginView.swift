import SwiftUI

struct TeleportLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore

    let cluster: KubernetesClusterProfile

    @State private var password = ""
    @State private var mfaCode = ""
    @State private var isLoggingIn = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("重新登录 Teleport")
                        .font(.title2.weight(.semibold))
                    Text("\(cluster.teleportUsername)@\(cluster.teleportProxy)")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(24)
            Divider()

            Form {
                SecureField("密码（留空使用已保存密码）", text: $password)
                if cluster.teleportRequiresMFA {
                    SecureField("当前 MFA 验证码", text: $mfaCode)
                    Text("MFA 验证码只用于本次登录，不会保存。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let errorMessage {
                    CopyableErrorView(message: errorMessage)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("登录") { Task { await login() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isLoggingIn)
            }
            .padding(18)
        }
        .frame(width: 520, height: cluster.teleportRequiresMFA ? 390 : 330)
    }

    @MainActor
    private func login() async {
        isLoggingIn = true
        defer { isLoggingIn = false }
        do {
            let resolvedPassword = password.isEmpty
                ? KeychainStore.teleportPassword(for: cluster.id) ?? ""
                : password
            guard !resolvedPassword.isEmpty else { throw ValidationError.message("请输入 Teleport 密码") }
            if cluster.teleportRequiresMFA && mfaCode.isEmpty {
                throw ValidationError.message("请输入当前 MFA 验证码")
            }
            try await TeleportClient.refresh(
                cluster,
                password: resolvedPassword,
                mfaCode: cluster.teleportRequiresMFA ? mfaCode : nil
            )
            if !password.isEmpty {
                try KeychainStore.setTeleportPassword(password, for: cluster.id)
            }
            store.teleportLoginDidSucceed(clusterID: cluster.id)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
