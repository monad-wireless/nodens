# Contributing to Nodens

Thank you for helping. This page explains how to build, test and change Nodens.

## Development setup

You need macOS 14 or later and Xcode. The package declares Swift tools 5.10;
development so far used Swift 6.4, so older toolchains are untested. Xcode
opens `Package.swift` directly as a project.

```sh
make test          # hook syntax check and dry runs, then the unit tests
make app           # build/Nodens.app, signed ad hoc
make run           # build and open it
make art           # re-render the icon set and docs/images
make clean
```

To try a build against real VPNs, install the engines
(`brew install openvpn wireguard-tools wireguard-go bash`) and run
`make install`. Be aware that a connect changes routes and DNS on your Mac.
Everything is recorded and reversible, but test where a broken network for a
few minutes costs you nothing.

## Where things go

Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) first. In short:

- **Logic that needs no system access goes in `NodensCore`, with tests.**
  Parsers, sanitizers, command builders and decision rules all live there.
- `Sources/Nodens` only runs processes, talks to sockets, and draws.
- A new VPN engine is a new `TunnelDriver` implementation plus a sanitizer in
  `NodensCore`.
- The drawing code (`NodensArt`) is shared by the app and `make art`. A design
  change is one edit there, then `make art`.

## Rules for code that runs as root

These rules exist because a mistake here runs as root on someone's Mac.

1. **No VPN protocol code.** Nodens drives proven engines; it does not
   reimplement them.
2. **Fail closed.** A configuration check rejects anything it does not fully
   understand. Prefer an allow-list over a deny-list.
3. **Validate twice.** Values that reach a root command are checked in Swift
   and again in the hook.
4. **Record and undo.** Every change the hook makes is recorded under its
   state directory, and `undo` reverses exactly that.
5. **Dry run first.** Every hook path has a dry-run case in
   `make check-hook`. Add one for any new path.
6. **Hard deadlines.** Every external process runs through `Shell.run` with a
   timeout.

## Tests

- Unit tests live in `Tests/NodensCoreTests` and run with `swift test`.
- Fixtures use documentation values only: `example.org`, `example.edu`,
  `192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24`, `2001:db8::/32`, and
  CGNAT `100.64.0.0/10` for tailnet addresses. Never paste real hostnames,
  addresses, keys or logs from your own network.
- A sanitizer change needs a test with the input that motivated it.

## Style

- Swift: the Swift API Design Guidelines, 4-space indentation, `// MARK:`
  sections in longer files.
- Shell: POSIX `sh`, no bashisms. POSIX sh has no local variables, so each
  function prefixes its variables.
- Documentation and UI text: short sentences, active voice, one term per
  concept.

## Pull requests

1. Open an issue first for anything larger than a small fix.
2. Keep a pull request to one change.
3. Run `make test` and say in the description how you verified the change
   (unit tests, dry run, or a live connect, and which VPN type).
4. Update `CHANGELOG.md` under "Unreleased".

By contributing you agree that your contribution is licensed under the
[MIT License](LICENSE).
