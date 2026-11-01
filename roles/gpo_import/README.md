# git_cgallagher.windows.gpo_import

Converges a target domain on a `gpo_backup` export. The role stages the
export on a Windows management host and runs the collection's `gpo_import`
module there: `Import-GPO -CreateIfNeeded` (optionally through a migration
table for cross-domain promotion) for every GPO whose content changed since
the last import, then GPO status, WMI filter links, security filtering
(downgrading removed Apply trustees to Read — MS16-072) and each manifest
container's whole ordered link list, including block-inheritance.

Safety behaviour:

- the module refuses any backup containing GPP `cpassword`, before it
  touches the domain;
- containers absent from the manifest are never touched; extra links on
  managed containers are only removed with
  `gpo_import_remove_unmanaged_links: true`;
- `--check` predicts every action without touching the domain or the
  module's state file, and `--diff` lists them; `gpo_import_report_only:
  true` does the same for this role alone, inside a play that otherwise
  applies.

The role reports a change only when the module changed the domain, so a
second run on a converged domain changes nothing. The module's result is
registered as `gpo_import_run`: `actions` (performed, or predicted in check
mode), `notices` (what was left alone, also shown as task warnings),
`errors`, `imported`, `gpo_count`, `som_count`, `server` and `state_file`
(`ansible-doc git_cgallagher.windows.gpo_import`).

Runs against the domain's PDC emulator unless `gpo_import_server` is set.
Requires RSAT (GroupPolicy + ActiveDirectory modules) and rights to write
GPOs, OU `gPLink`/`gPOptions` and (optionally) `msWMI-Som` objects.

All variables are documented in
[meta/argument_specs.yml](meta/argument_specs.yml), which Ansible also uses to
validate them (`ansible-doc -t role git_cgallagher.windows.gpo_import`); the
workflow, manifest format and cross-domain story are in the
[collection README](../../README.md) and [docs/design.md](../../docs/design.md).

Its Molecule scenario,
[`molecule/default`](https://github.com/git-cgallagher/ansible-collection-windows/tree/main/roles/gpo_import/molecule/default),
tests the import end to end against a real domain controller.
