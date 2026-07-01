#!/bin/bash
# =============================================================================
# Load the sudoRole schema extension and create ou=sudoers.
#
# IMPORTANT — Samba AD schema changes work differently from a normal
# operation: they are NOT applied over LDAP against a running server.
# Per Samba's own documentation and confirmed by many real-world reports
# (searching for "schema_data_add: updates are not allowed: reject request"
# turns up this exact failure), schema updates must be applied directly to
# the local sam.ldb file using `ldbmodify`, and the samba daemon must be
# STOPPED while this happens. Attempting it via `samba-tool` against a live
# LDAP connection — which is what an earlier version of this script did —
# fails immediately, every time, regardless of timing or retries.
#
# Because of this, this script is sourced from samba-setup.sh and runs
# during entrypoint.sh, BEFORE supervisord starts the samba daemon — i.e.
# exactly the opposite timing of what you'd expect for an LDAP operation,
# but the correct timing for a local database file operation.
#
# Idempotent via the .sudo-schema-loaded marker file.
# =============================================================================

# Expects SAMBA_REALM, DATA_DIR, SAMBA_JOINED, SAMBA_LOGS to already be set
# by the sourcing script (samba-setup.sh).

setup_sudo_schema() {
    local sam_ldb="/var/lib/samba/private/sam.ldb"
    local sudo_schema_loaded="${SAMBA_DATA}/.sudo-schema-loaded"

    if [ -f "$sudo_schema_loaded" ]; then
        echo "[Samba] sudoRole schema already loaded."
        return
    fi

    if [ -f "$SAMBA_JOINED" ]; then
        echo "[Samba] Replica DC — sudoRole schema arrives via AD replication. Skipping."
        return
    fi

    if [ ! -f "$sam_ldb" ]; then
        echo "[Samba] WARNING: ${sam_ldb} not found — domain not yet provisioned? Skipping schema setup for this run."
        return
    fi

    local domain_base
    domain_base=$(echo "${SAMBA_REALM}" | tr '[:upper:]' '[:lower:]' | awk -F'.' '{
        for (i=1; i<=NF; i++) printf "dc=%s%s", $i, (i<NF ? "," : "")
    }')

    echo "[Samba] Loading sudoRole schema into ${domain_base} (offline, via ldbmodify)..."

    local schema_ldif
    schema_ldif=$(mktemp /tmp/sudo-schema-XXXXXX.ldif)

    cat > "$schema_ldif" <<EOF
dn: CN=sudoUser,CN=Schema,CN=Configuration,${domain_base}
changetype: add
objectClass: top
objectClass: attributeSchema
cn: sudoUser
attributeID: 1.3.6.1.4.1.15953.9.1.1
attributeSyntax: 2.5.5.5
isSingleValued: FALSE
adminDisplayName: sudoUser
adminDescription: User(s) who may run sudo
oMSyntax: 22
searchFlags: 1

dn: CN=sudoHost,CN=Schema,CN=Configuration,${domain_base}
changetype: add
objectClass: top
objectClass: attributeSchema
cn: sudoHost
attributeID: 1.3.6.1.4.1.15953.9.1.2
attributeSyntax: 2.5.5.5
isSingleValued: FALSE
adminDisplayName: sudoHost
adminDescription: Host(s) on which sudo is allowed
oMSyntax: 22
searchFlags: 1

dn: CN=sudoCommand,CN=Schema,CN=Configuration,${domain_base}
changetype: add
objectClass: top
objectClass: attributeSchema
cn: sudoCommand
attributeID: 1.3.6.1.4.1.15953.9.1.3
attributeSyntax: 2.5.5.5
isSingleValued: FALSE
adminDisplayName: sudoCommand
adminDescription: Command(s) allowed or denied by sudo
oMSyntax: 22
searchFlags: 0

dn: CN=sudoOption,CN=Schema,CN=Configuration,${domain_base}
changetype: add
objectClass: top
objectClass: attributeSchema
cn: sudoOption
attributeID: 1.3.6.1.4.1.15953.9.1.5
attributeSyntax: 2.5.5.5
isSingleValued: FALSE
adminDisplayName: sudoOption
adminDescription: Options for sudo
oMSyntax: 22
searchFlags: 0

dn: CN=sudoRunAsUser,CN=Schema,CN=Configuration,${domain_base}
changetype: add
objectClass: top
objectClass: attributeSchema
cn: sudoRunAsUser
attributeID: 1.3.6.1.4.1.15953.9.1.6
attributeSyntax: 2.5.5.5
isSingleValued: FALSE
adminDisplayName: sudoRunAsUser
adminDescription: User(s) impersonated by sudo
oMSyntax: 22
searchFlags: 0

dn: CN=sudoRunAsGroup,CN=Schema,CN=Configuration,${domain_base}
changetype: add
objectClass: top
objectClass: attributeSchema
cn: sudoRunAsGroup
attributeID: 1.3.6.1.4.1.15953.9.1.7
attributeSyntax: 2.5.5.5
isSingleValued: FALSE
adminDisplayName: sudoRunAsGroup
adminDescription: Group(s) impersonated by sudo
oMSyntax: 22
searchFlags: 0

dn: CN=sudoRole,CN=Schema,CN=Configuration,${domain_base}
changetype: add
objectClass: top
objectClass: classSchema
cn: sudoRole
governsID: 1.3.6.1.4.1.15953.9.2.1
rDNAttID: cn
adminDisplayName: sudoRole
adminDescription: Sudoer Entries
objectClassCategory: 1
lDAPDisplayName: sudoRole
name: sudoRole
systemOnly: FALSE
systemPossSuperiors: container
systemPossSuperiors: organizationalUnit
systemPossSuperiors: domain
mayContain: sudoCommand
mayContain: sudoHost
mayContain: sudoOption
mayContain: sudoRunAsUser
mayContain: sudoRunAsGroup
mayContain: sudoUser
mustContain: cn
EOF

    mkdir -p "$SAMBA_LOGS"
    local log_file="${SAMBA_LOGS}/sudo-schema-setup.log"

    # ldbmodify against the LOCAL ldb file. No daemon involved, no network,
    # no LDAP connection — this is a direct, offline database file edit,
    # which is why it must happen here (before supervisord starts samba)
    # rather than after.
    if ldbmodify -H "$sam_ldb" "$schema_ldif" \
        --option="dsdb:schema update allowed"=true \
        >> "$log_file" 2>&1; then
        echo "[Samba] sudoRole schema attributes/class loaded successfully."
    else
        local import_exit=$?
        echo "[Samba] WARNING: ldbmodify exited with status ${import_exit}. Checking ${log_file} for details."
        echo "[Samba]          This can be harmless if the schema was already partially present."
    fi
    rm -f "$schema_ldif"

    # Verify the attribute actually landed before declaring success. This
    # check also uses the local ldb file directly (no daemon required).
    if ! ldbsearch -H "$sam_ldb" \
        -b "CN=sudoUser,CN=Schema,CN=Configuration,${domain_base}" \
        -s base "(objectClass=*)" cn >> "$log_file" 2>&1; then
        echo "[Samba] ERROR: sudoUser attribute not found in schema after import. Schema setup FAILED."
        echo "[Samba]        See ${log_file} for details. Will retry on next container restart."
        return
    fi
    echo "[Samba] Verified: sudoUser attribute present in schema."

    # Create the ou=sudoers container. This one CAN go over normal LDAP
    # once samba is running later — but since we're already doing local
    # ldb operations and don't want a second code path waiting on the
    # daemon, do it the same way here for consistency. ou=sudoers is a
    # regular object, not a schema object, so this is uncontroversial.
    local ou_ldif
    ou_ldif=$(mktemp /tmp/sudo-ou-XXXXXX.ldif)
    cat > "$ou_ldif" <<EOF
dn: ou=sudoers,${domain_base}
changetype: add
objectClass: top
objectClass: organizationalUnit
ou: sudoers
description: Sudo rules for domain-joined Linux hosts
EOF
    if ldbadd -H "$sam_ldb" "$ou_ldif" >> "$log_file" 2>&1; then
        echo "[Samba] ou=sudoers container created."
    else
        echo "[Samba] Note: ou=sudoers create step reported non-zero exit (likely already exists) — continuing."
    fi
    rm -f "$ou_ldif"

    touch "$sudo_schema_loaded"
    echo "[Samba] sudoRole schema setup complete. Marker written: ${sudo_schema_loaded}"
}
