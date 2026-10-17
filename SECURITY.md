# Security Policy

## Reporting a vulnerability

Please **do not** open a public issue for security problems. Email **security@aiflowlabs.io** with:

- a description of the issue and its impact,
- steps to reproduce (a proof of concept if you have one),
- the Container Desktop version, `container --version`, and macOS version.

You will get an acknowledgement within 3 business days. We will keep you informed while we work on a fix and
credit you in the release notes unless you prefer otherwise.

## Scope

In scope: the Container Desktop app, its build and release scripts, and the published DMG/Homebrew cask.

Out of scope: vulnerabilities in Apple's `container` runtime or Containerization framework — report those to
Apple via [github.com/apple/container](https://github.com/apple/container/security).

## Supported versions

Until 1.0, only the latest release receives security fixes.

## Design notes relevant to security

- The app is not sandboxed: it executes `/usr/local/bin/container` and talks to its launchd services. It never
  executes other binaries on your behalf, and the UI never builds shell strings from user input.
- Administrator actions (e.g. `container system dns create`) go through the standard macOS authorization prompt.
- Registry passwords are passed to the CLI via stdin only, never as arguments, logs, or files.
