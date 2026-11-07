# mssql's Molecule scenario

Installs SQL Server 2022 Developer with `mssql` on a domain member, with
mandatory encryption and a certificate from a lab root CA, checks it from the
host and from a client on the lab network, and runs the `mssql_info`,
`mssql_network` and `mssql_setup` integration targets. Two VMs share one lab
network: `dc01` (the domain controller, which holds the accounts, and the
scenario's client) and `sql01` (the SQL Server host). The VMs, the box and
how to run a scenario are described in
[tests/domain_lab](../../../../tests/domain_lab/README.md); run this scenario
from `roles/mssql` with `molecule test`. Before phase 3b it took 25 minutes in
CI (create 5, prepare 10, converge 2, verify 7); 3b's network checks and the
`mssql_network` target add engine restarts to verify.

The ISO is Microsoft's free SQL Server 2022 Developer edition, which `sql01`
downloads from `download.microsoft.com` itself through the role (QEMU's user
networking reaches the internet), pinned by its SHA-256 in `molecule.yml`.
The Developer edition is licensed for development and test; CI uses it with
the owner's agreement (2026-11-06), and the ISO is never uploaded or published.

| Step | What happens | What's asserted |
|---|---|---|
| create | Boot both VMs | WinRM/PSRP answers |
| prepare | Promote `dc01` to the first DC of a new forest, with a KDS root key backdated 10 hours (lab only); join `sql01` to the domain; `mssql_prereqs` creates the engine's domain account with its SPNs, the Agent's gMSA (which `SQL01$` may use) and the administrators' group; pin `dc01`'s names on `sql01` so DPAPI works for the setup account; issue `sql01` a server certificate (a legacy CSP key exchange key, as SQL Server needs) from a lab root CA that `sql01` and `dc01` trust; pin `sql01`'s names on `dc01` to its lab address | DPAPI works for the setup account; the certificate's key is `KeySpec = 1` in the SChannel CSP, and it chains to the lab root |
| converge | `mssql` downloads the ISO into its cache, checks it, installs a default instance (SQLEngine, Replication) running as the domain account and the gMSA, with two tempdb files, then binds the certificate, forces encryption, opens port 1433 and restarts the engine (it installed it in this run) | — |
| idempotence | Run the role again | No task reports a change |
| verify | Read the instance through `setup_mssql`'s `instance_state.ps1` (the registry, the services, the errorlog, the firewall, SqlClient) | Developer edition, version 16, the collation, the service accounts and their start modes, the sysadmins group, two tempdb files, instant file initialization, TCP/IP on, the cached ISO's checksum, nothing left mounted |
| | Search setup's `ConfigurationFile.ini` files | None holds the engine's password |
| | Read the instance's network | Force Encryption on, Force Strict off, the certificate bound and loaded (errorlog), port 1433 static and listening, the firewall rule, read access to the key for `NT SERVICE\MSSQLSERVER` and the engine's account |
| | From `dc01`, as a domain account, `client.ps1` | A SqlClient connection over TCP uses Kerberos and is encrypted, with the certificate checked; one that doesn't ask for encryption is encrypted too; a TDS PRELOGIN gets a TDS answer |
| | Turn strict encryption on with `mssql_network`, read the instance with `mssql_info`, probe from `dc01` again | `mssql_network`'s own claims (restarted, strict set, the certificate loaded); what strict does to SQL Server Agent, to `mssql_info`'s SqlClient connection and to `dc01`'s probes is logged, not asserted, until a lab has shown it |
| | Turn mandatory back on | SQL Server Agent runs again |
| | Run the role report-only | It plans nothing (setup or network), and reads the features asked for |
| | The `mssql_info` target | Its result's shape and values against the instance (encryption included); the instance and connection options; a local account that is no login gets a reported, not raised, failure |
| | The `mssql_network` target | Nine refusals, which write nothing; a port moved without a restart (pending, on a second run too) and then restarted into; encryption through optional, mandatory (with a certificate the target makes) and strict, each in check mode, for real and again; the instance put back as it was |
| | The `mssql_setup` target | 15 refusals; a pending reboot fails or is reported; a named instance (ITEST) installed from a UNC path into the target's cache (check mode first, then for real, then again), a feature added from the cached copy, notices for an unlisted feature and another collation, and the uninstall |

Not covered: SQL Server 2025 (whose Agent supports strict), Standard and
Enterprise media, a cumulative update folder, an Evaluation install, setup on
a host without `become`, and a client with a TDS 8.0 driver (Windows Server
2022 has none in the box, so strict is checked from what `dc01` can see
without one).
