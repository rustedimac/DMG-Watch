# Security Policy

## Supported versions

Security fixes are applied to the latest release line.

| Version | Supported |
|---|---|
| 1.x | Yes |
| Earlier development builds | No |

## Reporting a vulnerability

Use GitHub private vulnerability reporting when it is enabled for the repository. Otherwise, open a minimal issue requesting a private contact channel without publishing exploit details, sensitive paths, credentials, or proprietary installation media.

Include:

- The affected version
- The relevant command-line options
- The macOS version and architecture
- A minimal reproduction using non-proprietary test fixtures
- Expected and observed behavior
- Whether administrator authorization was involved

## Threat model

The project attempts to reduce accidental installation mistakes and unsafe path handling. It mounts images read-only, avoids following package symlinks, filters destination candidates, stages app replacements, and cleans up mounts and terminal state.

It does not sandbox or make untrusted software safe. A package installed through Apple’s `installer` command can execute scripts with administrator privileges. An installed application can execute arbitrary code when launched. Signature results are logged but are not enforced as a policy gate.

Only process software obtained from sources you trust. Review `--dry-run` output and the full log before a live installation.

## Out of scope

The following are not treated as vulnerabilities in this project by themselves:

- Gatekeeper blocking an unsigned or unnotarized app
- A vendor package installing files according to its own package metadata
- A GUI installer app being skipped
- An encrypted or interactive-license disk image failing to mount
- An external app in an unconventional, non-indexed folder not being discovered
- A warning caused by multiple legitimate installed copies
