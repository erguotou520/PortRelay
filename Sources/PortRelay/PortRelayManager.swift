import Foundation

@MainActor
final class PortRelayManager: ObservableObject {
    @Published private(set) var statuses: [UUID: MappingStatus] = [:]

    private var processes: [UUID: Process] = [:]
    private var errors: [UUID: Data] = [:]

    func status(for mappingID: UUID) -> MappingStatus {
        statuses[mappingID] ?? .stopped
    }

    func start(mapping: PortMapping, server: ServerProfile) throws {
        guard processes[mapping.id] == nil else { return }
        guard (1...65535).contains(mapping.localPort), (1...65535).contains(mapping.remotePort) else {
            throw ValidationError.message("端口必须在 1 到 65535 之间")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments(mapping: mapping, server: server)
        process.standardInput = FileHandle.nullDevice

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice
        errors[mapping.id] = Data()
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in
                self?.errors[mapping.id, default: Data()].append(data)
            }
        }

        if server.authentication == .password {
            var environment = ProcessInfo.processInfo.environment
            environment["SSH_ASKPASS"] = askPassExecutableURL.path
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["DISPLAY"] = "portforward:0"
            environment["PORTFORWARD_KEYCHAIN_ACCOUNT"] = server.id.uuidString
            process.environment = environment
        }

        process.terminationHandler = { [weak self] terminated in
            errorPipe.fileHandleForReading.readabilityHandler = nil
            let remainingErrorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            Task { @MainActor in
                guard let self else { return }
                self.errors[mapping.id, default: Data()].append(remainingErrorData)
                self.processes[mapping.id] = nil
                let message = String(data: self.errors.removeValue(forKey: mapping.id) ?? Data(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if terminated.terminationStatus == 0 {
                    self.statuses[mapping.id] = .stopped
                } else {
                    self.statuses[mapping.id] = .failed(message?.isEmpty == false ? message! : "SSH 连接已退出")
                }
            }
        }

        statuses[mapping.id] = .starting
        do {
            try process.run()
            processes[mapping.id] = process
        } catch {
            statuses[mapping.id] = .failed(error.localizedDescription)
            throw error
        }

        Task { @MainActor [weak self, weak process] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, let process, process.isRunning else { return }
            self.statuses[mapping.id] = .running
        }
    }

    func stop(mappingID: UUID) {
        guard let process = processes[mappingID] else {
            statuses[mappingID] = .stopped
            return
        }
        process.terminationHandler = nil
        process.terminate()
        processes[mappingID] = nil
        errors[mappingID] = nil
        statuses[mappingID] = .stopped
    }

    func stopAll() {
        for id in Array(processes.keys) {
            stop(mappingID: id)
        }
    }

    private func arguments(mapping: PortMapping, server: ServerProfile) -> [String] {
        var arguments = [
            "-N", "-T",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-o", "StrictHostKeyChecking=accept-new",
            "-L", "\(mapping.localHost):\(mapping.localPort):\(mapping.remoteHost):\(mapping.remotePort)"
        ]

        if server.source == .sshConfig, let alias = server.sshAlias {
            arguments.append(alias)
            return arguments
        }

        arguments += ["-p", String(server.port)]
        switch server.authentication {
        case .password:
            arguments += [
                "-o", "PubkeyAuthentication=no",
                "-o", "PreferredAuthentications=password,keyboard-interactive"
            ]
        case .privateKeyFile, .embeddedPrivateKey:
            if let path = server.privateKeyPath, !path.isEmpty {
                arguments += ["-i", (path as NSString).expandingTildeInPath]
            }
            arguments += ["-o", "BatchMode=yes"]
        case .systemDefault, .sshConfig:
            arguments += ["-o", "BatchMode=yes"]
        }
        arguments.append("\(server.username)@\(server.host)")
        return arguments
    }

    private var askPassExecutableURL: URL {
        let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent()
        return (executableDirectory ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            .appendingPathComponent("PortRelayAskPass")
    }
}
