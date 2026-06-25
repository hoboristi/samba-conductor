# Sudo & SSH Key Integration — Manual Schema Setup

Samba Conductor-provisioned DCs load the `sudoRole` schema extension and create the `ou=sudoers` container
automatically on first boot (see `docker/scripts/samba-setup.sh` → `setup_sudo_schema`). SSH public key storage
needs no schema changes at all, since it reuses the native `altSecurityIdentities` attribute.

This page is only needed if you're pointing Samba Conductor at a **pre-existing DC** that wasn't provisioned by
this project's Docker images, and therefore never ran that automatic setup.

## Checking Whether the Schema Is Already Present

```bash
samba-tool schema attribute show sudoUser
```

- If this prints attribute details, the schema is already loaded — you don't need to do anything here.
- If it errors with something like "No such object", continue below.

## Loading the Schema Manually

Run this on the DC itself (or against it via `ldapi://` if running outside the container):

```bash
samba-tool ldif-import /path/to/sudo-schema.ldif \
  --option="dsdb:schema update allowed = true"
```

Where `sudo-schema.ldif` contains the attribute and class definitions for `sudoRole`. The exact LDIF used by
Samba Conductor's `setup_sudo_schema` function in `docker/scripts/samba-setup.sh` is the authoritative reference —
copy the attribute/class definitions from there if you need to apply them by hand against an external DC.

After the schema import succeeds, create the sudoers container:

```bash
samba-tool ldapmodify <<EOF
dn: ou=sudoers,dc=yourdomain,dc=com
changetype: add
objectClass: top
objectClass: organizationalUnit
ou: sudoers
description: Sudo rules for domain-joined Linux hosts
EOF
```

Replace `dc=yourdomain,dc=com` with your actual domain base DN.

## Verifying

```bash
samba-tool schema attribute show sudoUser
samba-tool schema objectclass show sudoRole
ldapsearch -Y GSSAPI -b "ou=sudoers,dc=yourdomain,dc=com" "(objectClass=organizationalUnit)"
```

Once these succeed, **Admin → Sudo Rules** in Samba Conductor will work normally against this DC.

## Multi-DC Environments

The schema lives in the AD configuration partition and replicates automatically to every DC in the forest once
loaded on one of them — you only need to run this once, on any single writable DC. The `ou=sudoers` container,
being a normal directory object, also replicates normally.

Samba Conductor's own replica-join flow (`SAMBA_JOIN_AS_DC=true`) is aware of this: it skips schema setup on
replica DCs and relies on standard AD replication to bring the schema over from the primary.

## Host-Side Configuration

Once the schema and container exist, configure individual Linux hosts as described in
[Joining a Linux Machine to the Domain](join-linux.md#step-6a-enable-ssh-public-key-login-optional) (Steps 6a and
6b cover SSH keys and sudo respectively).

## See Also

- [Sudo Rules (Admin Guide)](../admin/sudo-management.md)
- [SSH Public Keys (Admin Guide)](../admin/ssh-keys-management.md)
- [Joining a Linux Machine to the Domain](join-linux.md)
