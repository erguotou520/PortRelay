import XCTest
@testable import PortRelay

final class KubernetesTests: XCTestCase {
    func testLegacyConfigurationDefaultsKubernetesCollectionsToEmpty() throws {
        let data = Data(#"{"servers":[],"mappings":[]}"#.utf8)

        let configuration = try JSONDecoder().decode(StoredConfiguration.self, from: data)

        XCTAssertTrue(configuration.kubernetesClusters.isEmpty)
        XCTAssertTrue(configuration.kubernetesMappings.isEmpty)
    }

    func testLegacyKubernetesClusterDefaultsTeleportFields() throws {
        let id = UUID()
        let data = Data("""
        {
          "id": "\(id.uuidString)",
          "name": "Production",
          "configSource": "localFile",
          "kubeconfigPath": "/tmp/config",
          "contextName": "production"
        }
        """.utf8)

        let cluster = try JSONDecoder().decode(KubernetesClusterProfile.self, from: data)

        XCTAssertEqual(cluster.teleportProxy, "")
        XCTAssertEqual(cluster.teleportUsername, "")
        XCTAssertEqual(cluster.teleportKubeCluster, "")
        XCTAssertFalse(cluster.teleportRequiresMFA)
    }

    func testTeleportLoginArgumentsSelectLocalAuthAndOptionalOTP() {
        XCTAssertEqual(
            TeleportCommandBuilder.loginArguments(
                proxy: "teleport.example.com:443",
                username: "alice",
                requiresMFA: true
            ),
            [
                "tsh", "login", "--proxy=teleport.example.com:443", "--user=alice",
                "--auth=local", "--mfa-mode=otp", "--browser=none"
            ]
        )
        XCTAssertTrue(
            TeleportCommandBuilder.loginArguments(
                proxy: "teleport.example.com:443",
                username: "alice",
                requiresMFA: false
            ).contains("--mfa-mode=auto")
        )
    }

    func testTeleportCredentialValidityUsesValidUntil() {
        let data = Data(#"{"active":{"valid_until":"2026-08-14T12:30:00+08:00"},"profiles":[]}"#.utf8)
        let now = ISO8601DateFormatter().date(from: "2026-08-14T04:00:00Z")!

        XCTAssertTrue(TeleportClient.isCredentialValid(data, now: now, minimumValidity: 20 * 60))
        XCTAssertFalse(TeleportClient.isCredentialValid(data, now: now, minimumValidity: 31 * 60))
    }

    func testTeleportKubeClustersParseSupportedJSONShapes() throws {
        let data = Data(#"[{"kube_cluster_name":"prod"},{"metadata":{"name":"staging"}},{"name":"prod"}]"#.utf8)

        XCTAssertEqual(try TeleportClient.parseKubeClusterNames(data), ["prod", "staging"])
    }

    func testTeleportSelectedKubeClusterParsing() {
        let data = Data(#"[{"kube_cluster_name":"prod","selected":false},{"kube_cluster_name":"staging","selected":true}]"#.utf8)

        XCTAssertEqual(TeleportClient.parseSelectedKubeCluster(data), "staging")
    }

    func testTeleportRetryPolicyOnlyRetriesTransientConnections() {
        XCTAssertTrue(TeleportRetryPolicy.shouldRetry("read: connection reset by peer"))
        XCTAssertTrue(TeleportRetryPolicy.shouldRetry("unexpected EOF"))
        XCTAssertTrue(TeleportRetryPolicy.shouldRetry("Error from server (InternalError): Internal Server Error"))
        XCTAssertTrue(TeleportRetryPolicy.shouldRetry("Client.Timeout exceeded while awaiting headers"))
        XCTAssertFalse(TeleportRetryPolicy.shouldRetry("Access denied"))
    }

    func testCommandOutputCleaningRemovesANSIForCopying() {
        XCTAssertEqual(
            CommandOutputText.cleaned("\u{001B}[31mERROR:\u{001B}[0m connection reset\n"),
            "ERROR: connection reset"
        )
    }

    func testTeleportRunnerRetriesOneTransientFailure() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("PortRelay-retry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let command = """
        if test -f '\(marker.path)'; then
          printf success
          exit 0
        fi
        touch '\(marker.path)'
        printf 'connection reset by peer' >&2
        exit 1
        """

        let output = try await TeleportRunner.run(["/bin/sh", "-c", command])

        XCTAssertEqual(String(decoding: output, as: UTF8.self), "success")
    }

    func testTeleportRunnerRetriesMultipleTransientFailures() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("PortRelay-retry-count-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let command = """
        count=0
        if test -f '\(marker.path)'; then count=$(cat '\(marker.path)'); fi
        count=$((count + 1))
        printf '%s' "$count" > '\(marker.path)'
        if test "$count" -lt 3; then
          printf 'Internal Server Error' >&2
          exit 1
        fi
        printf success
        """

        let output = try await TeleportRunner.run(["/bin/sh", "-c", command])

        XCTAssertEqual(String(decoding: output, as: UTF8.self), "success")
    }

    func testTeleportProxyNormalizationRemovesURLDecoration() {
        XCTAssertEqual(
            TeleportClient.normalizeProxy(" https://teleport.example.com:443/ "),
            "teleport.example.com:443"
        )
    }

    func testTeleportLoginDriverSuppliesPasswordAndOTP() async throws {
        let command = """
        printf 'Enter password for Teleport user alice:'
        IFS= read -r password
        printf 'Enter an OTP code from a device:'
        IFS= read -r otp
        test "$password" = 'secret value' && test "$otp" = '123456'
        """

        try await TeleportRunner.login(
            arguments: ["/bin/sh", "-c", command],
            password: "secret value",
            mfaCode: "123456"
        )
    }

    func testTeleportLoginDriverSupportsPasswordOnly() async throws {
        let command = """
        printf 'Enter password for Teleport user alice:'
        IFS= read -r password
        test "$password" = 'secret value'
        """

        try await TeleportRunner.login(
            arguments: ["/bin/sh", "-c", command],
            password: "secret value",
            mfaCode: nil
        )
    }

    func testTeleportLoginDriverReportsRequiredMFA() async {
        let command = """
        printf 'Enter password for Teleport user alice:'
        IFS= read -r password
        printf 'Enter an OTP code from a device:'
        IFS= read -r otp
        """

        do {
            try await TeleportRunner.login(
                arguments: ["/bin/sh", "-c", command],
                password: "secret value",
                mfaCode: nil
            )
            XCTFail("Expected MFA validation error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("需要 MFA"))
        }
    }

    func testKubernetesMappingLegacyEnabledStateDefaultsToFalse() throws {
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "clusterID": "\(UUID().uuidString)",
          "namespace": "default",
          "resourceKind": "service",
          "resourceName": "web",
          "remotePort": 80,
          "localHost": "127.0.0.1",
          "localPort": 8080
        }
        """

        let mapping = try JSONDecoder().decode(KubernetesPortMapping.self, from: Data(json.utf8))

        XCTAssertFalse(mapping.isEnabled)
    }

    func testPortForwardArgumentsPinKubeconfigContextAndNamespace() {
        let cluster = KubernetesClusterProfile(
            id: UUID(),
            name: "Production",
            configSource: .localFile,
            kubeconfigPath: "~/.kube/config",
            contextName: "production-admin"
        )
        let mapping = KubernetesPortMapping(
            id: UUID(),
            clusterID: cluster.id,
            namespace: "payments",
            resourceKind: .service,
            resourceName: "api",
            portName: "http",
            remotePort: 80,
            localHost: "127.0.0.1",
            localPort: 8082,
            isEnabled: true
        )

        let arguments = KubernetesCommandBuilder.portForwardArguments(mapping: mapping, cluster: cluster)

        XCTAssertEqual(arguments, [
            "kubectl", "--kubeconfig", ("~/.kube/config" as NSString).expandingTildeInPath,
            "--context", "production-admin",
            "port-forward", "service/api", "8082:80",
            "--namespace", "payments", "--address", "127.0.0.1"
        ])
    }

    func testTeleportKubernetesCommandsUseTshKubectlWithoutKubeconfig() {
        let cluster = KubernetesClusterProfile(
            id: UUID(),
            name: "Teleport Production",
            configSource: .teleport,
            kubeconfigPath: "/tmp/teleport-kubeconfig",
            contextName: "portrelay-context",
            teleportProxy: "teleport.example.com:443",
            teleportUsername: "alice",
            teleportKubeCluster: "production"
        )
        let mapping = KubernetesPortMapping(
            id: UUID(),
            clusterID: cluster.id,
            namespace: "payments",
            resourceKind: .service,
            resourceName: "api",
            portName: "http",
            remotePort: 80,
            localHost: "127.0.0.1",
            localPort: 8082
        )

        let prefix = [
            "tsh", "--proxy=teleport.example.com:443", "--user=alice", "kubectl"
        ]
        let portForward = KubernetesCommandBuilder.portForwardArguments(
            mapping: mapping,
            cluster: cluster
        )

        XCTAssertEqual(Array(portForward.prefix(4)), prefix)
        XCTAssertEqual(Array(portForward.dropFirst(4).prefix(3)), [
            "port-forward", "service/api", "8082:80"
        ])
        XCTAssertFalse(portForward.contains("--kubeconfig"))
        XCTAssertFalse(portForward.contains("--context"))
        XCTAssertEqual(
            Array(KubernetesCommandBuilder.logsArguments(
                cluster: cluster,
                namespace: "payments",
                podName: "api-123"
            ).dropFirst(4).prefix(2)),
            ["logs", "pod/api-123"]
        )
    }

    func testParsesServiceDeploymentAndPodPorts() throws {
        let json = """
        {
          "items": [
            {
              "kind": "Service",
              "metadata": {"name": "web"},
              "spec": {"ports": [
                {"name": "http", "port": 80, "protocol": "TCP"},
                {"name": "dns", "port": 53, "protocol": "UDP"}
              ]}
            },
            {
              "kind": "Deployment",
              "metadata": {"name": "worker"},
              "spec": {
                "template": {
                  "spec": {
                    "containers": [
                      {"ports": [{"name": "metrics", "containerPort": 9090}]},
                      {}
                    ]
                  }
                }
              }
            },
            {
              "kind": "Pod",
              "metadata": {"name": "worker-abc"},
              "spec": {
                "containers": [
                  {"ports": [
                    {"name": "http", "containerPort": 8080, "protocol": "TCP"},
                    {"name": "dns", "containerPort": 53, "protocol": "UDP"}
                  ]}
                ]
              },
              "status": {"phase": "Running"}
            }
          ]
        }
        """

        let ports = try KubernetesClient.parsePorts(Data(json.utf8))

        XCTAssertEqual(ports.count, 3)
        XCTAssertTrue(ports.contains(KubernetesPort(
            kind: .service,
            resourceName: "web",
            portName: "http",
            remotePort: 80
        )))
        XCTAssertTrue(ports.contains(KubernetesPort(
            kind: .deployment,
            resourceName: "worker",
            portName: "metrics",
            remotePort: 9090
        )))
        XCTAssertTrue(ports.contains(KubernetesPort(
            kind: .pod,
            resourceName: "worker-abc",
            portName: "http",
            remotePort: 8080,
            podPhase: "Running"
        )))
    }

    func testPodPortForwardTargetsPodResource() {
        let cluster = KubernetesClusterProfile(
            id: UUID(),
            name: "Production",
            configSource: .localFile,
            kubeconfigPath: "/tmp/kubeconfig",
            contextName: "production"
        )
        let mapping = KubernetesPortMapping(
            id: UUID(),
            clusterID: cluster.id,
            namespace: "payments",
            resourceKind: .pod,
            resourceName: "api-123",
            portName: "http",
            remotePort: 8080,
            localHost: "127.0.0.1",
            localPort: 18080
        )

        XCTAssertTrue(
            KubernetesCommandBuilder.portForwardArguments(mapping: mapping, cluster: cluster)
                .contains("pod/api-123")
        )
    }

    func testKeepsDeploymentAndPodWithoutDeclaredPorts() throws {
        let json = """
        {
          "items": [
            {
              "kind": "Deployment",
              "metadata": {"name": "worker"},
              "spec": {"template": {"spec": {"containers": [{}]}}}
            },
            {
              "kind": "Pod",
              "metadata": {"name": "worker-abc"},
              "spec": {"containers": [{}]},
              "status": {"phase": "Running"}
            }
          ]
        }
        """

        let resources = try KubernetesClient.parsePorts(Data(json.utf8))

        XCTAssertEqual(resources.count, 2)
        XCTAssertTrue(resources.contains(KubernetesPort(
            kind: .deployment,
            resourceName: "worker",
            portName: nil,
            remotePort: nil
        )))
        XCTAssertTrue(resources.contains(KubernetesPort(
            kind: .pod,
            resourceName: "worker-abc",
            portName: nil,
            remotePort: nil,
            podPhase: "Running"
        )))
    }

    func testInfersDeploymentPortFromMatchingServiceTargetPort() throws {
        let json = """
        {
          "items": [
            {
              "kind": "Deployment",
              "metadata": {"name": "openmodels-backend"},
              "spec": {
                "template": {
                  "metadata": {"labels": {"app": "openmodels-backend"}},
                  "spec": {"containers": [{}]}
                }
              }
            },
            {
              "kind": "Service",
              "metadata": {"name": "openmodels-backend"},
              "spec": {
                "selector": {"app": "openmodels-backend"},
                "ports": [
                  {"name": "http", "port": 8080, "targetPort": 8080, "protocol": "TCP"}
                ]
              }
            }
          ]
        }
        """

        let ports = try KubernetesClient.parsePorts(Data(json.utf8))

        XCTAssertTrue(ports.contains(KubernetesPort(
            kind: .deployment,
            resourceName: "openmodels-backend",
            portName: "http",
            remotePort: 8080
        )))
        XCTAssertFalse(ports.contains(KubernetesPort(
            kind: .deployment,
            resourceName: "openmodels-backend",
            portName: nil,
            remotePort: nil
        )))
    }

    func testDoesNotInferDeploymentPortFromUnmatchedService() throws {
        let json = """
        {
          "items": [
            {
              "kind": "Deployment",
              "metadata": {"name": "worker"},
              "spec": {
                "template": {
                  "metadata": {"labels": {"app": "worker"}},
                  "spec": {"containers": [{}]}
                }
              }
            },
            {
              "kind": "Service",
              "metadata": {"name": "api"},
              "spec": {
                "selector": {"app": "api"},
                "ports": [{"port": 80, "targetPort": 8080}]
              }
            }
          ]
        }
        """

        let ports = try KubernetesClient.parsePorts(Data(json.utf8))

        XCTAssertTrue(ports.contains(KubernetesPort(
            kind: .deployment,
            resourceName: "worker",
            portName: nil,
            remotePort: nil
        )))
    }

    func testNamespacesAreSorted() throws {
        let data = Data(#"{"items":[{"metadata":{"name":"zeta"}},{"metadata":{"name":"default"}}]}"#.utf8)

        XCTAssertEqual(try KubernetesClient.parseNamespaces(data), ["default", "zeta"])
    }

    func testDeploymentSelectorIsStableAndEscapedAsKubectlSelector() throws {
        let data = Data(#"{"spec":{"selector":{"matchLabels":{"tier":"api","app":"web"}}}}"#.utf8)

        XCTAssertEqual(try KubernetesClient.parseDeploymentSelector(data), "app=web,tier=api")
    }

    func testPodsPutRunningReplicasFirst() throws {
        let data = Data(#"{"items":[{"metadata":{"name":"web-b"},"status":{"phase":"Pending"}},{"metadata":{"name":"web-c"},"status":{"phase":"Running"}},{"metadata":{"name":"web-a"},"status":{"phase":"Running"}}]}"#.utf8)

        let pods = try KubernetesClient.parsePods(data)

        XCTAssertEqual(pods.map(\.name), ["web-a", "web-c", "web-b"])
        XCTAssertEqual(pods.filter(\.isRunning).count, 2)
    }

    func testLogAndInteractiveShellArgumentsPinPodAndNamespace() {
        let cluster = KubernetesClusterProfile(
            id: UUID(),
            name: "Production",
            configSource: .localFile,
            kubeconfigPath: "/tmp/kubeconfig",
            contextName: "production"
        )

        XCTAssertEqual(
            KubernetesCommandBuilder.logsArguments(
                cluster: cluster,
                namespace: "payments",
                podName: "api-123"
            ).suffix(7),
            ["logs", "pod/api-123", "--namespace", "payments", "--follow", "--tail=500", "--timestamps=true"]
        )
        XCTAssertEqual(
            KubernetesCommandBuilder.shellArguments(
                cluster: cluster,
                namespace: "payments",
                podName: "api-123",
                shell: "/bin/bash"
            ).suffix(8),
            ["exec", "-i", "-t", "pod/api-123", "--namespace", "payments", "--", "/bin/bash"]
        )
    }

    func testKubectlEnvironmentNeverInheritsHostKubeconfig() {
        // 应用只信任应用内配置的集群，宿主 shell 的 KUBECONFIG（如 OrbStack）必须被隔离
        XCTAssertNil(KubectlRunner.kubectlEnvironment["KUBECONFIG"])
        XCTAssertTrue(KubectlRunner.kubectlEnvironment["PATH"]?.isEmpty == false)
    }

    func testTeleportEnvironmentPointsAtClusterKubeconfig() {
        let cluster = KubernetesClusterProfile(
            id: UUID(),
            name: "Teleport",
            configSource: .teleport,
            kubeconfigPath: "/tmp/PortRelay/Kubeconfigs/cluster-1.yaml",
            contextName: "portrelay-cluster-1",
            teleportProxy: "https://teleport.example.com:443/",
            teleportUsername: "alice"
        )

        let environment = KubernetesCommandBuilder.environment(for: cluster)
        XCTAssertEqual(
            environment["KUBECONFIG"],
            "/tmp/PortRelay/Kubeconfigs/cluster-1.yaml"
        )
        // tsh 的代理地址应规范化（去协议前缀和结尾斜杠）
        XCTAssertEqual(
            KubernetesCommandBuilder.baseArguments(cluster: cluster),
            ["tsh", "--proxy=teleport.example.com:443", "--user=alice", "kubectl"]
        )
    }

    func testLocalFileEnvironmentHasNoKubeconfigVariable() {
        let cluster = KubernetesClusterProfile(
            id: UUID(),
            name: "Local",
            configSource: .localFile,
            kubeconfigPath: "/tmp/kubeconfig",
            contextName: "production"
        )

        XCTAssertNil(KubernetesCommandBuilder.environment(for: cluster)["KUBECONFIG"])
        // 本地集群靠 --kubeconfig/--context 参数定位集群
        XCTAssertEqual(
            KubernetesCommandBuilder.baseArguments(cluster: cluster),
            ["kubectl", "--kubeconfig", "/tmp/kubeconfig", "--context", "production"]
        )
    }

    func testStoppedKubernetesMappingDoesNotReserveLocalPort() {
        let stopped = KubernetesPortMapping(
            id: UUID(),
            clusterID: UUID(),
            namespace: "dajiache",
            resourceKind: .deployment,
            resourceName: "dajiache-admin-fireboom",
            portName: "http-9123",
            remotePort: 9123,
            localHost: "127.0.0.1",
            localPort: 8123,
            isEnabled: false
        )

        let conflict = LocalPortAvailability.conflict(
            host: "127.0.0.1",
            port: 8123,
            sshMappings: [],
            kubernetesMappings: [stopped]
        )

        XCTAssertNil(conflict)
    }

    func testEnabledKubernetesMappingReservesLocalPort() {
        let running = KubernetesPortMapping(
            id: UUID(),
            clusterID: UUID(),
            namespace: "dajiache",
            resourceKind: .deployment,
            resourceName: "dajiache-admin-fireboom",
            portName: "http-9123",
            remotePort: 9123,
            localHost: "127.0.0.1",
            localPort: 8123,
            isEnabled: true
        )

        let conflict = LocalPortAvailability.conflict(
            host: "127.0.0.1",
            port: 8123,
            sshMappings: [],
            kubernetesMappings: [running]
        )

        XCTAssertEqual(conflict, .kubernetes("Deployment/dajiache-admin-fireboom:9123"))
    }
}
