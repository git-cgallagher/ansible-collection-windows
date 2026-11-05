# git_cgallagher.windows.gpo_import

Converges a target domain on a `gpo_backup` export. The role stages the
export on a Windows management host and runs the collection's `gpo_sync_import`
module there: `Import-GPO -CreateIfNeeded` (optionally through a migration
table for cross-domain promotion) for every GPO whose content changed since
the last import, then GPO status, WMI filter links, security filtering
(downgrading removed Apply trustees to Read — MS16-072) and each manifest
container's whole ordered link list, including block-inheritance.

To import a few GPOs' settings from backup folders, without the manifest or
any topology, use the [`gpo_import`](../../plugins/modules/gpo_import.yml)
module instead (0.19.0, issue #64); it's a module, not this role.

Safety behaviour:

- the module refuses any backup containing GPP `cpassword`, before it
  touches the domain;
- containers absent from the manifest are never touched; extra links on
  managed containers are only removed with
  `gpo_import_remove_unmanaged_links: true`;
- `--check` predicts every action without touching the domain or the
  module's state file, and `--diff` lists them; `gpo_import_report_only:
  true` does the same for this role alone, inside a play that otherwise
  applies;
- before planning, in check mode too, the module's preflight proves the run
  could work: the manifest matches the staged backup folders, the migration
  table parses, no `cpassword`, `gpo_import_state_dir` is writable (a probe
  file, removed again), and the domain, GPMC, links and WMI filters can be
  read. A failing check fails the task with the reason instead of reporting a
  plan the real run could not complete.

The role reports a change only when the module changed the domain, so a
second run on a converged domain changes nothing. The module's result is
registered as `gpo_import_run`: `actions` (performed, or predicted in check
mode), `notices` (what was left alone, also shown as task warnings),
`errors`, `imported`, `gpo_count`, `som_count`, `server`, `state_file` and
the `preflight` facts (`ansible-doc git_cgallagher.windows.gpo_sync_import`).

`gpo_import_gpos` limits the whole run to the named GPOs: their content and
properties, only the WMI filters they link, and only their own links on
each container. Every other GPO's links, and every container's
block-inheritance, are left as they are, even with
`gpo_import_remove_unmanaged_links`, and a container the domain lacks is
skipped when none of the named GPOs is linked there. Each named GPO's link
goes right after the link the manifest puts before it (or first, when the
domain has none of those). So a subset of GPOs moves into a domain that
lacks the others: export it with `gpo_backup_gpos` and import it with the
same names in `gpo_import_gpos`. Before 0.16.0 links and WMI filters were
reconciled for the whole manifest
([issue #57](https://github.com/git-cgallagher/ansible-collection-windows/issues/57)).

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
