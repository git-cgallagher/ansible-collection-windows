# AGENTS.md — ansible-collection-windows

> Read `~/Code/AGENTS.md` first (workspace-wide rules). This file covers only
> this repo.

## What this is

Public Ansible collection **`git_cgallagher.windows`** (MIT): Windows Server
automation, grouped by area. Until 0.2.0 (2026-10-31) it was
`git_cgallagher.gpo`, in the repository `ansible-collection-gpo`. GitHub
redirects the old URLs and the old name was never on Galaxy, so issues,
commits and notes that say "gpo" mean this collection.

Its first area is **Group Policy as code**: `Backup-GPO`/`Import-GPO`
plus a JSON manifest for links, precedence, filtering, WMI filters and
status. Problem statement + decisions: `docs/design.md`. Two roles:

- `roles/gpo_backup` — export GPOs + manifest from a domain into a Git
  working copy (zip over WinRM, content-hash state so only changes ship).
  The export itself is the `gpo_sync_export` module (0.5.0, named
  `gpo_export` until 0.18.0), which the role calls; the role fetches and
  unpacks the zip on the controller.
- `roles/gpo_import` — converge a target domain on the repo: stages the
  export and runs the module `plugins/modules/gpo_sync_import` (0.6.0, named
  `gpo_import` until 0.18.0; it was the role's `files/import_gpos.ps1`
  through `win_powershell` before), which imports and reconciles topology,
  migration-table aware, with real check and diff mode.
  `gpo_import_report_only` is check mode on that task.

