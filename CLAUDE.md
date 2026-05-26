# CLAUDE.md

This file provides guidance to coding agents, e.g. pi or claude code, when working with code in this repository.

## Repository purpose

Helm charts for provisioning Kubernetes clusters via [Cluster API](https://cluster-api.sigs.k8s.io/) (CAPI), targeting the Hetzner Cloud infrastructure provider with kubeadm bootstrap/control-plane. Published as OCI charts to `ghcr.io/unbyte-de/cluster-api-cluster-charts`.

## Architecture

There is one **library chart** plus several **application charts** that consume it.

- `charts/cluster/` — library chart (type: library). Defines all CAPI resource templates as named templates: `_cluster.yaml`, `_controlplane-nodes.yaml`, `_worker-nodes.yaml`, `_machine-health-checks.yaml`, `_cluster-resource-set.yaml`, `_secret.yaml`, `_helpers.tpl`. Exports defaults under `exports.data` (consumed by parent charts via `import-values: [data]`).
- `charts/management-cluster/`, `charts/workload-cluster/` — opinionated umbrella charts. Their `templates/*.yaml` files are one-liners that `include` the library's named templates.
- `charts/example-workload-cluster/` — minimal workload chart used for validation; not for production.
- `charts/helpers/{cluster-bootstrap-configs,eso-providers,eso-secrets}/` — small helper charts needed during cluster bootstrap (ConfigMaps, External Secrets Operator providers/secrets).

All application charts depend on `cluster` via `file://../cluster` with an **exact version pin** (no `~`/`^`). Bump every chart's version in lockstep in the same PR — the release workflow iterates `Chart.yaml` files and skips versions already in GHCR, so unchanged charts cost nothing.

### Worker pools shape

`machines.workers.pools.<name>` and `hCloud.machines.workers.pools.<name>` each become a `MachineDeployment` + `HCloudMachineTemplate` + `KubeadmConfigTemplate` (+ optional `MachineHealthCheck`). The pool named `default` renders with un-suffixed resource names (`<cluster>-worker`) for backwards compatibility with the pre-0.11 singular `worker:` shape. See `charts/cluster/README.md` for the migration table.

### postKubeadm `extraCommands*`

`kubeadm.postKubeadm.extraCommandsCp` and `extraCommandsWorker` are inlined into a root-level bash script on every node. `extraCommandsCp` is rendered through `tpl` first (Helm templating works); `extraCommandsWorker` is verbatim. Both run under `set -eu` — a non-zero exit aborts cluster join. Keep the emitted bash compact (one-liners preferred); user-data has a size limit.

## Where to run commands

The agent is expected to operate **inside the devcontainer** (`.devcontainer/`). The container provides `helm`, `yamlfmt`, `just`, `yq`, `jq`, `git`, `python3`, and a pre-activated venv with `pre-commit` installed (set up by `.devcontainer/post-create.sh`; `VIRTUAL_ENV` and `PATH` are wired in `devcontainer.json`).

The `justfile` recipes come in two flavours:

- **Public recipes** (`just lint`, `just lint-cluster`, `just lint-chart <path>`, `just lint-apps`, `just fmt`, `just pre-commit`) shell into the devcontainer via `devcontainer exec`. Use these from the **host**.
- **Private recipes** (`just _lint`, `just _lint-cluster`, `just _lint-chart <path>`, `just _lint-apps`, `just _fmt`, `just _pre-commit`) run directly. Use these from **inside the devcontainer** to skip the redundant `devcontainer exec` round trip.

When already inside the container (the normal case), prefer the underscored form.

## Common commands

Run `just` with no recipe to list everything.

Inside the container:

```sh
just _fmt                          # yamlfmt across the repo
just _pre-commit                   # pre-commit run --all-files
just _lint                         # library chart + every app/helper chart, matches .github/workflows/lint.yaml
just _lint-cluster                 # just the library chart
just _lint-chart workload-cluster  # one chart by its path under charts/
just _lint-chart helpers/eso-secrets
just _lint-chart workload-cluster true  # verbose: prints yamlfmt diffs on failure
```

The `config_linting.yaml` in each application/helper chart supplies the minimum values needed for `helm lint` / `helm template` to succeed.

After making changes to charts, run the appropriate lint recipe to verify before describing the change. For a targeted edit to a single chart, `just _lint-chart <chart>` is enough; for changes touching the library chart or multiple charts, run `just _lint`.

## Release flow

`.github/workflows/release.yaml` triggers on push to `main` touching any `charts/**/Chart.yaml`. It packages each chart, pushes to `ghcr.io/<owner>/<repo>/<chart>:<version>`, and creates a git tag `<chart>-<version>`. Versions already in the registry are skipped — bumping `version:` is the only release trigger.

## Conventions

- Charts use `yamlfmt` with the config in `.yamlfmt` (double-quote strings, indentless arrays, 2-space indent, document start markers).
  Templates under `charts/*/templates/` are excluded from formatting.
- Permission policy lives in `.claude/settings.json`.
  The agent is not expected to install, upgrade, push, or apply anything against a real cluster, or to mutate git history or the remote.
  Those operations are denied at the tool layer; work within the lint loop.
