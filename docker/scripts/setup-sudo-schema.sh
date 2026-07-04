#!/bin/bash
# =============================================================================
# Load the sudoRole schema extension and create ou=sudoers.
#
# Schema updates must be applied directly to the local sam.ldb file using
# ldbmodify with samba stopped. Two separate passes are required:
#   Pass 1 — attribute definitions (sudoUser, sudoHost, etc.)
#   Pass 2 — the sudoRole objectClass (references the attributes by
#             lDAPDisplayName, so they must be committed first)
# =============================================================================

setup_sudo_schema() {
    local sam_ldb="/var/lib/samba/private/sam.ldb"
    local sudo_schema_loaded="${SAMBA_DATA}/.sudo-schema-loaded"
    local log_file="${SAMBA_LOGS}/sudo-schema-setup.log"

    mkdir -p "$SAMBA_LOGS"

    if [ -f "$sudo_schema_loaded" ]; then
        echo "[Samba] sudoRole schema already loaded."
        return
    fi

    if [ -f "$SAMBA_JOINED" ]; then
        echo "[Samba] Replica DC — sudoRole schema arrives via AD replication. Skipping."
        return
    fi

    if [ ! -f "$sam_ldb" ]; then
        echo "[Samba] WARNING: ${sam_ldb} not found — domain not yet provisioned? Skipping."
        return
    fi

    local domain_base
    domain_base=$(echo "${SAMBA_REALM}" | tr '[:upper:]' '[:lower:]' | awk -F'.' '{
        for (i=1; i<=NF; i++) printf "dc=%s%s", $i, (i<NF ? "," : "")
    }')

    echo "[Samba] Loading sudoRole schema into ${domain_base} (offline, via ldbmodify)..."

    # ------------------------------------------------------------------
    # Pass 1: attribute definitions only
    # ------------------------------------------------------------------
    local attrs_ldif
    attrs_ldif=$(mktemp /tmp/sudo-attrs-XXXXXX.ldif)

    cat > "$attrs_ldif" <<EOF
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
EOF

    echo "[Samba] Pass 1: loading attribute definitions..." | tee -a "$log_file"
    if ldbmodify -H "$sam_ldb" "$attrs_ldif" \
        --option="dsdb:schema update allowed"=true \
        >> "$log_file" 2>&1; then
        echo "[Samba] Pass 1: attributes loaded successfully."
    else
        local rc=$?
        echo "[Samba] WARNING: Pass 1 ldbmodify exited ${rc} — may be harmless if attributes already exist." | tee -a "$log_file"
    fi
    rm -f "$attrs_ldif"

    # Verify at least one attribute landed before continuing to Pass 2
    if ! ldbsearch -H "$sam_ldb" \
        -b "CN=sudoUser,CN=Schema,CN=Configuration,${domain_base}" \
        -s base "(objectClass=*)" cn >> "$log_file" 2>&1; then
        echo "[Samba] ERROR: sudoUser attribute not found after Pass 1. Aborting — will retry on next restart." | tee -a "$log_file"
        return
    fi
    echo "[Samba] Pass 1 verified: sudoUser attribute present."

    # ------------------------------------------------------------------
    # Pass 2: objectClass definition — now that the attributes are known
    # to the schema, mayContain references will resolve correctly
    # ------------------------------------------------------------------
    local class_ldif
    class_ldif=$(mktemp /tmp/sudo-class-XXXXXX.ldif)

    cat > "$class_ldif" <<EOF
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

    echo "[Samba] Pass 2: loading sudoRole objectClass..." | tee -a "$log_file"
    if ldbmodify -H "$sam_ldb" "$class_ldif" \
        --option="dsdb:schema update allowed"=true \
        >> "$log_file" 2>&1; then
        echo "[Samba] Pass 2: sudoRole class loaded successfully."
    else
        local rc=$?
        echo "[Samba] WARNING: Pass 2 ldbmodify exited ${rc} — may be harmless if class already exists." | tee -a "$log_file"
    fi
    rm -f "$class_ldif"

    # Verify the class landed
    if ! ldbsearch -H "$sam_ldb" \
        -b "CN=sudoRole,CN=Schema,CN=Configuration,${domain_base}" \
        -s base "(objectClass=*)" cn >> "$log_file" 2>&1; then
        echo "[Samba] ERROR: sudoRole class not found after Pass 2. Aborting — will retry on next restart." | tee -a "$log_file"
        return
    fi
    echo "[Samba] Pass 2 verified: sudoRole class present."

    # ------------------------------------------------------------------
    # Create ou=sudoers container (regular object, fine via ldb directly)
    # ------------------------------------------------------------------
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
        echo "[Samba] Note: ou=sudoers already exists — continuing."
    fi
    rm -f "$ou_ldif"

    touch "$sudo_schema_loaded"
    echo "[Samba] sudoRole schema setup complete. Marker written: ${sudo_schema_loaded}" | tee -a "$log_file"
}
