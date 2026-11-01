# git_cgallagher.windows.wsfc

Builds a Windows Server Failover Cluster and keeps it the way the variables
describe. It's the foundation for clustered file servers, SQL Server failover
cluster instances (FCIs) and Always On availability groups (AGs).

On **every host in the play** it installs `Failover-Clustering` and the
clustering PowerShell tools (plus any `wsfc_extra_features`). Then,
**once, on the managing node** (the first host, or `wsfc_manage_node`),
it runs the collection's `wsfc_cluster` module
(`ansible-doc git_cgallagher.windows.wsfc_cluster`), which:

1. finds the cluster through any node, and refuses a node that belongs to a
   different cluster;
2. runs `Test-Cluster` whenever nodes are about to join, then `New-Cluster`
   (always `-NoStorage`) or `Add-ClusterNode` for the nodes it's missing;
3. names cluster networks and sets their role and metric, matched by subnet;
4. sets cluster common properties (heartbeat thresholds and the like);
5. adds named shared disks, optionally formatting RAW ones first and adding
   them to Cluster Shared Volumes;
6. sets the quorum witness: none, disk, file share or Azure cloud witness.

Safety behaviour:

- nodes, disks, networks and witnesses the variables don't list are never
  removed; extra ones are reported as warnings. The one exception: a cluster
  name address on a network in `wsfc_ignore_networks` is removed (never the
  name's last address), because `New-Cluster` can add one there despite
  `-IgnoreNetwork`, and the name would register it in DNS;
- a disk is only formatted when `initialize` is set **and** it is still RAW;
- a feature install that needs a reboot fails unless
  `wsfc_allow_reboot: true`;
- `--check` reports every action without changing anything, and so does
  `wsfc_report_only: true` for the cluster (see below).

The module's result is registered as `wsfc_run` and the role prints its
`actions`, `warnings` and `validation_report` (the `Test-Cluster` report's
path on the managing node).

### Planning: `--check` and `wsfc_report_only`

The cluster task supports check mode for real: under `--check` the module
reads the cluster, lists the actions it would take (as the task's diff too,
with `--diff`) and writes nothing. On a cluster that doesn't exist yet the
plan stops after its creation, because its networks, properties, disks and
quorum can't be read before it exists, and `--check` leaves the feature
uninstalled, so on a bare node the plan is just "create the cluster".

`wsfc_report_only: true` runs only the cluster task in check mode. The
feature install (and a reboot, with `wsfc_allow_reboot`) happens for real,
and the rest of the play runs normally, so it is the way to install the
feature on new nodes and read the cluster plan in one run, or to plan the
cluster from a play you don't want to run with `--check`. Under `--check`
it makes no difference.

All variables are documented in
[meta/argument_specs.yml](meta/argument_specs.yml), which Ansible also uses to
validate them (`ansible-doc -t role git_cgallagher.windows.wsfc`).

## Variables

Only `wsfc_name` is required. The full descriptions, including each
list item's keys, are in the argument spec.

| Variable | Default | Purpose |
|---|---|---|
| `wsfc_name` | *(required)* | Cluster name (at most 15 characters) |
| `wsfc_nodes` | `[]` | Node computer names; empty = every host in the play |
| `wsfc_manage_node` | `''` | Host that creates and configures the cluster; empty = the first host |
| `wsfc_administrative_access_point` | `ActiveDirectoryAndDns` | `ActiveDirectoryAndDns`, `Dns` or `None` (creation only) |
| `wsfc_static_addresses` | `[]` | Cluster IP addresses, one per subnet; empty = DHCP (creation only) |
| `wsfc_ignore_networks` | `[]` | Networks (CIDR) `New-Cluster` mustn't use for the cluster IP |
| `wsfc_extra_features` | `[]` | More features on every node, for example `FS-FileServer`, `Multipath-IO` |
| `wsfc_allow_reboot` | `false` | Reboot a node when the feature install needs it, instead of failing |
| `wsfc_validate` | `true` | Run `Test-Cluster` before creating the cluster or adding nodes |
| `wsfc_validate_ignore` | `[]` | `Test-Cluster` categories to skip, for example `Storage` |
| `wsfc_quorum` | `{}` | `type` (`node_majority`, `disk_witness`, `file_share_witness`, `cloud_witness`) plus `disk`, `path`, or `account_name`/`access_key`/`endpoint`; empty = leave it |
| `wsfc_networks` | `[]` | `subnet` (CIDR) plus `name`, `role` (`none`, `cluster`, `cluster_and_client`), `metric` |
| `wsfc_properties` | `{}` | Cluster common properties, for example `SameSubnetThreshold` |
| `wsfc_disks` | `[]` | `name`, `unique_id`, and optionally `csv`, `initialize`, `file_system`, `allocation_unit_size`, `label`, `drive_letter` |
| `wsfc_report_only` | `false` | Run the cluster task in check mode while the feature install runs for real (`--check` implies it) |
| `wsfc_become_user` | `''` | Run the cluster task as this account (`runas`); see below |
| `wsfc_become_password` | `''` | Its password (vault it) |
| `wsfc_report_dir` | `C:\ProgramData\wsfc-iac` | `Test-Cluster` reports on the managing node |

## Credentials: the double hop

`Test-Cluster`, `New-Cluster` and `Add-ClusterNode` reach the other nodes (and
Active Directory) from the managing node. A plain WinRM logon can't pass its
credentials on, so on a multi-node cluster they fail with access denied unless
one of these holds:

- `wsfc_become_user` / `wsfc_become_password` are set: the
  cluster task runs through `runas` become with a local logon (recommended);
- the connection itself delegates (CredSSP, or Kerberos delegation).

The role sets `become` on its cluster task from `wsfc_become_user`,
so a play-level `become` doesn't reach that task. The account needs local
administrator rights on every node. With the default
`ActiveDirectoryAndDns` access point it also needs the right to create
computer objects in the nodes' OU, or Full Control over a **prestaged,
disabled** computer object named after the cluster.

## What each workload needs from this role

The role stops at the cluster. It doesn't install SQL Server, create shares,
or create availability groups. This is what each workload needs from it.

| Workload | Access point | Storage | Typical variables |
|---|---|---|---|
| Clustered file server (general use) | `ActiveDirectoryAndDns` | shared disks | `wsfc_disks` (NTFS, with a `drive_letter`), disk or file share witness; then the [`wsfc_fileserver`](../wsfc_fileserver/README.md) role for the file server, its shares, failover and validation |
| Scale-Out File Server | `ActiveDirectoryAndDns` | shared disks as CSV | `FS-FileServer`, `wsfc_disks` with `csv: true` (often ReFS) |
| SQL Server FCI | `ActiveDirectoryAndDns` | shared disks | `wsfc_disks` with `initialize: true` and 64 KB units; SQL Server setup (`InstallFailoverCluster` / `AddNode`) picks the disks by these resource names |
| SQL Server AG (domain) | `ActiveDirectoryAndDns` | none | `wsfc_validate_ignore: [Storage]`, file share or cloud witness |
| SQL Server AG (workgroup or multi-domain) | `Dns` | none | as above; every node needs a primary DNS suffix and the same local administrator account |
| SQL Server AG without a cluster name | `None` | none | as above; the cluster itself gets no network name or IP address |

For **multi-subnet** clusters (an AG across sites, or an FCI across subnets),
list one `wsfc_static_addresses` entry per subnet and consider relaxed
heartbeats, for example:

```yaml
wsfc_properties:
  CrossSubnetThreshold: 40
  CrossSubnetDelay: 1000
  SameSubnetThreshold: 20
```

`RegisterAllProvidersIP` and `HostRecordTTL` belong to the AG listener's
network name, which SQL Server creates, so this role doesn't set them.

Shared disks are matched by `UniqueId` because disk numbers differ between
nodes. Read it on the managing node:

```powershell
Get-Disk | Select-Object Number, FriendlyName, Size, PartitionStyle, UniqueId
```

## Example

```yaml
- name: Build the SQL cluster
  hosts: sqlclu01_nodes          # sql01, sql02
  gather_facts: false
  roles:
    - role: git_cgallagher.windows.wsfc
      vars:
        wsfc_name: SQLCLU01
        wsfc_static_addresses: [10.10.10.50]
        wsfc_ignore_networks: [10.10.20.0/24]
        wsfc_networks:
          - {subnet: 10.10.10.0/24, name: Client, role: cluster_and_client}
          - {subnet: 10.10.20.0/24, name: iSCSI, role: none}
        wsfc_disks:
          - {name: SQL Data, unique_id: 60003FF44DC75ADC8C3A5E1C1A0A9B01, initialize: true}
          - {name: SQL Log, unique_id: 60003FF44DC75ADC8C3A5E1C1A0A9B02, initialize: true}
          - {name: Witness, unique_id: 60003FF44DC75ADC8C3A5E1C1A0A9B03, initialize: true}
        wsfc_quorum:
          type: disk_witness
          disk: Witness
        wsfc_become_user: EXAMPLE\svc-cluster-build
        wsfc_become_password: "{{ vault_cluster_build_password }}"
```

More in [examples/cluster.yml](../../examples/cluster.yml).

## Tested, and not yet

Its own Molecule scenario,
[`molecule/default`](https://github.com/git-cgallagher/ansible-collection-windows/tree/main/roles/wsfc/molecule/default),
builds a **one-node workgroup cluster** (access point `None`) on a real
Windows Server 2022 VM: feature install, validation, `New-Cluster`, network
name, role and metric, common properties, node-majority quorum, an
idempotent re-run, a report-only plan and a drift fix. It then runs the
`wsfc_cluster` module's own integration target
(`tests/integration/targets/wsfc_cluster`), which builds and removes a
cluster of its own: check mode before each change, the change, a repeat
that changes nothing, out-of-band drift and the error messages.

The multi-node paths are covered by `wsfc_fileserver`'s scenario,
[`roles/wsfc_fileserver/molecule/default`](https://github.com/git-cgallagher/ansible-collection-windows/tree/main/roles/wsfc_fileserver/molecule/default):
three VMs on a lab network, a domain controller that serves two iSCSI disks
and two domain-joined nodes. It runs this role with the
`ActiveDirectoryAndDns` access point and a static address, `Test-Cluster`
with storage tests, both nodes in one `New-Cluster`, a management network
taken out of cluster use, two shared disks formatted on first use (one with
a drive letter), a disk witness and the double hop through `runas` become,
then an idempotent re-run.

Still not lab-tested ([issue #19](https://github.com/git-cgallagher/ansible-collection-windows/issues/19)):
adding a node to an existing cluster, the `Dns` access point, multi-subnet
clusters, Cluster Shared Volumes, file share and cloud witnesses, and a
failing `Test-Cluster`. The lab ignores `Test-Cluster`'s network tests,
because every lab VM's management NIC has the same address (QEMU user
networking). Try those in a lab of your own first.
