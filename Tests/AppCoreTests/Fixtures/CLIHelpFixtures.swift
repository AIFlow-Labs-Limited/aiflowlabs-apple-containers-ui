// Generated from `container` CLI 1.5.0 (build: release, commit: d265d66). Regenerate after a CLI upgrade with:
//   container <subcommand> --help   (machine create | k8s create | build), pasted between the #""" delimiters.
// Embedded as Swift (not .txt) so the test target needs no resource declaration in Package.swift.

enum CLIHelpFixtures {
    /// `container machine create --help`
    static let machineCreate = #"""
        OVERVIEW: Create a new container machine and boot it

        USAGE: container machine create [<options>] <image>

        ARGUMENTS:
          <image>                 Container image reference (e.g., alpine:3.22)

        MANAGEMENT OPTIONS:
          -a, --arch <arch>       Set arch if image can target multiple architectures
                                  (default: arm64)
          --os <os>               Set OS if image can target multiple operating systems
                                  (default: linux)
          --platform <platform>   Platform for the image if it's multi-platform. This
                                  takes precedence over --os and --arch

        REGISTRY OPTIONS:
          --scheme <scheme>       Scheme to use when connecting to the container
                                  registry. One of (http, https) (default: https)

        PROGRESS OPTIONS:
          --progress <type>       Progress type (format: auto|none|ansi|plain|color)
                                  (default: auto)

        IMAGE FETCH OPTIONS:
          --max-concurrent-downloads <max-concurrent-downloads>
                                  Maximum number of concurrent downloads (default: 3)

        OPTIONS:
          --debug                 Enable debug output [environment: CONTAINER_DEBUG]
          -n, --name <name>       Name for the container machine
          --set-default           Set this container machine as the default
          --no-boot               Create the container machine without booting it
          --cpus <cpus>           Number of virtual CPUs
          --memory <memory>       Memory allocation (e.g., 2G, 8G). Default: half of
                                  system memory
          --home-mount <home-mount>
                                  User's home directory mount option (ro, rw, none).
                                  Default: rw
          --virtualization        Enable nested virtualization (requires Apple Silicon
                                  M3+ and macOS 15+ and kernel with CONFIG_KVM=y)
          --kernel <kernel>       Path to a custom kernel binary (e.g. vmlinux).
          --version               Show the version.
          -h, --help              Show help information.
        """#

    /// `container k8s create --help`
    static let k8sCreate = #"""
        OVERVIEW: Create and start a local Kubernetes cluster

        USAGE: k8s create [--name <name>] [--rm] [--cpus <cpus>] [--memory <memory>] [--scheme <scheme>] [--max-concurrent-downloads <max-concurrent-downloads>] [--node-image <node-image>] [--cni <cni>]

        RESOURCE OPTIONS:
          -c, --cpus <cpus>       Number of CPUs to allocate to the container
          -m, --memory <memory>   Amount of memory (1MiByte granularity), with optional
                                  K, M, G, T, or P suffix

        REGISTRY OPTIONS:
          --scheme <scheme>       Scheme to use when connecting to the container
                                  registry. One of (http, https) (default: https)

        IMAGE FETCH OPTIONS:
          --max-concurrent-downloads <max-concurrent-downloads>
                                  Maximum number of concurrent downloads (default: 3)

        OPTIONS:
          --name <name>           Cluster name (default: k8s-dev) (default: k8s-dev)
          --rm, --remove          Remove the cluster container after it stops
          --node-image <node-image>
                                  Node image reference (default:
                                  docker.io/kindest/node:v1.35.5@sha256:ce977ae6d65918d0b58a5f8b5e940429c2ce42fa3a5619ec2bbc60b949c0ac95)
                                  (default:
                                  docker.io/kindest/node:v1.35.5@sha256:ce977ae6d65918d0b58a5f8b5e940429c2ce42fa3a5619ec2bbc60b949c0ac95)
          --cni <cni>             Optional path to a CNI manifest to apply.
          --version               Show the version.
          -h, --help              Show help information.
        """#

    /// `container build --help`
    static let build = #"""
        OVERVIEW: Build an image from a Dockerfile or Containerfile

        USAGE: container build [<options>] [<context-dir>]

        ARGUMENTS:
          <context-dir>           Build directory (default: .)

        OPTIONS:
          -a, --arch <value>      Add the architecture type to the build
          --build-arg <key=val>   Set build-time variables
          -c, --cpus <cpus>       Number of CPUs to allocate to the builder container
          -f, --file <path>       Path to Dockerfile
          -l, --label <key=val>   Set a label
          -m, --memory <memory>   Amount of builder container memory (1MiByte
                                  granularity), with optional K, M, G, T, or P suffix
          --no-cache              Do not use cache
          -o, --output <value>    Output configuration for the build (format:
                                  type=<oci|tar|local>[,dest=]) (default: type=oci)
          --os <value>            Add the OS type to the build
          --platform <platform>   Add the platform to the build (format:
                                  os/arch[/variant], takes precedence over --os and
                                  --arch) [environment: CONTAINER_DEFAULT_PLATFORM]
          --progress <type>       Progress type (format: auto|plain|tty) (default: auto)
          -q, --quiet             Suppress build output
          --secret <id=key,...>   Set build-time secrets (format:
                                  id=<key>[,env=<ENV_VAR>|,src=<local/path>])
          --ssh <default>         Forward SSH agent authentication to the build
                                  (format: default)
          -t, --tag <name>        Name for the built image (default:
                                  cf8bde79-8d87-473b-82b3-a376e96774d4)
          --target <stage>        Set the target build stage
          --vsock-port <port>     Builder shim vsock port (default: 8088)
          --debug                 Enable debug output [environment: CONTAINER_DEBUG]
          --dns <ip>              DNS nameserver IP address
          --dns-domain <domain>   Default DNS domain
          --dns-option <option>   DNS options
          --dns-search <domain>   DNS search domains
          --pull                  Pull latest image
          --version               Show the version.
          -h, --help              Show help information.
        """#
}
