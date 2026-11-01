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
- `roles/gpo_import` — converge a target domain on the repo (import +
  reconcile topology; migration-table aware; report-only mode).

Its second area is **failover clustering** (0.3.0):

- `roles/wsfc` — install Failover Clustering on every host in the
  play, then from one managing node validate, create the cluster (or add
  missing nodes) and converge networks, common properties, named shared
  disks and the quorum witness (`files/converge_cluster.ps1`). It's the base
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

- `roles/gpo_backup/molecule/default`: the export, its manifest and backup
  folders, an unchanged domain shipping nothing and a changed GPO shipping
  alone.
- `roles/gpo_import/molecule/default`: seed, export, out-of-band drift,
  report-only plan, import, verify, re-export round trip, and an import
  through a migration table.
- `roles/wsfc/molecule/default`: a one-node **workgroup** cluster
  (access point `None`) on the same VM, never promoted: feature install,
  `Test-Cluster`, `New-Cluster`, network name/role/metric, common
  properties, node-majority quorum, idempotence, a report-only plan and a
  drift fix.

They share the lab in `tests/domain_lab/` and the Molecule base config
`.config/molecule/config.yml` (see Conventions). The lab first passed on
2026-10-28 (PR #1, the initial collection), which closed the lab-validation
issue (#2); the per-role layout came in 0.1.1. It can't run on macOS. Other CI:
ansible-lint/yamllint, ansible-test sanity (including pslint), PowerShell
parse + PSScriptAnalyzer, a `cpassword` grep, and the `argument-specs`
workflow. Known gaps found by review are tracked as repo issues and listed
in the README's "What this doesn't do (yet)".

The IIS modules are lab-tested the same way, by their integration targets:
the `molecule (iis)` job boots the same box as a plain server (never a DC),
installs IIS and runs `tests/integration/targets/iis_mime_type` and
`iis_mime_type_info`: server, site and application levels, both
`config_file` stores, check and diff mode, overriding and hiding inherited
mappings, the refusal to override a level's own `web.config`, and the error
messages. The job first ran on 0.4.0's pull request. Not covered: a section
locked at a parent level, content directories on UNC paths, and a host with
IIS but without its management tools (the lab installs them for the
targets' independent reads).

Not covered by the lab yet (issue #16 unless noted):

- importing into a *different* domain: link targets rebased onto another
  root DN, domain-relative trustee names, a migration table between domains
- `--check` runs (`gpo_import` maps check mode onto report-only, which is
  covered; `gpo_backup` has its own check-mode path)
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

- PowerShell lives in `roles/*/files/*.ps1`, executed via
  `ansible.windows.win_powershell` with `parameters:`; scripts must stay
  **Windows PowerShell 5.1-compatible** (no `??`, no ternary, no
  `ConvertFrom-Json -AsHashtable`).
- Both GPO scripts duplicate a small `# region common` helper block — keep
  the copies in sync. `converge_cluster.ps1` shares nothing with them.
- `wsfc` passes its structured variables (quorum, networks,
  properties, disks) to PowerShell as JSON strings. Windows PowerShell 5.1's
  `ConvertFrom-Json` emits a JSON array as one object, so enumerate it
  (`ConvertFrom-JsonArray`) instead of wrapping it in `@()`, which turns `[]`
  into a one-element array.
- `wsfc` reaches the cluster through a **node name**
  (`-Cluster <node>`), never the cluster name: a cluster with access point
  `None` has no name to resolve.
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
  roles' scripts. The IIS modules use IIS's native configuration API
  (`Microsoft.ApplicationHost.AdminManager`/`WritableAdminManager`, what
  `appcmd.exe` uses), which ships with the `Web-Server` feature itself, and
  call it only through `_IisConfig.psm1`'s `Invoke-IisComMember` and
  `Set-IisElementValue`, never as `$element.Method()` (see Gotchas).
- **A module's tests are an ansible-test integration target named after
  it**, in `tests/integration/targets/<module>/`: `aliases` (`windows`),
  `meta/main.yml` (depends on the area's `setup_<area>` target) and `tasks/`.
  They're plain role tasks with no ansible-test-only variables, so they run
  both through `ansible-test windows-integration` against any Windows host
  and through Molecule in CI. One Molecule scenario per lab platform runs
  them, from `tests/integration`, whose `../../` depth matches
  `roles/<role>`, so the base config's relative paths hold: the IIS one is
  `tests/integration/molecule/iis/`. Its converge includes the targets as
  roles and drops Molecule's idempotence step, because the targets change
  things on purpose and check each module's idempotence themselves. The IIS
  targets check IIS through `setup_iis/files/read_mime_map.ps1` (appcmd.exe
  and the configuration files' XML), never through the module under test.
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

# ...or with your own tools (versions may differ from CI's):
pip install ansible-core ansible-lint yamllint
ansible-galaxy collection install -r requirements.yml -r tests/domain_lab/requirements.yml
yamllint . && ansible-lint

# PowerShell lint exactly as CI's `ansible-test sanity` pslint runs it — the
# settings ship inside ansible-core; Invoke-Formatter with the same -Settings
# auto-fixes brace/whitespace/indentation findings (how 0.1.0 was styled):
S=$(python3 -c 'import ansible_test, pathlib; print(pathlib.Path(ansible_test.__file__).parent / "_util/controller/sanity/pslint/settings.psd1")')
pwsh -c "Invoke-ScriptAnalyzer -Path roles -Recurse -Settings '$S'"

# argument specs (what the argument-specs workflow runs): build + install the
# collection, render the role docs, check specs vs defaults and validation
ansible-galaxy collection build --force --output-path /tmp/dist
ansible-galaxy collection install /tmp/dist/git_cgallagher-windows-*.tar.gz -p /tmp/colls --force
ANSIBLE_COLLECTIONS_PATH=/tmp/colls:~/.ansible/collections ansible-doc -t role git_cgallagher.windows.gpo_import
ANSIBLE_COLLECTIONS_PATH=/tmp/colls:~/.ansible/collections ansible-playbook tests/argument_specs/validate.yml

# a role's Molecule scenario: Linux with /dev/kvm only, one at a time, from
# the role's directory (full setup in tests/domain_lab/README.md). The
# driver and its collection come from one tag of ansible-collection-molecule:
pip install ansible-core molecule \
  "molecule-git-cgallagher[windows] @ git+https://github.com/git-cgallagher/ansible-collection-molecule@v0.2.1"
ansible-galaxy collection install git+https://github.com/git-cgallagher/ansible-collection-molecule.git,v0.2.1
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
  stale cluster configuration off the nodes, so `converge_cluster.ps1` first
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
  `tests/domain_lab/promote.yml` polls
  `Test-Path \\<domain>\SYSVOL\<domain>\Policies`.
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
  don't "simplify" that away.
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
