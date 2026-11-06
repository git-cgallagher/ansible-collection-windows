# Moving GPOs between domains

Can `gpo_export` back up a GPO so that `gpo_import` reapplies it in a new,
unrelated domain? **Yes, for its settings.** Everything outside the settings
is yours to supply: links, inheritance, security filtering, delegation, the
WMI filter, ADMX files. Some settings also need a migration table, and some
need fixing by hand after the import.

This page is what the lab observed, not what the documentation promises. The
`molecule (gpo_cross_domain)` domain-lab job
([tests/integration/molecule/gpo_cross_domain](../tests/integration/molecule/gpo_cross_domain/README.md))
runs on Windows Server 2022 with two DCs of separate forests,
`src.example.test` and `dst.example.test`. There is no trust, no DNS
forwarding and no network between them, so dst can't resolve one src name or
SID. The job authors one GPO per row below on src, exports it with
`gpo_export`, and carries the backup to dst through the controller. It imports
it with `gpo_import` twice: once through a migration table GPMC built on src,
once without one. It reads each GPO from `Get-GPOReport` XML and its SYSVOL
files on both sides. The result is pinned, so a change fails the job.

## The matrix

| Row | Where the setting lives | Result | What the lab saw on dst |
|---|---|---|---|
| Administrative Templates (a Windows ADMX policy) | `registry.pol` | **pass** | Lands as written; nothing names src |
| Security settings without principals: password, audit, security options | `GptTmpl.inf` | **pass** | Lands as written |
| User Rights Assignment naming a src group | `GptTmpl.inf` (`*SID`) | **needs migration table** | Without a table, src's SID is kept: the report shows it unresolved. With one, dst's group's SID |
| Restricted Groups naming a src group | `GptTmpl.inf` | **needs migration table** | Same |
| File system ACL with a src group | `GptTmpl.inf` (SDDL) | **needs migration table** | Same, inside the SDDL |
| Registry ACL with a src group | `GptTmpl.inf` (SDDL) | **needs migration table** | Same |
| Startup scripts: one stored in the GPO, one on `\\SRCDC01\...` | `scripts.ini` + the script file | **needs migration table** | The stored script travels inside the GPO. Without a table, the UNC path still names src's server. With one, it's rewritten to dst's |
| Folder redirection to `\\SRCDC01\...` | `fdeploy.ini` | **needs migration table** | Same as the UNC script |
| GPP registry item | `Registry.xml` | **pass** | Lands; nothing names src |
| GPP drive map to `\\SRCDC01.src.example.test\...` | `Drives.xml` | **not migrated** | The path names src, table or not: GPMC's migration table doesn't list GPP paths |
| GPP Local Users and Groups adding a src group | `Groups.xml` (name + SID) | **not migrated** | `SRC\GG-XD-Admins` and its SID survive, table or not |
| GPP item-level targeting by a src group | `Registry.xml` `<FilterGroup>` | **not migrated** | The filter's name and SID survive, table or not, so the item never applies on dst |
| Custom ADMX policy (ADMX only in src's central store) | `registry.pol` | **pass**, unnamed | The value lands, but dst has no ADMX for it. src's report names the policy; dst's shows it only as an extra registry setting |
| Windows Firewall rule | `registry.pol` | **pass** | Lands. These are registry-based, not the AD-stored IPsec or wireless extensions (not tested) |
| A policy value hard-coding `\\SRCDC01.src.example.test\Apps` | `registry.pol` | **not migrated** | Copied verbatim, table or not |
| A WMI filter linked to the GPO | AD (`gPCWQLFilter`) | **not carried** | dst's GPO has no WMI filter |
| Security filtering to a src group, editing delegated to another | AD (the GPO's DACL) | **not carried** | dst's GPO has dst's defaults: Authenticated Users apply, the admins edit |

How the results are defined: **pass** means the setting lands and nothing of
src's (its NetBIOS name, DNS name, DC's name or domain SID) is left even
without a migration table. **Needs migration table**: src references survive
without the table, and none survive with it. **Not migrated**: they survive
even with the table. **Not carried**: the import doesn't bring it at all.

Things the run also showed:

- **GPMC's migration table covers less than it looks.** Built from all
  17 GPOs, it listed the two src groups named in security settings, the
  built-in Administrators, and the two UNC paths in `scripts.ini` and
  `fdeploy.ini`. It didn't list the GPP drive map's path, GPP's groups or
  targeting, the hard-coded server, or the security-filtering group.
- **Without a table, the import still succeeds.** An unresolvable SID is
  copied as-is, and the report shows it as a bare SID. Nothing fails, so
  nothing tells you.
- **Switching the table on or off re-imports.** `gpo_import`'s import key
  includes the table, so importing again with or without it re-imports
  every GPO without `force`. Repeating the same import changes nothing.

## What you supply on dst

The backup carries settings content only (issue #64). To reapply GPOs in
another domain:

1. **A migration table**, built by GPMC from the GPOs you move: the
   Migration Table Editor's "Populate from GPO/backup", or the COM API as the
   lab's `files/new_xdomain_migtable.ps1` does. Point each src principal at
   its dst equivalent and each UNC path at dst's server, commit it with the
   backups, and pass it as `migration_table_path`. Create the destination
   groups on dst first; the lab does, so that `Import-GPO` can resolve them.
2. **GPP fix-ups.** A migration table never touches Group Policy Preferences.
   Rewrite drive-map paths, Local Users and Groups members (name and SID) and
   item-level-targeting groups in the GPO after the import, or author those
   preferences on dst.
3. **Hard-coded names in policy values.** Server names, UNC paths and
   domain names inside Administrative Templates values are copied verbatim.
   Find them in the backup's `gpreport.xml` before you move it.
4. **ADMX files.** Copy any custom ADMX/ADML into dst's central store.
   The setting applies without them, but dst's reports and editor show it only
   as an extra registry setting.
5. **Links and inheritance.** `New-GPLink` / `Set-GPLink` (order,
   enforced, enabled) and `Set-GPInheritance` on dst's OUs, or a role
   that manages them.
6. **Security filtering and delegation.** `Set-GPPermission` on dst. Keep
   Authenticated Users at Read when you filter (MS16-072).
7. **WMI filters.** Create the filter on dst and link it (`.WmiFilter` on
   the GPO object, through GPMC).

The `gpo_backup` and `gpo_import` roles (the sync layer) carry links,
filtering, the WMI filter and status in their manifest, with trustee names
domain-relative. The settings inside their backups behave as above, so they
need the same migration table and fix-ups. [design.md](design.md#4-cross-domain)
lists the mechanisms; this page is what a real move did.
