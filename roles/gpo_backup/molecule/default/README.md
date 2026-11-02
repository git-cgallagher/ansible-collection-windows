# gpo_backup's Molecule scenario

Exports a real domain with `gpo_backup` and checks the export. The domain
controller, the fixture and how to run it are described in
[tests/domain_lab](../../../../tests/domain_lab/README.md); run this scenario
from `roles/gpo_backup` with `molecule test`.

| Step | What happens | What's asserted |
|---|---|---|
| create | Boot the VM (the box is cached and SHA-256 pinned) and wait for its first boot to finish | WinRM/PSRP answers *and* the box's setup script is gone |
| prepare | Promote it to a DC; seed the authored state: five GPOs, including the [real-world scenarios](../../../../docs/scenarios.md); clear any previous export and the host's backup state | — |
| converge | `gpo_backup` exports the domain into an empty repo | — |
| idempotence | Export again | No task reports a change: an unchanged domain ships nothing |
| verify | Read the repo | The manifest reached it with every fixture GPO, and every fixture GPO has a backup folder (the fetch and unpack) |
| | Change a setting in one GPO through GPMC, then run the role in check mode | The module predicts that GPO, and only it, with no zip; the fetch is skipped and the repo is untouched |
| | Export again for real | That GPO ships, and only it, the same list check mode planned, and the role replaces its folder in the repo (a re-backup gets a fresh `{guid}` folder) |
| | The `gpo_export` module's integration target ([`tests/integration/targets/gpo_export`](../../../../tests/integration/targets/gpo_export/tasks/main.yml), with `setup_gpo_lab`), in a working directory of its own | Check mode against a missing working directory plans every GPO, probes the parent and creates nothing; the real export's zip holds the manifest and every GPO's backup, the state file is written, and the manifest has the exact link order (domain root included), enforced and disabled links, block-inheritance, security filtering, the WMI filter and GPO status; the repeat ships nothing; check mode leaves the working directory byte-for-byte as it was; a changed GPO ships alone; a new GPO ships and a deleted one is reported once; `gpo_names` selects, skips deletion detection and keeps the other GPOs' state; a missing `domain`, an ACL-denied working directory, one with no existing parent and two GPOs mapping to one folder name each fail clearly and write nothing; the domain and the host are left as found |
