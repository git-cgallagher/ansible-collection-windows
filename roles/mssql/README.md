# git_cgallagher.windows.mssql

Installs a **standalone SQL Server 2022 or 2025 instance** from an ISO, on
each host in the play in parallel, and reads it back. It's the second role of
this collection's SQL Server area, after
[`mssql_prereqs`](../mssql_prereqs/README.md), which creates the service
accounts and SPNs this role installs SQL Server under. The plan for the rest
(static ports, certificates and encryption; `sp_configure`; failover cluster
instances; `mssql_ag` for availability groups) is tracked in
[issue #48](https://github.com/git-cgallagher/ansible-collection-windows/issues/48).

The work happens in two modules, which you can use on their own:

- [`mssql_setup`](../../plugins/modules/mssql_setup.yml) stages and mounts the
  ISO, checks it's the version and edition asked for, and runs `setup.exe`;
- [`mssql_info`](../../plugins/modules/mssql_info.yml) reads the instances
  back, from the registry and services and from SQL Server itself.

## Order and safety

1. **Check the variables, without touching a host** (`tasks/plan.yml`): a
   Developer edition takes no product key, 2022 has no Standard Developer,
   `SQLEngine` is among the features, the media is an ISO pinned by its
   SHA-256, and each service account fits its password.
2. **Plan setup**, only when `mssql_allow_reboot` is true: the module's check
   mode says whether setup has work, and whether a reboot is pending, which
   setup refuses to run with. The role reboots first only when both are true.
3. **Install**, or add the features the instance lacks. Before setup runs,
   the module checks there's no pending reboot, the account it runs as (the
   `become` user) is among `mssql_sysadmins` or in one of its groups, the
   service accounts resolve, each path's volume exists, and the media matches
   its checksum. A UNC path or URL is copied into `mssql_media_cache_dir`
   first, and kept; the next run (another instance, an added feature) reuses
   the copy while its checksum matches.
4. **Reboot** when setup asks for one (exit code 3010), if
   `mssql_allow_reboot` lets it; otherwise fail and say so.
5. **Read the instance back** with `mssql_info`, publish it as the
   `mssql_instance` fact, and fail unless it runs and the role's account is a
   `sysadmin` there: the account later steps manage it as.

A second run changes nothing: an instance that matches never reads the media.
Settings fixed at install that differ (the version, the edition, the server
collation) and installed features that `mssql_features` doesn't list are
reported as warnings, never changed: the role doesn't reinstall, upgrade or
remove anything. `mssql_paths` and `mssql_tempdb` apply at install only and
aren't compared afterwards.

**Secrets.** The service passwords and the product key reach setup on its
command line, as setup requires; setup doesn't write them to the
`ConfigurationFile.ini` in its logs (the lab checks). The module never returns
them: its `setup.command` result shows `********`. A gMSA needs no password at
all.

**Check mode** (or `mssql_report_only`) reports what setup would do and runs
every check that only reads. It doesn't stage, mount or run anything, so the
media's version and edition are only checked by a real run.

## Media and editions

| `mssql_edition` | Versions | Media | Key |
|---|---|---|---|
| `enterprise_developer` | 2022 (its "Developer"), 2025 | Developer or Evaluation | well-known, passed by the module |
| `standard_developer` | 2025 | Standard Developer or Evaluation | well-known, passed by the module |
| `evaluation` | both | Evaluation (no key of its own) | none |
| `enterprise`, `standard` | both | licensed media | `mssql_product_key`, or the media's own |

