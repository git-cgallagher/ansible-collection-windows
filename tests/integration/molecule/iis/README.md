# The IIS modules' Molecule scenario

Runs the integration targets of `iis_mime_type` and `iis_mime_type_info`
(`tests/integration/targets/`) against a real Windows Server 2022 VM with IIS.
The VM is the domain labs' box, booted as a plain server and never promoted
(see [tests/domain_lab](../../../domain_lab/README.md) for the box, the
requirements and how a run is set up). Run it from `tests/integration`:

```bash
cd tests/integration
molecule test -s iis    # Linux with /dev/kvm; on a Mac, `molecule list` and `molecule syntax`
```

The same targets also run without Molecule, against a Windows host of your
own, through `ansible-test windows-integration` (see `AGENTS.md`).

| Step | What happens | What's asserted |
|---|---|---|
| create | Boot the VM as `iis01` (`lab_vm` in the base config) and wait for its first boot to finish | WinRM/PSRP answers *and* the box's setup script is gone |
| prepare | Quiet the VM; run `iis_mime_type_info` before IIS exists; run `setup_iis`: install IIS (`Web-Server` with its management tools, and `Web-Scripting-Tools`), and create the test website `Ansible IIS Test` with the application `/app1` | The module fails and says to install `Web-Server` |
| converge | The `iis_mime_type` target | Server level: add, other spellings of the extension, change, remove; each in check mode first (predicts, writes nothing, diff), then for real, then again (no change). Invalid input and missing levels fail clearly and write nothing. Site level: new mappings in `applicationHost.config` and in `web.config`, each stored only there; the refusal to override the website's own `web.config` from `applicationHost.config`; overriding an inherited mapping (a `<remove>` plus a `<mimeMap>`) and hiding one (a `<remove>`), with the server level untouched. Application level. The server-level map is the same afterwards. |
| | The `iis_mime_type_info` target | Server-level defaults, sorted; filters by extension, by MIME type and by both (both must match; no match is `[]`); `inherited` for entries defined in the website's `<location>` element, in its `web.config`, overridden, redefined with the inherited MIME type, and inherited, at the site and application levels; check mode returns the same data |
| verify | Read the server level, the website and the application | No test mapping is left at the server level; the website and the application store nothing of their own |

No idempotence step: the targets change mappings on purpose, and check each
module's idempotence themselves. Every check reads IIS through
`setup_iis/files/read_mime_map.ps1`, which uses `appcmd.exe` and the
configuration files' XML, never the module under test.
