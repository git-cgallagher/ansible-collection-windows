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
  The export itself is the `gpo_export` module (0.5.0), which the role calls;
  the role fetches and unpacks the zip on the controller.
- `roles/gpo_import` — converge a target domain on the repo: stages the
  export and runs the module `plugins/modules/gpo_import` (0.6.0; it was the
  role's `files/import_gpos.ps1` through `win_powershell` before), which
  imports and reconciles topology, migration-table aware, with real check
  and diff mode. `gpo_import_report_only` is check mode on that task.

Its second area is **failover clustering** (0.3.0):

- `roles/wsfc` — install Failover Clustering on every host in the
  play, then from one managing node validate, create the cluster (or add
  missing nodes) and converge networks, common properties, named shared
  disks and the quorum witness, through the `wsfc_cluster` module
  (`plugins/modules/wsfc_cluster.ps1`, which was the role's
  `files/converge_cluster.ps1` until 0.7.0). It's the base
  for file servers, SQL Server FCIs and AGs; it doesn't install SQL Server or
  create shares or AGs. The role is plain `wsfc` (owner's choice,
  2026-10-31; it was `wsfc_cluster` before PR #20 merged), so its variables
  are `wsfc_*`. A later role in this area, say `wsfc_fileserver`, gets
  variables `wsfc_fileserver_*`: don't add a `wsfc_` variable whose name
  starts with another role's suffix (`wsfc_fileserver_…`).

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
  Then the `gpo_export` module's integration target
  (`tests/integration/targets/gpo_export`, with `setup_gpo_lab`), which owns
  the module's checks since 0.10.0: check mode against a missing working
  directory (every GPO planned, the parent probed, nothing created), the
  real export (the zip's layout, the state file, the manifest against the
  fixture: links in precedence order, enforced and disabled links,
  block-inheritance, filtering, the WMI filter, status), the repeat, check
  mode leaving the working directory byte-for-byte as it was, a changed GPO
  shipping alone, a new and a deleted GPO, the `gpo_names` filter (deletion
  detection skipped, the other GPOs' state kept) and the failures (a missing
  `domain`, an ACL-denied working directory, one with no existing parent,
  two GPOs mapping to one folder name), in a working directory of its own.
- `roles/gpo_import/molecule/default`: the role's behaviour: seed, export,
  out-of-band drift, report-only plan (the role's `gpo_import_report_only`:
  predicts the drift, recreates nothing, writes no state file), import,
  idempotence, verify (the domain read through GPMC, the effective password
  policy, a check-mode re-plan of the role with zero actions and no change,
  the re-export round trip) and an import through a migration table staged
  from a relative path. Then the `gpo_import` module's integration target
  (`tests/integration/targets/gpo_import`, with `setup_gpo_lab`), which owns
  the module's checks since 0.10.0: the authored domain exported and
  unpacked into a source directory of its own, the first plan (every GPO
  "never imported", the preflight facts, no state file, no probe file, the
  domain untouched down to GPO versions), the import, the repeat, the
  fixture's drift, the plans against it (the defaults failing on the missing
  WMI filter with the unmanaged link noticed, then `create_wmi_filters` and
  `remove_unmanaged_links` planning the fixes, and nothing touched), the
  forced converge back to the authored state and the repeat, the migration
  table (the import key, the repeat, the import without it), and the
  failures (a missing `source_dir`, a missing migration table, the cpassword
  refusal, an incomplete backup folder, a missing manifest, a GPO missing
  from both domain and export, an ACL-denied `state_dir`), each leaving the
  domain and the state file as they were.
- `roles/wsfc/molecule/default`: a one-node **workgroup** cluster
  (access point `None`) on the same VM, never promoted: feature install,
  `Test-Cluster`, `New-Cluster`, network name/role/metric, common
  properties, node-majority quorum, idempotence, a report-only plan and a
  drift fix, then the `wsfc_cluster` module's integration target
  (`tests/integration/targets/wsfc_cluster`, with `setup_wsfc`): its own
  cluster planned in check mode, created, converged and drifted, with the
  repeat-changes-nothing check after each change, and the error messages.

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
- `--check` runs of a whole play (`gpo_import`'s module runs in check mode
  in the lab, through `gpo_import_report_only` and `apply: {check_mode:
  true}` on the role's include; `gpo_backup`'s check mode is covered by its
  scenario)
- security filtering on trustees other than domain groups and Authenticated
  Users, and Deny entries (the lab's GPOs have none)
- a member-server management host and a least-privilege account (#15);
  multi-query WMI filters aren't supported (#13)
- `wsfc` (#19, the multi-node lab): adding nodes, the
  `ActiveDirectoryAndDns`/`Dns` access points and static addresses, shared
  disks (format, CSV), disk/file share/cloud witnesses, a failing
  `Test-Cluster` (its failure detection matches `ClusterNotApproved` in the
  warning stream, unconfirmed) and the double hop. Each lab VM has its own
  QEMU user-mode network, but the driver's `lab_networks` puts several
  `windows_vm` platforms on one shared segment (its `windows_cluster`
  scenario boots two), so what's missing first is an iSCSI target for the
  shared disks.

`domain-lab` is deliberately not a required check: it's path-filtered (a
required check that never starts blocks merges forever) and depends on a
third-party box download. Promote its jobs, `molecule (gpo_backup)`,
`molecule (gpo_import)`, `molecule (wsfc)` and `molecule (iis)`, after four
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
  `backup_gpos.ps1` became `gpo_export` (0.5.0, issue #28) and
  `import_gpos.ps1` became `gpo_import` (0.6.0, issue #29) and
  `converge_cluster.ps1` became `wsfc_cluster` (0.7.0, issue #27).
- The GPO modules share `plugins/module_utils/_GpoCommon.psm1` (0.10.0; it
  was a `# region common` block copied into both): the pure logic, with no
  Ansible.Basic, AD or GPMC calls, so Pester tests it without a domain. That's
  hashing (`Get-DirContentHash`, whose line format is the recorded state's
  basis and is pinned by a unit test: never change it), the zip, the
  manifest's encodings (WMI filter `msWMI-Parm2`, relative DNs and trustee
  names), the export's state decisions (`Get-CarriedOverGpoState`,
  `Get-DeletedGpoEntry`), the import decision (`Get-GpoImportReason`) and the
  link plan (`Get-GpoLinkPlan`). A module keeps only what talks to Windows
  (and `Ansible.Basic`); new pure logic goes in the util, with a test.
  `wsfc_cluster.ps1` shares nothing with them.
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
  would produce reads the live source instead: `gpo_export` hashes each GPO's
  Group Policy Template under `\\<dc>\SYSVOL\<domain>\Policies\{guid}`
  (minus `gpt.ini`) in both modes, so check mode and the real run decide from
  the same hash and `Backup-GPO` runs only for the GPOs that ship (0.8.0).
  The one exception, also the owner's: check mode must still **prove the
  export target can be written**, with a uniquely named probe file in the
  target directory (or its nearest existing parent) that is removed at once,
  reported under `preflight` with whether AD and GPMC answered, and a clear
  failure when the probe fails. The gpo_import module does the same for its
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
  (`gpo_import` returns `notices`) and through `$module.Warn()`: `warnings`
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
  adds or updates its tests in the same PR. Still owed: the unit tests of
  `wsfc_cluster`, `iis_mime_type` and `iis_mime_type_info` (issue #47).
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
  `setup_wsfc/files/cluster_state.ps1`), `gpo_export` from `roles/gpo_backup`
  and `gpo_import` from `roles/gpo_import` (both need the promoted, seeded
  domain; `setup_gpo_lab` reads the domain's name from the host, checks the
  fixture is seeded, never seeds, since the fixture reports a change on every
  run, and provides `files/read_domain.ps1`, GPMC and AD, `read_export.ps1`,
  the zip and state file, and `new_migtable.ps1`; its `setup_gpo_lab_dir`,
  `C:\ProgramData\gpo-iac-test`, keeps the targets apart from the roles'
  state under `C:\ProgramData\gpo-iac`). The role scenarios keep role
  behaviour (staging, fetch/unpack, variables, `*_report_only`, the
  converge/idempotence of the role) and leave the module's behaviour to the
  targets. `gpo_import`'s target builds its source with `gpo_export`
  (the manifest is the two modules' contract) and its oracle is
  `read_domain.ps1`, so a `gpo_export` bug can't hide a `gpo_import` one.
  `setup_iis` creates the test website and application with
  `community.windows`'s IIS modules; that collection is a **test dependency**
  in `tests/integration/requirements.yml` (installed by ansible-test and by
  the `iis` scenario's dependency step; the lint image doesn't carry it and
  ansible-lint passes without it), never a `galaxy.yml` dependency. Keep the targets' own reads (`read_mime_map.ps1`, the inline
  reads) in PowerShell: the oracle must stay independent of the module under
  test and of any other IIS module.
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
  "molecule-git-cgallagher[windows] @ git+https://github.com/git-cgallagher/ansible-collection-molecule@v0.3.1"
ansible-galaxy collection install git+https://github.com/git-cgallagher/ansible-collection-molecule.git,v0.3.1
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
  don't "simplify" that away. `gpo_export`'s state hashes the live SYSVOL
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