The two modules and the two roles are the **sync layer**: a whole-domain
mirror (manifest, topology, state files). Owner decision of 2026-11-05
(issue #64): it's kept but not a priority, and its open defects (#4, #5,
#8, #9) are deprioritized. 0.18.0 renamed its modules `gpo_sync_export` and
`gpo_sync_import`, with no change in behaviour, so the names `gpo_export`
and `gpo_import` can become content-only primitives: settings content by
GPO name and path, no links, WMI filters, security filtering, status or
inheritance, and never a deletion.

Its second area is **failover clustering** (0.3.0):

- `roles/wsfc` — install Failover Clustering on every host in the
  play, then from one managing node validate, create the cluster (or add
  missing nodes) and converge networks, sites and node votes (0.13.0),
  common properties, named shared disks and the quorum witness, through the
  `wsfc_cluster` module
  (`plugins/modules/wsfc_cluster.ps1`, which was the role's
  `files/converge_cluster.ps1` until 0.7.0). Two more entry points (0.17.0)
  act on cluster groups through the `wsfc_group` module: `groups` converges
  `wsfc_groups` (owners, failback, properties, resources' properties, a
  move), and `failover` moves `wsfc_failover_group` to another node and back,
  timed into `wsfc_failover_result`; `main` never touches groups, since a
  workload's group exists only after the workload creates it. It's the base
  for file servers, SQL Server FCIs and AGs; it doesn't install SQL Server or
  create shares or AGs. The role is plain `wsfc` (owner's choice,
  2026-10-31; it was `wsfc_cluster` before PR #20 merged), so its variables
  are `wsfc_*`. A later role in this area, say `wsfc_fileserver`, gets
  variables `wsfc_fileserver_*`: don't add a `wsfc_` variable whose name
  starts with another role's suffix (`wsfc_fileserver_…`).
- `roles/wsfc_fileserver` (0.11.0) — a general-purpose clustered file server
  on a `wsfc` cluster: File Server role service on every node, then
  `Add-ClusterFileServerRole` (or converge: disks, online, preferred owners)
  and SMB shares scoped to its name, with exact share permissions
  (`files/converge_fileserver.ps1`; the shares are converged on the owner
  node, through `Invoke-Command` when that isn't the managing node). It has
  three entry points: `main`, `validate` (probe every share from a client)
  and `failover` (`files/failover_group.ps1` moves the group;
  `files/probe_shares.ps1` writes markers before and checks them after).
  `defaults/main.yml` holds every entry point's defaults, and
  `tests/argument_specs/check_role.yml` checks each entry point's options.

A new area joins as roles (or plugins) named with that area's prefix, the
way `gpo_*` and `wsfc` are, each role with its own Molecule scenario.

Its third area is **IIS** (0.4.0), with the collection's first modules:

- `plugins/modules/iis_mime_type` — ensure an extension's MIME type in IIS's
  static content MIME map (or its absence) at the server, site or
  application level, deciding against the effective map, inherited entries
  included. Writes to `<location>` elements in `applicationHost.config`, or
  with `config_file: web.config` to the level's `web.config`.
- `plugins/modules/iis_mime_type_info` — read that map at a level, filtered
  by extension and/or MIME type, with an `inherited` flag per entry.

Modules are tested by ansible-test integration targets rather than a
scenario each (see Conventions). The behavior was implemented clean-room from
a behavioral spec of the old `ansible-windows` modules, under this
collection's MIT license: don't copy code from GPL-licensed IIS modules
(microsoft.iis, community.windows) into it.

Its fourth area is **SQL Server** (0.12.0), planned in issue #48 (the roles,
their phases and the owner's decisions of 2026-11-01). The first role:

- `roles/mssql_prereqs` — the Active Directory accounts SQL Server runs
  under, created before SQL Server is: domain users (`microsoft.ad.user`) or
  gMSAs (`microsoft.ad.service_account`), their generated `MSSQLSvc` SPNs,
  groups, and the forest's KDS root key (checked, or created when asked). It
  runs once, from a DC. `tasks/plan.yml` is its pure half (defaults, SPN
  building, validation, no Active Directory), which
  `tests/argument_specs/validate.yml` runs on localhost with
  `tasks_from: plan` and `public: true`; `tasks/main.yml` imports it, then
  reads (KDS root keys, SPNs held elsewhere) before it writes anything.

Next, per issue #48: `mssql` (standalone instances and FCIs) and `mssql_ag`
(availability groups). **Every cluster change is made by `wsfc` itself**
(owner rule, 2026-11-01): amend `wsfc`/`wsfc_cluster`, never put cluster
configuration into an `mssql` role. Service accounts and SPNs stay in
`mssql_prereqs`, never in `mssql` or `mssql_ag`. The base role `mssql` must
never get a variable starting `mssql_ag_` or `mssql_prereqs_`.

## ⚠️ Maturity — read before relying on it

**Lab-tested within one domain.** Each role has its own Molecule scenario
next to it. Each boots a real Windows Server 2022 VM under KVM, promotes it
to a DC and runs its role against it (the `domain-lab` workflow, one job per
role):

- `roles/gpo_backup/molecule/default`: the role's behaviour: the export
  fetched and unpacked into the repo (the manifest and every fixture GPO's
  backup folder), an unchanged domain shipping nothing, a check-mode run of
  the role predicting a changed GPO with the fetch skipped and the repo
  untouched, and that GPO then shipping alone with its repo folder replaced.
  Then the `gpo_sync_export` module's integration target
  (`tests/integration/targets/gpo_sync_export`, with `setup_gpo_lab`), which owns
  the module's checks since 0.10.0: check mode against a missing working
  directory (every GPO planned, the parent probed, nothing created), the
  real export (the zip's layout, the state file, the manifest against the
  fixture: links in precedence order, enforced and disabled links,
  block-inheritance, filtering, the WMI filter, status), the repeat, check
  mode leaving the working directory byte-for-byte as it was, a changed GPO
  shipping alone, a new and a deleted GPO, the `gpo_names` filter (the
  whole domain's manifest written, the other GPOs' state kept, so a full run
  after it ships nothing; deletion detection skipped, a deleted GPO named in
  the filter kept for the next full run) and the failures (a missing
  `domain`, an ACL-denied working directory, one with no existing parent,
  two GPOs mapping to one folder name, a filtered run included), in a
  working directory of its own.
- `roles/gpo_import/molecule/default`: the role's behaviour: seed, export,
  out-of-band drift, report-only plan (the role's `gpo_import_report_only`:
  predicts the drift, recreates nothing, writes no state file), import,
  idempotence, verify (the domain read through GPMC, the effective password
  policy, a check-mode re-plan of the role with zero actions and no change,
  the re-export round trip) and an import through a migration table staged
  from a relative path. Then the `gpo_sync_import` module's integration target
  (`tests/integration/targets/gpo_sync_import`, with `setup_gpo_lab`), which owns
  the module's checks since 0.10.0: the authored domain exported and
  unpacked into a source directory of its own, the first plan (every GPO
  "never imported", the preflight facts, no state file, no probe file, the
  domain untouched down to GPO versions), the import, the repeat, the
  fixture's drift, the plans against it (the defaults failing on the missing
  WMI filter with the unmanaged link noticed, then `create_wmi_filters` and
  `remove_unmanaged_links` planning the fixes, and nothing touched), the
  forced converge back to the authored state and the repeat, two `gpo_names`
  subsets imported into the domain drifted again from the export lacking the
  deleted GPO's folder (check mode, the run, the repeat; only the subset's
  filter and links touched, the drift outside it left, then converged back),
  the migration
  table (the import key, the repeat, the import without it), and the
  failures (a missing `source_dir`, a missing migration table, the cpassword
  refusal, an incomplete backup folder, a missing manifest, a GPO missing
  from both domain and export, an ACL-denied `state_dir`), each leaving the
  domain and the state file as they were.
- `roles/mssql_prereqs/molecule/default`: a fresh forest. Before it has a
  KDS root key, `check` refuses the gMSA and a report-only `create` plans one
  and writes nothing; prepare then adds a key backdated 10 hours (a key is
  usable 10 hours after its effective time). Converge creates two domain
  users (default and named instance, short names, an extra SPN), a gMSA a
  role-created group may retrieve, and two groups; verify reads every SPN,
  flag, member and the AES-only encryption types through the ActiveDirectory
  cmdlets, refuses an SPN another account holds (naming it, writing
  nothing), plans a new account report-only (creating nothing), and checks
  that add mode keeps an out-of-band SPN while exclusive mode removes it and
  a repeat changes nothing.
- `roles/wsfc/molecule/default`: a one-node **workgroup** cluster
  (access point `None`) on the same VM, never promoted: feature install,
  `Test-Cluster`, `New-Cluster`, network name/role/metric, common
  properties, node-majority quorum, idempotence, a report-only plan and a
  drift fix, then the `wsfc_cluster` module's integration target
  (`tests/integration/targets/wsfc_cluster`, with `setup_wsfc`): its own
  cluster planned in check mode, created, converged and drifted, with the
  repeat-changes-nothing check after each change, and the error messages;
  then sites, a preferred site and the node's vote the same way (0.13.0).
  Then the `wsfc_group` target (0.17.0): a one-node cluster of its own with a
  test group holding an offline Generic Application resource, converged,
  repeated, drifted and refused the same way.
- `roles/wsfc_fileserver/molecule/default`: **three VMs** on a lab network
  (dc01 = DC + iSCSI target + client, node1/node2 joined): `wsfc` builds a
  two-node cluster (AD access point, static address, storage validation, two
  formatted iSCSI disks, disk witness, management network role 0, a site
  per node with DC1 preferred and node2's vote taken, and `wsfc`'s `groups`
  entry point on `Cluster Group`), then `wsfc_fileserver` a file server with
  two shares; idempotence, `validate` from dc01, `failover` there and back, a
  report-only plan and drift fix, and last `wsfc`'s `failover` entry point on
  `Cluster Group` (out and back, cluster up, witness online). It's the only
  lab where a group moves.
  It's `wsfc`'s multi-node coverage and the slowest job (about 35 minutes
  when it passes; its `molecule test` limit is 120 minutes, the job's 150).
  First passed end to end on 2026-11-02 (PR #36, 697ddc7), after eleven red
  runs whose lessons are the gotchas below. A VM's QEMU occasionally
  vanished during first boot (ansible-collection-molecule issue 13). Since the
  driver's v0.4.0 that fails at the next poll, and `<vm>-qemu.log` says how QEMU
  stopped (printed by the failure step's `vm-screendump`, kept in the
  diagnostics artifact): re-run, and keep the log.

They share the lab in `tests/domain_lab/` and the Molecule base config
`.config/molecule/config.yml` (see Conventions). The promotion is
`git_cgallagher.molecule.ad_forest`, included once by
`tests/domain_lab/promote.yml` with the lab's hooks (GPMC in the features and
the readiness test, `Group Policy Creator Owners` in the admin groups, the
SYSVOL path wait), then included again to assert the bootstrap changes nothing
on a second run; lab-bootstrap bugs are fixed in that role, not here. The
workgroup labs (`wsfc`, `iis`) quiet their VM with the same collection's
`quiet_vm` role (`ad_forest` includes it itself), so no scenario carries its
own copy of that step. The lab first passed on
2026-10-28 (PR #1, the initial collection), which closed the lab-validation
issue (#2); the per-role layout came in 0.1.1. It can't run on macOS. Other CI:
ansible-lint/yamllint, ansible-test sanity (including pslint; stable
ansible-core branches only, no `devel` canary since 2026-11-01 by owner
decision), PowerShell parse + PSScriptAnalyzer and the modules' Pester unit
tests (the `powershell` job), the `hygiene` job (a `cpassword` grep), and the
`argument-specs` workflow. Known gaps found
by review are tracked as repo issues and listed
in the README's "What this doesn't do (yet)".

The IIS modules are lab-tested the same way, by their integration targets:
the `molecule (iis)` job boots the same box as a plain server (never a DC),
installs IIS and runs `tests/integration/targets/iis_mime_type` and
`iis_mime_type_info`: server, site and application levels, both
`config_file` stores, check and diff mode, overriding and hiding inherited
mappings, the refusal to override a level's own `web.config`, and the error
messages. The job first ran on 0.4.0's pull request. Its prepare step also
runs `setup_iis` twice and asserts the second run changed nothing (the
scenario has no idempotence step). Not covered: a section
locked at a parent level, content directories on UNC paths, and a host with
IIS but without its management tools (the lab installs them for the
targets' independent reads).

Not covered by the lab yet (issue #16 unless noted):

- importing into a *different* domain: link targets rebased onto another
  root DN, domain-relative trustee names, a migration table between domains
- `--check` runs of a whole play (the `gpo_import` role's module runs in check mode
  in the lab, through `gpo_import_report_only` and `apply: {check_mode:
  true}` on the role's include; `gpo_backup`'s check mode is covered by its
  scenario)
- security filtering on trustees other than domain groups and Authenticated
  Users, and Deny entries (the lab's GPOs have none)
- a member-server management host and a least-privilege account (#15);
  multi-query WMI filters aren't supported (#13)
- `wsfc` (#19): adding a node to an existing cluster (the lab creates both
  in one `New-Cluster`), the `Dns` access point, multi-subnet clusters, CSVs,
  file share and cloud witnesses (and a file share witness's `credential`),
  failover between sites, and a failing `Test-Cluster` (its failure
  detection matches `ClusterNotApproved` in the warning stream, unconfirmed).
  The three-VM scenario covers the rest of what #19 listed.
- `wsfc_fileserver`: Scale-Out File Server (not built), adding a disk to an
  existing file server, a multi-subnet client access point, encrypted shares.

`domain-lab` is deliberately not a required check: it's path-filtered (a
required check that never starts blocks merges forever) and depends on a
third-party box download. Promote its jobs, `molecule (gpo_backup)`,
`molecule (gpo_import)`, `molecule (wsfc)`, `molecule (iis)`,
`molecule (wsfc_fileserver)` and `molecule (mssql_prereqs)`, after four
consecutive green weekly runs each, and replace the path filter with a job that always reports and skips the lab
when nothing relevant changed.

When the lab disagrees with the scripts, fix the scripts — don't bend the
lab to the scripts — and record the surprise below as a gotcha.

## Conventions

- **Every CI job sets `timeout-minutes`** (2026-11-01): GitHub's default is 6
  hours, and a stalled install would hold the runner that long. The quick jobs
  get 15 minutes, several times their slowest green run; `domain-lab` keeps 120
  with step limits. A new job needs one too.
- PowerShell lives in `roles/*/files/*.ps1`, executed via
  `ansible.windows.win_powershell` with `parameters:`, or in a module under
  `plugins/modules/` (see the module bullets below); either way it must stay
  **Windows PowerShell 5.1-compatible** (no `??`, no ternary, no
  `ConvertFrom-Json -AsHashtable`). A script that takes parameters, returns a
  structured result and needs `check_mode: false` to compute its report is
  module-shaped: make it a module with real check-mode support, the way
  `backup_gpos.ps1` became `gpo_export` (0.5.0, issue #28; `gpo_sync_export`
  since 0.18.0) and `import_gpos.ps1` became `gpo_import` (0.6.0, issue #29;
  `gpo_sync_import` since 0.18.0) and
  `converge_cluster.ps1` became `wsfc_cluster` (0.7.0, issue #27).
- The GPO modules share `plugins/module_utils/_GpoCommon.psm1` (0.10.0; it
  was a `# region common` block copied into both): the pure logic, with no
  Ansible.Basic, AD or GPMC calls, so Pester tests it without a domain. That's
  hashing (`Get-DirContentHash`, whose line format is the recorded state's
  basis and is pinned by a unit test: never change it), the zip, the
  manifest's encodings (WMI filter `msWMI-Parm2`, relative DNs and trustee
  names), the export's scope and state decisions (`Get-GpoExportScope`,
  `Get-DeletedGpoEntry`), the import decision (`Get-GpoImportReason`), the
  import's scope and link plans (`Get-GpoImportScope`, `Get-GpoLinkPlan`,
  `Get-GpoSubsetLinkPlan`). A module keeps only what talks to Windows
  (and `Ansible.Basic`); new pure logic goes in the util, with a test.
- The clustering modules share `plugins/module_utils/_WsfcCommon.psm1`
  (0.13.0, issue #48's W9): the helpers that were inside `wsfc_cluster.ps1`
  (`Get-ShortName`, `Get-Setting`, `Get-ResourceTypeName`,
  `Test-NetworkMatch`) and the site and vote planners (`Get-WsfcSitePlan`,
  `Get-WsfcNodeWeightPlan`), which take what the cluster reports as plain
  hashtables and return the changes. `wsfc_group` (0.17.0) plans with its
  `Get-WsfcGroupPlan`, refusals included (an availability group's group is
  SQL Server's); the SQL Server modules will use it too, rather than copies.
  Lists in it are made with `[System.Collections.Generic.List[object]]::new()`
  (see Gotchas).
- The IIS modules share `plugins/module_utils/_IisConfig.psm1`: the calls
  into IIS's configuration API, resolving `site`/`application` to a
  configuration level (`Resolve-IisConfigLevel`), reading a level's MIME map
  and what the level stores itself, and (0.15.0, issue #47) the modules'
  decisions: the option checks (`Get-IisFileExtensionProblem`,
  `Test-IisMimeType`), add/change/remove against the effective map
  (`Get-IisMimeMapDecision`), the file to write (`Get-IisCommitTarget`,
  `Get-IisWebConfigOverride`), the change itself, committed only outside
  check mode (`Invoke-IisMimeMapChange`), and `iis_mime_type_info`'s list
  (`Get-IisMimeTypeList`). Its Pester tests run without IIS against
  `tests/unit/plugins/module_utils/IisFake.ps1`, a fake of the API behind a
  mock of the util's one call into it (`Invoke-IisComInvokeMember`).
- **Idempotency contract (owner rule, 2026-11-01):** a task reports
  `changed` only when it changed the target, and a second converge reports
  zero changes (Molecule's `idempotence` step). `--check` predicts without
  writing, declared honestly: never `check_mode: false` on a task that could
  write managed state. `gpo_import`'s staging tasks keep `check_mode: false`
  + `changed_when: false` because the staging directory is scratch the
  module needs to plan from, never managed state. A `*_report_only` role
  variable is sugar for check mode on the task
  (`check_mode: "{{ true if x | bool else omit }}"`: `omit` keeps the play's
  own check mode in force; a templated `false` would switch `--check` off
  for that task). A role that must stage files during `--check` (gpo_import
  copies the export so the module can plan) owes a **preflight** in return
  (owner decision, issue #41): check mode proves the real run could work
  (writable state directory, parseable inputs, reachable services) and
  fails with the reason instead of reporting a plan; the facts come back as
  `preflight`.
- **Check mode writes nothing on the management host** (owner rule,
  2026-11-01, issue #39): no working directory, no staging, no scratch
  files, no temp path, however short-lived. A module that needs data a write
  would produce reads the live source instead: `gpo_sync_export` hashes each GPO's
  Group Policy Template under `\\<dc>\SYSVOL\<domain>\Policies\{guid}`
  (minus `gpt.ini`) in both modes, so check mode and the real run decide from
  the same hash and `Backup-GPO` runs only for the GPOs that ship (0.8.0).
  The one exception, also the owner's: check mode must still **prove the
  export target can be written**, with a uniquely named probe file in the
  target directory (or its nearest existing parent) that is removed at once,
  reported under `preflight` with whether AD and GPMC answered, and a clear
  failure when the probe fails. The gpo_sync_import module does the same for its
  state directory, and also validates the manifest, backup folders and
  migration table and reads the domain, GPMC, links and WMI filters (issue
  #41, 0.9.0).
- `wsfc` passes its structured variables (quorum, networks, properties,
  disks) to `wsfc_cluster` as the module's typed nested options. In the
  module, a list option left out is `$null` and `@($null).Count` is 1, so
  `Get-ListParam` coalesces it to `@()`; a dict's sub-options arrive as a
  `Dictionary<string, object>` with every key present (`$null` when left
  out), and `properties` (a free-form dict) keeps its JSON types.
- `wsfc_cluster` reaches the cluster through a **node name**
  (`-Cluster <node>`), never the cluster name: a cluster with access point
  `None` has no name to resolve.
- `wsfc`'s cluster task sets `check_mode: "{{ wsfc_report_only | bool or
  ansible_check_mode }}"`. The `or ansible_check_mode` is load-bearing: a
  bare `"{{ wsfc_report_only | bool }}"` templates to `check_mode: false`
  under `--check` and the task would write during a check run. Never set
  `check_mode: false` on a task that could write (owner rule, issue #27).
- The manifest (`gpo-manifest.json`) is the contract between the roles.
  Round-trip symmetry is the invariant: whatever `gpo_backup` writes,
  `gpo_import` consumes verbatim. Change both sides and the README together.
- The backup zip is built entry by entry (`New-ZipFromDirectory`), never with
  `Compress-Archive` (drops empty directories, which GPO backups contain) or
  `ZipFile::CreateFromDirectory` (some .NET Framework/PowerShell 5.1
  combinations write backslash separators, which Linux `unzip` warns about
  and `unarchive` treats as failure). Entries use `/`; empty directories get
  explicit entries.
- **Role variables are declared in `roles/*/meta/argument_specs.yml`** (the
  reference, and what Ansible validates against). Required variables have no
  entry in `defaults/main.yml`; every other variable's spec `default` must
  equal its `defaults/main.yml` value. The `argument-specs` workflow
  (`tests/argument_specs/`) enforces both. Add or change a variable in the
  spec, defaults, README table and tasks together.
- **Molecule scenarios live with their role**, in
  `roles/<role>/molecule/<scenario>/`, never at the collection root. The one
  exception is the modules' runner in `tests/integration/molecule/` (see the
  module bullets below). What every scenario shares goes in
  `.config/molecule/config.yml` (Molecule's base config: the driver, with the
  box pin and VM size in `driver.options.platform_defaults`, provisioner,
  inventory, `lab_fixture`, test sequence) or in `tests/domain_lab/`
  (promotion, seeding, the fixture script); a scenario's `molecule.yml` holds
  only what differs. The VM's lifecycle is the `molecule-git-cgallagher`
  driver's (its `windows_vm` kind; see Gotchas). The shared platform is a
  Windows Server 2022 VM named `dc01`; a scenario that needs another machine
  (a member server, no domain) overrides `platforms` in its own
  `molecule.yml`. Molecule replaces the whole `platforms` list, so an
  override names its VM (`- name: iis01`) and the driver fills in the rest
  from `platform_defaults`; a platform entry can still override any of those
  fields.
  Playbooks reach the shared fixture through `lab_tests_dir`, and a
  scenario's own `files/` through `playbook_dir`. `roles/*/molecule` and
  `.config` are in `galaxy.yml`'s `build_ignore` and in the version-bump
  gate's ignore list, like `tests/`.
- Release flow mirrors `ansible-collection-isc`: every merge that changes
  shipped files must bump `galaxy.yml` + add a `CHANGELOG.md` entry
  (CI-enforced). After the merge's green `ansible-test` run on main,
  `release.yml` publishes that version to Galaxy and tags `v<version>` with
  a GitHub release; it also runs weekly as a self-heal and on demand.
  `GALAXY_API_KEY` lives in the main-only `galaxy` environment. **Merge one
  PR at a time** and let its release run finish first (see Gotchas).
- **Modules** live in `plugins/modules/<area>_<name>.ps1`, documented in a
  YAML sidecar next to each (`<area>_<name>.yml` with `DOCUMENTATION`,
  `EXAMPLES` and `RETURN`), with shared code in
  `plugins/module_utils/_<Name>.psm1` (the underscore marks it private to the
  collection). They use `Ansible.Basic` with the argument spec and `Create`
  at the top, before anything Windows-only: validate-modules runs the file
  under pwsh on Linux up to `Create` to read the spec. They support check
  mode, and stay Windows PowerShell 5.1-compatible and pslint-clean like the
  roles' scripts. A module's structured warnings go in a key of their own
  (`gpo_sync_import` returns `notices`) and through `$module.Warn()`: `warnings`
  is a reserved result key that Ansible consumes. The IIS modules use IIS's native configuration API
  (`Microsoft.ApplicationHost.AdminManager`/`WritableAdminManager`, what
  `appcmd.exe` uses), which ships with the `Web-Server` feature itself, and
  call it only through `_IisConfig.psm1`'s `Invoke-IisComMember` and
  `Set-IisElementValue`, never as `$element.Method()` (see Gotchas).
- **The testing standard** (owner rules, 2026-11-01, issue #44 and its
  comment): **every role has a Molecule scenario** in
  `roles/<role>/molecule/<scenario>/` with converge, idempotence and verify
  (see the Molecule bullet), and **every module has an ansible-test
  integration target and Pester unit tests**. A role's scenario that happens
  to call a module doesn't count for the module. No CI step checks this (the
  owner dropped the hygiene gate PR 46 first proposed, 2026-11-01): it's a
  rule every change follows, so a PR that adds or changes a role or module
  adds or updates its tests in the same PR. Every module has both since
  0.15.0 (issue #47 added the IIS modules' unit tests).
- **A module's unit tests** are Pester 5, in
  `tests/unit/plugins/modules/<name>.Tests.ps1`, with shared code's in
  `tests/unit/plugins/module_utils/<util>.Tests.ps1`; the `powershell` CI job
  runs them all with `Invoke-Pester` (see Commands). They test the module's
  pure logic (hashing, manifest and state decisions, plan computation,
  argument normalisation) without Windows or a domain, by importing the
  `plugins/module_utils/` file that holds it: extract a module's pure
  functions there rather than dot-sourcing the module (its body runs
  `Ansible.Basic`'s `Create` at once). Each module's file also checks its
  wiring: it loads the util, defines none of the util's functions itself, and
  calls nothing but its own functions, the util, PowerShell and the cmdlets
  of the Windows modules it needs. Tests use `$TestDrive` and must pass on
  pwsh on Linux and on Windows PowerShell 5.1 (`[Environment]::NewLine`
  where a format depends on it). Where behaviour must not drift (a hash
  format, a manifest encoding), pin a known value.
- **A module's integration target** is named after it, in
  `tests/integration/targets/<module>/`: `aliases` (`windows`),
  `meta/main.yml` (depends on the area's `setup_<area>` target) and
  `tasks/main.yml`. Each target covers at least: check mode
  predicts and writes nothing (assert the on-disk and in-domain state
  unchanged, and the preflight facts where the module has them); the real
  run applies the change and returns the documented result shape (every
  result key the `.yml` sidecar promises is present); a repeat run reports
  `changed: false`; each documented failure path (the `fail_json` messages),
  argument validation included; and the module's own options (a filter, a
  flag). The target's own setup and cleanup follow the idempotency contract
  too: a second run of the target on the same host is clean, so everything
  it creates it removes (`block`/`always`), in directories of its own, apart
  from the roles' defaults. Its reads go through the area's `setup_<area>`
  scripts (PowerShell against the real thing), never through the module
  under test, nor through a sibling module where a direct read exists.
  They're plain role tasks with no ansible-test-only variables, so they run
  both through `ansible-test windows-integration` against any Windows host
  and through Molecule in CI, from the scenario of the lab that has the right
  Windows box: one Molecule scenario per lab platform runs them, from
  `tests/integration`, whose `../../` depth matches `roles/<role>`, so the
  base config's relative paths hold: the IIS one is
  `tests/integration/molecule/iis/`. Its converge includes the targets as
  roles and drops Molecule's idempotence step, because the targets change
  things on purpose and check each module's idempotence themselves. The IIS
  targets check IIS through `setup_iis/files/read_mime_map.ps1` (appcmd.exe
  and the configuration files' XML). A target that needs a role's lab runs
  last from that role's scenario's verify.yml, after the role's own checks
  (`ANSIBLE_ROLES_PATH` in its molecule.yml points at
  `tests/integration/targets`): `wsfc_cluster` from `roles/wsfc` (a cluster
  needs the workgroup prerequisites its prepare.yml sets; the target removes
  the role's cluster, builds its own and removes it, reading through
  `setup_wsfc/files/cluster_state.ps1`) and then `wsfc_group` (it builds its
  own cluster with `wsfc_cluster`, adds a test group, and reads it through
  `setup_wsfc/files/group_state.ps1`), `gpo_sync_export` from `roles/gpo_backup`
  and `gpo_import` from `roles/gpo_import` (both need the promoted, seeded
  domain; `setup_gpo_lab` reads the domain's name from the host, checks the
  fixture is seeded, never seeds, since the fixture reports a change on every
  run, and provides `files/read_domain.ps1`, GPMC and AD, `read_export.ps1`,
  the zip and state file, and `new_migtable.ps1`; its `setup_gpo_lab_dir`,
  `C:\ProgramData\gpo-iac-test`, keeps the targets apart from the roles'
  state under `C:\ProgramData\gpo-iac`). The role scenarios keep role
  behaviour (staging, fetch/unpack, variables, `*_report_only`, the
  converge/idempotence of the role) and leave the module's behaviour to the
  targets. `gpo_sync_import`'s target builds its source with `gpo_sync_export`
  (the manifest is the two modules' contract) and its oracle is
  `read_domain.ps1`, so a `gpo_sync_export` bug can't hide a `gpo_sync_import` one.
  `setup_iis` creates the test website and application with
  `community.windows`'s IIS modules; that collection is a **test dependency**
  in `tests/integration/requirements.yml` (installed by ansible-test and by
  the `iis` scenario's dependency step; the lint image doesn't carry it and
  ansible-lint passes without it), never a `galaxy.yml` dependency. Keep the targets' own reads (`read_mime_map.ps1`, the inline
  reads) in PowerShell: the oracle must stay independent of the module under
  test and of any other IIS module.
- **No secret in a loop item.** `loop_control.label` shortens only the
  summary line; `-v` output and registered results keep the whole item. Loop
  over a projection without the secret (`mssql_prereqs` strips `password`
  with `map('dict2items') | map('rejectattr', 'key', 'equalto', 'password')
  | map('list') | map('items2dict')`) and look the secret up by name inside
  the task, as a module argument the module itself hides.
- **An empty `set` clears a `microsoft.ad` list option** (since 1.11.0 it's
  no longer ignored on creation): send `{set: []}` only when clearing is
  meant, as `mssql_prereqs_exclusive: true` does, and omit the option
  otherwise.
- **Every module needs `validate-modules:missing-gplv3-license` ignores** in
  `tests/sanity/ignore-2.18.txt` through `ignore-2.23.txt`, for its `.ps1`
  and its `.yml`: the collection is MIT, and validate-modules demands a GPLv3
  header in every module and sidecar. Add a new module's two files to every
  file, and a file per new ansible-core version CI tests.

## Commands

```bash
# lint, exactly as CI runs it: in the ansible-runtime image (pinned ansible-core,
# ansible-lint, yamllint, ansible.windows, microsoft.ad), through the same wrapper.
# Needs Docker. The image tag + digest live in ansible-test.yml's RUNTIME_IMAGE.
export RUNTIME_IMAGE=$(sed -n 's/^ *RUNTIME_IMAGE: //p' .github/workflows/ansible-test.yml)
.github/ci/runtime.sh yamllint . && .github/ci/runtime.sh ansible-lint

# ...or with your own tools at CI's versions: the image's constraints.txt (every
# tool version comes from RUNTIME_IMAGE, ansible-runtime's shared dependency model)
docker run --rm "$RUNTIME_IMAGE" cat /usr/share/ansible-runtime/constraints.txt > /tmp/constraints.txt
pip install -c /tmp/constraints.txt ansible-core ansible-lint yamllint
ansible-galaxy collection install -r requirements.yml -r tests/domain_lab/requirements.yml
yamllint . && ansible-lint

# PowerShell lint exactly as CI's `ansible-test sanity` pslint runs it — the
# settings ship inside ansible-core; Invoke-Formatter with the same -Settings
# auto-fixes brace/whitespace/indentation findings (how 0.1.0 was styled):
S=$(python3 -c 'import ansible_test, pathlib; print(pathlib.Path(ansible_test.__file__).parent / "_util/controller/sanity/pslint/settings.psd1")')
pwsh -c "Invoke-ScriptAnalyzer -Path roles -Recurse -Settings '$S'"

# the modules' Pester unit tests, as the powershell CI job runs them; without
# a local pwsh, in ansible-test's container (Pester 5.5+ is installed if missing)
docker run --rm -v "$PWD:/work:ro" -w /work --entrypoint pwsh quay.io/ansible/default-test-container:v2.21-4 -c \
  'Install-Module Pester -MinimumVersion 5.5.0 -Force -Scope CurrentUser -SkipPublisherCheck; $c = New-PesterConfiguration; $c.Run.Path = "tests/unit"; $c.Run.Exit = $true; Invoke-Pester -Configuration $c'

# argument specs (what the argument-specs workflow runs, in the image:
# .github/ci/runtime.sh bash -c '…' with the same lines): build + install the
# collection, render the role docs, check specs vs defaults and validation
ansible-galaxy collection build --force --output-path /tmp/dist
ansible-galaxy collection install /tmp/dist/git_cgallagher-windows-*.tar.gz -p /tmp/colls --force
ANSIBLE_COLLECTIONS_PATH=/tmp/colls:~/.ansible/collections ansible-doc -t role git_cgallagher.windows.gpo_import
ANSIBLE_COLLECTIONS_PATH=/tmp/colls:~/.ansible/collections ansible-playbook tests/argument_specs/validate.yml

# a role's Molecule scenario: Linux with /dev/kvm only, one at a time, from
# the role's directory (full setup in tests/domain_lab/README.md). The
# driver and its collection come from one tag of ansible-collection-molecule:
pip install ansible-core molecule \
  "molecule-git-cgallagher[windows] @ git+https://github.com/git-cgallagher/ansible-collection-molecule@v0.5.0"
ansible-galaxy collection install git+https://github.com/git-cgallagher/ansible-collection-molecule.git,v0.5.0
cd roles/gpo_import && molecule test
# on a Mac, from a role's directory: config and syntax (`molecule create`
# runs up to the /dev/kvm check)
cd roles/gpo_backup && molecule list && molecule syntax

# the IIS modules' integration targets, the same way but from tests/integration
cd tests/integration && molecule test -s iis
# or against a Windows host of your own that may get IIS, listed under
# [windows] in tests/integration/inventory.winrm (gitignored: it holds
# credentials), from an ansible_collections/git_cgallagher/windows checkout
ansible-test windows-integration iis_mime_type iis_mime_type_info

# sanity as CI runs it (validate-modules, pslint, yamllint, ...), from an
# ansible_collections/git_cgallagher/windows checkout
ansible-test sanity --docker default

# pslint without a local pwsh, in ansible-test's own container (it carries
# PSScriptAnalyzer and the extra PSSA-PSCustomUseLiteralPath rule)
P=$(python3 -c 'import ansible_test, pathlib; print(pathlib.Path(ansible_test.__file__).parent / "_util/controller/sanity/pslint")')
docker run --rm -v "$PWD:/work" -v "$P:/pslint:ro" --entrypoint pwsh quay.io/ansible/default-test-container:v2.21-4 \
  -c 'Invoke-ScriptAnalyzer -Path /work/plugins -Recurse -Settings /pslint/settings.psd1'

# build the tarball
ansible-galaxy collection build --force
```

## ⚠️ Gotchas

- **pwsh 7.6 can't `@()` a `List[object]` made with `New-Object`.**
  `@($list)` throws `ArgumentException: Argument types do not match` (from
  `PSToObjectArrayBinder`) when `$list` came from `New-Object
  System.Collections.Generic.List[object]`, whose result is wrapped in a
  PSObject; a `List[string]` and a list made with `::new()` are fine. The
  Pester run in ansible-test's container (pwsh 7.6.0) caught it in
  `_WsfcCommon.psm1` (0.13.0); Windows PowerShell 5.1 doesn't have the bug.
  In code Pester runs, make lists with
  `[System.Collections.Generic.List[object]]::new()`.

- **The fault domain cmdlets are CIM cmdlets without `-Cluster`.**
  `Get-`/`New-`/`Set-ClusterFaultDomain` act on the cluster of the node they
  run on, so `wsfc_cluster` plans sites only once the managing node is a
  member. Their reference doesn't document the returned objects. The lab
  (Windows Server 2022; PR #55's integration target logs every property)
  showed `root/MSCLUSTER:MSCluster_FaultDomain` instances whose CIM `Type`
  is numeric (Site 1000, Node 4000) while PowerShell's `Type` property reads
  `Site`/`Node`. `ParentName` holds the parent's name; `Parent` and
  `FaultDomain` hold a CIM reference, whose string is
  `MSCluster_FaultDomain (Id = "…")`, never a name. A node's fault domain is
  named by its short computer name, and `(Get-Cluster).PreferredSite` reads
  back as the site's name, a string. The module still takes types from the
  documented `-Type` filter, matches nodes by short name (Microsoft's
  examples also show FQDNs) and translates a preferred site given as an ID:
  cheap insurance for other versions. The parameters are
  `-FaultDomainType` (alias `-Type`) and `-FaultDomain` (alias `-Parent`).
  The labs' read scripts read sites through `Get-ClusterFaultDomainXML`, a
  different path from the module's.

- **`Move-ClusterGroup -Wait` returns when the move ends, not when the group
  is online.** `wsfc_group` (like `wsfc_fileserver`'s `failover_group.ps1`)
  then waits for the group to settle on the target: online there if it was
  online before, otherwise just owned there, since an offline group never
  comes online by moving.

- **A resource checks its private properties as a set.** Setting a Generic
  Application's `CommandLine` alone, while its required `CurrentDirectory`
  was still empty, failed with "Unable to save property changes" (PR #61's
  first lab run, 2026-11-05). `wsfc_group` writes all of a resource's
  changes in one `Set-ClusterParameter -Multiple` call, while still listing
  one action per property. A later run was refused again with all three of
  `CommandLine`, `CurrentDirectory` and `UseNetworkName = 1` together, most
  likely because `UseNetworkName` needs a network name in the group, which
  the test group lacks, so the integration target sets only the first two.
  `wsfc_group` now reports a failure's inner exceptions too, since the
  outer message says nothing more. The first run also showed that `Remove-Cluster`
  refuses a cluster that still has non-core groups ("It has non-core
  application groups which must be deleted"), so `setup_wsfc`'s
  `remove_cluster.ps1` removes those first.

- **Some private properties only apply when their resource restarts.**
  `Set-ClusterParameter` says so as a warning (the AG listener's
  `RegisterAllProvidersIP` and `HostRecordTTL` are the usual case).
  `wsfc_group` passes it on through `$module.Warn` and never restarts a
  resource: that's an outage the operator schedules. Failback window hours
  read back as 4294967295 (0xFFFFFFFF) for "no window", which the options
  spell `-1`.

- **A domain cluster starts with a site of its own.** On the three-VM lab
  (Windows Server 2022, AD access point) `New-Cluster` created
  `Site 10.42.0.0/24`, named after the nodes' subnet, with both nodes in
  it; the one-node workgroup cluster got none. `wsfc_sites` moves the nodes
  out, and the empty site stays, reported on each run (nothing is ever
  removed). The labs log `AutoAssignNodeSite`; whether the cluster later
  re-places nodes on its own is unconfirmed (the idempotence run saw none).

- **A cluster lab's shared disks come from an iSCSI target on the DC**, not
  from the driver: `FS-iSCSITarget-Server` on dc01 serves VHDX virtual disks,
  allowed by the nodes' lab addresses (`IPAddress:10.42.0.11`), and each
  node connects persistently. A LUN has the same UniqueId on every node (what
  `wsfc_disks` matches), and Windows' target supports the persistent
  reservations `Test-Cluster`'s storage tests need (confirmed by the first
  run, 2026-11-01: both nodes saw both disks and storage validation passed).

- **Every lab VM's management NIC is 10.0.2.15** (QEMU user networking,
  which carries WinRM and can't reach the other VMs). In a cluster lab it
  shows up as a cluster network on every node with duplicate addresses: the
  scenario skips `Test-Cluster`'s network tests (`wsfc_validate_ignore:
  [Network]`), keeps the cluster names off it (`*_ignore_networks`) and sets
  its role to none. If `New-Cluster` ever fails over it, the fix is per-VM
  user-network subnets in the driver, not here.

- **`New-Cluster -IgnoreNetwork` doesn't always keep the cluster name off a
  network.** The third three-VM run (2026-11-01, PR #36) built the cluster
  with `-IgnoreNetwork 10.0.2.0/24`, and the cluster name still had two IP
  Address resources: 10.42.0.100 and a DHCP 10.0.2.15 on the management
  network (the file server's `Add-ClusterFileServerRole -IgnoreNetwork` was
  fine). The `wsfc_cluster` module now removes a cluster name address on an
  ignored network (step 3b), never the last one. The same run passed
  create, prepare, converge (cluster and file server) and idempotence.

- **A delegated task takes `become` from the host it's delegated to.**
  `wsfc_fileserver`'s client checks run on a host outside the cluster's
  inventory group (dc01 in the lab, whose role variables are in `group_vars`
  `lab_nodes`). Ansible resolved `become`, `become_user` and
  `ansible_become_password` from dc01's variables, which fell back to the
  role's empty defaults: no `runas`, a plain WinRM logon (which on a DC is the
  same `GPOLAB\vagrant`, so the identity looked right) with no credentials to
  pass on, and `Access is denied` on every share call (the double hop).
  Module arguments, by contrast, came from the cluster node's variables. It cost
  eight lab runs (2026-11-01/02, PR #36) and three wrong theories (the share
  root, timing, provider reads) before a diagnostic task with its own
  `become`, reading `group_vars` `all`, did every operation fine. The role now
  `set_fact`s the resolved account on the cluster nodes and, with
  `delegate_facts: true`, on the client, and the delegated tasks use those
  facts.

- **Don't take a node's computer name from `ansible_facts.hostname`.** On
  the three-VM lab's slow nodes, `ansible.windows.setup` (`min` subset)
  warned "Failed to collect platform due to timeout" and left the fact unset,
  and `wsfc` failed with "object of type 'dict' has no attribute 'hostname'"
  (2026-11-01, PR #36). The role reads `$env:COMPUTERNAME` with
  `win_powershell` instead, which has no collector timeout.

- **`win_powershell` renders anything nested deeper than `Result.x[i]` as its
  type name.** A list of hashtables inside a hashtable in `$Ansible.Result`
  came back as `"System.Collections.Hashtable"` strings. Keep result lists of
  objects at the top level, and nested lists as strings.

- **`New-Cluster` puts a static address only on a network with a default
  gateway.** At creation, the client role (ClusterAndClient, the only one
  that can hold the cluster name's address) goes only to networks whose NICs
  have a gateway; the lab network had none, and the first three-VM run
  (2026-11-01, PR #36) failed with "Static address '10.42.0.100' was given
  for the Cluster Name but no appropriate ClusterandClient network was
  found". The scenario's prepare gives each node's lab NIC a default route
  to an unused 10.42.0.1 at metric 5000 (management traffic keeps its own
  gateway). The same run confirmed the rest of prepare: the domain, the
  joins, the iSCSI disks, `Test-Cluster` with storage tests and the `runas`
  double hop as `GPOLAB\vagrant`.

- **`Set-GPInheritance` can return without an error and change nothing.** On
  a fresh lab DC the drift's unblock of the Workstations OU once didn't take
  (issue #50, PR #49's first `gpo_import` lab run), and the target's plan check
  then failed far from the cause. `lab_fixture.ps1` sets inheritance only
  through `Set-LabInheritance` (read back, retry, throw), and the target's
  "Check the drift took" asserts it. Read back any other fixture write that a
  later check depends on.

- **`wsfc`'s cluster task sets `become` itself** (from
  `wsfc_become_user`), which overrides a play-level `become` for that
  task. `New-Cluster` and friends hit the WinRM double hop on multi-node
  clusters; `runas` become gives a local logon with credentials. The lab uses
  it too (as `vagrant`).

- **The FailoverClusters cmdlets have no `-Confirm`, and `New-Cluster` still
  prompts.** Learned in the wsfc lab runs of 2026-10-31 (PR #20): `New-Cluster`
  failed with "PowerShell is in NonInteractive mode" after validation passed,
  and adding `-Confirm:$false` failed with "A parameter cannot be found that
  matches parameter name 'Confirm'" (the cmdlets don't implement
  ShouldProcess). The fix is `New-Cluster -Force`, but `-Force` also wipes
  stale cluster configuration off the nodes, so `wsfc_cluster` first
  refuses if any node still has `Cluster\CLUSDB` with no cluster answering
  (`Assert-NoClusterDatabase`).

- **A passing `Test-Cluster` reports `ClusterConditionallyApproved`**, not a
  plain "approved", when tests are skipped (the lab skips Storage). The role
  fails only on `ClusterNotApproved`; that failure string isn't confirmed in
  a lab yet.

- **Write GPO AD objects through GPMC (or LDAP), never `Set-ADObject`.**
  Confirmed in the domain_lab runs of 2026-10-28: `Set-ADObject` (AD Web
  Services) on a GPO's `groupPolicyContainer` fails with 8344 "insufficient
  access rights" even though the session's token holds Domain Admins,
  BUILTIN\Administrators and Group Policy Creator Owners (checked with
  `whoami /groups` on the DC itself, so not a double hop). GPMC's writes and
  ADSI/LDAP writes to the same objects succeed. The exact ADWS cause is
  unknown. The roles link and clear WMI filters with `Gpo.WmiFilter` (clearing
  with `$null` is verified); the fixture uses ADSI for writes GPMC can't
  express. ADWS *creates* (`New-ADObject` for `msWMI-Som`) do work.
- **`Import-GPO` re-serializes security templates.** An imported GPO's
  `GptTmpl.inf` has GPMC's canonical section order and sorted Restricted
  Groups members, so it's byte-different from the backup even when every
  setting matches. Compare security templates semantically, and expect the
  first export after an import to re-ship such GPOs once (the next one ships
  nothing). Matters for the "adopt without reimporting" design (issue #9).
- **`Import-GPO` restores GPO status** (the computer/user halves), unlike
  links, filtering and the WMI filter link.
- **`gpo_sync_export`'s `gpo_names` is ship scope only.** The manifest loop goes
  over `$all`, not `$live`, and a filtered run carries every state entry it
  doesn't rewrite (`Get-GpoExportScope`). Building the manifest from the
  selected GPOs only, to save the `Get-GPPermission` calls, reopens issue
  #37: the repo's manifest loses the other GPOs and the next full run
  reports `manifest_changed` on an unchanged domain. `gpo_sync_import`'s
  `gpo_names` scopes the WMI filters and links as well (issue #57), so the
  whole-domain manifest doesn't drag the other GPOs into a subset import.
- **A subset import's link orders are absolute.** `New-GPLink`/`Set-GPLink
  -Order` take positions on the whole container, which also holds links the
  run must leave alone, so `Get-GpoSubsetLinkPlan` places each selected GPO
  right after its manifest predecessor instead of planning on filtered
  lists (which yields relative orders and never converges). Feeding a merged
  list to `Get-GpoLinkPlan` doesn't work either: it emits `set` operations
  on the other GPOs' links. The Pester test's random containers prove one
  pass converges; run them after any change to either planner.
- **After promoting a DC, wait for `\\<domain>\SYSVOL` itself**, not just
  the SYSVOL share and `SysvolReady`. Group Policy Preferences cmdlets write
  through the domain's DFS path, which failed with "The network path was not
  found" in one lab run 6 seconds after the other checks passed.
  `tests/domain_lab/promote.yml` sets `ad_forest_wait_sysvol_path`, and the
  role polls `Test-Path \\<domain>\SYSVOL\<domain>\Policies`.
- **The lab bootstrap's idempotence is only partly asserted.** `promote.yml`
  runs `ad_forest` twice and asserts on the results the role registers (the
  forest, the SYSVOL wait, the groups); its DNS client, feature and quiet
  tasks aren't registered, so their `changed` shows only in the lab log. PR
  #33's first lab runs (2026-11-01, driver v0.2.1) caught `win_dns_client`
  changing on every run that way: promotion adds `::1` and the role listed
  only `127.0.0.1`. Fixed in the molecule collection's 0.3.0 (its issue 11),
  which the labs pin. A lab-bootstrap surprise is fixed in that role, then
  the assert extended there, not patched around in promote.yml.
- **The effective domain password policy** follows link order at the domain
  root after `gpupdate /target:computer /force` on the PDC (the first refresh
  after promotion took about 90 seconds in the lab).

- **`ansible-test sanity` runs pslint over every `*.ps1` in the collection**,
  `roles/*/files/` included, with ansible-core's own `settings.psd1`:
  uncuddled `else`/`catch`/`finally` (close brace gets its own line), no
  aligned `=` columns, 4-space pipeline indentation. PR #1 (the initial
  collection PR) failed all five sanity jobs on 72 style findings; the fix is
  the `Invoke-Formatter` command above, not hand-editing.
- **On a pull request, `domain-lab`'s `paths:` filter matches the whole PR
  diff, not the pushed commit.** Once a PR touches `roles/**` or
  `molecule/**`, every push to it re-runs the 14-minute lab, docs-only
  pushes included (PR #1's last docs commit did). Batch the doc edits.
- **Merge one PR at a time and wait for its release run.** `release.yml`
  tags the merge commit it was triggered for. If another PR merges first,
  `GITHUB_TOKEN` can't tag the older commit (its workflows differ from
  main's), so `gh release create` fails with HTTP 403 "Resource not
  accessible by integration": Galaxy still gets the version, but the GitHub
  release is lost. Learned on ansible-collection-isc 1.3.1 (2026-10-28).
- **The VM comes from the `molecule-git-cgallagher` driver**
  (`git-cgallagher/ansible-collection-molecule`, which started as this lab's
  `create.yml`/`destroy.yml`; the lab moved onto it on 2026-11-01). The base
  config's `driver.options.platform_defaults` holds `kind: windows_vm` and
  the box, and Molecule's inventory is built from each platform entry as
  written, so `platform_defaults` can't set `name`, `groups` or `children`.
  A platform key the `windows_vm` kind doesn't know fails the run (check
  the driver's README). `MOLECULE_LAB_DIR` (default `~/.cache/molecule-lab`)
  holds the box cache and VM disk, and the scenarios' `lab_dir` reads the
  same variable, so the GPO exports sit next to them. `domain-lab.yml` pins
  the driver by commit in two `uses:` lines (`setup-molecule`,
  `vm-screendump`); bump them together, along with the tag in the install
  lines above and in `tests/domain_lab/README.md`.
- **The labs download no collection from Galaxy** (since driver v0.5.0,
  after two lab jobs were lost to Galaxy errors on 2026-11-02). setup-molecule's
  `collections-image` copies every collection out of the ansible-runtime image
  `ansible-test.yml` pins (except `git_cgallagher.molecule`, from the action's
  own commit), and `tests/domain_lab/requirements.yml` and
  `tests/integration/requirements.yml` are only checked against them, offline.
  So a collection or minimum the labs newly need goes into ansible-runtime's
  `requirements/collections.yml` first; until an image with it is pinned, the
  setup step fails and names the file. Molecule's own `dependency` step then
  finds everything installed ("Nothing to do").
- **A composite action's steps can't set `timeout-minutes`** (the runner's
  `action_yaml.json` schema has no such key), so the 10-minute guard the
  KVM/QEMU install step got after a stuck apt hung a run for two hours
  (2026-11-01) sits on the `setup-molecule` step in `domain-lab.yml`, as 15
  minutes because that step also installs pip packages and collections.
  Since the driver's v0.2.1 the action also limits its own `apt-get` calls
  (3 minutes for update, 8 for install) and fails with a message to re-run,
  so the step limit is a backstop.
- **Molecule's base config is implicit.** `.config/molecule/config.yml` at
  the repository root is merged under every scenario's `molecule.yml`
  because `--base-config` defaults to it (Molecule logs "Found config
  file"), so a role's `molecule.yml` holds almost nothing. Look there before
  concluding a scenario has no platform or inventory.
- **Run Molecule from the role's directory**, not with `-s` from the
  repository root. Molecule finds scenarios under the working directory, and
  ansible-compat's prerun recognizes a role inside a collection only by the
  working directory (`roles/<name>` with `../../galaxy.yml`): from there it
  installs the collection from disk instead of treating the role as a
  standalone one and checking its name. CI sets `working-directory`.
- **ansible-lint treats a role's Molecule playbooks as role code.**
  `var-naming[no-role-prefix]` wants every `register:` under
  `roles/<role>/molecule/` named with the role's prefix (10 findings when
  the scenarios moved there in 0.1.1). Those files are listed in
  `.ansible-lint-ignore` with `skip`: add a line when another scenario file
  starts registering results, rather than renaming test results into the
  role's namespace or skipping the rule for the roles themselves.
- `Import-GPO` **replaces the whole GPO** and bumps its version (clients
  reprocess). That's why both roles hash content and keep state files
  (`C:\ProgramData\gpo-iac\*-state-<domain>.json` on the management host) —
  don't "simplify" that away. `gpo_sync_export`'s state hashes the live SYSVOL
  template (`hash_basis: sysvol`, 0.8.0); a state file without that key came
  from the backup-basis hash of 0.5.0–0.7.x and never matches, so the first
  export after upgrading re-ships every GPO once.
- Security filtering: never remove a trustee's last permission — downgrade
  Apply→Read (MS16-072). The import does this; keep it that way.
- Trustee names in the manifest are domain-relative (source NetBIOS prefix
  stripped) — that's deliberate cross-domain behaviour, not a bug.
- GPP `cpassword`: the import hard-fails on it, CI greps for it. Never
  weaken either check.
- GPO backups embed SIDs/domain names. Fine for the *consuming* (usually
  private) repo; never commit real-domain backups to THIS public repo —
  examples use `example.com` placeholders only.
- **ansible-test's pslint has one more rule than a local
  `Invoke-ScriptAnalyzer` with its settings file**: `PSSA-PSCustomUseLiteralPath`
  (`-LiteralPath`, never `-Path`, on cmdlets that take both). A local run
  without that module misses it; run the container command above, or write
  `-LiteralPath` throughout.
- **Don't call `$module.FailJson` inside a `try` block.** It exits by
  running `exit` from C#. On pwsh 7.6 that passes through the surrounding
  `try`/`catch` (probed in ansible-test's container), but a `catch` that did
  catch it would report a second failure. The IIS modules record a refusal
  inside the block and fail after it, and call `FailJson` in `catch` blocks.
- **PowerShell's own COM binding can't call IIS's configuration API.** On
  the lab VM (Windows Server 2022, Windows PowerShell 5.1), the first method
  call on a `Microsoft.ApplicationHost.AdminManager` object threw `Object
  reference not set to an instance of an object.` from PowerShell's binder
  (`ComInterop.IDispatchComObject.EnsureScanDefinedMethods`) before IIS saw
  the call, on MTA and STA threads alike, and `Get-Member` lists no members
  (the class is registered `ThreadingModel=Both`, so it isn't an apartment
  problem). `Type.InvokeMember` over IDispatch, the way VBScript calls these
  objects, works, and so does Microsoft.Web.Administration.
  `_IisConfig.psm1` sends every call through `Invoke-IisComMember` /
  `Set-IisElementValue`, which also pass arguments as base objects (IIS
  must get its own element back, not a PSObject) and rethrow IIS's
  COMException rather than PowerShell's `Exception calling "InvokeMember"`
  wrapper. Found on 0.4.0's pull request (#22), whose first lab runs failed
  this way.
- **ansible-core 2.19+ renders a template that is one expression as its
  native type.** `fail_msg: "{{ result }}"` becomes a dict, and `assert`
  checks that `fail_msg` is a string or a list of strings before it
  evaluates `that`, so even a passing assertion fails with `argument
  'fail_msg' is of type dict`. End such a `fail_msg` in `| string`, or put
  text around the expression.
- **IIS doesn't say where a collection entry is defined.** [MC-IISA]
  documents a `deepestPathSet` metadata for elements, but on the lab VM
  (IIS 10, Windows Server 2022) `GetMetadata('deepestPathSet')` on a MIME
  map entry returns ERROR_NOT_SUPPORTED, and Microsoft.Web.Administration's
  `IsLocallyStored` is per file, so it can't tell a `<location>` entry from a
  server-level one in `applicationHost.config`. `iis_mime_type_info` decides
  `inherited` by comparing with the parent level's map and, for an entry
  that repeats the parent's mapping, by reading the level's own `<location>`
  element and `web.config` (`Get-IisStoredMimeMapExtension`, which follows
  `redirection.config` for shared configuration). It doesn't read a
  `<location>` element in a parent level's `web.config` that targets the
  level. The lab's website redefines `.png` with the MIME type it inherits
  to test this.
- **`ansible.windows.win_powershell` serializes results only 2 levels deep
  by default**; a dict of lists of dicts comes back with the inner dicts as
  strings. The IIS targets pass `depth: 5` to every read.
- **A template made only of Jinja tags renders to `None` when it outputs
  nothing** (ansible-core 2.21.5 in the ansible-runtime image, found
  building `mssql_prereqs`, 2026-11-02): `{%- for … -%}…{%- endfor -%}` over
  an empty loop gave `None`, so `| length` failed. Build such lists in a
  `namespace` (`{%- set found.items = found.items + [x] -%}`) and end the
  template with `{{ found.items }}`.
- **A role's `vars/main.yml` isn't visible after `include_role` without
  `public: true`**; facts the role sets are. The argument-specs test of
  `mssql_prereqs`' plan includes it with `public: true`.
- **A KDS root key is usable 10 hours after its effective time**, so a lab
  that needs a gMSA at once backdates its key
  (`Add-KdsRootKey -EffectiveTime (Get-Date).AddHours(-10)`, in
  `mssql_prereqs`' prepare). `mssql_prereqs_kds_root_key: create` makes a
  key that waits the 10 hours.
- **`Get-KdsRootKey` emits `$null` when the forest has no key**, so a plain
  `@(Get-KdsRootKey).Count` is 1 on a fresh forest. PR #52's first lab run
  (2026-11-02) skipped its pre-key tests and its own key creation that way,
  and the role then rightly found no key. Count with
  `@(Get-KdsRootKey | Where-Object { $null -ne $_ }).Count`.
  (`microsoft.ad.kds_root_key_info` is fine: it loops over the cmdlet's
  output, and PowerShell doesn't iterate over a lone `$null`.)
- **The `microsoft.ad` modules resolve principals even in check mode.** A
  gMSA whose `allowed_to_retrieve_password` names a group the same run only
  *plans* failed `mssql_prereqs`' report-only plan with "Failed to find the AD
  object DNs" (PR #52's second lab run, 2026-11-02). The role now passes
  `lookup_failure_action: warn` in check mode for a list that names one of its
  own groups (gMSA retrievers and group members), and `fail` otherwise.
