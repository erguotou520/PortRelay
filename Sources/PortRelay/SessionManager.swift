import Foundation

enum SessionKind: Equatable {
    case sshShell
    case kubernetesShell
    case kubernetesLogs

    var isKubernetes: Bool { self != .sshShell }
    var isInteractive: Bool { self != .kubernetesLogs }
}

enum SessionStatus: Equatable {
    case connecting
    case running
    case stopped
    case failed(String)

    var title: String {
        switch self {
        case .connecting: "连接中"
        case .running: "已连接"
        case .stopped: "已结束"
        case .failed: "失败"
        }
    }
}

@MainActor
final class CommandSession: ObservableObject, Identifiable {
    let id = UUID()
    let kind: SessionKind
    let title: String
    let subtitle: String

    @Published private(set) var output = ""
    @Published private(set) var status = SessionStatus.connecting

    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?

    init(kind: SessionKind, title: String, subtitle: String) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
    }

    func start(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        pseudoTerminal: Bool
    ) {
        guard process == nil else { return }

        let process = Process()
        if pseudoTerminal {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
            process.arguments = ["-q", "-F", "/dev/null", executable] + arguments
        } else {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
        }
        process.environment = environment

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.append(data) }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.append(data) }
        }
        process.terminationHandler = { [weak self] terminated in
            Task { @MainActor in
                guard let self else { return }
                self.finish(exitCode: terminated.terminationStatus)
            }
        }

        self.process = process
        self.inputPipe = inputPipe
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe
        do {
            try process.run()
            status = .running
        } catch {
            fail("无法启动命令：\(error.localizedDescription)")
        }
    }

    func send(_ command: String) {
        guard let data = "\(command)\n".data(using: .utf8) else { return }
        send(data)
    }

    func send(_ data: Data) {
        guard kind.isInteractive, status == .running, !data.isEmpty else { return }
        do {
            try inputPipe?.fileHandleForWriting.write(contentsOf: data)
        } catch {
            fail("发送命令失败：\(error.localizedDescription)")
        }
    }

    func fail(_ message: String) {
        append("\n\(message)\n")
        status = .failed(message)
        cleanUp()
    }

    func stop() {
        guard let process else {
            if status == .connecting || status == .running { status = .stopped }
            return
        }
        process.terminationHandler = nil
        if process.isRunning { process.terminate() }
        status = .stopped
        cleanUp()
    }

    private func append(_ data: Data) {
        append(String(decoding: data, as: UTF8.self))
    }

    private func append(_ value: String) {
        output += Self.cleanTerminalText(value)
        if output.count > 1_000_000 {
            output = String(output.suffix(800_000))
        }
    }

    private func finish(exitCode: Int32) {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        if exitCode == 0 {
            status = .stopped
        } else {
            let message = "命令已退出（状态码 \(exitCode)）"
            append("\n\(message)\n")
            status = .failed(message)
        }
        cleanUp()
    }

    private func cleanUp() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        try? inputPipe?.fileHandleForWriting.close()
        process = nil
        inputPipe = nil
        outputPipe = nil
        errorPipe = nil
    }

    private static func cleanTerminalText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(
                of: "\u{001B}\\[[0-?]*[ -/]*[@-~]",
                with: "",
                options: .regularExpression
            )
    }
}

@MainActor
final class GlobalSessionManager: ObservableObject {
    @Published private(set) var sessions: [CommandSession] = []
    @Published var selectedSessionID: UUID?
    @Published var isPanelCollapsed = false

    var kubernetesSessions: [CommandSession] { sessions.filter(\.kind.isKubernetes) }
    var sshSessions: [CommandSession] { sessions.filter { !$0.kind.isKubernetes } }

    func openSSH(server: ServerProfile) {
        let session = addSession(
            kind: .sshShell,
            title: server.name,
            subtitle: server.subtitle
        )
        select(session)
        session.start(
            executable: "/usr/bin/ssh",
            arguments: SSHCommandBuilder.connectionArguments(server: server),
            environment: SSHCommandBuilder.environment(for: server),
            pseudoTerminal: true
        )
    }

    func openKubernetesLogs(
        cluster: KubernetesClusterProfile,
        namespace: String,
        deployment: String,
        pod: KubernetesPod
    ) {
        let session = addSession(
            kind: .kubernetesLogs,
            title: "\(deployment) · 日志",
            subtitle: "\(namespace) / \(pod.name)"
        )
        select(session)
        session.start(
            executable: "/usr/bin/env",
            arguments: KubernetesCommandBuilder.logsArguments(
                cluster: cluster,
                namespace: namespace,
                podName: pod.name
            ),
            environment: KubectlRunner.kubectlEnvironment,
            pseudoTerminal: false
        )
    }

    func openKubernetesShell(
        cluster: KubernetesClusterProfile,
        namespace: String,
        deployment: String,
        pod: KubernetesPod
    ) {
        let session = addSession(
            kind: .kubernetesShell,
            title: "\(deployment) · Shell",
            subtitle: "\(namespace) / \(pod.name)"
        )
        select(session)
        Task {
            do {
                let shell = try await KubernetesClient.availableShell(
                    cluster: cluster,
                    namespace: namespace,
                    podName: pod.name
                )
                session.start(
                    executable: "/usr/bin/script",
                    arguments: ["-q", "-F", "/dev/null", "/usr/bin/env"]
                        + KubernetesCommandBuilder.shellArguments(
                            cluster: cluster,
                            namespace: namespace,
                            podName: pod.name,
                            shell: shell
                        ),
                    environment: KubectlRunner.kubectlEnvironment,
                    pseudoTerminal: false
                )
            } catch {
                session.fail(error.localizedDescription)
            }
        }
    }

    func close(_ session: CommandSession) {
        session.stop()
        sessions.removeAll { $0.id == session.id }
        if selectedSessionID == session.id {
            selectedSessionID = sessions.last?.id
        }
    }

    func stopAll() {
        sessions.forEach { $0.stop() }
    }

    private func addSession(kind: SessionKind, title: String, subtitle: String) -> CommandSession {
        let session = CommandSession(kind: kind, title: title, subtitle: subtitle)
        sessions.append(session)
        return session
    }

    private func select(_ session: CommandSession) {
        selectedSessionID = session.id
        isPanelCollapsed = false
    }
}
