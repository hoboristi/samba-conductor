#!/bin/bash
# =============================================================================
# Shared Samba setup script
# Used by both samba-ad-dc (standalone) and all-in-one images
#
# Expects these variables to be set before sourcing:
#   SAMBA_REALM, SAMBA_DOMAIN, SAMBA_ADMIN_PASSWORD,
#   SAMBA_DNS_FORWARDER, SAMBA_SERVER_ROLE, DATA_DIR
#
# Optional (for replica mode):
#   SAMBA_JOIN_AS_DC=true     — join an existing domain as replica DC
#   SAMBA_PRIMARY_DC=hostname — primary DC to replicate from
#   SAMBA_SITE=site_name      — AD site name (optional)
# =============================================================================

SAMBA_DATA="${DATA_DIR}/samba"
SAMBA_CONFIG="${DATA_DIR}/samba-config"
SAMBA_LOGS="${DATA_DIR}/logs/samba"
TLS_DIR="${SAMBA_DATA}/private/tls"
SAMBA_PROVISIONED="${SAMBA_DATA}/.provisioned"
SAMBA_JOINED="${SAMBA_DATA}/.joined"
SUDO_SCHEMA_LOADED="${SAMBA_DATA}/.sudo-schema-loaded"

# -----------------------------------------------------------------------------
# Create directory structure and symlink standard paths to /data
# -----------------------------------------------------------------------------
setup_samba_directories() {
    mkdir -p "${SAMBA_DATA}" "${SAMBA_CONFIG}" "${SAMBA_LOGS}"

    [ -L /var/lib/samba ] || { rm -rf /var/lib/samba; ln -sf "${SAMBA_DATA}" /var/lib/samba; }
    [ -L /etc/samba ]     || { rm -rf /etc/samba;     ln -sf "${SAMBA_CONFIG}" /etc/samba; }
    [ -L /var/log/samba ] || { rm -rf /var/log/samba;  ln -sf "${SAMBA_LOGS}" /var/log/samba; }
}

