# Container Desktop and Docker Desktop

An honest map of where Container Desktop (v0.2, on Apple's `container` runtime) stands next to Docker Desktop on
a Mac. It is written for someone deciding whether to switch, so it lists what is missing as plainly as what is
there. Docker Desktop is a mature product with a much larger feature set; this page only covers the daily
container workflow on Apple silicon.

Not affiliated with or endorsed by Apple Inc. or Docker, Inc.

## Where Container Desktop is ahead

| | Container Desktop | Docker Desktop |
|---|---|---|
| Licence and cost | MIT, free for any company size | Paid subscription required for larger companies |
| Account | None, no sign-in | A Docker account for some features |
| Isolation | Every container runs in its own lightweight virtual machine (Apple's runtime) | Containers share one Linux virtual machine |
| Background footprint | No always-on daemon or shared VM; a container's VM exists only while it runs | A Linux VM runs while Docker Desktop is open |
| App | Native SwiftUI, a few megabytes | Electron-based |
| Telemetry | None. The only network call the app makes itself is the optional daily update check to github.com | Usage statistics, can be turned off |
| Before you run | Compose import and the Run sheet show the exact commands that will run, copyable | — |
| Linux machines | Persistent Linux machines (`container machine`) with a shell, next to containers | Not a feature |

## On par for daily work

Containers list with start, stop, restart, kill and delete, singly or in bulk; logs with follow and search;
inspect; an embedded terminal; live CPU, memory, network and disk charts; a **Files** tab (browse, download,
upload, preview, delete); images with pull, push, tag, save, load and build; volumes; networks; registry logins;
disk usage and clean-up; a menu bar item; light and dark mode; update notifications.

## Where Docker Desktop is ahead

| | State in Container Desktop |
|---|---|
| Compose | Import and run a compose file with a preview and warnings. No `compose up` engine: no restart policies, health-check ordering, `watch`, scaling or override files. See [COMPOSE.md](COMPOSE.md). |
| Restart policies | Apple's runtime has none, so a container stays stopped after a crash or a reboot. |
| Service names | Containers find each other by name only on the default network with a DNS domain set up. |
| Kubernetes | Local clusters through Apple's experimental cluster plugin; no dashboard for pods and deployments. |
| Extensions, Scout, Build Cloud, Dev Environments, Model Runner | Not available. |
| Intel Macs, Windows, Linux | Apple silicon and macOS 26 or later only. |
| Docker API and socket | Tools that talk to the Docker socket (Testcontainers, IDE plugins, `docker` itself) do not work with Apple's runtime. |
| Signed installer | Builds are not notarized yet; first launch needs a Gatekeeper step. |
| Maturity | Pre-1.0, on a runtime that is itself young. Support for runtime 1.6 and 1.7 is not yet verified on a live engine; see [COMPATIBILITY.md](COMPATIBILITY.md). |

## Who should switch today

- **Yes:** you run a handful of services, databases and one-off images on an Apple silicon Mac, you want
  stronger isolation and no licence question, and your compose files are simple.
- **Not yet:** your workflow depends on the Docker socket, on compose features such as health-check ordering and
  restart policies, or on Docker Desktop extensions.
