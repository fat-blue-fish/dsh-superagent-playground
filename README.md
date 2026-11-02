# dsh-superagent-playground
Playground for the official DeepSeek Harness dsh-superagent research prototype (2026-11-02).

## Operations

Self-hosting operations, the health-check matrix, troubleshooting, upgrades and security guidance are in [docs/OPERATIONS.md](docs/OPERATIONS.md).

Run the read-only preflight before and after a deployment change:

```sh
sh bin/preflight.sh          # human-readable table
sh bin/preflight.sh --json   # JSON array for automation
sh bin/preflight.sh --help   # usage and exit codes
sh tests/test_preflight.sh   # offline test suite
```

Exit `0` means every check passed or only warnings; exit `1` means at least one check failed.
