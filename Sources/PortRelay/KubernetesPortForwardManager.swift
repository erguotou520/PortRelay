import Foundation
import Darwin

@MainActor
final class KubernetesPortForwardManager: ObservableObject {
    @Published private(set) var statuses: [UUID: MappingStatus] = [:]

    private var processes: [UUID: Process] = [:]
    private var outputs: [UUID: Data] = [:]

    func status(for mappingID: UUID) -> MappingStatus {
        statuses[mappingID] ?? .stopped
    }

    func start(mapping: KubernetesPortMapping, cluster: KubernetesClusterProfile) throws {
        guard processes[mapping.id] == nil else { return }
        guard FileManager.default.fileExists(
            atPath: (cluster.kubeconfigPath as NSString).expandingTildeInPath
        ) else {
            throw ValidationError.message("找不到 kubeconfig：\(cluster.kubeconfigPath)")
        }
        guard (1...65535).contains(mapping.localPort), (1...65535).contains(mapping.remotePort) else {
            throw ValidationError.message("端口必须在 1 到 65535 之间")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = KubernetesCommandBuilder.portForwardArguments(mapping: mapping, cluster: cluster)
        process.environment = KubernetesCommandBuilder.environment(for: cluster)
        process.standardInput = FileHandle.nullDevice

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        outputs[mapping.id] = Data()

        let consume: @Sendable (FileHandle) -> Void = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in
                guard let self else { return }
                self.outputs[mapping.id, default: Data()].append(data)
                let text = String(decoding: self.outputs[mapping.id, default: Data()], as: UTF8.self)
                if text.contains("Forwarding from") {
                    self.statuses[mapping.id] = .running
                }
            }
        }
        outputPipe.fileHandleForReading.readabilityHandler = consume
        errorPipe.fileHandleForReading.readabilityHandler = consume

        process.terminationHandler = { [weak self] terminated in
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            let remainingOutput = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let remainingError = errorPipe.fileHandleForReading.readDataToEndOfFile()
            Task { @MainActor in
                guard let self else { return }
                self.outputs[mapping.id, default: Data()].append(remainingOutput)
                self.outputs[mapping.id, default: Data()].append(remainingError)
                self.processes[mapping.id] = nil
                let message = String(
                    data: self.outputs.removeValue(forKey: mapping.id) ?? Data(),
                    encoding: .utf8
                )?.trimmingCharacters(in: .whitespacesAndNewlines)
                self.statuses[mapping.id] = .failed(
                    message?.isEmpty == false ? message! : "kubectl port-forward 已退出"
                )
            }
        }

        statuses[mapping.id] = .starting
        do {
            try process.run()
            processes[mapping.id] = process
        } catch {
            statuses[mapping.id] = .failed(error.localizedDescription)
            throw ValidationError.message("无法启动 kubectl：\(error.localizedDescription)")
        }

        Task { @MainActor [weak self, weak process] in
            for _ in 0..<100 {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, let process, process.isRunning,
                      self.statuses[mapping.id] == .starting else { return }
                if self.isListening(host: mapping.localHost, port: mapping.localPort) {
                    self.statuses[mapping.id] = .running
                    return
                }
            }
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
        outputs[mappingID] = nil
        statuses[mappingID] = .stopped
    }

    func markFailed(mappingID: UUID, message: String) {
        statuses[mappingID] = .failed(message)
    }

    func stopAll() {
        for id in Array(processes.keys) {
            stop(mappingID: id)
        }
    }

    private func isListening(host: String, port: Int) -> Bool {
        let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else { return false }
        defer { close(socketDescriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        let connectHost = host == "0.0.0.0" ? "127.0.0.1" : host
        guard inet_pton(AF_INET, connectHost, &address.sin_addr) == 1 else { return false }

        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
