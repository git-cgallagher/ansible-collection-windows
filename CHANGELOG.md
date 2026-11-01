# Changelog

## 0.10.0 — 2026-11-01

Every module has its own integration target (issue #44).

- `gpo_export` and `gpo_import` get ansible-test integration targets
  (`tests/integration/targets/gpo_export`, `gpo_import`, with the shared
  `setup_gpo_lab`), run from the `gpo_backup` and `gpo_import` roles'
  Molecule scenarios after the roles' own checks, the way `wsfc_cluster` runs
  from `wsfc`'s. Each covers check mode (predicts, writes nothing, the
  preflight facts), the real run and its documented result keys, the repeat
  (`changed: false`), every documented failure path and the module's options:
  for `gpo_export` the manifest against the fixture, a changed GPO shipping
  alone, a new and a deleted GPO, `gpo_names`, an ACL-denied working
  directory, one with no existing parent and two GPOs mapping to one folder
  name; for `gpo_import` the fixture's drift, the plans against it, the forced
  converge back, `remove_unmanaged_links`, `create_wmi_filters`, the migration
  table, the cpassword refusal, an incomplete backup folder, a missing
  manifest, a missing migration table, a GPO missing from both domain and
  export, and an ACL-denied `state_dir`. The roles' scenarios keep role
  behaviour (staging, fetch/unpack, variables, report-only) and leave the
  module's to the targets; `new_migtable.ps1` moved to `setup_gpo_lab`.
- `gpo_export` and `gpo_import` share `plugins/module_utils/_GpoCommon.psm1`
  instead of each carrying a copy of the common helpers. It holds their pure
  logic: hashing, the zip, the manifest's encodings, the export's state
  decisions, the import decision and the link plan, now separate functions
  (`Get-GpoImportReason`, `Get-GpoLinkPlan` and others). Behaviour is
  unchanged: the hash format is pinned by a unit test, so recorded state
  still matches. Small differences: `deleted` is sorted by name, and after a
  failed link change in a run that fails anyway, the remaining links are
  planned as if it had succeeded.
- Pester unit tests (`tests/unit/plugins/`) for the util and both GPO
  modules, run by the `powershell` CI job: the pinned hash formats,
  `gpt.ini` left out of the live hash, the zip's entries, the WMI filter
  encoding round trip, relative DNs and trustee names, the state carry-over
  and deleted-GPO detection, the import reasons, the link plan (including
  that it converges in one pass and a re-plan is empty), the migration table
  path, the backup folder check and each module's wiring to the util.
- AGENTS.md records the testing standard: every role has a Molecule
  scenario; every module has an integration target (what it must cover,
  where it runs) and Pester unit tests. It's a convention, not a CI check.
  `wsfc_cluster` and the IIS modules' unit tests are a follow-up (issue #47).
- **Fix:** `gpo_export` and `gpo_import` given a `work_dir`, `state_dir` or
  `source_dir` on a drive that doesn't exist fail in the preflight with its
  message (`none of its parents exist`, `no existing parent directory`,
  `manifest not found`) instead of PowerShell's "Cannot find drive". Found
  by the new `gpo_export` target.
- **Fix:** a `gpo_export` run with `gpo_names` keeps the unselected GPOs'
  hashes in the state file. Before, it rewrote the state with the selected
  GPOs only, so the next unfiltered export re-shipped every other GPO and
  forgot which GPOs had been deleted. Found by the new target.

## 0.9.0 — 2026-11-01

