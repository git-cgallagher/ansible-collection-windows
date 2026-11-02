# git_cgallagher.windows.mssql_prereqs

Creates the Active Directory accounts SQL Server runs under, and the Kerberos
service principal names (SPNs) that go with them, before SQL Server is
installed. It's the first role of this collection's SQL Server area; the plan
for the rest (`mssql` for standalone instances and FCIs, `mssql_ag` for
availability groups) is tracked in
[issue #48](https://github.com/git-cgallagher/ansible-collection-windows/issues/48).

From one list, `mssql_prereqs_accounts`, it creates or converges:

- **domain user accounts** (`microsoft.ad.user`): password set only on
  creation (`update_password: on_create`, so a run never resets the password
  the services were installed with), password never expires, user can't
  change it;
- **group managed service accounts** (gMSAs, `microsoft.ad.service_account`):
  DNS host name, AES-only Kerberos encryption, and the principals allowed to
  retrieve the password;
- each account's **`MSSQLSvc` SPNs**, built from host names, port and
  instance name.

`mssql_prereqs_groups` adds security groups, for example the SQL Server
administrators, or the hosts allowed to retrieve a gMSA's password. Groups
are created before the accounts, so a gMSA can name one of them.

It runs **once, from the first host in the play**. That host must be a domain
controller, or a member server with the ActiveDirectory PowerShell module
(`RSAT-AD-PowerShell`). It needs no SQL Server.

## Order and safety

1. **Plan, without touching Active Directory** (`tasks/plan.yml`). It fills in
   each account's defaults, builds the SPNs, and validates the whole list:
   - account names and lengths (a user at most 20 characters, a gMSA at most
     15);
   - a password for every user that is to exist, a `dns_hostname` for every
     such gMSA;
   - host and instance names;
   - no SPN listed for two accounts.
2. **Read.** If a gMSA is listed, check the forest's KDS root key. For every
   account, look in Active Directory for its SPNs on *other* accounts. A
   duplicate SPN breaks Kerberos for both accounts, so the role stops here,
   naming the holder.
3. **Write**: groups, the KDS root key (only with `create`), gMSAs, then
   domain users.

The role never removes what the variables don't list, with two exceptions:
an item with `state: absent`, and `mssql_prereqs_exclusive: true` (below).

**Passwords** stay out of the loops: the role loops over the accounts with
their passwords removed, and looks each one up by name inside the task that
sets it, where `microsoft.ad.user` hides it. `loop_control.label` alone
wouldn't do: it shortens only the summary line, and `-v` output and
registered results keep the whole loop item.

## SPNs

Each `spn_sets` entry describes one instance the account runs. List every
name clients connect with: each replica host and the AG listener, or a
failover cluster instance's network name.

| Instance | SPNs per host name |
|---|---|
| default (`instance: MSSQLSERVER`) | `MSSQLSvc/<host>:<port>`, `MSSQLSvc/<host>` |
| named (`instance: INST1`) | `MSSQLSvc/<host>:<port>`, `MSSQLSvc/<host>:INST1` |

`short_names: true` adds the same SPNs for each host's first label (`sql01`),
for clients that connect by short name. `extra_spns` adds others verbatim.

- **One engine account per availability group.** Every replica of an AG runs
  its engine under the same account, so the listener's SPN can sit on that
  account. Otherwise Kerberos through the listener works only while that
  account's replica is primary.
- **These accounts don't register their own SPNs.** A domain user can't
  without extra rights, and a gMSA only for its own host name. So this role
  owns them, and SQL Server logs a harmless "could not register the SPN" at
  startup.

## gMSAs and the KDS root key

A gMSA needs a KDS root key in the forest, and a key becomes usable only 10
hours after its effective time. `mssql_prereqs_kds_root_key` decides what the
role does when a gMSA is listed:

| Value | Does |
|---|---|
| `check` (default) | Fails before any change when the forest has no key. |
| `create` | Adds one when the forest has none, effective after `mssql_prereqs_kds_root_key_effective_time_hours` (10). It's a forest-wide change, so keep it for labs, where the 10-hour wait still applies. |
| `skip` | Doesn't look. |

`retrieve_password` names the principals that may retrieve the password,
usually the SQL Server hosts' computer accounts (`SQL01$`). A computer named
directly can use the gMSA at once. One added to a group needs a reboot, or a
`klist purge` as SYSTEM, before its token carries the new membership.

## List modes: add, or exclusive

By default the role **adds** the listed SPNs, password-retrieval principals
and group members, and leaves any others in place. With
`mssql_prereqs_exclusive: true` each list becomes the exact set: anything it
doesn't list is removed, and an empty list clears the attribute. Use it only
for accounts and groups that exist just for SQL Server.

## Credentials: the double hop

On a domain controller, the connection user is enough. From a member server,
a plain WinRM logon can't pass its credentials on to a DC, so set
`mssql_prereqs_domain_username` and `mssql_prereqs_domain_password`, which
every `microsoft.ad` task gets. (`mssql_prereqs_domain_server` names the DC.)

The KDS root key tasks (`microsoft.ad.kds_root_key` and `_info`) have no such
options. They run as the connection user, which needs Domain Admin rights to
read or create a key. Run the role on a domain controller when it manages
gMSAs.

## Check mode

`--check`, or `mssql_prereqs_report_only: true` for this role alone, reports
every change without making it. The `microsoft.ad` modules predict their
changes, and the reads (the KDS root keys, the SPN lookup) run as usual, so a
report-only run still fails on a missing key or a duplicate SPN.

A group the same run would create doesn't exist yet in check mode, yet the
modules still look principals up. So when a gMSA's `retrieve_password` or a
group's `members` names one of `mssql_prereqs_groups`, the plan looks that
list up with `lookup_failure_action: warn`: the lookup warns instead of
failing. Any other unknown principal in the same list then only warns too,
in check mode only.

## Variables

All variables are documented in
[meta/argument_specs.yml](meta/argument_specs.yml), which Ansible also uses to
validate them (`ansible-doc -t role git_cgallagher.windows.mssql_prereqs`).

| Variable | Default | Purpose |
|---|---|---|
| `mssql_prereqs_accounts` | `[]` | Accounts: `name`, `type` (`user`/`gmsa`), `password` (users), `path`, `description`, `upn`, `dns_hostname` (gMSAs), `retrieve_password` (gMSAs), `spn_sets` (`hosts`, `port` 1433, `instance` MSSQLSERVER, `short_names`), `extra_spns`, `state` |
| `mssql_prereqs_groups` | `[]` | Groups: `name`, `scope` (global), `path`, `description`, `members`, `state` |
| `mssql_prereqs_exclusive` | `false` | Make the SPN, retrieve-password and member lists exact |
| `mssql_prereqs_kds_root_key` | `check` | `check`, `create` or `skip` (gMSAs only) |
| `mssql_prereqs_kds_root_key_effective_time_hours` | `10` | Hours until a key that `create` adds becomes effective |
| `mssql_prereqs_domain_server` | `''` | Domain controller for the `microsoft.ad` modules |
| `mssql_prereqs_domain_username` | `''` | Account for them; needed from a member server |
| `mssql_prereqs_domain_password` | `''` | Its password (vault it) |
| `mssql_prereqs_report_only` | `false` | Report changes without making them (`--check` implies it) |

## Example

An availability group across two sites, with its engine in a domain user
account and SQL Server Agent in a gMSA:

```yaml
- name: SQL Server prerequisites in Active Directory
  hosts: dc01.example.com
  gather_facts: false
  roles:
    - role: git_cgallagher.windows.mssql_prereqs
      vars:
        mssql_prereqs_groups:
          - name: GG-SQL-AG01-Hosts
            path: OU=SQL Servers,DC=example,DC=com
            members: [SQL01$, SQL02$, SQL03$, SQL04$]
          - name: GG-SQL-Admins
            members: [svc-ansible, GG-DBA]
        mssql_prereqs_accounts:
          - name: svc-sqldb-ag01
            password: "{{ vault_svc_sqldb_ag01 }}"
            path: OU=Service Accounts,DC=example,DC=com
            description: SQL Server engine, AG01 replicas and listener
            spn_sets:
              - hosts: [sql01.example.com, sql02.example.com, sql03.example.com,
                        sql04.example.com, ag01-lsn.example.com]
                short_names: true
          - name: gmsa-sqlagt-ag01
            type: gmsa
            dns_hostname: gmsa-sqlagt-ag01.example.com
            path: OU=Service Accounts,DC=example,DC=com
            retrieve_password: [GG-SQL-AG01-Hosts]
```

## Tested, and not yet

Its Molecule scenario,
[`molecule/default`](https://github.com/git-cgallagher/ansible-collection-windows/tree/main/roles/mssql_prereqs/molecule/default),
promotes a Windows Server 2022 VM to the first domain controller of a new
forest, and checks everything through the ActiveDirectory module's own
cmdlets:

- Before the forest has a KDS root key, `check` refuses the gMSA, and a
  report-only `create` plans one and writes nothing.
- It creates two domain users (a default and a named instance, short names,
  an extra SPN), a gMSA whose password a group the role creates may retrieve,
  and two groups. Then it checks every SPN, flag, member and the encryption
  types, and that a second run changes nothing.
- It refuses an SPN another account holds, and creates nothing.
- A report-only plan for a new account creates nothing.
- Add mode keeps an SPN the role doesn't list, exclusive mode removes it, and
  a repeat changes nothing.

The plan (SPN generation and every validation) is also tested without
Windows, by the `argument-specs` workflow.

Not lab-tested yet: running from a member server (`mssql_prereqs_domain_*`),
a KDS root key that `create` actually adds (the lab's key is backdated, so its
gMSA works at once), `state: absent`, and a host using the gMSA.
