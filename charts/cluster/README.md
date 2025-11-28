# cluster chart

This is a [library chart](https://helm.sh/docs/topics/library_charts/)
and implemented to be used by umbrella/parent charts
to create [Cluster API](https://cluster-api.sigs.k8s.io/) (CAPI) workload clusters
for their own purposes.
This chart can't be installed as itself.

Supported [providers](https://cluster-api-operator.sigs.k8s.io/01_user/01_concepts):

* Core provider: [Cluster API](https://github.com/kubernetes-sigs/cluster-api)
* Infrastructure providers:
  * [hetzner](https://github.com/syself/cluster-api-provider-hetzner) (CAPH)
* Control Plane providers
  * [kubeadm](https://github.com/kubernetes-sigs/cluster-api/tree/main/controlplane/kubeadm)
  * [talos](https://github.com/siderolabs/cluster-api-control-plane-provider-talos) (CACPPT)
* Bootstrap providers:
  * [kubeadm](https://github.com/kubernetes-sigs/cluster-api/tree/main/bootstrap/kubeadm)
  * [talos](https://github.com/siderolabs/cluster-api-bootstrap-provider-talos) (CABPT)

We also plan to extend this repo enable other CAPI providers such as
[Azure infrastructure provider](https://github.com/kubernetes-sigs/cluster-api-provider-azure).
Full list of providers that supported by CAPI is [here](https://cluster-api.sigs.k8s.io/reference/providers).

## kubeadm Configuration

We created the kubeadm configuration from
[syself/cluster-api-provider-hetzner](https://github.com/syself/cluster-api-provider-hetzner/) repository.
and updated for our needs. Here is quick way to see their configuration:

```sh
git clone -b main git@github.com:unbyte-de/cluster-api-provider-hetzner.git
cp cluster-api-provider-hetzner/templates/cluster-templates/hcloud/kustomization.yaml cluster-api-provider-hetzner/templates/cluster-templates/bases/kustomization.yaml
kustomize build cluster-api-provider-hetzner/templates/cluster-templates/bases/
# To get only config for worker nodes
kustomize build cluster-api-provider-hetzner/templates/cluster-templates/bases/ | yq 'select(.kind == "KubeadmConfigTemplate") | .spec'
# kubectl explain KubeadmConfigTemplate.spec
# To get only config for CP nodes
kustomize build cluster-api-provider-hetzner/templates/cluster-templates/bases/ | yq 'select(.kind == "KubeadmControlPlane") | .spec'
# kubectl explain KubeadmControlPlane.spec
```

For hardening we consulted [kube-bench](https://github.com/aquasecurity/kube-bench) and
kube-spray documentation
([here](https://github.com/kubernetes-sigs/kubespray/blob/master/docs/operations/hardening.md) and
[here](https://github.com/kubernetes-sigs/kubespray/blob/master/docs/ansible/vars.md).)

Refs:

* https://cluster-api.sigs.k8s.io/tasks/bootstrap/kubeadm-bootstrap/#kubeadmconfig-objects
* https://kubernetes.io/docs/reference/config-api/kubeadm-config.v1beta3/

### CRDs

* CAPI: https://doc.crds.dev/github.com/kubernetes-sigs/cluster-api/
  * https://github.com/kubernetes-sigs/cluster-api/blob/main/config/crd/
* CAPI Operator: https://doc.crds.dev/github.com/kubernetes-sigs/cluster-api-operator
