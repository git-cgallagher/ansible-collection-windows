# gpo_import's Molecule scenario

Drifts a real domain away from a `gpo_backup` export and checks that
`gpo_import` puts it back. The domain controller, the fixture and how to run
it are described in [tests/domain_lab](../../../../tests/domain_lab/README.md);
run this scenario from `roles/gpo_import` with `molecule test`.

| Step | What happens | What's asserted |
|---|---|---|
| create | Boot the VM (the box is cached and SHA-256 pinned) and wait for its first boot to finish | WinRM/PSRP answers *and* the box's setup script is gone |
| prepare | Promote it to a DC; reboot until AD Web Services, SYSVOL and GPMC all answer | — |
| | Seed the authored state (`lab_fixture.ps1 -Action Seed`): five GPOs including the [real-world scenarios](../../../../docs/scenarios.md) | The seeded domain password policy, linked above Default Domain Policy, is the *effective* policy (14 characters, lockout at 5) |
| | Export it with `gpo_backup` (`gpo_backup`'s own scenario checks the export) | — |
| | Drift the domain out-of-band (`-Action Drift`): delete a GPO and the WMI filter, reorder the domain root, add Domain Users to the servers' local Administrators preference, unlink the Restricted Groups GPO, and more | Default Domain Policy's weaker settings now win (7 characters, no lockout) |
| | `gpo_import` in report-only mode (`gpo_import_report_only`, check mode on the module) | The role stages the export; the module predicts the drift's fixes (`changed`, the action list, the preflight passed), recreates nothing and writes no state file |
| converge | `gpo_import` from the export | — |
| idempotence | Converge again | No task reports a change |
| verify | `files/assert_domain.ps1` reads the domain through GPMC and AD | Links, precedence, inheritance, status, filtering (Authenticated Users kept at Read), WMI filter (GPMC's own parser reads the query back), and settings of four types: Admin Templates, Preferences (including local Administrators), security settings and Restricted Groups |
| | Read the effective domain password policy | Back to 14 characters and lockout at 5 |
| | `gpo_import` again, in check mode | Zero planned actions, no change reported |
| | Re-export twice | Manifest identical to the pre-drift export; the second export ships nothing |
| | Build a migration table with GPMC's API, import the Restricted Groups GPO through it (a path relative to the repo), then import it again without the table | The table rewrote the member's SID; the plain import restored the original |
| | The `gpo_import` module's integration target ([`tests/integration/targets/gpo_import`](../../../../tests/integration/targets/gpo_import/tasks/main.yml), with `setup_gpo_lab`), from a source and state directory of its own | The authored domain exported and unpacked from the zip; the first plan imports every GPO ("never imported"), returns every documented result key and the preflight facts, writes no state file, leaves no probe file and touches nothing (GPO versions included); the import does what the plan said and records it; the repeat plans nothing. After the fixture's drift: the defaults fail on the missing WMI filter and notice the unmanaged link; `create_wmi_filters` and `remove_unmanaged_links` plan every fix (and only the deleted GPO's import: imports are keyed on the backup's content) while touching nothing; a GPO missing from both the domain and the export is the one error; the forced converge puts the domain back (links, inheritance, status, filtering, the WMI filter and the settings of all four types) and the repeat plans nothing. A migration table re-imports the GPO once (the table is in the import key), translates the member, and dropping it restores the original. A missing `source_dir`, a missing migration table, a planted `cpassword`, an incomplete backup folder, a missing manifest and an ACL-denied `state_dir` each fail with their message, plan nothing and change neither the domain nor the state file. The domain is left in the authored state |
