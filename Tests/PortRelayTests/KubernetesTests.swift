import XCTest
@testable import PortRelay

final class KubernetesTests: XCTestCase {
    func testLegacyConfigurationDefaultsKubernetesCollectionsToEmpty() throws {
        let data = Data(#"{"servers":[],"mappings":[]}"#.utf8)

        let configuration = try JSONDecoder().decode(StoredConfiguration.self, from: data)

        XCTAssertTrue(configuration.kubernetesClusters.isEmpty)
        XCTAssertTrue(configuration.kubernetesMappings.isEmpty)
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
            "--namespace", "payments",
            "port-forward", "service/api", "8082:80", "--address", "127.0.0.1"
        ])
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
            ["--namespace", "payments", "logs", "pod/api-123", "--follow", "--tail=500", "--timestamps=true"]
        )
        XCTAssertEqual(
            KubernetesCommandBuilder.shellArguments(
                cluster: cluster,
                namespace: "payments",
                podName: "api-123",
                shell: "/bin/bash"
            ).suffix(8),
            ["--namespace", "payments", "exec", "-i", "-t", "pod/api-123", "--", "/bin/bash"]
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
