# Changelog

## 0.16.0 — 2026-11-04

A subset of GPOs moves between domains: `gpo_import`'s `gpo_names` now
scopes the WMI filters and links too (issue #57).

### Changed

- `gpo_import`'s `gpo_names` (the `gpo_import` role's `gpo_import_gpos`)
  scopes every step to the selected GPOs. It checks, or creates with
  `create_wmi_filters`, only the WMI filters they link, and on each
  container reconciles only their links: each goes right after the link the
  manifest puts before it, or first when the domain has none of those.
  Other GPOs' links, even with `remove_unmanaged_links`, and every
  container's block-inheritance are left as they are, and a container the
  domain lacks is skipped when no selected GPO is linked there. Before, a
  filtered import reconciled every manifest container's whole link list and
  every WMI filter, so in a domain lacking the other GPOs it failed on their
  links. 0.14.0 documented that as unsupported; export with `gpo_names` and
  import with the same names now works.
- With `gpo_names`, `som_count` counts the containers the manifest links a
  selected GPO to.

### Other

- The import's scope and the subset's link plan are pure functions in
  `_GpoCommon.psm1`, `Get-GpoImportScope` and `Get-GpoSubsetLinkPlan`, with
  Pester tests, including 300 random containers that each converge in one
  pass without touching another GPO's link.

## 0.15.0 — 2026-11-04

