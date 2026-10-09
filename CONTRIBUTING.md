# Contributing

Contributions are welcome when they preserve the project’s safety model and broad macOS portability.

## Development requirements

Runtime code must remain compatible with Apple’s bundled Bash 3.2. Do not introduce dependencies on Homebrew, Python, Node.js, GNU-only command flags, or developer tools for normal operation.

Avoid Bash features added after 3.2, including:

- Associative arrays
- `mapfile` or `readarray`
- `coproc`
- `${variable,,}` and `${variable^^}` case conversion
- `globstar`
- `&>>`
- Negative array indexes

Prefer Apple-supplied tools at their standard absolute paths. When a capability is optional, provide a safe fallback rather than making the whole script fail.

## Behavioral requirements

Changes should preserve these properties:

- `--dry-run` must not copy apps, run packages, or modify destinations.
- Images must be mounted read-only.
- Packages in subfolders must not be installed.
- GUI installer apps must not be launched as though they had a universal silent mode.
- Existing app locations must be preserved when a reliable match is found.
- App replacement must retain rollback behavior.
- Source disk images must not be removed or modified.
- Terminal state and mounted images must be cleaned up on normal exit and signals.
- No user name, host name, personal volume name, or machine-specific absolute path may be committed.

## Validation

Run:

```bash
./tests/validate.sh
```

On macOS, the validation script also performs an empty-watch-folder smoke test. It does not install applications or packages.

Before submitting a change, also test the relevant behavior manually with `--dry-run`. Live installation testing should use disposable, trusted fixtures and a non-production Mac or volume whenever possible.

## Pull requests

A focused pull request should include:

- A clear description of the behavior changed
- The safety implications
- The macOS versions and architectures tested
- Updated README or changelog text when user-visible behavior changes
- Updated validation checks where practical

Do not include proprietary software, commercial disk images, credentials, logs containing personal paths, or other copyrighted installation media in issues or pull requests.
