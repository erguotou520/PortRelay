import Foundation

enum KubernetesCommandBuilder {
    static func baseArguments(kubeconfigPath: String, contextName: String? = nil) -> [String] {
        var arguments = ["kubectl", "--kubeconfig", (kubeconfigPath as NSString).expandingTildeInPath]
        if let contextName, !contextName.isEmpty {
            arguments += ["--context", contextName]
        }
        return arguments
    }

    static func portForwardArguments(
        mapping: KubernetesPortMapping,
        cluster: KubernetesClusterProfile
    ) -> [String] {
        baseArguments(kubeconfigPath: cluster.kubeconfigPath, contextName: cluster.contextName) + [
            "--namespace", mapping.namespace,
            "port-forward",
            "\(mapping.resourceKind.kubectlName)/\(mapping.resourceName)",
            "\(mapping.localPort):\(mapping.remotePort)",
            "--address", mapping.localHost
        ]
    }

    static func logsArguments(
        cluster: KubernetesClusterProfile,
        namespace: String,
        podName: String
    ) -> [String] {
        baseArguments(kubeconfigPath: cluster.kubeconfigPath, contextName: cluster.contextName) + [
            "--namespace", namespace,
            "logs", "pod/\(podName)",
            "--follow", "--tail=500", "--timestamps=true"
        ]
    }

    static func shellArguments(
        cluster: KubernetesClusterProfile,
        namespace: String,
        podName: String,
        shell: String,
        interactive: Bool = true
    ) -> [String] {
        var arguments = baseArguments(
            kubeconfigPath: cluster.kubeconfigPath,
            contextName: cluster.contextName
        ) + ["--namespace", namespace, "exec"]
        if interactive { arguments += ["-i", "-t"] }
        arguments += ["pod/\(podName)", "--", shell]
        if !interactive { arguments += ["-c", "exit 0"] }
        return arguments
    }
}