`gpo_import` proves a plan could run (issue #41).

- The `gpo_import` module runs a preflight before planning, in check mode
  too, and returns what it found as `preflight`: the manifest parses and
  every backup folder it names and the export carries is a complete
  `Backup-GPO` folder, the migration table parses, no `cpassword`,
  `state_dir` is writable (a probe file is created and removed; a directory
  that doesn't exist yet is probed at its nearest existing parent), and the
  domain, GPMC, the links at the domain root and the WMI filters can be
  read. A failing check fails the module with the reason, before anything
  is planned or touched, so `--check` no longer reports a plan the real run
  could not complete (an unwritable state directory, for example). The
  cpassword refusal and the module's behaviour otherwise are unchanged.
- The lab asserts the preflight facts of the report-only plan, that the
  probe file is gone, and that a plan against a state directory the
  connection account is denied write to fails in the preflight and touches
  nothing.
## 0.8.0 — 2026-11-01

`gpo_export` writes nothing in check mode.

- `gpo_export` decides what ships from each GPO's live Group Policy Template
  in SYSVOL (every file and directory under
  `\\<dc>\SYSVOL\<domain>\Policies\{guid}` except `gpt.ini`), read from the
  domain controller the export runs against, instead of from a fresh backup
  of every GPO. A `--check` run therefore reads Active Directory and SYSVOL
  and returns the plan: no `Backup-GPO`, no working directory, no staging,
  no zip (`zip: null`), no state file. A real run backs up only the GPOs that
  ship. Results keep their shape.
- **Behaviour change on upgrade:** the state file's hashes change basis
  (`hash_basis: sysvol`), so the first export after upgrading from 0.5.0 to
  0.7.x ships every GPO once; the next export is incremental again.
- `gpo_backup`'s Molecule scenario checks that a check-mode run leaves the
  working directory byte-for-byte as it was, that one pointed at a missing
  working directory plans every GPO without creating it, that one pointed at
  a directory whose ACL denies writes fails with the preflight message and
  leaves no probe file, and that the real run ships the list check mode
  planned.

## 0.7.1 — 2026-11-01

Test-only: nothing shipped changes.

- The domain lab's bootstrap (`tests/domain_lab/promote.yml`) is one
  `include_role` of `git_cgallagher.molecule.ad_forest` (since the labs moved
  onto the driver), and now runs the role a second time on the promoted DC
  and asserts that it changed nothing: the forest, the SYSVOL wait and the
  admin group membership.
- The labs pin the molecule collection and driver at v0.3.1, whose
  `ad_forest` is idempotent on a promoted DC (its DNS task listed only
  `127.0.0.1`, which PR #33's second-run check caught), and the `wsfc` and
  `iis` scenarios quiet their VM with its shared `quiet_vm` role instead of a
  copied PowerShell block.
- `setup_iis`, the IIS integration targets' setup, creates the test website
  and application with `community.windows.win_iis_website` and
  `community.windows.win_iis_webapplication` instead of a PowerShell script,
  and the `iis` Molecule scenario runs it a second time and asserts that
  nothing changed. `community.windows` is a test dependency only
  (`tests/integration/requirements.yml`), not one of the collection's.
## 0.7.0 — 2026-11-01

The `wsfc` role's cluster script is now a module.

- New module `wsfc_cluster`: creates a Windows Server Failover Cluster from
  the nodes named, or adds the nodes an existing cluster is missing, and
  converges its networks, common properties, named shared disks and quorum
  witness. It is `roles/wsfc/files/converge_cluster.ps1` turned into a real
  module: typed options (`quorum`, `networks`, `properties` and `disks` are
  nested options rather than JSON strings), real check mode instead of a
  `ReportOnly` parameter, the planned actions as the diff, the cloud
  witness's `access_key` masked by the module, and `ansible-doc`
  documentation. Its behaviour is the script's: the same order of
  operations, actions, warnings and refusals. One addition, `drive_letter`
  on a disk, gives the volume a first-time format creates a drive letter
  (also `wsfc_disks[].drive_letter` in the role).
- `wsfc` calls the module. Its variables are unchanged. `wsfc_report_only`
  stays: it runs the cluster task in check mode while the feature install
  runs for real, which `--check` alone can't do. The cluster task no longer
  turns check mode off, so `--check` writes nothing. The role reads each
  node's computer name from the `ansible_facts.hostname` fact (gathering the `min`
  subset when the play hasn't) instead of running a script for it. The
  registered result's shape changed: `wsfc_run.actions`,
  `wsfc_run.warnings`, `wsfc_run.created` and `wsfc_run.validation_report`
  are top-level keys now, and `report_only` is gone.
- The module's integration target, `tests/integration/targets/wsfc_cluster`
  (with `setup_wsfc`), builds and removes its own one-node cluster: check
  mode before each change, the change, then a repeat that changes nothing;
  out-of-band drift; the error messages. The `wsfc` Molecule scenario runs
  it after the role's own checks, so CI's `molecule (wsfc)` job covers both.

## 0.6.0 — 2026-11-01

`gpo_import`'s import is a module.

- New module `gpo_import`: converges a domain on a `gpo_backup`/`gpo_export`
  export, the work that `roles/gpo_import/files/import_gpos.ps1` did through
  `win_powershell`. Same behaviour (`Import-GPO -CreateIfNeeded` keyed on
  content hashes, migration tables, status, WMI filter links, security
  filtering with the MS16-072 downgrade, each container's ordered link list
  and block-inheritance, the cpassword refusal), now with a typed argument
  spec, `ansible-doc`, real check mode and diff mode. It reports `changed`
  only when the domain changed; a converged domain reports no change. In
  check mode it predicts every action (returned in `actions` and as the
  diff) and writes neither to the domain nor to its state file. The
  cpassword refusal is a documented module failure, raised before the domain
  is touched, with the offending files in `cpassword_files`.
- The `gpo_import` role calls the module; its variables are unchanged.
  `gpo_import_report_only` now puts the import task in check mode, so it
  does exactly what `--check` does, for this role alone inside a play that
  otherwise applies. The registered result `gpo_import_run` changes shape:
  the module's return values are top-level (`gpo_import_run.actions`,
  `.imported`, `.errors`, ...) instead of under `.result`, `report_only` is
  gone, the structured warnings are `notices` (they are also emitted as task
  warnings), and a report-only or check-mode run that has work to do now
  reports `changed: true`, as check mode should.
- The lab scenario asserts the check-mode contract: the plan predicts the
  drift with `changed`, recreates nothing and writes no state file, and a
  converged domain re-planned in check mode reports zero actions and no
  change.

## 0.5.0 — 2026-11-01

The GPO export is a module.

- New module `gpo_export`: what `roles/gpo_backup/files/backup_gpos.ps1` did,
  as a documented module (`ansible-doc git_cgallagher.windows.gpo_export`)
  with a typed argument spec (`domain`, `server`, `work_dir`, `gpo_names`,
  `full_export`) and real check-mode support: a `--check` run computes what
  would ship and writes neither the zip (returned as `null`) nor the
  content-hash state file. Manifest content, hashing, change detection, the
  state file and the backup folder layout are unchanged, so existing exports
  and `gpo_import` round trips are unaffected.
- `gpo_backup` calls the module instead of `win_powershell`, without
  `check_mode: false`, and fetches the zip only when the module wrote one.
  Its registered result, `gpo_backup_export`, now carries the module's return
  values at the top level (`shipped`, `deleted`, `manifest_changed`,
  `gpo_count`, `zip`, `server`, `errors`) instead of under `result`. The
  role's variables are unchanged.
- `gpo_backup`'s Molecule scenario now also runs the role in check mode after
  changing a GPO and checks that it predicts that GPO, and only it, without
  writing the zip, and that the real run that follows still ships it.

## 0.4.0 — 2026-11-01

A new area, IIS, with the collection's first modules.

- New module `iis_mime_type`: ensures that a file extension maps to a MIME
  type in IIS's static content MIME map, or has no mapping, at the server
  level, for a website, or for an application or virtual directory under one.
  It decides against the map IIS serves at that level, inherited mappings
  included, so it overrides or hides inherited mappings at that level rather
  than copying them. It writes each change in one commit, reads the level back
  afterwards, and supports check mode and diff mode. Site and application
  mappings go into `<location>` elements in `applicationHost.config` by
  default, or into the level's `web.config` with `config_file: web.config`.
- New module `iis_mime_type_info`: lists the mappings IIS serves at a level,
  filtered by extension, by MIME type or by both, says which ones are
  inherited, and returns an empty list when nothing matches.
- Both are new implementations that replace `win_iis_mimetype` and
  `win_iis_mimetype_info` from the old `ansible-windows` repository. Their
  options differ: `site` and `application` instead of a configuration path,
  `mime_type` is required for `state: present` and must look like
  `type/subtype` (backslashes are no longer rewritten to slashes), and the
  info module applies both filters together.
- Their integration targets (`tests/integration/targets/`) run in CI on a
  Windows Server 2022 VM with IIS, through the Molecule scenario
  `tests/integration/molecule/iis` (the `domain-lab` workflow's
  `molecule (iis)` job). The Molecule base config now keeps the box pin and
  the VM's size in one default, `lab_vm`, so a scenario can boot a VM under
  its own name without repeating the pin.
- README: how to install the collection from Galaxy, and a note sending
  Active Directory site management to `microsoft.ad.site`, with a check for
  domain controllers before deleting a site.

## 0.3.0 — 2026-10-31

A second area: failover clusters.

- New role `wsfc`: installs Failover Clustering on every node, then
  from one managing node validates the nodes (`Test-Cluster`), creates the
  cluster or adds the nodes it is missing, and converges cluster network
  names, roles and metrics, common properties, named shared disks (with an
  optional first-time format of RAW disks and Cluster Shared Volumes) and the
  quorum witness (none, disk, file share or Azure cloud witness). It never
  removes nodes, disks or networks, refuses to reboot a node unless
  `wsfc_allow_reboot` is set, and supports check mode and a
  report-only plan. Its README says what file servers, SQL Server FCIs and
  availability groups each need from it.
- Its Molecule scenario builds a one-node workgroup cluster on a real Windows
  Server 2022 VM in CI. Multi-node clusters, shared disks, witnesses and the
  domain access points aren't lab-tested yet (issue #19, the multi-node
  lab).
- `examples/cluster.yml`: a file server cluster, a SQL Server FCI's cluster
  and a multi-subnet availability group's cluster.

## 0.2.0 — 2026-10-31

Renamed to `git_cgallagher.windows`, to grow into a collection for Windows
Server automation beyond Group Policy. The repository is now
`git-cgallagher/ansible-collection-windows`; GitHub redirects the old
`ansible-collection-gpo` URLs.

- The roles keep their names and variables. Update the FQCNs in your
  playbooks: `git_cgallagher.gpo.gpo_backup` is now
  `git_cgallagher.windows.gpo_backup`, and `git_cgallagher.gpo.gpo_import` is
  now `git_cgallagher.windows.gpo_import`. `git_cgallagher.gpo` was never
  published to Galaxy.
- Backups now carry the comment `git_cgallagher.windows export`, and WMI
  filters that `gpo_import` creates record `git_cgallagher.windows` as their
  author.

## 0.1.1 — 2026-10-31

Tests and packaging only; the roles are unchanged.

- Each role now has its own Molecule scenario next to it.
  `roles/gpo_backup/molecule/default` checks the export: the manifest, the
  backup folders, that an unchanged domain ships nothing and that a changed
  GPO ships alone. `roles/gpo_import/molecule/default` runs the import round
  trip that was `molecule/domain_lab`. They share one lab, `tests/domain_lab/`,
  and one Molecule base config, `.config/molecule/config.yml`.
- CI's `domain-lab` workflow runs the two scenarios in parallel, one job per
  role.
- `roles/*/molecule` and `.config` are excluded from the collection tarball.

## 0.1.0 — 2026-10-28

Initial release of `git_cgallagher.gpo`, tested end to end against a real
Windows Server 2022 domain controller in CI (`molecule/domain_lab`), within
one domain. Importing into a different domain isn't lab-tested yet (issue
#16).

- `gpo_backup`: exports every GPO in a domain (`Backup-GPO`, one
  self-contained backup folder per GPO) plus a `gpo-manifest.json` capturing
  what `Import-GPO` can't: link targets, link order (precedence), enforced /
  enabled flags, block-inheritance, security filtering, WMI filters and GPO
  status. Ships only what changed since the last export (content-hash state
  on the management host) so Git diffs stay reviewable.
- Manifest link targets are relative to the domain root (`""` = the root),
  so one export rebases onto another domain; the manifest also records the
  source `root_dn` and `domain_sid`, and each GPO's Deny entries (`denied`),
  which are never treated as Apply and, when missing in a target, fail the
  import (they can't be created through GPMC's cmdlets).
- `gpo_import`: imports backups into a (possibly different) target domain
  with `Import-GPO -CreateIfNeeded`, optional migration table, then
  reconciles GPO status, WMI filter links, security filtering (keeping Read
  for removed Apply trustees — MS16-072) and each container's whole ordered
  link list. Refuses any backup containing GPP `cpassword`. Report-only mode
  for plan-style runs.
- Both roles declare their variables in `meta/argument_specs.yml`: Ansible
  validates types and required variables before the first task, and
  `ansible-doc -t role git_cgallagher.gpo.<role>` documents them.
- `docs/design.md`: the problem statement — why domain GPOs resist IaC, why
  backup/import is the only mechanism covering every setting type, and what
  it still doesn't cover.
- `docs/scenarios.md`: worked real-world examples — a domain password and
  lockout policy above Default Domain Policy, local Administrators via Group
  Policy Preferences and via Restricted Groups, and lab → production
  promotion with a migration table.
