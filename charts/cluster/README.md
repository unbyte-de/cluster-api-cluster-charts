# cluster chart

This is a [library chart](https://helm.sh/docs/topics/library_charts/)
and implemented to be used by umbrella/parent charts
to create [Cluster API](https://cluster-api.sigs.k8s.io/) (CAPI) clusters
for their own purposes.
This chart can't be installed as itself.

Supported [providers](https://cluster-api-operator.sigs.k8s.io/01_user/01_concepts):

* Core provider: [Cluster API](https://github.com/kubernetes-sigs/cluster-api) (CAPI)
* Infrastructure providers:
  * [hetzner](https://github.com/syself/cluster-api-provider-hetzner) (CAPH)
* Control Plane providers
  * [kubeadm](https://github.com/kubernetes-sigs/cluster-api/tree/main/controlplane/kubeadm)
* Bootstrap providers:
  * [kubeadm](https://github.com/kubernetes-sigs/cluster-api/tree/main/bootstrap/kubeadm)

Providers itself are installed out-of-band (using cluster-api-operator / clusterctl / ArgoCD),
not by this chart.

## Compatibility

For the authoritative CAPH <-> CAPI <-> Kubernetes support ranges, see the
[CAPH compatibility matrix](https://syself.com/docs/caph/getting-started/introduction#compatibility-with-cluster-api-and-kubernetes-versions)
and the [Cluster API version support](https://cluster-api.sigs.k8s.io/reference/versions) page.

This chart is currently tested against:

| Cluster chart version | Core provider (CAPI) | Bootstrap provider | Control-plane provider | Infrastructure provider | Node OS image | Kubernetes (node image) | Notes |
|-----------|---------|---------|-----------|--------------|-------|-------|-------------------------|
| `0.10.x` | `v1.8.12` | kubeadm: `v1.8.12` | kubeadm: `v1.8.12` | CAPH: `v1.0.7` | Ubuntu `24.04` | `1.31.4` | [See also migration notes](#from-010x-to-0110) |
| `0.10.x` | `v1.10.10` | kubeadm: `v1.10.10` | kubeadm: `v1.10.10` | CAPH: `v1.0.12` | Ubuntu `24.04` | `1.32.13`, `1.33.12` | `1.33.12` requires a [manual RBAC fix](https://github.com/kubernetes-sigs/cluster-api/blob/6c70a17c7f343442238fc695e66884e6c84cfa01/docs/book/src/user/troubleshooting.md#kubeadm-join-fails-after-upgrading-to-kubernetes-patch-releases) [See also migration notes](#kubernetes-132-and-133-010x) |
| `0.11.0` - `0.13.0` | `v1.13.2` | kubeadm: `v1.13.2` | kubeadm: `v1.13.2` | CAPH: `v1.1.6` | Ubuntu `24.04` | `1.33.12`, `1.34.8`, `1.35.5`, `1.36.1` | Migration notes for [0.11.0](#from-010x-to-0110), [0.12.0](#from-011x-to-0120) and [0.13.0](#from-012x-to-0130). Bare-metal pools (0.13.0) were checked against CAPH `v1.1.9` |

As of `0.11.0` this chart renders the CAPI core resources at `v1beta2`
(infrastructure resources stay `v1beta1`, served by CAPH `v1.1.x`),
the middle row of the table below (v1beta2 <-> v1beta1 via shim).
Chart `0.10.x` and earlier render v1beta1 and target CAPI v1.8.x–v1.10.x with CAPH v1.0.x (top row).

| Pairing | apiVersion served | Contract (core <-> provider) | What to do with v1beta1 YAMLs | Notes |
|---------|-------------------|------------------------------|-------------------------------|-------|
| CAPI `v1.8.x - v1.10.x` and CAPH `v1.0.x`  | v1beta1 only | v1beta1 <-> v1beta1 | leave as v1beta1 |  stable, but CAPI 1.10 is now **EOL**! |
| CAPI `v1.12.x - v1.15.x` and CAPH [`v1.1.x`](https://github.com/syself/cluster-api-provider-hetzner/releases/tag/v1.1.0) | core v1beta1+v1beta2; CAPH v1beta1 | v1beta2 <-> v1beta1 (bridged by temporary shim) | Optionally migrate only CAPI resources (Cluster, KubeadmControlPlane, MachineDeployment) to v1beta2 | Works via shim |
| CAPI `>= v1.12.x` and CAPH `v1.2.x` | v1beta2 | v1beta2 <-> v1beta2 | Migrate all resources to v1beta2 | Fully aligned. This is the destination, but CAPH `v1.2.x` not released yet. |

For Kubernetes version support

* check the [CAPH compatibility matrix](https://syself.com/docs/caph/getting-started/introduction#compatibility-with-cluster-api-and-kubernetes-versions) (pay attention to compatibility notes)
* check CAPI release notes, e.g. for [v1.10.10](https://github.com/kubernetes-sigs/cluster-api/releases/tag/v1.10.10)
* check [containerd's kubernetes version support](https://containerd.io/releases/#kubernetes-support)

`cilium` or `hcloud-cloud-controller-manager` versions,installed via `ClusterResourceSet`, are independent of providers.

References:

* [CAPH compatibility matrix](https://syself.com/docs/caph/getting-started/introduction#compatibility-with-cluster-api-and-kubernetes-versions)
* [CAPI release vs contract versions](https://cluster-api.sigs.k8s.io/reference/versions#cluster-api-release-vs-contract-versions)
* [CAPI release support](https://cluster-api.sigs.k8s.io/reference/versions#cluster-api-release-support)
* [CAPI v1.10 to v1.11 migration guide](https://cluster-api.sigs.k8s.io/developer/providers/migrations/v1.10-to-v1.11)
* [CAPI removes v1beta1 apiVersion (GitHub Issue)](https://github.com/kubernetes-sigs/cluster-api/issues/11920)

## Worker pools

A cluster's worker `MachineDeployment` set is configured as **multiple pools**:
`machines.workers.pools:` + `hCloud.machines.workers.pools:`.
Each key under `pools` becomes its own
`MachineDeployment` + `HCloudMachineTemplate` + `KubeadmConfigTemplate` (+ `MachineHealthCheck`),
letting you mix machine types, images, replica counts, and autoscaler settings in the same cluster.
A pool can also run on dedicated servers, see [Bare-metal pools](#bare-metal-pools).

Each pool inherits `machines.workers.defaults` and `hCloud.machines.workers.defaults:` by default,
so you only need to specify fields that differ from the defaults.

A pool can give its nodes extra labels and taints (`nodeLabels`, `nodeTaints`).
kubeadm sets them when a node joins, so changing them replaces the pool's nodes.
Every worker also gets `node.kubernetes.io/role=worker`.

### Multi-pool example

For hetzner cloud:

```yaml
hCloud:
  machines:
    workers:
      defaults:
        type: "cpx32"
        osVersion: "2404"
        k8sVersion: "v1.31.4"
        buildTimestamp: "1744781328"
        imageName: >-
          {{- $machines := (include "machines" $) | fromYaml -}}
          cluster-api-ubuntu-{{ $machines.workers.defaults.osVersion }}-{{ $machines.workers.defaults.k8sVersion }}-{{ $machines.workers.defaults.buildTimestamp | required "ERROR: worker image buildTimestamp is required." }}
        # If autoscaler is enabled, replicas must be ignored by ArgoCD.
        # If autoscaler is enabled, replicas is in effect only until autoscaler is active, e.g. during bootstrap of the cluster.
        replicas: 3
        autoscaler:
          enabled: false
          minSize: "3"
          maxSize: "5"
        remediation:
          enabled: true
      pools:
        # general-purpose workers
        # Uses the legacy `worker:` naming for backwards compatibility.
        default: {}
        # specialized pool
        gpu:
          type: "x"
          placementGroupName: worker-gpu
          osVersion: "2404"
          k8sVersion: "v1.32.4"
          buildTimestamp: "1234567890"
          imageName: >-
            {{- $machines := (include "machines" $) | fromYaml -}}
            cluster-api-ubuntu-{{ $machines.workers.pools.gpu.osVersion }}-{{ $machines.workers.pools.gpu.k8sVersion }}-{{ $machines.workers.pools.gpu.buildTimestamp | required "ERROR: worker image buildTimestamp is required." }}
          replicas: 1
          autoscaler:
            enabled: true
            minSize: "1"
            maxSize: "2"
```

### Bare-metal pools

A pool can run on Hetzner dedicated (Robot) servers instead of hcloud servers,
using CAPH's [bare-metal support](https://syself.com/docs/caph/topics/baremetal/introduction).
Set `bareMetal.enabled: true` on the pool under `hCloud.machines.workers.pools`.
Instead of an `HCloudMachineTemplate`, the pool then renders:

- one `HetznerBareMetalHost` per entry in `bareMetal.hosts`,
  named `<pool-name>-<serverID>` and labelled `capi/worker-pool: <pool-name>`,
- a `HetznerBareMetalMachineTemplate` that claims these hosts via `hostSelector`,
  installs the OS with installimage (`bareMetal.installImage`)
  and reaches the server over SSH (`bareMetal.sshSpec`).

The `KubeadmConfigTemplate`, `MachineDeployment` and `MachineHealthCheck` work like for hcloud pools,
so bare-metal nodes get the same kubelet config and the `node.kubernetes.io/role=worker` label.
The differences:

- **Node IP** for `kubeadm.setKubeletNodeIp`: dedicated servers have no metadata service,
  so bare-metal nodes use the source IPv4 of their default route, which is the server's public IPv4.
- **Health check:** `bareMetal.healthCheck` is merged over the pool's `healthCheck`,
  because a dedicated server needs much longer to come up and to reboot (default: 1 hour to join, 5 minutes NotReady).
- **Remediation:** instead of the pool's `remediation` (HCloudRemediationTemplate),
  `bareMetal.remediation` renders a `HetznerBareMetalRemediationTemplate` that reboots an unhealthy server through the Robot API.
  Only when the reboots don't help (`retryLimit`, `cooldown`) is the Machine deleted, which reinstalls the server (`onExhaustion: Reuse`).
  With `onExhaustion: Retire` the host stays out of the pool until someone removes its `capi.syself.com/permanent-error` annotation.
- **Rollout:** `bareMetal.rollingUpdate` defaults to `maxSurge: 0, maxUnavailable: 1`.
  Without a spare server a new Machine has nowhere to go, so a rollout reinstalls the servers one by one,
  and a single-server pool has no node while that happens.
- **No autoscaler:** rendering fails if `autoscaler.enabled` is set, CAPI can't order dedicated servers.

`type`, `placementGroupName` and `imageName` are ignored for bare-metal pools.
See `hCloud.machines.workers.defaults.bareMetal` in [values.yaml](values.yaml) for all fields and defaults:
Ubuntu 24.04 from Hetzner's image share, software RAID1, and a `postInstallScript` that installs cloud-init.

Dedicated servers don't boot our hcloud node image, so the chart appends a node setup to the `postInstallScript`
(`bareMetal.nodeSetup`, on by default). It follows the image-builder v0.1.48 roles our
[hcloud images](https://github.com/unbyte-de/cluster-api-machine-images) are built with:

- **setup:** dist-upgrade and the baseline packages (auditd, chrony, conntrack, ebtables, jq, socat, …).
- **providers (hcloud):** cloud-init and its helper packages, `linux-tools-generic`,
  the CSI prerequisites (open-iscsi, nfs-common, lvm2, xfsprogs) with iscsid enabled,
  cloud-init's config and final stages ordered after containerd (the kubeadm join runs in the final stage),
  and the same cloud-init feature flag.
- **node:** kernel modules and sysctls (our kubelet runs with `protect-kernel-defaults`), no swap,
  no automatic apt runs, auditd enabled.
- **containerd:** containerd and runc from upstream releases with the same `config.toml`
  (systemd cgroups, `certs.d`, pinned pause image).
- **kubernetes:** kubelet, kubeadm and kubectl at the pool's `k8sVersion`, plus cri-tools (crictl) and kubernetes-cni,
  from pkgs.k8s.io, with the same kubelet defaults file, version file, bash completions and `profile.d` script.
- **sysprep:** apt cleaned up and all installed packages held.
- **machine-images repo:** yq.

Left out on purpose: hypervisor guest tools, etcd network tuning (control plane only),
kubeadm image pre-pull (containerd doesn't run during installimage),
image templating resets (machine-id, SSH host keys, netplan, cloud-init state) that would break an installed server,
cloud-init's timestamped output logging, the grub console settings for cloud images, and the Harbor registry mirrors (see below).

The versions are values (`nodeSetup.containerdVersion`, `nodeSetup.runcVersion`, `nodeSetup.yq`).
When you bump `k8sVersion`, align them with `config/vars/k8s-<minor>.json` in the machine-images repo.

The `HetznerCluster` also changes once a cluster has a bare-metal pool (`hCloud.robot`):

- `spec.sshKeys.robotRescueSecretRef` points to the secret with the SSH key for the rescue system (default `robot-ssh`).
  The key name in that secret must match a key in Robot (Server > Key Management).
- The `capi.syself.com/use-hrobot-provider-id-for-baremetal` annotation makes CAPH use the `hrobot://<server-id>` ProviderID.
  The CCM has to set the same format, or new bare-metal nodes never join:
  the upstream hcloud-cloud-controller-manager always does, and Syself's fork
  ([syself/hetzner-cloud-controller-manager](https://github.com/syself/hetzner-cloud-controller-manager) >= v2.0.6)
  does with `HCLOUD_USE_HROBOT_PROVIDER_ID_FOR_BAREMETAL=true`.

```yaml
hCloud:
  machines:
    workers:
      pools:
        gpu:
          replicas: 1
          # Only GPU workloads that tolerate the taint run on this pool.
          nodeLabels:
            nodepool: gpu
          nodeTaints:
          - key: nvidia.com/gpu
            value: present
            effect: NoSchedule
          bareMetal:
            enabled: true
            hosts:
            - serverID: 1234567
              rootDeviceHints:
                raid:
                  wwn:
                  - "eui.0025388a21b0a1b2"
                  - "eui.0025388a21b0a1b3"
```

Things to know:

- **Disk WWNs:** add the host without `rootDeviceHints` first.
  CAPH registers it, writes the disks to `hardwareDetails` and waits.
  Read them with `kubectl describe hetznerbaremetalhost <name>`, then add `rootDeviceHints`.
- **`replicas`** can't be higher than the number of hosts, rendering fails otherwise.
- **Taints apply to DaemonSets too:** anything that should also run on a tainted pool's nodes
  (log shippers, node exporters, CSI node plugins, …) needs a toleration.
- **Removing a host:** set its `maintenanceMode: true` and sync first, so it deprovisions and isn't claimed anymore.
  Then remove it from `hosts`.
- **Don't replace or force-sync `HetznerBareMetalHost` objects.**
  CAPH keeps the provisioning state in `spec.status`, and a replace wipes it.
- **No registry mirrors:** hcloud images route image pulls through Harbor's proxy cache (containerd `certs.d`),
  bare-metal nodes pull from the upstream registries.

## `extraCommands` run as root - treat them as trusted code

`kubeadm.postKubeadm.extraCommandsCp` and `kubeadm.postKubeadm.extraCommandsWorker` are
inlined into the postKubeadm bash that runs **as root** on every node during cluster
bootstrap. Treat them as trusted code, not data — anyone who can write either value can
execute arbitrary commands on every CP / worker node.

Two differences worth knowing before you write either value:

- `extraCommandsCp` is rendered as a Helm template first (`{{ tpl . $ }}`), so you can
  reference other values inside it (e.g. `{{ include "cluster-name" . }}`). The
  trade-off is that anything in this field is interpreted as both a Helm template and
  a bash script.
- `extraCommandsWorker` is **not** templated — its content is passed to bash verbatim.
  Helm `{{ … }}` expressions inside it will reach the node as literal text.

Both blocks run under `set -eu`, so a non-zero exit aborts the rest of postKubeadm and
the node never finishes joining the cluster. Validate snippets locally before shipping
them via GitOps.

## When does an update replace nodes?

This chart names each `HCloudMachineTemplate`, `HetznerBareMetalMachineTemplate` and `KubeadmConfigTemplate` with a hash of its **spec**.
CAPI replaces machines only when the name that a `MachineDeployment` or `KubeadmControlPlane` references changes,
i.e. only when the underlying spec changes.
Labels and other metadata are **not** part of the hash.

**Replaces nodes (rolling update):**

- Changing `k8sVersion`, `osVersion` or `buildTimestamp` or `imageName` (new node image).
- Changing the server `type` or `placementGroupName`.
- Changing the kubeadm config: kubelet args, `nodeLabels`, `nodeTaints`, `postKubeadm` commands, etc.
- For bare-metal pools: changing `k8sVersion`, `bareMetal.installImage`, `bareMetal.nodeSetup` or `bareMetal.sshSpec`.
  Replacing a bare-metal node reinstalls the server and wipes its disks.

**Does _not_ replace nodes:**

- Bumping the chart `version` alone (only the `helm.sh/chart` label changes).
- Upgrading the providers (CAPI or CAPH controllers), related to management-plane only.
- Bumping `cilium` or `hcloud-cloud-controller-manager` versions (installed via `ClusterResourceSet`, unrelated to machine specs).
- Changing `replicas`, autoscaler annotations, or `MachineHealthCheck` settings.
- For bare-metal pools: changing `bareMetal.hosts` (hosts aren't part of the template),
  `bareMetal.healthCheck`, `bareMetal.remediation` or `bareMetal.rollingUpdate`.
  Setting a host's `maintenanceMode: true` still deprovisions the machine on it.

## Migration

### From 0.12.x to 0.13.0

Adds [bare-metal pools](#bare-metal-pools), `hCloud.robot`, and pool-level `nodeLabels`/`nodeTaints`.
Clusters with only hcloud pools render exactly the same as before, so **no nodes are replaced**.
No config changes needed.

### From 0.11.x to 0.12.0

0.12.0 changes node IP discovery and adds worker pools.

#### Node IP discovery

Node IP discovery in `postKubeadmCommands` now uses the Hetzner metadata service (`169.254.169.254`) instead of `api.ipify.org`,
fixing silent empty-IP failures when ipify was unreachable.

**Replaces all nodes.** The change alters the embedded bootstrap config, so CP and worker nodes are **rolled and re-created** on upgrade.
No config changes needed; plan for a full node rollout.

#### Worker pools

Version 0.12.0 introduces the `workers.pools:` shape, which replaces the legacy `worker:` shape.
This is a breaking change, because it changes the resource names and `nodepool` labels of existing `MachineDeployment`s,
which causes **replacing** the existing nodes with new ones during the update.
To prevent this, the chart treats the **pool named `default` as un-suffixed**,
it renders with the same resource names and `nodepool` label as the legacy singular
shape. With the **default** pool the new shape itself replaces nothing
(the node IP change above still rolls all nodes).

| pool key | MachineDeployment | `nodepool` label |
|---|---|---|
| (legacy `worker:`) | `<cluster>-worker` | `<cluster>-worker` |
| `pools.default`    | `<cluster>-worker` | `<cluster>-worker` |
| `pools.gpu`        | `<cluster>-worker-gpu` | `<cluster>-worker-gpu` |

Two migration paths, all safe:

1. **Convert to a single-pool plural shape:**
  Move the config from `machines.worker:` into `machines.workers.defaults:`
  and `hCloud.machines.worker` into `hCloud.machines.workers.defaults`,
  and define `hCloud.machines.workers.pools.default: {}`.
  This change alone doesn't replace any nodes.
2. **Add more pools**:
  Do (1) first to establish `pools.default`,
  then add additional keys (e.g. `pools.gpu: { type: ccx33, ... }`).
  The `default` pool is unchanged, only the new pool's resources are created.
  See the [multi-pool example](#multi-pool-example) above for more details.

### From 0.10.x to 0.11.0

Version 0.11.0 renders the CAPI **core** resources (`Cluster`, `KubeadmControlPlane`,
`MachineDeployment`, `MachineHealthCheck`, `ClusterResourceSet`) at the **`v1beta2`**
API version (previously `v1beta1`). The infrastructure resources (`HetznerCluster`,
`HCloudMachineTemplate`, `HCloudRemediationTemplate`) are still rendered at
`infrastructure.cluster.x-k8s.io/v1beta1`, because CAPH `v1.1.x` only serves `v1beta1`.
The core `v1beta2` objects reference them by `apiGroup`, and CAPI bridges the contract
(see [Compatibility](#compatibility)).

**Provider requirements - upgrade the management plane first**

- CAPI **`v1.13.x`** (tested with `v1.13.2`) must be installed and serving `v1beta2`
  **before** the chart is upgraded, otherwise the API server rejects the new manifests.
- CAPH **`v1.1.x`** (tested with `v1.1.6`).

Upgrade the CAPI and CAPH controllers out-of-band and confirm they are healthy,
then upgrade the chart.

**Breaking `values.yaml` changes - `MachineHealthCheck`**

The `v1beta2` `MachineHealthCheck` schema reshaped the health-check fields,
so the `healthCheck` block (under `machines.cp` and under every `machines.workers` pool) changed.
Durations are now **integer seconds** instead of duration strings. If you override any of these, migrate them:

| 0.10.x (`v1beta1`) | 0.11.0 (`v1beta2`) |
|---|---|
| `healthCheck.nodeStartupTimeout: 15m0s` | `healthCheck.checks.nodeStartupTimeoutSeconds: 900` |
| `healthCheck.unhealthyConditions` | `healthCheck.checks.unhealthyNodeConditions` |
| `healthCheck.unhealthyConditions[].timeout: 5m0s` | `healthCheck.checks.unhealthyNodeConditions[].timeoutSeconds: 300` |
| `healthCheck.maxUnhealthy: 100%` | `healthCheck.remediation.triggerIf.unhealthyLessThanOrEqualTo: 100%` |

**This upgrade replaces all nodes**

`v1beta2` requires kubeadm `extraArgs`/`kubeletExtraArgs` as `name`/`value` lists instead of maps.
That changes the `KubeadmConfigTemplate` spec (and therefore its spec-hash name) and
the control-plane `kubeadmConfigSpec`,
so upgrading to 0.11.0 triggers a **rolling replacement of all control-plane and worker nodes**;
treat it like a `k8sVersion` bump and plan for a rolling update.
See [When does an update replace nodes?](#when-does-an-update-replace-nodes).

**Recommended steps**

1. Upgrade CAPI to `v1.13.x` and CAPH to `v1.1.x` (out-of-band); confirm both controllers are healthy.
2. Update your `healthCheck` overrides per the table above.
3. Render and validate against the live cluster before applying:
  ```bash
  helm template <release> charts/workload-cluster -f your-values.yaml \
    | kubectl apply --dry-run=server -f -
  ```
4. Apply / sync the **control-plane** resources first, excluding the worker
  `MachineDeployment` / `KubeadmConfigTemplate` (ArgoCD: selective sync or sync-waves;
  `kubectl`: apply `cluster.yaml` and `controlplane-nodes.yaml` only).
  Wait for the control-plane machines to roll and the cluster to report healthy.
5. Then apply / sync the **worker** changes and watch those nodes roll.

### Kubernetes 1.32 and 1.33 (0.10.x)

0.10.x supports Kubernetes 1.32 and 1.33.

`1.33.12` requires a [manual RBAC fix](https://github.com/kubernetes-sigs/cluster-api/blob/6c70a17c7f343442238fc695e66884e6c84cfa01/docs/book/src/user/troubleshooting.md#kubeadm-join-fails-after-upgrading-to-kubernetes-patch-releases) after upgrading.
