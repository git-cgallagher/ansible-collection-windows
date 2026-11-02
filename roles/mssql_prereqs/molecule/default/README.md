# mssql_prereqs' Molecule scenario

Creates the lab's SQL Server accounts, gMSA, SPNs and groups with
`mssql_prereqs` in a fresh forest on the shared lab VM, and checks them. The
VM, the box and how to run a scenario are described in
[tests/domain_lab](../../../../tests/domain_lab/README.md); run this scenario
from `roles/mssql_prereqs` with `molecule test`. The accounts, groups and the
SPNs the role should build live in `molecule.yml` (`lab_accounts`,
`lab_groups`, `lab_expected_spns`).

| Step | What happens | What's asserted |
|---|---|---|
| create | Boot the VM | WinRM/PSRP answers |
| prepare | Promote the VM to the first DC of a new forest (`tests/domain_lab/promote.yml`); remove what a previous run created; create `svc-squatter-lab`, holding an SPN the refusal test asks for | — |
| | Before the forest has a KDS root key, run the role with `check` | It refuses the gMSA and names the missing key |
| | Run it with `create`, report-only | It plans the key, the users, the gMSA and the groups, and the forest still has no key |
| | Create a KDS root key backdated 10 hours (lab only), so the gMSA works at once | — |
| converge | `mssql_prereqs` creates two domain users, a gMSA and two groups | — |
| idempotence | Run the role again | No task reports a change |
| verify | Read everything through the ActiveDirectory module | Every SPN, the password and enabled flags, the gMSA's DNS host name, password retrievers and AES-only encryption types, the groups' members, and a KDS root key |
| | Ask for the squatter's SPN on a new account | The role refuses, names the holder and the SPN, and creates nothing |
| | Plan a new account report-only | Only that account is planned, and it isn't created |
| | Add an SPN to a user out-of-band, then run the role | Add mode keeps it and changes nothing |
| | Run with `mssql_prereqs_exclusive: true` | It removes that SPN and nothing else; a repeat changes nothing |

Not covered: running from a member server, a key `create` really adds (the
10-hour wait), `state: absent`, and a host retrieving the gMSA's password.