# -----------------------------------------------------------------------------
# Provision a new AD domain (first run, primary DC only)
# -----------------------------------------------------------------------------
provision_samba_domain() {
    if [ -f "$SAMBA_PROVISIONED" ] || [ -f "$SAMBA_JOINED" ]; then
        echo "[Samba] Already provisioned/joined."
        return
    fi

    if [ -z "$SAMBA_ADMIN_PASSWORD" ]; then
        echo "ERROR: SAMBA_ADMIN_PASSWORD is required."
        exit 1
    fi

    echo "[Samba] Provisioning AD DC..."
    echo "  Realm:  ${SAMBA_REALM}"
    echo "  Domain: ${SAMBA_DOMAIN}"

    rm -f /etc/samba/smb.conf
    rm -rf /var/lib/samba/*

    samba-tool domain provision \
        --use-rfc2307 \
        --realm="${SAMBA_REALM}" \
        --domain="${SAMBA_DOMAIN}" \
        --server-role="${SAMBA_SERVER_ROLE}" \
        --dns-backend=SAMBA_INTERNAL \
        --adminpass="${SAMBA_ADMIN_PASSWORD}" \
        --option="dns forwarder = ${SAMBA_DNS_FORWARDER}" \
        --option="ad dc functional level = 2016"

    # Raise domain and forest functional levels to 2016
    samba-tool domain level raise --domain-level=2016 --forest-level=2016 || true

    touch "$SAMBA_PROVISIONED"
    echo "[Samba] Provisioned at Windows Server 2016 functional level."
}

# -----------------------------------------------------------------------------
# Join an existing domain as a replica DC
# -----------------------------------------------------------------------------
join_samba_domain() {
    if [ -f "$SAMBA_PROVISIONED" ] || [ -f "$SAMBA_JOINED" ]; then
        echo "[Samba] Already provisioned/joined."
        return
    fi

    if [ -z "$SAMBA_ADMIN_PASSWORD" ]; then
        echo "ERROR: SAMBA_ADMIN_PASSWORD is required for domain join."
        exit 1
    fi

    if [ -z "$SAMBA_PRIMARY_DC" ]; then
        echo "ERROR: SAMBA_PRIMARY_DC is required when SAMBA_JOIN_AS_DC=true."
        echo "  Set it to the hostname of the primary DC (e.g., dc1.samdom.example.com)"
        exit 1
    fi

    local realm_lower
    realm_lower=$(echo "${SAMBA_REALM}" | tr '[:upper:]' '[:lower:]')

    echo "[Samba] Joining domain as replica DC..."
    echo "  Realm:      ${SAMBA_REALM}"
    echo "  Primary DC: ${SAMBA_PRIMARY_DC}"

    # Resolve primary DC IP for DNS config
    local primary_ip
    primary_ip=$(getent hosts "${SAMBA_PRIMARY_DC}" 2>/dev/null | awk '{print $1}')
    if [ -z "$primary_ip" ]; then
        # Try resolving via DNS if getent fails
        primary_ip=$(dig +short "${SAMBA_PRIMARY_DC}" 2>/dev/null | head -1)
    fi
    if [ -z "$primary_ip" ]; then
        echo "ERROR: Cannot resolve ${SAMBA_PRIMARY_DC}. Check DNS configuration."
        exit 1
    fi

    echo "  Primary IP: ${primary_ip}"

    # Point DNS to the primary DC
    echo "nameserver ${primary_ip}" > /etc/resolv.conf

    rm -rf /var/lib/samba/*

    # Create smb.conf before join (needs sysvol/netlogon shares)
    mkdir -p /etc/samba /var/lib/samba/sysvol
    cat > /etc/samba/smb.conf <<EOF
[global]
    workgroup = ${SAMBA_DOMAIN}
    realm = ${SAMBA_REALM}
    server role = active directory domain controller
    dns forwarder = ${SAMBA_DNS_FORWARDER}
    interfaces = lo eth0
    bind interfaces only = no
    ad dc functional level = 2016

[sysvol]
    path = /var/lib/samba/sysvol
    read only = No

[netlogon]
    path = /var/lib/samba/sysvol/${realm_lower}/scripts
    read only = No
EOF
    mkdir -p "/var/lib/samba/sysvol/${realm_lower}/scripts"

    # Generate Kerberos config before join
    cat > /etc/krb5.conf <<EOF
[libdefaults]
    default_realm = ${SAMBA_REALM}
    dns_lookup_realm = false
    dns_lookup_kdc = true
[realms]
    ${SAMBA_REALM} = {
        kdc = ${primary_ip}
        admin_server = ${primary_ip}
        default_domain = ${realm_lower}
    }
[domain_realm]
    .${realm_lower} = ${SAMBA_REALM}
    ${realm_lower} = ${SAMBA_REALM}
EOF

    echo "[Samba] Waiting for primary DC to be ready..."
    local retries=0
    while ! samba-tool domain info "${primary_ip}" >/dev/null 2>&1; do
        retries=$((retries + 1))
        if [ $retries -ge 30 ]; then
            echo "ERROR: Primary DC not responding after 30 attempts."
            exit 1
        fi
        echo "  Waiting... (attempt ${retries}/30)"
        sleep 5
    done
    echo "[Samba] Primary DC is ready."

    local join_args=(
        "domain" "join" "${realm_lower}" "DC"
        "--server=${primary_ip}"
        "--dns-backend=SAMBA_INTERNAL"
        "--option=dns forwarder = ${SAMBA_DNS_FORWARDER}"
        "--option=interfaces = lo eth0"
        "-U" "Administrator%${SAMBA_ADMIN_PASSWORD}"
    )

    if [ -n "$SAMBA_SITE" ]; then
        join_args+=("--site=${SAMBA_SITE}")
    fi

    samba-tool "${join_args[@]}"

    touch "$SAMBA_JOINED"
    echo "[Samba] Successfully joined domain as replica DC."
}

# -----------------------------------------------------------------------------
# Ensure Kerberos configuration is correct
# -----------------------------------------------------------------------------
setup_kerberos() {
    if [ -f /var/lib/samba/private/krb5.conf ]; then
        cp /var/lib/samba/private/krb5.conf /etc/krb5.conf
    else
        local realm_lower
        realm_lower=$(echo "${SAMBA_REALM}" | tr '[:upper:]' '[:lower:]')
        cat > /etc/krb5.conf <<EOF
[libdefaults]
    default_realm = ${SAMBA_REALM}
    dns_lookup_realm = false
    dns_lookup_kdc = true
[realms]
    ${SAMBA_REALM} = {
        default_domain = ${realm_lower}
    }
[domain_realm]
    .${realm_lower} = ${SAMBA_REALM}
    ${realm_lower} = ${SAMBA_REALM}
EOF
    fi
    echo "[Samba] Kerberos configured: $(grep default_realm /etc/krb5.conf | head -1 | xargs)"
}

# -----------------------------------------------------------------------------
# Generate self-signed TLS certificate if missing
# -----------------------------------------------------------------------------
setup_tls() {
    local hostname_part
    hostname_part="${HOSTNAME:-$(cat /etc/hostname 2>/dev/null || echo 'dc')}"

    if [ -f "${TLS_DIR}/cert.pem" ] && [ -f "${TLS_DIR}/key.pem" ]; then
        echo "[Samba] TLS certificate exists."
    else
        echo "[Samba] Generating self-signed TLS certificate..."
        mkdir -p "${TLS_DIR}"
        local realm_lower fqdn
        realm_lower=$(echo "${SAMBA_REALM}" | tr '[:upper:]' '[:lower:]')
        fqdn="${hostname_part}.${realm_lower}"

        openssl req -x509 -nodes -newkey rsa:4096 \
            -keyout "${TLS_DIR}/key.pem" \
            -out "${TLS_DIR}/cert.pem" \
            -days 3650 \
            -subj "/CN=${fqdn}/O=${SAMBA_DOMAIN}/C=BR" \
            -addext "subjectAltName=DNS:${fqdn},DNS:localhost,IP:127.0.0.1" \
            2>/dev/null

        cp "${TLS_DIR}/cert.pem" "${TLS_DIR}/ca.pem"
        chmod 600 "${TLS_DIR}/key.pem"
        chmod 644 "${TLS_DIR}/cert.pem" "${TLS_DIR}/ca.pem"
        echo "[Samba] TLS certificate generated for ${fqdn}."
    fi

    # Configure smb.conf for TLS
    if ! grep -q "tls certfile" /etc/samba/smb.conf 2>/dev/null; then
        sed -i "/^\[global\]/a \\
\\ttls enabled  = yes\\n\\
\\ttls certfile = ${TLS_DIR}/cert.pem\\n\\
\\ttls keyfile  = ${TLS_DIR}/key.pem\\n\\
\\ttls cafile   = ${TLS_DIR}/ca.pem" /etc/samba/smb.conf
        echo "[Samba] TLS configured in smb.conf."
    fi
}

# -----------------------------------------------------------------------------
# Extend the AD schema with the sudoRole objectClass and create ou=sudoers.
# This enables storing sudo rules in AD for consumption by sssd's
# sudo_provider = ldap on domain-joined Linux hosts.
#
# Only runs on the primary/provisioning DC — replica DCs inherit the schema
# via normal AD replication, so this is skipped when SAMBA_JOIN_AS_DC=true.
# Idempotent: guarded by SUDO_SCHEMA_LOADED marker file.
# -----------------------------------------------------------------------------
setup_sudo_schema() {
    if [ -f "$SUDO_SCHEMA_LOADED" ]; then
        echo "[Samba] sudoRole schema already loaded."
        return
    fi

    if [ "${SAMBA_JOIN_AS_DC}" = "true" ]; then
        echo "[Samba] Replica DC — sudoRole schema will arrive via replication. Skipping."
        return
    fi

    if ! samba-tool domain info 127.0.0.1 >/dev/null 2>&1; then
        echo "[Samba] WARNING: Samba is not responding yet — skipping sudoRole schema setup."
        echo "         It will be retried on next container start."
        return
    fi

    local domain_base
    domain_base=$(echo "${SAMBA_REALM}" | tr '[:upper:]' '[:lower:]' | awk -F'.' '{
        for (i=1; i<=NF; i++) printf "dc=%s%s", $i, (i<NF ? "," : "")
    }')

    echo "[Samba] Loading sudoRole schema into ${domain_base}..."

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

    if samba-tool ldif-import "$schema_ldif" \
        --option="dsdb:schema update allowed = true" \
        >> "${SAMBA_LOGS}/sudo-schema-setup.log" 2>&1; then
        echo "[Samba] sudoRole schema loaded successfully."
    else
        echo "[Samba] WARNING: sudoRole schema import reported errors — check ${SAMBA_LOGS}/sudo-schema-setup.log"
        echo "         (this is often harmless if the schema was already partially present)"
    fi

    rm -f "$schema_ldif"

    # Create the ou=sudoers container, ignoring failure if it already exists
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
    samba-tool ldif-import "$ou_ldif" >> "${SAMBA_LOGS}/sudo-schema-setup.log" 2>&1 || true
    rm -f "$ou_ldif"

    touch "$SUDO_SCHEMA_LOADED"
    echo "[Samba] ou=sudoers ready."
}

# -----------------------------------------------------------------------------
# Run full Samba setup
# -----------------------------------------------------------------------------
setup_samba() {
    setup_samba_directories

    if [ "${SAMBA_JOIN_AS_DC}" = "true" ]; then
        join_samba_domain
    else
        provision_samba_domain
    fi

    setup_kerberos
    setup_tls
    setup_sudo_schema
}