enum KubernetesClient {
    static func contexts(kubeconfigPath: String) async throws -> [String] {
        let data = try await KubectlRunner.run(
            KubernetesCommandBuilder.baseArguments(kubeconfigPath: kubeconfigPath)
                + ["config", "get-contexts", "-o", "name"]
        )
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    static func namespaces(cluster: KubernetesClusterProfile) async throws -> [String] {
        try await TeleportClient.ensureReady(cluster)
        let data = try await KubectlRunner.run(
            KubernetesCommandBuilder.baseArguments(
                kubeconfigPath: cluster.kubeconfigPath,
                contextName: cluster.contextName
            ) + ["--request-timeout=15s", "get", "namespaces", "-o", "json"]
        )
        return try parseNamespaces(data)
    }

    static func parseNamespaces(_ data: Data) throws -> [String] {
        let list = try JSONDecoder().decode(NamespaceList.self, from: data)
        return list.items.map(\.metadata.name).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    static func ports(cluster: KubernetesClusterProfile, namespace: String) async throws -> [KubernetesPort] {
        try await TeleportClient.ensureReady(cluster)
        let data = try await KubectlRunner.run(
            KubernetesCommandBuilder.baseArguments(
                kubeconfigPath: cluster.kubeconfigPath,
                contextName: cluster.contextName
            ) + [
                "--request-timeout=15s", "--namespace", namespace,
                "get", "services,deployments,pods", "-o", "json"
            ]
        )
        return try parsePorts(data)
    }

    static func pods(
        cluster: KubernetesClusterProfile,
        namespace: String,
        deployment: String
    ) async throws -> [KubernetesPod] {
        try await TeleportClient.ensureReady(cluster)
        let base = KubernetesCommandBuilder.baseArguments(
            kubeconfigPath: cluster.kubeconfigPath,
            contextName: cluster.contextName
        ) + ["--request-timeout=15s", "--namespace", namespace]
        let deploymentData = try await KubectlRunner.run(
            base + ["get", "deployment", deployment, "-o", "json"]
        )
        let selector = try parseDeploymentSelector(deploymentData)
        let podData = try await KubectlRunner.run(
            base + ["get", "pods", "--selector", selector, "-o", "json"]
        )
        return try parsePods(podData)
    }

    static func availableShell(
        cluster: KubernetesClusterProfile,
        namespace: String,
        podName: String
    ) async throws -> String {
        try await TeleportClient.ensureReady(cluster)
        for shell in ["/bin/bash", "/bin/sh"] {
            let arguments = KubernetesCommandBuilder.shellArguments(
                cluster: cluster,
                namespace: namespace,
                podName: podName,
                shell: shell,
                interactive: false
            )
            if (try? await KubectlRunner.run(arguments)) != nil { return shell }
        }
        throw ValidationError.message("Pod 中未找到可用的 bash 或 sh")
    }

    static func parseDeploymentSelector(_ data: Data) throws -> String {
        let deployment = try JSONDecoder().decode(DeploymentSelectorResource.self, from: data)
        let labels = deployment.spec.selector.matchLabels
        guard !labels.isEmpty else {
            throw ValidationError.message("Deployment 没有可用于查找 Pod 的标签选择器")
        }
        return labels.keys.sorted().map { "\($0)=\(labels[$0]!)" }.joined(separator: ",")
    }

    static func parsePods(_ data: Data) throws -> [KubernetesPod] {
        let list = try JSONDecoder().decode(PodList.self, from: data)
        return list.items.map {
            KubernetesPod(name: $0.metadata.name, phase: $0.status?.phase ?? "Unknown")
        }.sorted {
            if $0.isRunning != $1.isRunning { return $0.isRunning }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static func parsePorts(_ data: Data) throws -> [KubernetesPort] {
        let list = try JSONDecoder().decode(ResourceList.self, from: data)
        var ports: [KubernetesPort] = []

        let services = list.items.filter { $0.kind == "Service" }

        for item in list.items {
            if item.kind == "Service" {
                for port in item.spec?.ports ?? [] {
                    guard let number = port.port, port.protocolName ?? "TCP" == "TCP" else { continue }
                    ports.append(KubernetesPort(
                        kind: .service,
                        resourceName: item.metadata.name,
                        portName: port.name,
                        remotePort: number
                    ))
                }
            } else if item.kind == "Deployment" {
                let initialCount = ports.count
                let containers = item.spec?.template?.spec.containers ?? []
                for container in containers {
                    for port in container.ports ?? [] {
                        guard let number = port.containerPort, port.protocolName ?? "TCP" == "TCP" else { continue }
                        ports.append(KubernetesPort(
                            kind: .deployment,
                            resourceName: item.metadata.name,
                            portName: port.name,
                            remotePort: number
                        ))
                    }
                }
                let podLabels = item.spec?.template?.metadata?.labels ?? [:]
                for service in services where service.spec?.serviceSelector?.matches(podLabels) == true {
                    for servicePort in service.spec?.ports ?? [] {
                        guard servicePort.protocolName ?? "TCP" == "TCP",
                              let number = servicePort.targetPortNumber(in: containers) else { continue }
                        guard !ports.contains(where: {
                            $0.kind == .deployment
                                && $0.resourceName == item.metadata.name
                                && $0.remotePort == number
                        }) else { continue }
                        ports.append(KubernetesPort(
                            kind: .deployment,
                            resourceName: item.metadata.name,
                            portName: servicePort.name,
                            remotePort: number
                        ))
                    }
                }
                if ports.count == initialCount {
                    ports.append(KubernetesPort(
                        kind: .deployment,
                        resourceName: item.metadata.name,
                        portName: nil,
                        remotePort: nil
                    ))
                }
            } else if item.kind == "Pod" {
                let initialCount = ports.count
                for container in item.spec?.containers ?? [] {
                    for port in container.ports ?? [] {
                        guard let number = port.containerPort,
                              port.protocolName ?? "TCP" == "TCP" else { continue }
                        ports.append(KubernetesPort(
                            kind: .pod,
                            resourceName: item.metadata.name,
                            portName: port.name,
                            remotePort: number,
                            podPhase: item.status?.phase
                        ))
                    }
                }
                if ports.count == initialCount {
                    ports.append(KubernetesPort(
                        kind: .pod,
                        resourceName: item.metadata.name,
                        portName: nil,
                        remotePort: nil,
                        podPhase: item.status?.phase
                    ))
                }
            }
        }

        return Array(Set(ports)).sorted {
            if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
            let resourceOrder = $0.resourceName.localizedStandardCompare($1.resourceName)
            if resourceOrder != .orderedSame { return resourceOrder == .orderedAscending }
            return ($0.remotePort ?? 0) < ($1.remotePort ?? 0)
        }
    }
}

enum KubectlRunner {
    static func run(_ arguments: [String]) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            let temporaryDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("PortRelay-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

            let outputURL = temporaryDirectory.appendingPathComponent("stdout")
            let errorURL = temporaryDirectory.appendingPathComponent("stderr")
            FileManager.default.createFile(atPath: outputURL.path, contents: nil)
            FileManager.default.createFile(atPath: errorURL.path, contents: nil)
            let outputHandle = try FileHandle(forWritingTo: outputURL)
            let errorHandle = try FileHandle(forWritingTo: errorURL)
            defer {
                try? outputHandle.close()
                try? errorHandle.close()
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = arguments
            process.environment = kubectlEnvironment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = outputHandle
            process.standardError = errorHandle

            do {
                try process.run()
            } catch {
                throw ValidationError.message("无法启动 kubectl：\(error.localizedDescription)")
            }
            process.waitUntilExit()
            try? outputHandle.synchronize()
            try? errorHandle.synchronize()

            let output = (try? Data(contentsOf: outputURL)) ?? Data()
            let error = (try? Data(contentsOf: errorURL)) ?? Data()
            guard process.terminationStatus == 0 else {
                let message = String(data: error, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw ValidationError.message(message?.isEmpty == false ? message! : "kubectl 执行失败")
            }
            return output
        }.value
    }

    static var kubectlEnvironment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let commonPaths = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        if let current = environment["PATH"], !current.isEmpty {
            environment["PATH"] = "\(current):\(commonPaths)"
        } else {
            environment["PATH"] = commonPaths
        }
        return environment
    }
}

private struct NamespaceList: Decodable {
    let items: [NamespaceItem]
}

private struct NamespaceItem: Decodable {
    let metadata: KubernetesMetadata
}

private struct ResourceList: Decodable {
    let items: [KubernetesResource]
}

private struct KubernetesResource: Decodable {
    let kind: String
    let metadata: KubernetesMetadata
    let spec: KubernetesResourceSpec?
    let status: PodStatus?
}

private struct KubernetesMetadata: Decodable {
    let name: String
    let labels: [String: String]?
}

private struct KubernetesResourceSpec: Decodable {
    let ports: [KubernetesServicePort]?
    let template: KubernetesPodTemplate?
    let containers: [KubernetesContainer]?
    let serviceSelector: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case ports, template, containers
        case serviceSelector = "selector"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ports = try container.decodeIfPresent([KubernetesServicePort].self, forKey: .ports)
        template = try container.decodeIfPresent(KubernetesPodTemplate.self, forKey: .template)
        containers = try container.decodeIfPresent([KubernetesContainer].self, forKey: .containers)
        serviceSelector = try? container.decode([String: String].self, forKey: .serviceSelector)
    }
}

private struct KubernetesServicePort: Decodable {
    let name: String?
    let port: Int?
    let targetPort: KubernetesTargetPort?
    let protocolName: String?

    private enum CodingKeys: String, CodingKey {
        case name, port, targetPort
        case protocolName = "protocol"
    }

    func targetPortNumber(in containers: [KubernetesContainer]) -> Int? {
        switch targetPort {
        case .number(let number):
            return number
        case .name(let name):
            return containers
                .flatMap { $0.ports ?? [] }
                .first { $0.name == name }?
                .containerPort
        case nil:
            return port
        }
    }
}

private struct KubernetesPodTemplate: Decodable {
    let metadata: KubernetesPodTemplateMetadata?
    let spec: KubernetesPodSpec
}

private struct KubernetesPodTemplateMetadata: Decodable {
    let labels: [String: String]?
}

private struct KubernetesPodSpec: Decodable {
    let containers: [KubernetesContainer]
}

private struct KubernetesContainer: Decodable {
    let ports: [KubernetesContainerPort]?
}

private struct KubernetesContainerPort: Decodable {
    let name: String?
    let containerPort: Int?
    let protocolName: String?

    private enum CodingKeys: String, CodingKey {
        case name, containerPort
        case protocolName = "protocol"
    }
}

private enum KubernetesTargetPort: Decodable {
    case number(Int)
    case name(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int.self) {
            self = .number(number)
        } else {
            self = .name(try container.decode(String.self))
        }
    }
}

private extension Dictionary where Key == String, Value == String {
    func matches(_ labels: [String: String]) -> Bool {
        !isEmpty && allSatisfy { labels[$0.key] == $0.value }
    }
}

private struct DeploymentSelectorResource: Decodable {
    let spec: DeploymentSelectorSpec
}

private struct DeploymentSelectorSpec: Decodable {
    let selector: DeploymentSelector
}

private struct DeploymentSelector: Decodable {
    let matchLabels: [String: String]
}

private struct PodList: Decodable {
    let items: [PodResource]
}

private struct PodResource: Decodable {
    let metadata: KubernetesMetadata
    let status: PodStatus?
}

private struct PodStatus: Decodable {
    let phase: String?
}
