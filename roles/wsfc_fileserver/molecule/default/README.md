# wsfc_fileserver's Molecule scenario

A two-node file server cluster, built and operated for real, on three
Windows Server 2022 VMs. It's also the `wsfc` role's multi-node coverage. The
box and how to run a scenario are described in
[tests/domain_lab](../../../../tests/domain_lab/README.md); run this scenario
from `roles/wsfc_fileserver` with `molecule test`. CI runs it as the
`domain-lab` workflow's `molecule (wsfc_fileserver)` job, in about an hour.

| VM | Lab address | Role in the lab |
|---|---|---|
| `dc01` (DC01) | 10.42.0.10 | First DC of `gpolab.test`, iSCSI target for the shared disks, the file server's client |
| `node1` (NODE1) | 10.42.0.11 | Cluster node |
| `node2` (NODE2) | 10.42.0.12 | Cluster node |

All three share one lab network (the driver's `lab_networks`). Their first
NIC is QEMU user networking, which carries WinRM; it has the same address,
10.0.2.15, on every VM and can't reach the others, so the cluster takes it out
of cluster use and `Test-Cluster`'s network tests are skipped.

The shared disks are iSCSI: dc01 runs the iSCSI Target Server role service
and serves two virtual disks (1 GB `Witness`, 4 GB `FS Data`) to both nodes
by their lab addresses. Each disk has the same UniqueId on both nodes, so
`wsfc_disks` finds it, and the target supports the persistent reservations
`Test-Cluster`'s storage tests need. The driver needs no shared-disk support.

| Step | What happens | What's asserted |
|---|---|---|
| create | Boot the three VMs side by side | WinRM/PSRP answers on each |
| prepare | Quiet every VM; promote dc01 (renamed DC01); install the iSCSI target and serve both disks; on the nodes, use dc01 for DNS, give the lab NIC a default gateway (New-Cluster puts a static address only on a network with one), rename and join the domain, open file sharing, connect to the iSCSI target | Both nodes see both disks |
| converge | Read the disks' UniqueIds; `wsfc` builds cluster `FSCLU` (10.42.0.100, Active Directory access point) after `Test-Cluster` with storage tests, takes the management network out of cluster use, formats and adds both disks (`FS Data` as S:) and sets the disk witness; `wsfc_fileserver` builds file server `FSLAB` (10.42.0.101) on `FS Data` with shares `Projects` and `AppData` | — |
| idempotence | Run both roles again | No task reports a change |
| verify | Read the cluster and the file server | Two nodes up; the cluster address; disk witness; both disks online; network roles; the file server online with its address, preferred owners, disk and both shares' paths, settings and exact permissions |
| | `tasks_from: validate` from dc01 | Every share takes a write and returns it |
| | `tasks_from: failover`, then back to the first owner | The role moved each time, came online, and the markers written before each move read back after it |
| | Change a share's description out-of-band, run the role report-only, then for real | The plan has exactly that fix; the real run makes it |

The roles' variables are in [molecule.yml](molecule.yml) (`group_vars`
`lab_nodes`), so converge and verify run them with the same ones. Cluster
commands run as the domain account `vagrant@gpolab.test` through `runas`
become (the box's `vagrant` account became a Domain Admin when dc01 was
promoted).

Memory: three VMs at 2.5 GB each on GitHub's 16 GB runner. At 3 GB each, one
run lost dc01's QEMU process during its first boot (an out-of-memory kill,
unconfirmed); the workflow now prints host memory and kernel OOM kills when a
job fails.