Unit tests for the IIS modules (issue #47): every module now has an
integration target and Pester unit tests.

- `iis_mime_type`'s and `iis_mime_type_info`'s decisions move from the
  modules into `plugins/module_utils/_IisConfig.psm1`, unchanged, so Pester
  tests them without IIS: the `extension` and `mime_type` checks, the
  add/change/remove decision against the map IIS serves at the level, the
  file to write and the web.config check, the change itself (committed only
  outside check mode), and the info module's filtering, sorting and
  `inherited` flag. The modules' options, results and messages are the same.
- New suites: `tests/unit/plugins/module_utils/_IisConfig.Tests.ps1`,
  `tests/unit/plugins/modules/iis_mime_type.Tests.ps1` and
  `iis_mime_type_info.Tests.ps1`, with a fake of IIS's configuration API
  (`tests/unit/plugins/module_utils/IisFake.ps1`).

## 0.14.0 — 2026-11-04

A filtered `gpo_export` run no longer makes the next full run report a change
(issue #37).

### Changed

- `gpo_export`'s `gpo_names` (the `gpo_backup` role's `gpo_backup_gpos`) now
  limits only which GPOs are hashed and shipped. `gpo-manifest.json` always
  describes the whole domain, every GPO, WMI filter and link, so a filtered
  run writes the same manifest as a full one and leaves the repo's manifest
  whole. Before, a filtered run wrote a manifest of the selected GPOs only:
  the repo's manifest lost every other GPO, and the next full export on an
  unchanged domain reported `manifest_changed` and `changed`. A consumer can
  see the difference: a filtered export's zip, and the repo it unpacks into,
  now carry manifest entries for GPOs without a backup folder. Moving a
  subset of GPOs between domains isn't supported yet: `gpo_import` with
  `gpo_names` still reconciles every container's links and WMI filters
  (issue #57). The module docs and both role READMEs say so.
- Two GPOs whose names map to the same folder name now fail a filtered run
  too, as the manifest names every GPO's folder.
- If your last export before upgrading was filtered, its state holds the
  partial manifest's hash, so the first 0.14.0 export reports
  `manifest_changed` once and rewrites the repo's manifest whole; nothing
  re-ships.

### Fixed

- A filtered run that names a GPO since deleted from the domain kept no
  entry for it, so no later run reported the deletion. It now keeps the
  entry, like every other entry it doesn't rewrite, and the next full run
  reports it in `deleted`.

### Other

- The export's scope and carried-over state are one pure function,
  `Get-GpoExportScope` in `_GpoCommon.psm1`, which replaces
  `Get-CarriedOverGpoState` (only `gpo_export` used it).
- Tests: Pester covers the scope (every GPO in the manifest, the selection,
  the folder-name clash with a filter) and the carried state (a filtered run
  keeps the others, a full run replaces them, a selected GPO's entry is the
  run's, no previous state, a deleted GPO named in the filter), and that the
  module writes nothing outside its real-run block but the check-mode probe.
  The `gpo_export` target runs a filtered export, then a check-mode and a
  real full export of the unchanged domain, which ship nothing and report no
  change, and a filtered run fails on a folder-name clash.

## 0.13.0 — 2026-11-02

Clusters across datacenters: the first `wsfc` changes the SQL Server roles
need (issue #48, phase 1).

- `wsfc_cluster` has three new options, and the `wsfc` role a variable for
  each. `sites` (`wsfc_sites`) creates site fault domains and moves each
  listed node into its own. `preferred_site` (`wsfc_preferred_site`) sets the
  cluster's `PreferredSite`. `node_weights` (`wsfc_node_weights`) gives a node
  its quorum vote (`NodeWeight`) or takes it away. Unlisted sites are reported
  and left in place, and unlisted nodes keep their site and vote. Every
  refusal (a node in two sites, an unknown preferred site, a weight other
  than 0 or 1) comes before any site or vote changes. A domain cluster may
  already have put its nodes in a site named after their subnet
  (`Site 10.42.0.0/24` in the lab); `wsfc_sites` moves them, and that site
  stays, reported, until you remove it or list it.
- A file share witness can take a `credential` (`wsfc_quorum.credential`),
  for a share outside the domain such as one on a NAS (Windows Server 2019
  and later). It can't be read back, so it is only sent when the witness is
  set or its path changes. Not lab-tested yet.
- The `wsfc` README covers two datacenters (sites, the preferred site, votes,
  cross-site heartbeats), a vSphere profile of common properties from
  Broadcom's guidance, and Windows Server 2025's two-node shared-disk issue
  and SMB signing for the witness.
- The cluster helpers move from `wsfc_cluster.ps1` into
  `plugins/module_utils/_WsfcCommon.psm1`, with the site and vote planners,
  so Pester tests them without a cluster
  (`tests/unit/plugins/modules/wsfc_cluster.Tests.ps1`).
- Tests: the module's integration target plans, applies and repeats sites, a
  preferred site and a vote, fixes out-of-band drift and checks each refusal;
  `wsfc_fileserver`'s two-node lab puts its nodes in two sites, prefers the
  first and takes node2's vote.

## 0.12.0 — 2026-11-02

A new area, **SQL Server**, starts with the role `mssql_prereqs` (issue #48
plans the rest: `mssql` for standalone instances and FCIs, `mssql_ag` for
availability groups, and the `wsfc` changes they need).

- `mssql_prereqs` creates or converges the Active Directory accounts SQL
  Server runs under, before SQL Server is installed. Domain user accounts
  (password set only on creation, never expires, user can't change it) and
  gMSAs (DNS host name, AES-only Kerberos, the principals allowed to retrieve
  the password) come from one list. Each account gets the `MSSQLSvc` SPNs
  built from its host names, port and instance name: default and named
  instances, short names and extra SPNs. Optional security groups are created
  first, so a gMSA can name one of them.
- Nothing is written until the whole list validates and Active Directory has
  been read. An SPN listed twice, or already held by another account, stops
  the run and names the holder. With a gMSA listed, the forest's KDS root key
  is checked (`check`), created (`create`, for labs) or ignored (`skip`).
- Lists add by default; `mssql_prereqs_exclusive: true` makes the SPN,
  retrieve-password and group-member lists exact. Passwords never appear in a
  loop item, and `mssql_prereqs_report_only` (or `--check`) plans without
  writing. A group the same run creates doesn't exist yet during a plan, so a
  gMSA or group naming one is looked up with a warning, not a failure.
- `tasks/plan.yml` (defaults, SPNs, validation) needs no Windows host, so the
  `argument-specs` workflow tests it, every refusal included. A new
  `domain-lab` job, `molecule (mssql_prereqs)`, runs the role against a fresh
  forest.
- **New dependency:** `microsoft.ad` 1.11.0 or later (in `galaxy.yml` and
  `requirements.yml`), for `kds_root_key`; gMSAs need its `service_account`.
  The lab's requirements move to the same minimum.

## 0.11.0 — 2026-11-02

Clustered file servers, and the first multi-node cluster lab.

- New role `wsfc_fileserver`: runs a general-purpose clustered file server on
  a cluster built by `wsfc`. It installs the File Server role service on every
  node, creates the role (`Add-ClusterFileServerRole`) on named cluster disks
  or converges an existing one (disks it lacks, online state, preferred
  owners), and converges SMB shares scoped to the file server's name: folder,
  description, continuous availability, access-based enumeration, encryption
  and exact share permissions. Check mode and `wsfc_fileserver_report_only`
  report a plan.
- Two more entry points for operations: `tasks_from: validate` writes, reads
  back and deletes a probe file in every share from a client host, through
  `\\<name>\<share>`; `tasks_from: failover` writes a marker into every
  share, moves the role to another node (`Move-ClusterGroup`), waits for it to
  come online, and proves from the client that the markers read back and each
  share takes a new write. It reports how long the move took.
- `wsfc_cluster` (and so `wsfc`): removes a cluster name address on a
  network in `ignore_networks` (`wsfc_ignore_networks`), never the name's
  last one. `New-Cluster` added one there despite `-IgnoreNetwork` in the
  lab, and the name would register it in DNS.
- `wsfc`: reads each node's computer name with `$env:COMPUTERNAME` again,
  instead of the `ansible_facts.hostname` fact (0.7.0). On slow nodes the
  setup module's platform collector timed out and left the fact unset, which
  failed the role.
- `wsfc_cluster` and `wsfc`: a static address's network needs a default
  gateway when the cluster is created (`New-Cluster` gives the client role
  only to such networks); the documentation now says so.
- New Molecule scenario `roles/wsfc_fileserver/molecule/default` (the
  `domain-lab` workflow's `molecule (wsfc_fileserver)` job, about an hour):
  three VMs on a lab network, a domain controller that also serves two iSCSI
  disks, and two domain-joined nodes. It builds a two-node cluster with an
  Active Directory access point, a disk witness and both shared disks (the
  `wsfc` paths issue #19 listed as untested), then the file server with two
  shares, validates it from the DC, fails it over and back, and fixes
  out-of-band drift.
- `tests/argument_specs/check_role.yml` checks every entry point of a role's
  argument spec, not only `main`.

## 0.10.2 — 2026-11-02

No module or role changes; the domain lab's fixture and the `gpo_import`
integration target ([#50](https://github.com/git-cgallagher/ansible-collection-windows/issues/50)).

- `Set-GPInheritance` once returned without an error and left the lab's
  Workstations OU blocked, so the drift's unblock didn't take and the
  `gpo_import` target's plan check failed for the wrong reason (PR #49's first
  `gpo_import` lab run). `tests/domain_lab/files/lab_fixture.ps1` now sets
  inheritance through `Set-LabInheritance`, which reads it back after every
  write, retries, and throws if it never takes; the drift also confirms the
  unblock survived its later link changes. The fixture's diagnostics record
  how many writes each step needed.
- The `gpo_import` target's "Check the drift took" asserts the unblock, so a
  drift that didn't take fails there, not later in the plan check.


## 0.10.1 — 2026-11-02

No module or role changes. The domain labs move to molecule-git-cgallagher
**v0.3.2** (`setup-molecule` and `vm-screendump` pinned to `3cefe7f`), whose
`quiet_vm` no longer fails a prepare step when Windows refuses to stop
Windows Update right after first boot
([ansible-collection-molecule#18](https://github.com/git-cgallagher/ansible-collection-molecule/issues/18),
seen in this repo's PR #46 `gpo_import` lab): it disables the service first,
retries the stop, and warns instead of failing if Windows still refuses. It
also waits out Windows Update Medic re-enabling the service shortly after
boot. The local install lines in `AGENTS.md` and `tests/domain_lab/README.md`
move to v0.3.2.


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
  `manifest not found`) instead of PowerShell's "Cannot find drive": their
  existence checks no longer let `Test-Path` stop the run, and paths under
  those directories are built with `[IO.Path]::Combine`, because Windows
  PowerShell's `Join-Path` resolves the drive. Found by the new `gpo_export`
  target.
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
