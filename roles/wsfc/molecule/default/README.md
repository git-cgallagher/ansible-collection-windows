# wsfc's Molecule scenario

Builds a one-node **workgroup** cluster with `wsfc` on the shared lab
VM and checks it. The VM, the box and how to run a scenario are described in
[tests/domain_lab](../../../../tests/domain_lab/README.md); run this scenario
from `roles/wsfc` with `molecule test`. Unlike the GPO scenarios, the
VM is never promoted to a domain controller.

| Step | What happens | What's asserted |
|---|---|---|
| create | Boot the VM (the box is cached and SHA-256 pinned) and wait for its first boot to finish | WinRM/PSRP answers *and* the box's setup script is gone |
| prepare | Quiet the VM; set a primary DNS suffix and `LocalAccountTokenFilterPolicy` (Microsoft's workgroup-cluster prerequisites) and reboot; remove a cluster a previous converge left | — |
| converge | `wsfc` installs Failover Clustering, runs `Test-Cluster` (Storage ignored) and creates cluster `WSFCLAB` with access point `None`, then names the network, sets its role and metric, sets two heartbeat properties and a node-majority quorum | — |
| idempotence | Run the role again | No task reports a change |
| verify | Read the cluster | One node, up; the network's name, role (cluster only) and metric; both properties; no witness; no cluster network name |
| | Change a property out-of-band, then run the role report-only | The plan has exactly that one fix, and the cluster is unchanged |
| | Run the role for real | It fixes only that property, and doesn't recreate the cluster |

Not covered here (one VM, no shared network or storage): adding nodes, the
`ActiveDirectoryAndDns` and `Dns` access points, static addresses, shared
disks and CSVs, disk, file share and cloud witnesses, and the double hop
([issue #19](https://github.com/git-cgallagher/ansible-collection-windows/issues/19)).
