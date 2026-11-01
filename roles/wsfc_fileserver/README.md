# git_cgallagher.windows.wsfc_fileserver

Runs a general-purpose clustered file server on a Windows Server Failover
Cluster, and makes failing it over something you can do, and prove, on
demand.

It sits on a cluster built by [`wsfc`](../wsfc/README.md): an Active
Directory access point (`ActiveDirectoryAndDns`) and the file server's disks
in `wsfc_disks`, formatted and with a drive letter.

The role has three entry points (`tasks_from`), all run against the cluster's
nodes (`hosts` = the nodes), with the cluster work done once, on one node:

| Entry point | What it does | Changes |
|---|---|---|
| `main` (default) | Installs the File Server role service on every node; creates the file server (`Add-ClusterFileServerRole`) on named cluster disks, or converges an existing one: disks it lacks, online state, preferred owners; converges SMB shares scoped to its name | Yes; check mode and `wsfc_fileserver_report_only` only report |
| `validate` | Checks the role is online, then from a client host writes, reads back and deletes a probe file in every share through `\\<name>\<share>` | No |
| `failover` | Writes a marker into every share from the client, moves the role to another node (`Move-ClusterGroup`), waits for it to come online, then proves from the client that every marker reads back and each share takes a new write; reports how long the move took | Moves the role; check mode only reports |

`failover` is a planned move, as for patching or maintenance; it doesn't
simulate a node crash.

Safety behaviour:

- shares, disks and owners the variables don't list are never removed;
- a share whose path differs from its variable is reported, not moved;
- share permissions are made exact only for a share that lists some; NTFS
  permissions are never changed;
- the `validate` and `failover` probes clean up after themselves (a failed
  `failover` can leave its marker files, named
  `.wsfc_fileserver-failover-*.txt`).

All variables are documented in
[meta/argument_specs.yml](meta/argument_specs.yml), which Ansible also uses to
validate them (`ansible-doc -t role git_cgallagher.windows.wsfc_fileserver`).

## Variables

Only `wsfc_fileserver_name` is required.

| Variable | Default | Entry points | Notes |
|---|---|---|---|
| `wsfc_fileserver_name` | — | all | Client access point and cluster group name, at most 15 characters |
| `wsfc_fileserver_static_addresses` | `[]` | main | One per subnet; empty means DHCP. Only used at creation |
| `wsfc_fileserver_ignore_networks` | `[]` | main | Networks the name must not take a DHCP address on. Only used at creation |
| `wsfc_fileserver_disks` | `[]` | main | Cluster disk resource names (from `wsfc_disks`); creating the role needs one |
| `wsfc_fileserver_shares` | `[]` | main (validate and failover use the names) | `name`, `path`, and optionally `description`, `full_access`, `change_access`, `read_access`, `continuously_available`, `folder_enumeration_mode`, `encrypt_data` |
| `wsfc_fileserver_preferred_owners` | `[]` | main | Computer names in order; empty leaves them |
| `wsfc_fileserver_report_only` | `false` | main | Report, change nothing |
| `wsfc_fileserver_validate_client` | `''` | validate, failover | Inventory host that reaches the shares; empty means the managing node |
| `wsfc_fileserver_validate_shares` | `[]` | validate, failover | Share names to check; empty means every share in `wsfc_fileserver_shares` |
| `wsfc_fileserver_failover_to` | `''` | failover | Computer name of the target node; empty means another node that is up, preferred owners first |
| `wsfc_fileserver_failover_timeout` | `300` | failover | Seconds to wait for the role to come online |
| `wsfc_fileserver_manage_node` | `''` | all | Inventory host that runs the cluster commands; empty means the first host |
| `wsfc_fileserver_become_user` / `_password` | `''` | all | `runas` account for the cluster commands and the client checks |

A share's `continuously_available` turns on SMB transparent failover, so open
handles survive a move: right for application data (Hyper-V, SQL Server),
usually left off for user documents.

## Credentials: the double hop

Moving a role, and creating shares when another node owns the role, reach
another machine from inside the WinRM session, which a plain WinRM logon can't
do. Set `wsfc_fileserver_become_user` and `wsfc_fileserver_become_password`
to an account that administers the cluster; the role runs those tasks with
`runas` become, which logs on locally with the credentials. The client checks
use the same account, which needs permission to create and delete files in
each share it checks. As with `wsfc`, the role sets `become` on those tasks
itself, overriding a play-level `become`.

## Example

```yaml
- name: Build the file server
  hosts: fsclu01_nodes
  gather_facts: false
  roles:
    - role: git_cgallagher.windows.wsfc_fileserver
      vars:
        wsfc_fileserver_name: FS01
        wsfc_fileserver_static_addresses: [10.10.10.70]
        wsfc_fileserver_disks: [FS Data]
        wsfc_fileserver_preferred_owners: [FSNODE01, FSNODE02]
        wsfc_fileserver_shares:
          - name: Projects
            path: 'S:\Shares\Projects'
            full_access: ['EXAMPLE\File Admins']
            change_access: ['EXAMPLE\Domain Users']
            folder_enumeration_mode: AccessBased
        wsfc_fileserver_become_user: EXAMPLE\svc-cluster
        wsfc_fileserver_become_password: "{{ vault_cluster_password }}"

- name: Fail it over and prove it from a workstation
  hosts: fsclu01_nodes
  gather_facts: false
  tasks:
    - name: Move FS01 to the other node and check its shares
      ansible.builtin.include_role:
        name: git_cgallagher.windows.wsfc_fileserver
        tasks_from: failover
      vars:
        wsfc_fileserver_name: FS01
        wsfc_fileserver_validate_shares: [Projects]
        wsfc_fileserver_validate_client: ws01
        wsfc_fileserver_become_user: EXAMPLE\svc-cluster
        wsfc_fileserver_become_password: "{{ vault_cluster_password }}"
```

After `failover`, `wsfc_fileserver_failover.result` holds `from`, `to`,
`seconds` and the group's state; `wsfc_fileserver_validation.result.shares`
holds each share's check.

## Tested, and not yet

Its Molecule scenario,
[`molecule/default`](https://github.com/git-cgallagher/ansible-collection-windows/tree/main/roles/wsfc_fileserver/molecule/default),
boots three Windows Server 2022 VMs on a lab network: a domain controller
that also serves two iSCSI disks and is the file server's client, and two
domain-joined nodes. It builds the cluster with `wsfc`, then the file server
with two shares (one continuously available, one with access-based
enumeration and exact share permissions), re-runs both roles (idempotence),
validates the shares from the DC, fails over to the other node and back,
plans and fixes out-of-band share drift.

Not lab-tested yet: Scale-Out File Server (this role builds only the
general-purpose kind), adding a disk to an existing file server, a
multi-subnet client access point, and encrypted shares.
