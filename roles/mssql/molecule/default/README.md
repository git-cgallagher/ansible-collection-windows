# mssql's Molecule scenario

Installs SQL Server 2022 Developer with `mssql` on a domain member, checks it,
and runs the `mssql_info` and `mssql_setup` integration targets. Two VMs share
one lab network: `dc01` (the domain controller, which holds the accounts) and
`sql01` (the SQL Server host). The VMs, the box and how to run a scenario are
described in [tests/domain_lab](../../../../tests/domain_lab/README.md); run
this scenario from `roles/mssql` with `molecule test`. It takes about an hour
and a half, most of it SQL Server setup (three runs) on nested virtualization.

The ISO is Microsoft's free SQL Server 2022 Developer edition, which `sql01`
downloads from `download.microsoft.com` itself through the role (QEMU's user
networking reaches the internet), pinned by its SHA-256 in `molecule.yml`.
The Developer edition is licensed for development and test; CI uses it with
the owner's agreement (2026-11-06), and the ISO is never uploaded or published.

| Step | What happens | What's asserted |
|---|---|---|
| create | Boot both VMs | WinRM/PSRP answers |
| prepare | Promote `dc01` to the first DC of a new forest, with a KDS root key backdated 10 hours (lab only); join `sql01` to the domain; `mssql_prereqs` creates the engine's domain account with its SPNs, the Agent's gMSA (which `SQL01$` may use) and the administrators' group | — |
| converge | `mssql` downloads the ISO into its cache, checks it, and installs a default instance (SQLEngine, Replication) running as the domain account and the gMSA, with two tempdb files | — |
| idempotence | Run the role again | No task reports a change |
| verify | Read the instance through `setup_mssql`'s `instance_state.ps1` (the registry, the services, SqlClient) | Developer edition, version 16, the collation, the service accounts and their start modes, the sysadmins group, two tempdb files, instant file initialization, TCP/IP on, the cached ISO's checksum, nothing left mounted |
| | Search setup's `ConfigurationFile.ini` files | None holds the engine's password |
| | Run the role report-only | It plans nothing, and reads the features asked for |
| | The `mssql_info` target | Its result's shape and values against the instance; the instance and connection options; a local account that is no login gets a reported, not raised, failure |
| | The `mssql_setup` target | 15 refusals; a pending reboot fails or is reported; a named instance (ITEST) installed from a UNC path into the target's cache (check mode first, then for real, then again), a feature added from the cached copy, notices for an unlisted feature and another collation, and the uninstall |

Not covered: SQL Server 2025, Standard and Enterprise media, a cumulative
update folder, an Evaluation install, and setup on a host without `become`.
