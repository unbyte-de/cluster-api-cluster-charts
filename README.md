<p align="center">
  <a href="https://unbyte.de">
    <img src="https://www.unbyte.de/wp-content/uploads/2024/12/unbyte_logo.svg" alt="unbyte GmbH" width="300">
  </a>
</p>

# cluster-api-cluster-charts

Helm charts for defining, provisioning, and managing Kubernetes clusters using
[Cluster API (CAPI)](https://cluster-api.sigs.k8s.io/).

This repository contains a reusable base chart as well as opinionated application
charts used by **unbyte** to create management and workload clusters.

## Charts

| Chart Name | Type | Description |
| :--- | :--- | :--- |
| `cluster` | library | Base library chart providing shared templates and values for defining a Cluster API cluster |
| `example-workload-cluster` | application | Minimal example workload cluster used for validation, testing, and documentation |
| `mgt-cluster` | application | Opinionated chart for provisioning unbyte management clusters |
| `workload-cluster` | application | Opinionated chart for provisioning unbyte workload clusters |

## Notes
- Application charts depend on the `cluster` library chart.
- Charts are designed to work with Cluster API–compatible infrastructure providers.
- The `example-workload-cluster` chart is **not intended for production use**.
