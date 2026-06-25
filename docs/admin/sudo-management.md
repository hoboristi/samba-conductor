# Sudo Rules

Manage sudo access rules stored in Active Directory (`ou=sudoers`). Domain-joined Linux hosts running SSSD with
`sudo_provider = ldap` read these rules to determine who can run what as which user, without needing a local
`/etc/sudoers` entry on every machine.

## Accessing This Page

Navigate to **Admin** > **Sudo Rules** or go to `/admin/sudo`.

## Prerequisites

Sudo rules rely on the `sudoRole` schema extension, which is **not** part of the standard Active Directory schema.
Samba Conductor's DC image loads this extension automatically on first provisioning (see
`docker/scripts/samba-setup.sh` → `setup_sudo_schema`). If you're running against a DC that wasn't provisioned by
this project, you'll need to load the schema manually -- see [Sudo & SSH Key Integration](../infra/sudo-ssh-integration.md).

## Features

### Rule List

The rule list displays all sudo rules in a searchable table with the following columns:

- **Name** -- the rule's `cn` (unique identifier)
- **Users / Groups** -- the `sudoUser` values this rule applies to. Groups are shown prefixed with `%`.
- **Hosts** -- the `sudoHost` values (or `ALL`)
- **Commands** -- the `sudoCommand` values (or `ALL`)
- **Actions** -- Edit and Delete buttons

Use the search bar to filter rules by any visible field.

### Creating a Rule

1. Click the **New Rule** button in the top-right corner.
2. Fill in the form fields.
3. Click **Create Rule**.

**Route:** `/admin/sudo` (inline form)

| Field           | Required | Description                                                                                          |
|-----------------|----------|-------------------------------------------------------------------------------------------------------|
| Rule Name (cn)  | Yes      | Unique identifier for the rule (e.g., `devops-restart`). Cannot be changed after creation.            |
| Users / Groups  | Yes      | Comma-separated list. Prefix groups with `%` (e.g., `alice, %devops`). Use `ALL` for every user.      |
| Hosts           | No       | Comma-separated hostnames this rule applies to. Defaults to `ALL`.                                    |
| Commands        | No       | Comma-separated command paths. Defaults to `ALL`. Prefix a command with `!` to explicitly deny it.    |
| Options         | No       | sudo flags such as `NOPASSWD` or `!authenticate`, comma-separated.                                    |
| Run As User     | No       | The user sudo will run commands as. Defaults to `root`.                                               |
| Run As Group    | No       | The group sudo will run commands as. Optional.                                                        |
| Description     | No       | Free-text description of the rule's purpose.                                                          |

### Editing a Rule

Click **Edit** on a rule row to open the same form pre-filled with the rule's current values. The **Rule Name**
field is read-only when editing.

### Deleting a Rule

1. Click **Delete** in the Actions column for the rule you want to remove.
2. A confirmation dialog warns that deletion cannot be undone.
3. Click **Delete** to confirm.

## How Rules Apply to Linux Hosts

Once a rule is saved here, it becomes visible to any Linux host configured with:

```ini
[domain/yourdomain.com]
sudo_provider         = ldap
ldap_sudo_search_base = ou=sudoers,dc=yourdomain,dc=com
```

and `sudoers: files sss` in `/etc/nsswitch.conf`. See
[Sudo & SSH Key Integration](../infra/sudo-ssh-integration.md) for full host-side setup instructions, including
SSSD caching tuneables.

Changes typically propagate to hosts within `ldap_sudo_smart_refresh_interval` (15 minutes by default), or
immediately if you run `sudo -l -U <user>` (which triggers an on-demand refresh in most SSSD configurations).

## Notes

- Rule precedence follows standard sudoers semantics: later-matching rules can override earlier ones, and `!`-prefixed
  commands act as explicit denials within a rule.
- There is currently no UI to reorder rules (`sudoOrder`). If you need explicit ordering, set it directly via
  `samba-tool` or an LDAP client until this is exposed in the UI.
- Sudo rules are independent of AD group membership rules for application access -- they only control `sudo`
  behavior on Linux hosts that consume `ou=sudoers`.
