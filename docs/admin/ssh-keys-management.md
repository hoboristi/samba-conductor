# SSH Public Keys

Manage SSH public keys for Active Directory users. Keys are stored directly on the user's AD object (in
`altSecurityIdentities`) and consumed by domain-joined Linux hosts running SSSD, enabling passwordless SSH login
without distributing `authorized_keys` files by hand.

## Accessing This Page

SSH key management is embedded in two places rather than having its own top-level page:

- **Admin:** open **Admin** > **Users** > *(a user)* > **Edit**. The **SSH Public Keys** section appears below
  **Group Membership** on the user edit form (`/admin/users/:username/edit`).
- **Self-service:** any logged-in user can manage their own keys from **Profile** (`/profile`), below the profile
  fields.

## Prerequisites

None -- `altSecurityIdentities` is a native attribute on every AD user object, so no schema extension is required.
Self-service writes, however, do require a configured **sync account** with write access (see
[Settings](settings.md)), because regular AD users typically lack write permission on their own object by default.

## Features

### Listing Keys

Both the admin and self-service views show each key with:

- **Label** -- the comment portion of the key (e.g. `work-laptop`), or "(no label)" if omitted
- **Key type** -- e.g. `ssh-ed25519`, `ssh-rsa`
- **Key data** -- the key's base64 payload, truncated for display

### Adding a Key

1. Paste a full public key (e.g. the contents of `id_ed25519.pub`) into the text area.
2. Optionally provide a label to help identify the key later (e.g. `work-laptop`, `phone`).
3. Click **Add Key**.

Supported key types: `ssh-rsa`, `ssh-ed25519`, `ecdsa-sha2-nistp256/384/521`, and FIDO2/U2F `sk-` variants.

Duplicate keys (identical key data) are rejected with an error.

### Removing a Key

Click **Remove** next to the key you want to delete. There is no confirmation step -- removal is immediate, since
the underlying key file presumably still exists on the user's machine and can be re-added if removed by mistake.

## How Keys Apply to Linux Hosts

Once a key is saved, it becomes available to any Linux host configured with:

```ini
[domain/yourdomain.com]
ldap_user_extra_attrs    = altSecurityIdentities:altSecurityIdentities
ldap_user_ssh_public_key = altSecurityIdentities
```

and in `sshd_config`:

```
AuthorizedKeysCommand     /usr/bin/sss_ssh_authorizedkeys %u
AuthorizedKeysCommandUser nobody
```

See [Sudo & SSH Key Integration](../infra/sudo-ssh-integration.md) for full host-side setup instructions.

Key changes typically propagate within SSSD's cache refresh interval, or immediately after
`sss_cache -u <username>` on the target host.

## Notes

- A user can have any number of keys; there is no enforced limit.
- `altSecurityIdentities` is also used by Windows for other purposes (e.g. certificate mappings). Samba Conductor
  only manages the values it prefixes with `SSHKey:` and leaves any other values on the attribute untouched.
- Self-service additions and removals are performed using the configured sync account rather than the user's own
  session credentials, since AD's default ACLs do not grant users write access to their own
  `altSecurityIdentities` attribute.
