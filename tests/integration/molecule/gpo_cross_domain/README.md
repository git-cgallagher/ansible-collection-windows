# gpo_cross_domain: moving GPOs between forests

Answers one question with evidence: can `gpo_export` back up a GPO in one
domain so that `gpo_import` can reapply it in an unrelated one, and what does
the user have to supply around it? The answer, row by row, is in
[docs/gpo-cross-domain.md](../../../../docs/gpo-cross-domain.md); this
scenario is how it was observed, and it keeps observing it.

Run it from `tests/integration` (Linux with `/dev/kvm`, about 16 GB of RAM
for the two VMs; see [tests/domain_lab](../../../domain_lab/README.md) for
the box and the setup):

```bash
cd tests/integration
molecule test -s gpo_cross_domain
```

## The lab

Two Windows Server 2022 VMs, each the first DC of its own forest:

| VM | Domain | NetBIOS | DC |
|---|---|---|---|
| `srcdc` | `src.example.test` | `SRC` | `SRCDC01` |
| `dstdc` | `dst.example.test` | `DST` | `DSTDC01` |

They share nothing: no trust, no DNS forwarding, no network between them (each
VM has only its QEMU user NIC). dst can't resolve one src name or SID, as in
a move between unrelated domains. The backup travels through the controller
(`$MOLECULE_LAB_DIR/gpo-xdomain`).

## Steps

| Step | What happens | What's asserted |
|---|---|---|
| prepare | Promote both VMs (`tests/domain_lab/promote.yml`, with their own `host_vars`). On src, `files/xdomain_fixture.ps1` creates three groups, a central store with a custom ADMX, a WMI filter and one GPO per matrix row (`lab_xd_rows` in `molecule.yml`); on dst, the same-named groups. GPMC builds a migration table from the matrix GPOs on src (`files/new_xdomain_migtable.ps1`), every entry naming src pointed at dst's namesake; it goes to dst through the controller | The promotion's own repeat changes nothing. Every row shows in its src GPO (report or SYSVOL), the custom ADMX setting by its name in the report; the WMI filter and the security filtering are on src |
| converge | `gpo_export` of the matrix on src; the backup fetched to the controller file by file and copied to dst; `gpo_import` of the matrix on dst through the migration table | |
| idempotence | The converge again | Nothing changes: no export, no fetch, no copy, no import |
| verify | Read every matrix GPO on src and on dst (`files/observe_xdomain.ps1`: `Get-GPOReport` XML plus every SYSVOL file, as UTF-16LE and UTF-8). `gpo_import` again without the migration table, read dst again, classify each row. Import through the table again, then once more | The import without the table re-imports every GPO (the table is part of the import key). The observed matrix equals the pinned one (`lab_xd_expected`). Back through the table: every GPO once, then nothing |

## How a row is classified

`files/observe_xdomain.ps1` looks, in each GPO's report and files, for the
row's markers (did the setting land) and for each domain's NetBIOS prefix
(`SRC\`), DNS name, DC host name and domain SID prefix. From the readings on
src, on dst through the table and on dst without it:

| Class | Meaning |
|---|---|
| `pass` | The setting lands, and nothing of src's is left in it even without a migration table |
| `needs-migration-table` | The setting lands; src's names or SIDs survive without the table, and none with it |
| `not-migrated` | The setting lands; src's names, SIDs or server survive even with the table. Fix it up after the import |
| `not-carried` | The setting (or, for the `wmi` and `filtering` rows, the WMI filter or security filtering) isn't on dst |
| `carried` | A `wmi` or `filtering` row's link or filtering is on dst |
| `not-seeded` | The src GPO didn't hold the row: a fixture fault, never pinned |

verify keeps the three readings in `$MOLECULE_LAB_DIR/gpo-xdomain/observed.json`
and prints, for every row, what was left of src with and without the table.
