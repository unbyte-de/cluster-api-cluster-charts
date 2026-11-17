{{/*
Expand the name of the chart.
*/}}
{{- define "cluster.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "cluster.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "cluster.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "cluster.labels" -}}
helm.sh/chart: {{ include "cluster.chart" . }}
{{ include "cluster.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "cluster.selectorLabels" -}}
app.kubernetes.io/name: {{ include "cluster.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
validate runs preflight checks on .Values. Called from the top of
`cluster.cluster` so the whole render fails at the first invalid config,
instead of relying on top-level {{ fail }} blocks scattered through this
helper file (which made the trigger point opaque and ran the hetzner-only
LB check even when a different infrastructure provider was selected).
*/}}
{{- define "cluster.validate" -}}
{{- if ne .Values.capi.providers.core.name "cluster-api" -}}
{{- fail "Please set which CAPI core provider to use. Supported providers: 'cluster-api'." -}}
{{- end -}}
{{- if ne .Values.capi.providers.controlPlane.name "kubeadm" -}}
{{- fail "Please set which CAPI controlPlane provider to use. Supported providers: 'kubeadm'." -}}
{{- end -}}
{{- if ne .Values.capi.providers.bootstrap.name "kubeadm" -}}
{{- fail "Please set which CAPI bootstrap provider to use. Supported providers: 'kubeadm'." -}}
{{- end -}}
{{- if eq .Values.capi.providers.infrastructure.name "hetzner" -}}
  {{- if not (or .Values.hCloud.lb.existing.ip .Values.hCloud.lb.new) -}}
  {{- fail "Please use an existing LB via '.Values.hCloud.lb.existing' or add configuration for a new one via '.Values.hCloud.lb.new'." -}}
  {{- end -}}
{{- else -}}
{{- fail "Please set which CAPI infrastructure provider to use. Supported providers: 'hetzner'." -}}
{{- end -}}
{{- end }}

{{/*
fetchNodeIp emits a one-line bash assignment that sets NODEIP to the node's
public IPv4 from the Hetzner Cloud metadata service, with bounded retry and a
hard per-request timeout. Replaces the previous unbounded curl to api.ipify.org,
which masked failures via `tr` and silently wrote empty values into kubelet/etcd
flags when ipify was unreachable.
The IP 169.254.169.254 is the link-local address for the Hetzner Cloud Metadata Service.
It allows instances to securely access their own configuration, user data, and
network details from within the server itself without routing through the public internet.
Stays single-line because this is emitted into postKubeadmCommands.sh, which
ships via cloud-init user-data and has a size budget.
*/}}
{{- define "cluster.fetchNodeIp" -}}
NODEIP=$(curl -fsS --max-time 5 --retry 3 --retry-delay 2 http://169.254.169.254/hetzner/v1/metadata/public-ipv4)
{{- end }}

{{/*
fetchNodeIpFromDefaultRoute is fetchNodeIp for dedicated (Robot) servers, which have no metadata service.
It sets NODEIP to the source IPv4 of the default route, which on a dedicated server is its public IPv4
(on the NIC itself, no NAT). `ip route get` only looks up the route, it doesn't send anything to 1.1.1.1.
Fails instead of continuing with an empty IP. Stays single-line for the same reason as fetchNodeIp.
*/}}
{{- define "cluster.fetchNodeIpFromDefaultRoute" -}}
NODEIP=$(ip -4 route get 1.1.1.1 | sed -n 's/.* src \([0-9.]*\).*/\1/p'); [ -n "$NODEIP" ] || { echo "ERROR: no IPv4 source address on the default route" >&2; exit 1; }
{{- end }}

{{/*
Merge hCloud.networking with networking. hCloud.networking overwrites.
*/}}
{{- define "networking" -}}
  {{- if eq .Values.capi.providers.infrastructure.name "hetzner" }}
  {{- mustMergeOverwrite (deepCopy .Values.networking) .Values.hCloud.networking | toYaml }}
  {{- end }}
{{- end }}

{{/*
Merge hCloud.machines with machines. hCloud.machines overwrites.
*/}}
{{- define "machines" -}}
  {{- if eq .Values.capi.providers.infrastructure.name "hetzner" }}
  {{- mustMergeOverwrite (deepCopy .Values.machines) .Values.hCloud.machines | toYaml }}
  {{- end }}
{{- end }}

{{- define "cluster-name" -}}
{{- .Values.cluster.name | default .Release.Name }}
{{- end }}

{{- define "lb-existing-name" -}}
{{- .Values.hCloud.lb.existing.name | default .Release.Name }}
{{- end }}

{{- define "cp-name" -}}
{{- printf "%s-cp" (include "cluster-name" .) }}
{{- end }}

{{/*
worker-name renders the base name shared by a pool's MachineDeployment,
HCloudMachineTemplate, KubeadmConfigTemplate, MachineHealthCheck, and the
`nodepool` label.
The pool named "default" is intentionally un-suffixed so it
matches the legacy single-pool name `<cluster>-worker`. This is what makes
migrating `machines.worker` → `machines.workers.pools.default` a no-op.

Accepts a {root, poolName, poolSpec} dict (per-pool helper call sites).
NOTE: poolSpec is not used by this helper.
*/}}
{{- define "worker-pool-name" -}}
{{- if eq .poolName "default" -}}
{{- printf "%s-worker" (include "cluster-name" .root) -}}
{{- else -}}
{{- printf "%s-worker-%s" (include "cluster-name" .root) .poolName -}}
{{- end -}}
{{- end }}

{{- define "cp-hcloud-machine-template-spec" -}}
{{- $machines := (include "machines" .) | fromYaml -}}
{{- /*
PublicNetwork specifies information for public networks. It defines the specs about the primary IP address of the server.
If both IPv4 and IPv6 are disabled, then the private network has to be enabled.
*/ -}}
publicNetwork:
  enableIPv4: true
  enableIPv6: false
imageName: {{ tpl ($machines.cp.imageName | required "ERROR: CP imageName is required.") . }}
placementGroupName: {{ $machines.cp.placementGroupName }}
type: {{ $machines.cp.type | required "ERROR: CP type is required." }}
{{- end }}
{{- define "cp-hcloud-machine-template-name" -}}
{{- printf "%s-%s" (include "cp-name" .) ((include "cp-hcloud-machine-template-spec" .) | sha256sum | trunc 16) }}
{{- end }}
{{- define "cp-hcloud-machine-template-labels" -}}
{{- $machines := (include "machines" .) | fromYaml -}}
{{- with $machines.cp.osVersion -}}
capi/osVersion: {{ . | quote }}
{{- end }}
capi/k8sVersion: {{ $machines.cp.k8sVersion | required "ERROR: CP k8sVersion is required" | quote }}
capi/imageName: {{ tpl ($machines.cp.imageName | required "ERROR: CP imageName is required.") . | quote }}
{{- end }}

{{/*
cluster.workerPools returns a YAML map `{ <pool-name>: <merged-pool-spec> }`
that callers iterate over to render per-pool MachineDeployment, templates and MHC resources.
It accepts machines.workers.{defaults,pools} + hCloud.machines.workers.{defaults,pools}.
*/}}
{{- define "cluster.workerPools" -}}
{{- /* First get machine defaults and pools */}}
{{- $defaults := (.Values.machines.workers.defaults | default dict) -}}
{{- $pools := (.Values.machines.workers.pools | default dict) -}}
{{- /* Prepare merged output */}}
{{- $out := dict -}}
{{- /* Get hetzner cloud defaults and pools, and merge. */}}
{{- if eq .Values.capi.providers.infrastructure.name "hetzner" -}}
{{- $hcDefaults := (.Values.hCloud.machines.workers.defaults | default dict) -}}
{{- $hcPools := (.Values.hCloud.machines.workers.pools | default dict) -}}
{{- $mergedDefaults := mustMergeOverwrite (deepCopy $defaults) $hcDefaults -}}
{{- $allKeys := keys $pools | concat (keys $hcPools) | uniq -}}
{{- range $k := $allKeys -}}
  {{- $p := (index $pools $k) | default dict -}}
  {{- $hcp := (index $hcPools $k) | default dict -}}
  {{- $poolMerged := mustMergeOverwrite (deepCopy $mergedDefaults) $p $hcp -}}
  {{- $_ := set $out $k $poolMerged -}}
{{- end -}}
{{- /* Validate worker pool names length */}}
{{- $cluster := include "cluster-name" . -}}
{{- range $k, $_ := $out -}}
  {{- $base := "" -}}
  {{- if eq $k "default" -}}
    {{- $base = printf "%s-worker" $cluster -}}
  {{- else -}}
    {{- $base = printf "%s-worker-%s" $cluster $k -}}
  {{- end -}}
  {{- if gt (int (add (len $base) 17)) 63 -}}
    {{- fail (printf "worker pool %q produces resource name %q which exceeds 63 chars once the 17-char spec-hash suffix is appended; shorten the cluster name or pool name" $k $base) -}}
  {{- end -}}
{{- end -}}
{{- /* Validate bare-metal pools */}}
{{- range $k, $p := $out -}}
  {{- if dig "bareMetal" "enabled" false $p -}}
    {{- if dig "autoscaler" "enabled" false $p -}}
      {{- fail (printf "worker pool %q is a bare-metal pool, which can't be autoscaled (CAPI can't order servers); set autoscaler.enabled to false" $k) -}}
    {{- end -}}
    {{- $hosts := dig "bareMetal" "hosts" (list) $p -}}
    {{- if gt (int $p.replicas) (len $hosts) -}}
      {{- fail (printf "worker pool %q has replicas %d but only %d bare-metal hosts; add hosts or lower replicas" $k (int $p.replicas) (len $hosts)) -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- end -}}
{{- $out | toYaml -}}
{{- end }}

{{/*
cluster.hasBareMetalPools returns "true" if at least one worker pool is a bare-metal pool, "false" otherwise.
*/}}
{{- define "cluster.hasBareMetalPools" -}}
{{- $found := false -}}
{{- range $_, $p := (include "cluster.workerPools" .) | fromYaml -}}
  {{- if dig "bareMetal" "enabled" false $p -}}
    {{- $found = true -}}
  {{- end -}}
{{- end -}}
{{- $found -}}
{{- end }}

{{/*
worker-hcloud-machine-template-spec renders the HCloudMachineTemplate.spec.template.spec
for a single pool. Accepts a {root, poolName, poolSpec} dict where:
  - .root is the chart root context (for `tpl` and required-key errors)
  - .poolName is the pool key (used only in error messages)
  - .poolSpec is the merged pool spec from `cluster.workerPools`
*/}}
{{- define "worker-hcloud-machine-template-spec" -}}
publicNetwork:
  enableIPv4: true
  enableIPv6: false
imageName: {{ tpl (.poolSpec.imageName | required (printf "ERROR: worker pool %q imageName is required." .poolName)) .root }}
placementGroupName: {{ .poolSpec.placementGroupName }}
type: {{ .poolSpec.type | required (printf "ERROR: worker pool %q type is required." .poolName) }}
{{- end }}
{{/*
Accepts a {root, poolName, poolSpec} dict (per-pool helper call sites).
*/}}
{{- define "worker-hcloud-machine-template-name" -}}
{{- printf "%s-%s" (include "worker-pool-name" .) ((include "worker-hcloud-machine-template-spec" .) | sha256sum | trunc 16) }}
{{- end }}
{{/*
Accepts a {root, poolName, poolSpec} dict (per-pool helper call sites).
*/}}
{{- define "worker-hcloud-machine-template-labels" -}}
{{- with .poolSpec.osVersion -}}
capi/osVersion: {{ . | quote }}
{{- end }}
capi/k8sVersion: {{ .poolSpec.k8sVersion | required (printf "ERROR: worker pool %q k8sVersion is required" .poolName) | quote }}
capi/imageName: {{ tpl (.poolSpec.imageName | required (printf "ERROR: worker pool %q imageName is required." .poolName)) .root | quote }}
{{- end }}

{{/*
worker-bare-metal-host-selector-labels renders the label that ties a bare-metal pool's
HetznerBareMetalHosts to the hostSelector of its HetznerBareMetalMachineTemplate.
Accepts a {root, poolName, poolSpec} dict (per-pool helper call sites).
NOTE: poolSpec is not used by this helper.
*/}}
{{- define "worker-bare-metal-host-selector-labels" -}}
capi/worker-pool: {{ include "worker-pool-name" . }}
{{- end }}
{{/*
worker-bare-metal-machine-template-spec renders the HetznerBareMetalMachineTemplate.spec.template.spec
for a single bare-metal pool. Accepts a {root, poolName, poolSpec} dict (per-pool helper call sites).
*/}}
{{- define "worker-bare-metal-machine-template-spec" -}}
{{- $bareMetal := .poolSpec.bareMetal -}}
{{- $installImage := deepCopy ($bareMetal.installImage | required (printf "ERROR: bare-metal worker pool %q installImage is required." .poolName)) -}}
{{- if dig "nodeSetup" "enabled" false $bareMetal -}}
{{- $_ := set $installImage "postInstallScript" (printf "%s\n%s" ($installImage.postInstallScript | default "#!/bin/bash" | trimSuffix "\n") (include "worker-bare-metal-node-setup" .)) -}}
{{- end -}}
hostSelector:
  matchLabels:
    {{- include "worker-bare-metal-host-selector-labels" . | nindent 4 }}
installImage: {{- toYaml $installImage | nindent 2 }}
sshSpec: {{- toYaml ($bareMetal.sshSpec | required (printf "ERROR: bare-metal worker pool %q sshSpec is required." .poolName)) | nindent 2 }}
{{- end }}
{{/*
worker-bare-metal-node-setup renders the bash that `bareMetal.nodeSetup` appends to the installimage
post-install script. It gives a dedicated server what our hcloud images get from image-builder v0.1.48
(roles setup, node, providers/hcloud, containerd, kubernetes and sysprep)
and from https://github.com/unbyte-de/cluster-api-machine-images (yq).
Left out on purpose:
- hypervisor guest tools (open-vm-tools, linux-*-tools-virtual, linux-cloud-tools-generic, hv-kvp-daemon),
- etcd network tuning (only control-plane nodes run etcd),
- kubeadm image pre-pull (containerd doesn't run during installimage),
- image templating resets (machine-id, SSH host keys, netplan, cloud-init state), which would break an installed server,
- cloud-init's timestamped output logging and the grub console settings for cloud images,
- the Harbor proxy-cache config in containerd's certs.d, because it needs registry credentials.
It runs inside the freshly installed system (chroot), so it only installs packages and writes config.
Kernel modules and sysctls take effect on the first boot, before kubelet starts.
Accepts a {root, poolName, poolSpec} dict (per-pool helper call sites).
*/}}
{{- define "worker-bare-metal-node-setup" -}}
{{- $nodeSetup := .poolSpec.bareMetal.nodeSetup -}}
{{- $k8sVersion := .poolSpec.k8sVersion | required (printf "ERROR: worker pool %q k8sVersion is required" .poolName) | trimPrefix "v" -}}
{{- $k8sParts := splitList "." $k8sVersion -}}
{{- if not (semverCompare ">=2.0.0" $nodeSetup.containerdVersion) -}}
{{- fail (printf "ERROR: worker pool %q: bareMetal.nodeSetup.containerdVersion must be >= 2.0.0" .poolName) -}}
{{- end -}}
# Node setup, rendered by the cluster chart (bareMetal.nodeSetup).
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
K8S_VERSION="v{{ $k8sVersion }}"
K8S_SERIES="v{{ index $k8sParts 0 }}.{{ index $k8sParts 1 }}"
K8S_DEB_VERSION="{{ $k8sVersion }}-{{ $nodeSetup.kubernetesDebRevision }}"
CONTAINERD_VERSION="{{ $nodeSetup.containerdVersion }}"
RUNC_VERSION="{{ $nodeSetup.runcVersion }}"
YQ_VERSION="{{ $nodeSetup.yq.version }}"
YQ_SHA256="{{ $nodeSetup.yq.sha256 }}"
# setup: dist-upgrade and baseline packages.
apt-get update
apt-get dist-upgrade -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold
apt-get install -y auditd apt-transport-https ca-certificates conntrack chrony curl ebtables jq gnupg \
  libnetfilter-acct1 libnetfilter-cttimeout1 libnetfilter-log1 python3-netifaces python3-pip socat
# providers (hcloud): cloud-init, tools and CSI prerequisites.
apt-get install -y cloud-init cloud-guest-utils cloud-initramfs-copymods cloud-initramfs-dyn-netconf linux-tools-generic \
  nfs-common open-iscsi lvm2 xfsprogs
systemctl enable iscsid.service
systemctl enable cloud-init-local.service cloud-init.service cloud-config.service cloud-final.service
# cloud-init runs the kubeadm join in its final stage, so its config and final stages wait for containerd.
for unit in cloud-config cloud-final; do
  mkdir -p "/etc/systemd/system/${unit}.service.d"
  printf '[Unit]\nAfter=containerd.service\nWants=containerd.service\n' > "/etc/systemd/system/${unit}.service.d/boot-order.conf"
done
echo "ERROR_ON_USER_DATA_FAILURE = False" > /usr/lib/python3/dist-packages/cloudinit/feature_overrides.py
# node: no automatic apt runs, kernel modules, sysctls, no swap, auditd.
systemctl mask apt-daily.timer apt-daily-upgrade.timer apt-daily.service apt-daily-upgrade.service unattended-upgrades.service
# kubelet runs with protect-kernel-defaults and doesn't start without the vm.* and kernel.* values.
cat > /etc/modules-load.d/kubernetes.conf <<'EOF'
overlay
br_netfilter
EOF
cat > /etc/sysctl.d/99-kubernetes.conf <<'EOF'
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv4.tcp_congestion_control = bbr
net.ipv4.conf.all.rp_filter = 1
vm.overcommit_memory = 1
vm.panic_on_oom = 0
kernel.panic = 10
kernel.panic_on_oops = 1
kernel.keys.root_maxkeys = 1000000
kernel.keys.root_maxbytes = 25000000
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 524288
EOF
sed -ri '/\sswap\s/s/^#?/#/' /etc/fstab
systemctl enable auditd.service
# containerd: containerd and runc from upstream releases.
cd /tmp
curl -fsSLO "https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz"
curl -fsSLO "https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz.sha256sum"
sha256sum -c "containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz.sha256sum"
tar -C /usr/local -xzf "containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz"
curl -fsSL -o /etc/systemd/system/containerd.service "https://raw.githubusercontent.com/containerd/containerd/v${CONTAINERD_VERSION}/containerd.service"
curl -fsSLO "https://github.com/opencontainers/runc/releases/download/v${RUNC_VERSION}/runc.amd64"
curl -fsSLO "https://github.com/opencontainers/runc/releases/download/v${RUNC_VERSION}/runc.sha256sum"
grep ' runc.amd64$' runc.sha256sum | sha256sum -c -
install -m 0755 runc.amd64 /usr/local/sbin/runc
mkdir -p /etc/containerd/certs.d /etc/containerd/conf.d /etc/systemd/system/containerd.service.d
cat > /etc/containerd/config.toml <<'EOF'
version = 3
imports = ["/etc/containerd/conf.d/*.toml"]
[plugins]
  [plugins.'io.containerd.cri.v1.images'.pinned_images]
    sandbox = "{{ $nodeSetup.pauseImage }}"
  [plugins.'io.containerd.cri.v1.images'.registry]
    config_path = '/etc/containerd/certs.d'
  [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc]
    runtime_type = 'io.containerd.runc.v2'
  [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc.options]
    SystemdCgroup = true
EOF
cat > /etc/systemd/system/containerd.service.d/memory-pressure.conf <<'EOF'
[Service]
OOMScoreAdjust=-999
EOF
cat > /etc/systemd/system/containerd.service.d/max-tasks.conf <<'EOF'
[Service]
TasksMax=infinity
EOF
echo "runtime-endpoint: unix:///var/run/containerd/containerd.sock" > /etc/crictl.yaml
ln -sf /usr/local/bin/ctr /usr/bin/ctr
systemctl enable containerd.service
# kubernetes: kubelet, kubeadm, kubectl, cri-tools (crictl) and kubernetes-cni from pkgs.k8s.io.
mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_SERIES}/deb/Release.key" | gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_SERIES}/deb/ /" > /etc/apt/sources.list.d/kubernetes.list
apt-get update
apt-get install -y "kubelet=${K8S_DEB_VERSION}" "kubeadm=${K8S_DEB_VERSION}" "kubectl=${K8S_DEB_VERSION}" cri-tools kubernetes-cni
apt-mark hold kubelet kubeadm kubectl
systemctl enable kubelet.service
echo "KUBELET_EXTRA_ARGS=" > /etc/default/kubelet
printf '%s' "${K8S_VERSION}" > /etc/kubernetes-version
mkdir -p /usr/share/bash-completion/completions
for cmd in kubectl kubeadm crictl; do
  "${cmd}" completion bash > "/usr/share/bash-completion/completions/${cmd}"
done
cat > /etc/profile.d/kubernetes.sh <<'EOF'
# shellcheck shell=sh disable=SC2166,SC2157,SC3044
# Check for interactive bash
if [ "x${BASH_VERSION-}" != x -a "x${PS1-}" ]; then
  ADMIN_CONF=/etc/kubernetes/admin.conf
  SUPER_ADMIN_CONF=/etc/kubernetes/super-admin.conf
  if [ -r "${SUPER_ADMIN_CONF}" ]; then
    export KUBECONFIG="${SUPER_ADMIN_CONF}"
  elif [ -r "${ADMIN_CONF}" ]; then
    export KUBECONFIG="${ADMIN_CONF}"
  fi
  alias k=kubectl
  __load_completion kubectl >/dev/null 2>&1 || true
  complete -F __start_kubectl k 2>/dev/null || true
fi
EOF
# cluster-api-machine-images: yq.
curl -fsSL -o /usr/bin/yq "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64"
echo "${YQ_SHA256}  /usr/bin/yq" | sha256sum -c -
chmod 0755 /usr/bin/yq
# sysprep: clean up apt and hold all installed packages, so nothing gets upgraded on the node.
apt-get autoremove -y
apt-get clean
rm -rf /var/lib/apt/lists/*
# Only installed ones: chrony replaces systemd-timesyncd, which stays known to dpkg with its config files.
dpkg-query -W -f '${db:Status-Status} ${binary:Package}\n' | awk '$1 == "installed" { print $2 }' | xargs apt-mark hold >/dev/null
{{- end }}
{{/*
Accepts a {root, poolName, poolSpec} dict (per-pool helper call sites).
*/}}
{{- define "worker-bare-metal-machine-template-name" -}}
{{- printf "%s-%s" (include "worker-pool-name" .) ((include "worker-bare-metal-machine-template-spec" .) | sha256sum | trunc 16) }}
{{- end }}
{{/*
Accepts a {root, poolName, poolSpec} dict (per-pool helper call sites).
*/}}
{{- define "worker-bare-metal-machine-template-labels" -}}
{{- with .poolSpec.osVersion -}}
capi/osVersion: {{ . | quote }}
{{- end }}
capi/k8sVersion: {{ .poolSpec.k8sVersion | required (printf "ERROR: worker pool %q k8sVersion is required" .poolName) | quote }}
{{- end }}

{{/*
worker-kubeadm-config-template-spec renders the KubeadmConfigTemplate body.
Pools differ only in their node labels and taints (`nodeLabels`, `nodeTaints`),
and bare-metal pools in how postKubeadmCommands finds the node IP.

Accepts a {root, poolName, poolSpec} dict (per-pool helper call sites).
NOTE: poolName is not used by this helper.
*/}}
{{- define "worker-kubeadm-config-template-spec" -}}
{{- $bareMetal := dig "bareMetal" "enabled" false .poolSpec -}}
{{- $nodeLabels := list "node.kubernetes.io/role=worker" -}}
{{- range $k, $v := (.poolSpec.nodeLabels | default dict) -}}
{{- $nodeLabels = append $nodeLabels (printf "%s=%v" $k $v) -}}
{{- end -}}
{{- $nodeTaints := .poolSpec.nodeTaints -}}
{{- with .root -}}
joinConfiguration:
  nodeRegistration:
    criSocket: unix:///var/run/containerd/containerd.sock
    # https://kubernetes.io/docs/reference/command-line-tools-reference/kubelet/
    # https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/
    # https://cluster-api.sigs.k8s.io/tasks/bootstrap/kubeadm-bootstrap/kubelet-config
    {{- /* v1beta2: kubeletExtraArgs is a []Arg list of {name,value} (was map[string]string). */}}
    kubeletExtraArgs:
    - name: anonymous-auth
      value: "false"
    - name: authentication-token-webhook
      value: "true"
    - name: authorization-mode
      value: Webhook
    - name: cloud-provider
      value: external
    - name: event-qps
      value: "1"
    # - name: feature-gates
    #   value: RotateKubeletServerCertificate=true
    - name: kubeconfig
      value: /etc/kubernetes/kubelet.conf
    - name: max-pods
      value: "220"
    - name: node-labels
      value: {{ join "," $nodeLabels | quote }}
    - name: protect-kernel-defaults
      value: "true"
    - name: read-only-port
      value: "0"
    - name: rotate-certificates
      value: "true"
    - name: rotate-server-certificates
      value: "true"
    - name: seccomp-default
      value: "true"
    - name: streaming-connection-idle-timeout
      value: "5m"
    - name: tls-min-version
      value: VersionTLS12
    - name: tls-cipher-suites
      value: TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305
    {{- with $nodeTaints }}
    taints: {{- toYaml . | nindent 4 }}
    {{- end }}
  {{- /*
  # https://cluster-api.sigs.k8s.io/tasks/bootstrap/kubeadm-bootstrap/kubelet-config.html?highlight=KubeletConfiguration#use-kubeadms-kubeletconfiguration-patch-target
  # kubectl explain KubeadmControlPlane.spec.kubeadmConfigSpec.joinConfiguration.patches
  # patches:
  #   directory: /etc/kubernetes/patches
  */}}
  {{- if .Values.kubeadm.kubeApiServer.disablePublicAccessClusterInfoConfigMap }}
  discovery:
    file:
      kubeConfig:
        {{- /*
        user:
          # exec:
          #   apiVersion: client.authentication.k8s.io/v1
          #   command: |
          #     cat <<EOF
          #     {
          #       "apiVersion": "client.authentication.k8s.io/v1",
          #       "kind": "ExecCredential",
          #       "spec": {},
          #       "status": {}
          #     }
          #     EOF
      */}}
      kubeConfigPath: /etc/kubernetes/discovery-kubeconfig.yaml
  {{- end }}
{{- /*
preKubeadmCommands:
- bash /etc/kubernetes/preKubeadmCommands.sh 2>&1 | tee -a /var/log/preKubeadmCommands.log
*/}}
postKubeadmCommands:
- bash /etc/kubernetes/postKubeadmCommands.sh 2>&1 | tee -a /var/log/postKubeadmCommands.log
files:
{{- /*
- path: /etc/kubernetes/preKubeadmCommands.sh
  owner: root:root
  permissions: "0700"
  content: |-
    #!/usr/bin/env bash
    set -eu
    echo "preKubeadmCommands started!"

    # {{- if .Values.kubeadm.kubeApiServer.disablePublicAccessClusterInfoConfigMap }}
    # if [ -f /etc/kubernetes/discovery-kubeconfig.yaml ]; then
    #   # cat /run/kubeadm/kubeadm-join-config.yaml
    #   yq eval '.users = null' -i /etc/kubernetes/discovery-kubeconfig.yaml
    #   yq eval '.clusters.0.name = ""' -i /etc/kubernetes/discovery-kubeconfig.yaml
    #   yq eval '.contexts = null' -i /etc/kubernetes/discovery-kubeconfig.yaml
    #   yq eval '.current-context = ""' -i /etc/kubernetes/discovery-kubeconfig.yaml
    # fi
    # {{- end }}
    echo "Done!"
*/}}
- path: /etc/kubernetes/postKubeadmCommands.sh
  owner: root:root
  permissions: "0700"
  content: |-
    #!/usr/bin/env bash
    set -eu
    echo "postKubeadmCommands started!"

    {{- if .Values.kubeadm.setKubeletNodeIp }}
    {{- if $bareMetal }}
    {{- include "cluster.fetchNodeIpFromDefaultRoute" . | nindent 4 }}
    {{- else }}
    {{- include "cluster.fetchNodeIp" . | nindent 4 }}
    {{- end }}
    echo "$NODEIP"
    sed -i "/--node-ip/d" /var/lib/kubelet/kubeadm-flags.env
    echo "KUBELET_KUBEADM_ARGS=\"--node-ip=$NODEIP $(cat /var/lib/kubelet/kubeadm-flags.env \
      | sed 's/KUBELET_KUBEADM_ARGS=\"//')" > /var/lib/kubelet/kubeadm-flags.env
    systemctl restart kubelet
    {{- end }}

    {{- with .Values.kubeadm.postKubeadm.extraCommandsWorker }}
    {{- . | nindent 10 }}
    {{- end }}
    echo "Done!"
{{- /*
{{- if not .Values.kubeadm.disableKubeProxy }}
# https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/#kubelet-config-k8s-io-v1beta1-KubeletConfiguration
- path: /etc/kubernetes/patches/kubeproxyconfiguration0+strategic.json
  owner: root:root
  permissions: "0644"
  content: |-
    {
      "apiVersion": "kubeproxy.config.k8s.io/v1alpha1",
      "kind": "KubeletConfiguration",
      "metricsBindAddress": "0.0.0.0:10249"
    }
{{- end }}
*/}}
{{- end }}
{{- end }}
{{/*
Accepts a {root, poolName, poolSpec} dict (per-pool helper call sites).
*/}}
{{- define "worker-kubeadm-config-template-name" -}}
{{- printf "%s-%s" (include "worker-pool-name" .) ((include "worker-kubeadm-config-template-spec" .) | sha256sum | trunc 16) }}
{{- end }}

{{/* Trim a version like "v1.31.4" to "v1.31" */}}
{{- define "cluster.cp.k8sVersionMajor" -}}
{{- $machines := (include "machines" .) | fromYaml -}}
{{- $v := $machines.cp.k8sVersion | splitList "." -}}
{{- printf "%s.%s" (index $v 0) (index $v 1) -}}
{{- end -}}

{{/* Check if there is any resource with strategy "ApplyOnce". Used in _cluster-resource-set.yaml */}}
{{- define "hasApplyOnce" -}}
{{- $found := false -}}
{{- range $k, $v := . -}}
  {{- if eq (default "" $v.strategy) "ApplyOnce" }}
    {{- $found = true -}}
  {{- end -}}
{{- end -}}
{{- $found -}}
{{- end -}}
{{/* Check if there is any resource with strategy "Reconcile". Used in _cluster-resource-set.yaml */}}
{{- define "hasReconcile" -}}
{{- $found := false -}}
{{- range $k, $v := . -}}
  {{- if eq (default "" $v.strategy) "Reconcile" }}
    {{- $found = true -}}
  {{- end -}}
{{- end -}}
{{- $found -}}
{{- end -}}
