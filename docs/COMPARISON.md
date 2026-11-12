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

Two things Apple's runtime does not have are provided by the app itself, close to Docker's behaviour but not
identical (details and every difference in [COMPOSE.md](COMPOSE.md)):

| | Container Desktop | The limit |
|---|---|---|
| Restart policies (`no`, `always`, `unless-stopped`, `on-failure[:N]`) | Set in the Run sheet or with `restart:` in a compose file. A container that stops is started again with a growing delay; stacks come back when the app launches or the container system starts; stops made in the app are respected. | Enforced by Container Desktop, not by a daemon: it works **only while the app is running** (window closed is fine). A `container stop` typed in a terminal looks like a crash and is undone. The runtime reports no exit codes, so `on-failure` reacts to every unexpected stop. The policy cannot be changed after the container is created. |
| Compose health-check ordering (`depends_on` with `condition: service_healthy` / `service_completed_successfully`) | The import runs the dependency's `healthcheck` inside its container and starts the dependent service only once it passes. | Health is checked during the import run, not continuously, and no health status is shown afterwards. "Completed successfully" means "has exited": the exit code is not available. |

## Where Docker Desktop is ahead

| | State in Container Desktop |
|---|---|
| Compose | Import and run a compose file with a preview and warnings. No `compose up` engine: no `watch`, scaling, override files or re-running only what changed. See [COMPOSE.md](COMPOSE.md). |
| Supervision without the app | Docker's daemon restarts containers and tracks their health whether or not Docker Desktop's window is open, and after a `docker stop` from any terminal it knows the stop was meant. Container Desktop does both jobs itself, so they stop when the app is quit (see the table above). |
| Service names | Containers find each other by name only on the default network with a DNS domain set up. |
| Kubernetes | Local clusters through Apple's experimental cluster plugin; no dashboard for pods and deployments. |
| Extensions, Scout, Build Cloud, Dev Environments, Model Runner | Not available. |
| Intel Macs, Windows, Linux | Apple silicon and macOS 26 or later only. |
| Docker API and socket | Tools that talk to the Docker socket (Testcontainers, IDE plugins, `docker` itself) do not work with Apple's runtime. |
| Signed installer | Builds are not notarized yet; first launch needs a Gatekeeper step. |
| Maturity | Pre-1.0, on a runtime that is itself young. Verified on live 1.5.0 and 1.7.1 engines; runtime 1.6 support is read from source only. See [COMPATIBILITY.md](COMPATIBILITY.md). |

## Who should switch today

- **Yes:** you run a handful of services, databases and one-off images on an Apple silicon Mac, you want
  stronger isolation and no licence question, and your compose files are simple.
- **Not yet:** your workflow depends on the Docker socket, on containers being restarted while no desktop app is
  running, on continuous health status, or on Docker Desktop extensions.
