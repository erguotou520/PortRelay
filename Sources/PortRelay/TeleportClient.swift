import Foundation

enum TeleportCommandBuilder {
    static func loginArguments(proxy: String, username: String, requiresMFA: Bool) -> [String] {
        [
            "tsh", "login",
            "--proxy=\(proxy)",
            "--user=\(username)",
            "--auth=local",
            "--mfa-mode=\(requiresMFA ? "otp" : "auto")",
            "--browser=none"
        ]
    }

    static func statusArguments(proxy: String, username: String) -> [String] {
        ["tsh", "--proxy=\(proxy)", "--user=\(username)", "status", "--format=json"]
    }

    static func kubeListArguments(proxy: String, username: String) -> [String] {
        ["tsh", "--proxy=\(proxy)", "--user=\(username)", "kube", "ls", "--format=json"]
    }

    static func kubeLoginArguments(
        proxy: String,
        username: String,
        kubeCluster: String,
        contextName: String
    ) -> [String] {
        [
            "tsh", "--proxy=\(proxy)", "--user=\(username)",
            "kube", "login", kubeCluster,
            "--set-context-name=\(contextName)"
        ]
    }
}

enum TeleportClient {
    static let renewalThreshold: TimeInterval = 10 * 60

    static func normalizeProxy(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://"] where result.hasPrefix(prefix) {
            result.removeFirst(prefix.count)
        }
        while result.hasSuffix("/") { result.removeLast() }
        return result
    }

    static func loginAndListClusters(
        proxy: String,
        username: String,
        password: String,
        mfaCode: String?
    ) async throws -> [String] {
        let proxy = normalizeProxy(proxy)
        try validateInstallation()
        try await TeleportRunner.login(
            arguments: TeleportCommandBuilder.loginArguments(
                proxy: proxy,
                username: username,
                requiresMFA: mfaCode != nil
            ),
            password: password,
            mfaCode: mfaCode
        )
        let data = try await TeleportRunner.run(
            TeleportCommandBuilder.kubeListArguments(proxy: proxy, username: username)
        )
        return try parseKubeClusterNames(data)
    }

    static func configureKubeconfig(for cluster: KubernetesClusterProfile) async throws -> String {
        guard cluster.configSource == .teleport else { return cluster.kubeconfigPath }
        let path = try ConfigurationStore.prepareTeleportKubeconfig(clusterID: cluster.id)
        var environment = KubectlRunner.kubectlEnvironment
        environment["KUBECONFIG"] = path
        _ = try await TeleportRunner.run(
            TeleportCommandBuilder.kubeLoginArguments(
                proxy: normalizeProxy(cluster.teleportProxy),
                username: cluster.teleportUsername,
                kubeCluster: cluster.teleportKubeCluster,
                contextName: cluster.contextName
            ),
            environment: environment
        )
        return try ConfigurationStore.prepareTeleportKubeconfig(clusterID: cluster.id)
    }

    static func ensureReady(_ cluster: KubernetesClusterProfile) async throws {
        guard cluster.configSource == .teleport else { return }
        try validateInstallation()
        let proxy = normalizeProxy(cluster.teleportProxy)
        if let status = try? await TeleportRunner.run(
            TeleportCommandBuilder.statusArguments(proxy: proxy, username: cluster.teleportUsername)
        ), isCredentialValid(status, minimumValidity: renewalThreshold) {
            if FileManager.default.contents(atPath: cluster.kubeconfigPath)?.isEmpty != false {
                _ = try await configureKubeconfig(for: cluster)
            }
            return
        }
        guard !cluster.teleportRequiresMFA else {
            throw ValidationError.message("Teleport 登录已过期，请右键集群并选择“重新登录”后输入新的 MFA 验证码")
        }
        guard let password = KeychainStore.teleportPassword(for: cluster.id), !password.isEmpty else {
            throw ValidationError.message("Teleport 密码未保存，请修改集群并重新输入密码")
        }
        try await refresh(cluster, password: password, mfaCode: nil)
    }

    static func refresh(
        _ cluster: KubernetesClusterProfile,
        password: String,
        mfaCode: String?
    ) async throws {
        let proxy = normalizeProxy(cluster.teleportProxy)
        try validateInstallation()
        try await TeleportRunner.login(
            arguments: TeleportCommandBuilder.loginArguments(
                proxy: proxy,
                username: cluster.teleportUsername,
                requiresMFA: cluster.teleportRequiresMFA
            ),
            password: password,
            mfaCode: mfaCode
        )
        _ = try await configureKubeconfig(for: cluster)
    }

    static func isCredentialValid(
        _ data: Data,
        now: Date = Date(),
        minimumValidity: TimeInterval = 0
    ) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let active = root["active"] as? [String: Any],
              let value = active["valid_until"] as? String,
              let expiration = parseISO8601(value) else { return false }
        return expiration.timeIntervalSince(now) > minimumValidity
    }

    static func parseKubeClusterNames(_ data: Data) throws -> [String] {
        guard let values = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ValidationError.message("无法解析 Teleport Kubernetes 集群列表")
        }
        let names = values.compactMap { value -> String? in
            if let name = value["kube_cluster_name"] as? String { return name }
            if let name = value["name"] as? String { return name }
            if let metadata = value["metadata"] as? [String: Any],
               let name = metadata["name"] as? String { return name }
            return nil
        }
        return Array(Set(names)).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    private static func validateInstallation() throws {
        let paths = (KubectlRunner.kubectlEnvironment["PATH"] ?? "")
            .split(separator: ":")
            .map { String($0) + "/tsh" }
        guard paths.contains(where: FileManager.default.isExecutableFile) else {
            throw ValidationError.message("未找到 tsh，请先安装 Teleport 客户端")
        }
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

enum TeleportRunner {
    static func run(
        _ arguments: [String],
        environment: [String: String] = KubectlRunner.kubectlEnvironment
    ) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = arguments
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            let output = Pipe()
            let error = Pipe()
            process.standardOutput = output
            process.standardError = error
            do {
                try process.run()
            } catch {
                throw ValidationError.message("无法启动 tsh：\(error.localizedDescription)")
            }
            process.waitUntilExit()
            let outputData = output.fileHandleForReading.readDataToEndOfFile()
            let errorData = error.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0 else {
                throw ValidationError.message(errorMessage(errorData, fallback: outputData))
            }
            return outputData
        }.value
    }

    static func login(arguments: [String], password: String, mfaCode: String?) async throws {
        try await Task.detached(priority: .userInitiated) {
            let script = #"""
            set timeout 120
            log_user 1
            gets stdin password
            gets stdin otp
            set command [split $env(PORTRELAY_TSH_ARGUMENTS) "\u001f"]
            unset env(PORTRELAY_TSH_ARGUMENTS)
            spawn -noecho /usr/bin/env {*}$command
            expect {
                -re {Enter password for Teleport user.*:} {
                    send -- "$password\r"
                    exp_continue
                }
                -re {Enter an OTP code from a device:} {
                    if {$otp eq ""} {
                        puts stderr "__PORTRELAY_MFA_REQUIRED__"
                        exit 75
                    }
                    send -- "$otp\r"
                    exp_continue
                }
                timeout {
                    puts stderr "Teleport 登录等待超时"
                    exit 124
                }
                eof {
                    catch wait result
                    exit [lindex $result 3]
                }
            }
            """#
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/expect")
            process.arguments = ["-c", script]
            var environment = KubectlRunner.kubectlEnvironment
            environment["PORTRELAY_TSH_ARGUMENTS"] = arguments.joined(separator: "\u{001F}")
            process.environment = environment
            let input = Pipe()
            let output = Pipe()
            let error = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = error
            do {
                try process.run()
                let secretInput = "\(password)\n\(mfaCode ?? "")\n"
                try input.fileHandleForWriting.write(contentsOf: Data(secretInput.utf8))
                try input.fileHandleForWriting.close()
            } catch {
                if process.isRunning { process.terminate() }
                throw ValidationError.message("无法启动 Teleport 登录：\(error.localizedDescription)")
            }
            process.waitUntilExit()
            let outputData = output.fileHandleForReading.readDataToEndOfFile()
            let errorData = error.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0 else {
                let combined = errorData + outputData
                let message = String(decoding: combined, as: UTF8.self)
                if message.contains("__PORTRELAY_MFA_REQUIRED__") {
                    throw ValidationError.message("此 Teleport 账户需要 MFA，请启用 MFA 并输入当前 OTP 验证码")
                }
                throw ValidationError.message(errorMessage(errorData, fallback: outputData))
            }
        }.value
    }

    private static func errorMessage(_ primary: Data, fallback: Data) -> String {
        let value = primary.isEmpty ? fallback : primary
        let message = String(decoding: value, as: UTF8.self)
            .replacingOccurrences(
                of: "\u{001B}\\[[0-?]*[ -/]*[@-~]",
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "tsh 执行失败" : message
    }
}
