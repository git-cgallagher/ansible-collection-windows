# git_cgallagher.windows.wsfc_cluster

Builds a Windows Server Failover Cluster and keeps it the way the variables
describe. It's the foundation for clustered file servers, SQL Server failover
cluster instances (FCIs) and Always On availability groups (AGs).

On **every host in the play** it installs `Failover-Clustering` and the
clustering PowerShell tools (plus any `wsfc_cluster_extra_features`). Then,
**once, on the managing node** (the first host, or `wsfc_cluster_manage_node`),
it:

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
  removed; extra ones are reported as warnings;
- a disk is only formatted when `initialize` is set **and** it is still RAW;
- a feature install that needs a reboot fails unless
  `wsfc_cluster_allow_reboot: true`;
- `wsfc_cluster_report_only: true` (or `--check`) reports every action
  without changing the cluster.

All variables are documented in
[meta/argument_specs.yml](meta/argument_specs.yml), which Ansible also uses to
validate them (`ansible-doc -t role git_cgallagher.windows.wsfc_cluster`).

## Credentials: the double hop

`Test-Cluster`, `New-Cluster` and `Add-ClusterNode` reach the other nodes (and
Active Directory) from the managing node. A plain WinRM logon can't pass its
credentials on, so on a multi-node cluster they fail with access denied unless
one of these holds:

- `wsfc_cluster_become_user` / `wsfc_cluster_become_password` are set: the
  cluster task runs through `runas` become with a local logon (recommended);
- the connection itself delegates (CredSSP, or Kerberos delegation).

The role sets `become` on its cluster task from `wsfc_cluster_become_user`,
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
| Clustered file server (general use) | `ActiveDirectoryAndDns` | shared disks | `wsfc_cluster_extra_features: [FS-FileServer]`, `wsfc_cluster_disks` (NTFS), disk or file share witness |
| Scale-Out File Server | `ActiveDirectoryAndDns` | shared disks as CSV | `FS-FileServer`, `wsfc_cluster_disks` with `csv: true` (often ReFS) |
| SQL Server FCI | `ActiveDirectoryAndDns` | shared disks | `wsfc_cluster_disks` with `initialize: true` and 64 KB units; SQL Server setup (`InstallFailoverCluster` / `AddNode`) picks the disks by these resource names |
| SQL Server AG (domain) | `ActiveDirectoryAndDns` | none | `wsfc_cluster_validate_ignore: [Storage]`, file share or cloud witness |
| SQL Server AG (workgroup or multi-domain) | `Dns` | none | as above; every node needs a primary DNS suffix and the same local administrator account |
| SQL Server AG without a cluster name | `None` | none | as above; the cluster itself gets no network name or IP address |

For **multi-subnet** clusters (an AG across sites, or an FCI across subnets),
list one `wsfc_cluster_static_addresses` entry per subnet and consider relaxed
heartbeats, for example:

```yaml
wsfc_cluster_properties:
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
    - role: git_cgallagher.windows.wsfc_cluster
      vars:
        wsfc_cluster_name: SQLCLU01
        wsfc_cluster_static_addresses: [10.10.10.50]
        wsfc_cluster_ignore_networks: [10.10.20.0/24]
        wsfc_cluster_networks:
          - {subnet: 10.10.10.0/24, name: Client, role: cluster_and_client}
          - {subnet: 10.10.20.0/24, name: iSCSI, role: none}
        wsfc_cluster_disks:
          - {name: SQL Data, unique_id: 60003FF44DC75ADC8C3A5E1C1A0A9B01, initialize: true}
          - {name: SQL Log, unique_id: 60003FF44DC75ADC8C3A5E1C1A0A9B02, initialize: true}
          - {name: Witness, unique_id: 60003FF44DC75ADC8C3A5E1C1A0A9B03, initialize: true}
        wsfc_cluster_quorum:
          type: disk_witness
          disk: Witness
        wsfc_cluster_become_user: EXAMPLE\svc-cluster-build
        wsfc_cluster_become_password: "{{ vault_cluster_build_password }}"
```

More in [examples/cluster.yml](../../examples/cluster.yml).

## Tested, and not yet

Its Molecule scenario,
[`molecule/default`](https://github.com/git-cgallagher/ansible-collection-windows/tree/main/roles/wsfc_cluster/molecule/default),
builds a **one-node workgroup cluster** (access point `None`) on a real
Windows Server 2022 VM: feature install, validation, `New-Cluster`, network
name, role and metric, common properties, node-majority quorum, an
idempotent re-run, a report-only plan and a drift fix.

The lab is one VM on QEMU user-mode networking, so these aren't lab-tested
yet (tracked in the multi-node lab issue): adding nodes, the
`ActiveDirectoryAndDns` and `Dns` access points and static addresses, shared
disks (formatting, CSV), disk, file share and cloud witnesses, a failing
`Test-Cluster`, and the double hop. Try them in a lab of your own first.