The Developer editions are free, and licensed for development and test, not
production. Microsoft publishes them as ISOs, for example
`https://download.microsoft.com/download/3/8/d/38de7036-2433-4207-8eae-06e247e17b25/SQLServer2022-x64-ENU-Dev.iso`
(SHA-256 `80d2cd75dd2b28098c0182f50ad86bd44f9b3a9f357c30ff617480a1497daffd`,
the lab's). The module reads the media's own `MediaInfo.xml` (its build) and
`x64\DefaultSetup.ini` (its key) once it's mounted, refuses media that isn't
the version or edition asked for, and checks the installed edition after
setup.

Setup runs with `/UpdateEnabled=False` unless `mssql_update_source` names a
folder of cumulative updates to slipstream: it never reaches Microsoft Update.
TCP/IP is always enabled (the Developer editions install with it off).

## Running setup over WinRM

Set `mssql_become_user` (with `mssql_become_password`). Setup then runs
through `runas` become, a logon with credentials: a WinRM logon has none to
pass on (the double hop), which a UNC path needs, and setup can run for half
an hour. That account, or one of its groups, must be in `mssql_sysadmins`.

## Variables

Every variable is documented in `meta/argument_specs.yml`
(`ansible-doc -t role git_cgallagher.windows.mssql`).

| Variable | Default | Purpose |
|---|---|---|
| `mssql_version` | required | `'2022'` or `'2025'` |
| `mssql_edition` | required | see the table above |
| `mssql_media` | required | `{path, checksum}`: a local path, UNC path or URL to the ISO, and `sha256:<hex>` |
| `mssql_sysadmins` | required | accounts and groups made `sysadmin`; must include the role's account |
| `mssql_product_key` | `''` | for `enterprise`/`standard` media without a key |
| `mssql_instance_name` | `MSSQLSERVER` | the default instance, or a named one |
| `mssql_features` | `[SQLEngine]` | plus `Replication`, `FullText` |
| `mssql_collation` | `SQL_Latin1_General_CP1_CI_AS` | at install only |
| `mssql_media_cache_dir` | `C:\ProgramData\mssql-iac\media` | where a UNC or URL ISO is copied and kept |
| `mssql_update_source` | `''` | a CU folder to slipstream |
| `mssql_engine_account` / `_password` | `''` | domain account + password, gMSA (`$`) without, or setup's virtual account |
| `mssql_agent_account` / `_password` | `''` | the same for SQL Server Agent |
| `mssql_agent_startup` | `automatic` | `automatic`, `manual` or `disabled` |
| `mssql_instant_file_init` | `true` | instant file initialization for the engine's account |
| `mssql_paths` | `{}` | `instance_dir`, `data_root`, `data`, `log`, `backup`, `tempdb_data`, `tempdb_log` |
| `mssql_tempdb` | `{}` | `file_count`, `file_size_mb`, `file_growth_mb`, `log_size_mb`, `log_growth_mb` |
| `mssql_become_user` / `_password` | `''` | the `runas` account setup and the reads run as |
| `mssql_allow_reboot` | `false` | reboot before or after setup when needed |
| `mssql_report_only` | `false` | plan only |

## Example

```yaml
- name: SQL Server accounts and SPNs
  hosts: dc01
  roles:
    - role: git_cgallagher.windows.mssql_prereqs
      vars:
        mssql_prereqs_accounts:
          - name: svc-sqldb
            password: "{{ vault_svc_sqldb }}"
            spn_sets: [{hosts: [sql01.example.com]}]
          - name: gmsa-sqlagt
            type: gmsa
            dns_hostname: gmsa-sqlagt.example.com
            retrieve_password: [SQL01$]

- name: SQL Server
  hosts: sql01
  roles:
    - role: git_cgallagher.windows.mssql
      vars:
        mssql_version: '2022'
        mssql_edition: enterprise
        mssql_product_key: "{{ vault_sql2022_key }}"
        mssql_media:
          path: \\files.example.com\media\SQLServer2022-x64-ENU.iso
          checksum: "sha256:{{ sql2022_iso_sha256 }}"
        mssql_features: [SQLEngine, Replication]
        mssql_engine_account: EXAMPLE\svc-sqldb
        mssql_engine_password: "{{ vault_svc_sqldb }}"
        mssql_agent_account: EXAMPLE\gmsa-sqlagt$
        mssql_sysadmins: [EXAMPLE\GG-SQL-Admins]
        mssql_paths: {data: 'D:\MSSQL\Data', log: 'L:\MSSQL\Log', backup: 'B:\MSSQL\Backup', tempdb_data: 'T:\MSSQL\TempDB'}
        mssql_tempdb: {file_count: 8, file_size_mb: 1024}
        mssql_become_user: EXAMPLE\svc-ansible
        mssql_become_password: "{{ vault_svc_ansible }}"
        mssql_allow_reboot: true
```

## Testing

The Molecule scenario `molecule/default` (see its README) boots a domain
controller and a SQL Server host, creates the accounts with `mssql_prereqs`,
installs SQL Server 2022 Developer from Microsoft's ISO with this role, and
runs the modules' integration targets. CI runs it in the `domain-lab`
workflow. SQL Server 2025, Standard and Enterprise media aren't lab-tested yet.
