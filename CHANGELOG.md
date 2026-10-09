# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-10-08

### Added

- Recursive discovery of `.dmg` and `.iso` files in a configurable watch folder.
- Read-only, no-Finder disk-image mounting with nested-image recursion.
- Drag-and-drop application installation with Spotlight and fallback destination discovery.
- Preservation of existing application locations, including conventional application folders on external volumes.
- Root-level `.pkg` and `.mpkg` installation with package-payload target-volume inference.
- Deliberate reporting and exclusion of packages stored in ordinary subfolders.
- Transactional app replacement with staging, backup, verification, and rollback.
- Fixed-screen alternate-buffer TUI with progress, recent activity, counters, and persistent completion screen.
- Plain-output, no-color, dry-run, and no-wait modes.
- Signal-safe cleanup for mounted images and terminal state.
- Environment configuration for watch folder, default app directory, recursion depth, and log path.
- macOS platform and standard-tool preflight checks.
- Host-neutral configuration for newly installed app destinations and log files.
- GitHub Actions validation and a local validation script.

### Security

- Reject malformed `.app` directories without `Contents/Info.plist`.
- Reject symbolic-link `Info.plist` files inside source app bundles.
- Reject symbolic-link packages and symbolic-link app destinations.
- Prevent interactive disk-image prompts by mounting with standard input closed.
- Avoid descending into application and package bundles while searching for nested payloads.
- Detach an attached disk device even when an image exposes no mountable volume.
- Use BSD/macOS-compatible `find` expressions throughout the runtime path.
- Neutralize control characters before rendering discovered names in the terminal UI or structured log messages.
