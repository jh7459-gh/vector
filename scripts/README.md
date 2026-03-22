# `scripts` folder

The `scripts` folder contains various utility scripts that help to
maintain the Vector project. All of these are exposed through the `Makefile`,
and it should be rare that you have to call these directly.

Please see the [`CONTRIBUTING.md` file](/CONTRIBUTING.md) for environment
setup and usage information.

## Local E2E Harnesses

- `scripts/test-e2e-memory-seed-operations.sh`
  Runs a local end-to-end check for seeded `memory` enrichment tables with
  operation-based live updates (`http_client -> memory table -> filter`).
