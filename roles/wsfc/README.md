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
3. with `wsfc_cno_create_computer_objects`, lets the cluster name object
   create computer objects in its OU (see
   [Clustered roles' computer objects](#clustered-roles-computer-objects-the-cnos-right));
4. names cluster networks and sets their role and metric, matched by subnet;
5. creates site fault domains and places the nodes in them, and sets the
   preferred site and the nodes' quorum votes;
6. sets cluster common properties (heartbeat thresholds and the like);
7. adds named shared disks, optionally formatting RAW ones first and adding
   them to Cluster Shared Volumes;
8. sets the quorum witness: none, disk, file share or Azure cloud witness.
   With `wsfc_witness_share`, the role provisions the file share first, on a
   Windows host in the inventory, and runs the module once more to set it (see
   [The witness share](#the-witness-share-wsfc_witness_share)).

Safety behaviour:

- nodes, sites, disks, networks and witnesses the variables don't list are
  never removed; extra ones are reported as warnings. The one exception: a cluster
  name address on a network in `wsfc_ignore_networks` is removed (never the
  name's last address), because `New-Cluster` can add one there despite
  `-IgnoreNetwork`, and the name would register it in DNS;
- a disk is only formatted when `initialize` is set **and** it is still RAW;
- a feature install that needs a reboot fails unless
  `wsfc_allow_reboot: true`;
- `--check` reports every action without changing anything, and so does
  `wsfc_report_only: true` for the cluster (see below).

The module's result is registered as `wsfc_run` (and the quorum run after a
provisioned witness share as `wsfc_quorum_run`), and the role prints their
`actions`, `warnings` and `validation_report` (the `Test-Cluster` report's
path on the managing node). `wsfc_run.cno` is the cluster name object: its
account, SID and the domain controller it was created on.

Two more entry points act on the cluster's **groups**, through the
`wsfc_group` module (`ansible-doc git_cgallagher.windows.wsfc_group`):
`tasks_from: groups` converges the groups in `wsfc_groups`, and
`tasks_from: failover` moves a group to another node and back, timing each
move (see [Cluster groups](#cluster-groups-the-groups-entry-point) and
[Failover tests](#failover-tests-the-failover-entry-point)).

### Planning: `--check` and `wsfc_report_only`

The cluster task supports check mode for real: under `--check` the module
reads the cluster, lists the actions it would take (as the task's diff too,
with `--diff`) and writes nothing. On a cluster that doesn't exist yet the
plan stops after its creation, because its networks, sites, properties, disks
and quorum can't be read before it exists, and `--check` leaves the feature
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

Only `wsfc_name` is required (and `wsfc_failover_group` for the `failover`
entry point). The full descriptions, including each list item's keys, are in
the argument spec.

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
| `wsfc_quorum` | `{}` | `type` (`node_majority`, `disk_witness`, `file_share_witness`, `cloud_witness`) plus `disk`, `path` (and a `credential` for a share outside the domain), or `account_name`/`access_key`/`endpoint`; empty = leave it |
| `wsfc_witness_share` | `{}` | Provision `wsfc_quorum`'s file share witness: `host` (inventory name), `path` (folder on it) and optionally `description`; empty = the share exists |
| `wsfc_cno_create_computer_objects` | `false` | Grant the cluster name object **Create Computer objects** on its OU; `false` = leave it |
| `wsfc_networks` | `[]` | `subnet` (CIDR) plus `name`, `role` (`none`, `cluster`, `cluster_and_client`), `metric` |
| `wsfc_properties` | `{}` | Cluster common properties, for example `SameSubnetThreshold` |
| `wsfc_sites` | `[]` | Site fault domains: `name`, and optionally `nodes` (computer names) and `description` |
| `wsfc_preferred_site` | `''` | The cluster's preferred site; empty = leave it |
| `wsfc_node_weights` | `{}` | Node votes by computer name, `1` or `0`; unlisted nodes keep theirs |
| `wsfc_disks` | `[]` | `name`, `unique_id`, and optionally `csv`, `initialize`, `file_system`, `allocation_unit_size`, `label`, `drive_letter` |
| `wsfc_report_only` | `false` | Run the cluster task in check mode while the feature install runs for real (`--check` implies it) |
| `wsfc_become_user` | `''` | Run the cluster task as this account (`runas`); see below |
| `wsfc_become_password` | `''` | Its password (vault it) |
| `wsfc_report_dir` | `C:\ProgramData\wsfc-iac` | `Test-Cluster` reports on the managing node |
| `wsfc_groups` | `[]` | Entry point `groups`: each group's `name`, and optionally `preferred_owners`, `owner` (a move), `move_timeout`, `failback` (`allowed`, `window_start`, `window_end`), `properties` and `resources` (`name`, `properties`, `parameters`) |
| `wsfc_failover_group` | *(required by `failover`)* | Entry point `failover`: the group to move |
| `wsfc_failover_to` | `''` | The node to move it to; empty = another node that is up, the group's preferred owners first |
| `wsfc_failover_back` | `true` | Move it back afterwards |
| `wsfc_failover_timeout` | `300` | Seconds each move may take |

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
`wsfc_cno_create_computer_objects` needs it to be allowed to change that OU's
permissions too (a domain admin, or a delegated **Modify permissions**).

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
network name, which SQL Server creates. Once it exists, set them with the
`groups` entry point (below): they are private properties of that resource.

### Clustered roles' computer objects: the CNO's right

A clustered role with a network name gets a computer object of its own,
which the cluster creates through its cluster name object (CNO): a file
server's client access point, a SQL Server FCI's network name, an AG
listener. In the default `Computers` container the CNO can create up to the
domain's machine account quota (`ms-DS-MachineAccountQuota`, 10 by
default). Many domains set it to 0, and in an OU the quota doesn't help, so
there the role's computer object fails to come online (event 1194).

`wsfc_cno_create_computer_objects: true` grants the CNO **Create Computer
objects** on the OU or container that holds it, for that container and
everything below it, as Microsoft's
[guide to prestaging cluster objects](https://learn.microsoft.com/windows-server/failover-clustering/prestage-cluster-adds)
does. It needs the `ActiveDirectoryAndDns` access point and an account that
may change the OU's permissions (`wsfc_become_user`). Check mode reads the
OU's permissions and reports the grant without making it; `false` leaves them
alone, and the role never takes the right away.

Where that can't be delegated, prestage each role's computer object instead,
named after the role's network name, and give the CNO Full Control over it.

### Two datacenters: sites, the preferred site and votes

A cluster across datacenters should know which nodes share one.
`wsfc_sites` creates a site fault domain per datacenter and moves each node
into its own; then a group fails over to a node in its own site before one
in another. `wsfc_preferred_site` names the primary datacenter: groups start
there on a cold start, and in a tie between the sites, dynamic quorum takes
votes from the other site first, so the preferred site keeps the cluster
running. A file share witness in a third site breaks the tie in the first
place:

```yaml
wsfc_sites:
  - {name: DC1, nodes: [AG11, AG12], description: Primary datacenter}
  - {name: DC2, nodes: [AG21, AG22], description: Secondary datacenter}
wsfc_preferred_site: DC1
wsfc_quorum:
  type: file_share_witness
  path: \\witness.dc3.example.com\witness$\AGCLU02
```

Sites match by name, without case, and a node's site follows `nodes`. A
site the cluster has that `wsfc_sites` doesn't list is reported and left in
place, and so is the site of a node no site lists. Sites need the managing
node to be in the cluster: under `--check` against a cluster the managing
node is about to join, they are planned on the next run.

A domain cluster may already have a site when `wsfc_sites` first runs: in
the lab, `New-Cluster` on Windows Server 2022 created one named after the
nodes' subnet (`Site 10.42.0.0/24`) and put both nodes in it. `wsfc_sites`
moves the nodes into your sites, and the emptied site stays, reported on
each run. List it in `wsfc_sites` without nodes to keep it quietly, or
remove it once with `Remove-ClusterFaultDomain -Name 'Site 10.42.0.0/24'`.

Heartbeats between sites can be tuned with `CrossSiteDelay` (default 1000
ms) and `CrossSiteThreshold` (default 20) in `wsfc_properties`. Whether they
or the same-subnet values apply to nodes on one subnet stretched across two
sites is **unconfirmed**, so on a stretched subnet set both, as in the
vSphere profile below.

`wsfc_node_weights` takes the quorum vote from nodes that mustn't keep the
cluster running on their own, for example disaster recovery replicas:
`{AG31: 0}`. Unlisted nodes keep their vote.

### The witness share: `wsfc_witness_share`

When the third site's witness is a Windows server, the role can provision
the share as well. The share is for the cluster name object (CNO), which
exists only once `New-Cluster` has run, so with `wsfc_witness_share` set the
role:

1. creates or converges the cluster **without** the quorum;
2. on the witness host (`host`, an inventory name; the role connects with
   that host's own settings and needs local administrator rights there),
   creates the folder `path`, gives the CNO Full Control of it, and shares it
   with the CNO only (**every other share permission is removed**);
3. checks that each node reaches the witness host on TCP 445;
4. runs the cluster module again to set the quorum (`wsfc_quorum_run`).

```yaml
wsfc_quorum:
  type: file_share_witness
  path: \\witness.dc3.example.com\AGCLU02-Witness
wsfc_witness_share:
  host: witness01            # the inventory name
  path: C:\ClusterWitness\AGCLU02
```

`wsfc_quorum.path` must be `\\server\share`: the share's name comes from it,
and the share serves one cluster. It needs the `ActiveDirectoryAndDns` access
point and no `credential`; a share on a NAS or outside the domain isn't
provisioned (give `wsfc_quorum.credential` instead).

The witness host looks the CNO up through its own domain controller, which
right after `New-Cluster` may not have it yet. The share task retries for up
to ten minutes. Between sites that replicate on a schedule that may not be
enough: run the play again once Active Directory has replicated (or replicate
with `repadmin /syncall`). The folder's permission names the CNO by SID, so it
needs no lookup.

Under `--check`, or with `wsfc_report_only`, a cluster that doesn't exist
yet plans no share, because it has no CNO yet; on an existing cluster the plan
covers the folder, its permission, the share and the quorum. A share moved to
another path or host leaves the old one in place.

### On vSphere

Broadcom's guidance for clusters of vSphere VMs
([KB 313472](https://knowledge.broadcom.com/external/article/313472/))
recommends these common properties, the "vSphere profile":

```yaml
wsfc_properties:
  QuorumArbitrationTimeMax: 60   # with clustered VMDKs
  SameSubnetThreshold: 10
  CrossSubnetThreshold: 20
  RouteHistoryLength: 40
```

The same KB says a cluster with shared disks must stay inside one vCenter
Server. Broadcom treats a cluster without them, such as an availability
group's, like any other VMs ([KB 2147661](https://kb.vmware.com/kb/2147661)),
but doesn't say whether one may span linked vCenters: ask Broadcom before
relying on it. On **Windows Server 2025** KB 313472 lists a known issue:
shutting down the active node of a **two-node** cluster with shared disks
can take the cluster down.

Windows Server 2025 also signs every outbound SMB connection by default, so
a file share witness must accept SMB signing. Windows file servers do; check
a NAS. A NAS outside the domain needs `wsfc_quorum.credential`, an account
the share's host knows:

```yaml
wsfc_quorum:
  type: file_share_witness
  path: \\nas01.dc3.example.com\witness
  credential:
    username: witness
    password: "{{ vault_witness_password }}"
```

Shared disks are matched by `UniqueId` because disk numbers differ between
nodes. Read it on the managing node:

```powershell
Get-Disk | Select-Object Number, FriendlyName, Size, PartitionStyle, UniqueId
```

## Cluster groups: the `groups` entry point

`tasks_from: groups` runs the `wsfc_group` module once, from the managing
node, for each group in `wsfc_groups`. It sets the group's common properties
(failback among them) and its preferred owners, its resources' common and
private properties, and last moves the group to `owner` when it's
elsewhere. It never creates or removes groups or resources: a group that
doesn't exist fails the run.

The main entry point never touches groups, because a workload's group exists
only once the workload has created it. Run `groups` after the workload (an
FCI's group, after SQL Server setup), or before it for the groups every
cluster has:

```yaml
- name: Put Available Storage on the node SQL Server setup runs on
  ansible.builtin.include_role:
    name: git_cgallagher.windows.wsfc
    tasks_from: groups
  vars:
    wsfc_groups:
      - name: Available Storage
        owner: SQL01

# After SQL Server setup: the FCI prefers the first datacenter's nodes and
# fails back only at night; the AG listener registers one address in DNS.
- name: Converge the SQL Server groups
  ansible.builtin.include_role:
    name: git_cgallagher.windows.wsfc
    tasks_from: groups
  vars:
    wsfc_groups:
      - name: SQL Server (MSSQLSERVER)
        preferred_owners: [SQL01, SQL02]
        failback: {allowed: true, window_start: 1, window_end: 4}
      - name: AG1
        resources:
          - name: AG1_AGLISTENER
            parameters: {RegisterAllProvidersIP: 0, HostRecordTTL: 300}
```

- `preferred_owners` is an exact, ordered list. `failback.allowed` has no
  effect without preferred owners (a warning says so). The failback window
  is two hours from 0 to 23 in the cluster's local time, or `-1` for none,
  in which case failback happens as soon as the preferred owner is back.
- A private property that only takes effect when its resource restarts is
  set with a warning saying so; the role never restarts a resource.
- **Availability groups:** SQL Server owns an AG's cluster group. Microsoft
  says not to change its owners or properties, add or remove its resources,
  or move it through the cluster, so `wsfc_group` refuses `preferred_owners`,
  `owner`, `failback` and `properties` for such a group, and any change to
  the availability group resource. Its other resources, such as the
  listener's network name, stay settable. Fail an AG over with T-SQL.
- `--check` and `wsfc_report_only: true` plan every change, moves included,
  without making them.

## Failover tests: the `failover` entry point

`tasks_from: failover` moves `wsfc_failover_group` to another node (or
`wsfc_failover_to`), waits for it to settle there (online, if it was), and
moves it back (unless `wsfc_failover_back: false`). It's a planned failover,
as for patching a node; it doesn't simulate a crash. The result, with how long
each move took, is in `wsfc_failover_result`:

```yaml
- name: Fail the FCI over and back
  ansible.builtin.include_role:
    name: git_cgallagher.windows.wsfc
    tasks_from: failover
  vars:
    wsfc_failover_group: SQL Server (MSSQLSERVER)

- name: Show the timings
  ansible.builtin.debug:
    var: wsfc_failover_result   # {group, from, to, seconds, moved_back, back_seconds, planned_only}
```

It refuses an availability group's group: AGs fail over through T-SQL. The
file server role has its own `failover` entry point, which also checks the
shares from a client.

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
a drive letter), a file share witness the role provisions on the domain
controller while it builds the cluster (`wsfc_witness_share`), and the double
hop through `runas` become, then an idempotent re-run. The lab domain's
machine account quota is 0 and `wsfc_cno_create_computer_objects` is on, so
the file server's computer object can only come from the cluster name
object's right; verify checks the right, the share's and folder's
permissions, and that the file server's computer object carries no
`ms-DS-CreatorSID` (which a quota would have stamped). Verify ends by moving
the quorum to a disk witness.

The same lab puts the two nodes in two sites (`DC1` and `DC2`), makes `DC1`
the preferred site and takes `node2`'s vote, and the module's integration
target checks sites, the preferred site and votes on its one-node cluster.
It also runs the `groups` entry point on `Cluster Group` (preferred owners
and a description, through the idempotent re-run) and ends with the
`failover` entry point on that group: to the other node and back, with the
cluster still up and its file share witness online.

The same lab runs the `wsfc_cluster` module's domain integration target
(`tests/integration/targets/wsfc_cluster_cno`): with the cluster name
object's right taken away on the domain controller, check mode plans the
grant and writes nothing, the grant adds the one rule, a repeat changes
nothing, and the option turned off leaves the right in place. The one-node
target checks the refusal on a cluster without a cluster name object.

The `wsfc_group` module's integration target
(`tests/integration/targets/wsfc_group`, run by this role's scenario) builds
a one-node cluster with a test group holding an offline Generic Application
resource, and checks group properties, failback, preferred owners and the
resource's common and private properties the same way: check mode, the
change, a repeat, drift and the error messages. A move needs two nodes, so
only the three-VM lab moves a group.

Still not lab-tested ([issue #19](https://github.com/git-cgallagher/ansible-collection-windows/issues/19)):
adding a node to an existing cluster, the `Dns` access point, multi-subnet
clusters, Cluster Shared Volumes, a cloud witness, a file share witness with a
`credential` (a NAS) or in another site (Active Directory replication delays
the share's permission), the CNO's right on an OU rather than the default
`Computers` container, failover between sites, failback (it needs a node to
fail and come back), an availability group's group (refused, but only proven
by unit tests), and a failing `Test-Cluster`. The lab ignores `Test-Cluster`'s network tests,
because every lab VM's management NIC has the same address (QEMU user
networking). Try those in a lab of your own first.
