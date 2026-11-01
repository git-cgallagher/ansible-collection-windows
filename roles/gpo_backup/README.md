# git_cgallagher.windows.gpo_backup

Exports every GPO in a domain (`Backup-GPO`, one self-contained backup folder
per GPO) plus `gpo-manifest.json` — links, precedence, enforcement,
block-inheritance, security filtering, WMI filters, GPO status — from a
Windows management host into a directory on the controller (your repo working
copy). Only GPOs whose settings content changed since the last run are
re-shipped, so Git diffs stay reviewable.

The export itself is the
[`gpo_export`](../../plugins/modules/gpo_export.yml) module
(`ansible-doc git_cgallagher.windows.gpo_export`), which runs on the
management host and keeps the per-domain content-hash state in
`gpo_backup_workdir`; the role fetches its zip and unpacks it into
`gpo_backup_repo_dir`. The role reports `changed` only when a GPO shipped, a
GPO disappeared or the manifest changed, so a second run against an
unchanged domain changes nothing. In check mode the module predicts what
would ship without writing its zip or state, and the fetch is skipped.

Runs against the domain's PDC emulator unless `gpo_backup_server` is set.
Requires RSAT (GroupPolicy + ActiveDirectory modules) on the target host and
`unzip` on the controller.

All variables are documented in
[meta/argument_specs.yml](meta/argument_specs.yml), which Ansible also uses to
validate them (`ansible-doc -t role git_cgallagher.windows.gpo_backup`); the
workflow and manifest format are in the
[collection README](../../README.md).

Its Molecule scenario,
[`molecule/default`](https://github.com/git-cgallagher/ansible-collection-windows/tree/main/roles/gpo_backup/molecule/default),
tests the export end to end against a real domain controller.
