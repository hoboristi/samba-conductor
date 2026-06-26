#!/bin/bash
# =============================================================================
# One-shot job: load the sudoRole schema extension and create ou=sudoers.
#
# This MUST run after the `samba` daemon is actually listening on LDAP —
# unlike the rest of samba-setup.sh, it cannot run during entrypoint.sh
# (before supervisord starts samba), because samba-tool needs to talk to a
# live LDAP server to perform a schema update.
#
# Designed to be invoked as its own supervisor program (autorestart=false)
# so it runs exactly once per container start, after waiting for samba to
# come up. Idempotent via the .sudo-schema-loaded marker file, so re-running
# it on every restart is harmless and cheap once the marker exists.
# =============================================================================
set -u

DATA_DIR="${DATA_DIR:-/data}"
SAMBA_DATA="${DATA_DIR}/samba"
SAMBA_LOGS="${DATA_DIR}/logs/samba"
SAMBA_JOINED="${SAMBA_DATA}/.joined"
SUDO_SCHEMA_LOADED="${SAMBA_DATA}/.sudo-schema-loaded"

mkdir -p "${SAMBA_LOGS}"
LOG_FILE="${SAMBA_LOGS}/sudo-schema-setup.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

if [ -f "$SUDO_SCHEMA_LOADED" ]; then
    log "sudoRole schema already loaded. Nothing to do."
    exit 0
fi

if [ -f "$SAMBA_JOINED" ]; then
    log "Replica DC — sudoRole schema arrives via AD replication. Nothing to do."
    exit 0
fi

# Wait for samba to actually be listening on LDAP before touching the schema.
# Schema updates are LDAP operations against the live server, not local
# database edits, so samba-tool needs a server to talk to.
log "Waiting for samba to accept LDAP connections on 127.0.0.1:389..."
RETRIES=0
MAX_RETRIES=60   # 60 x 2s = up to 2 minutes
while ! timeout 1 bash -c 'echo > /dev/tcp/127.0.0.1/389' 2>/dev/null; do
    RETRIES=$((RETRIES + 1))
    if [ "$RETRIES" -ge "$MAX_RETRIES" ]; then
        log "ERROR: samba did not start listening on LDAP after ${MAX_RETRIES} attempts. Giving up for this run."
        log "       Will retry automatically on next container restart."
        exit 1
    fi
    sleep 2
done
log "samba is listening. Proceeding with schema setup."

# A listening socket doesn't guarantee the DB is fully ready to accept
# schema writes immediately; give it a short grace period and then verify
# with an actual samba-tool query (which exercises the real LDAP path).
RETRIES=0
MAX_RETRIES=30   # 30 x 2s = up to 1 minute additional
while ! samba-tool domain info 127.0.0.1 >/dev/null 2>&1; do
    RETRIES=$((RETRIES + 1))
    if [ "$RETRIES" -ge "$MAX_RETRIES" ]; then
        log "ERROR: 'samba-tool domain info' did not succeed after ${MAX_RETRIES} attempts. Giving up for this run."
        log "       Will retry automatically on next container restart."
        exit 1
    fi
    sleep 2
done
log "samba-tool confirms the domain is queryable."

if [ -z "${SAMBA_REALM:-}" ]; then
    log "ERROR: SAMBA_REALM is not set in the environment. Cannot determine domain base DN."
    exit 1
fi

DOMAIN_BASE=$(echo "${SAMBA_REALM}" | tr '[:upper:]' '[:lower:]' | awk -F'.' '{
    for (i=1; i<=NF; i++) printf "dc=%s%s", $i, (i<NF ? "," : "")
}')

log "Loading sudoRole schema into ${DOMAIN_BASE}..."

SCHEMA_LDIF=$(mktemp /tmp/sudo-schema-XXXXXX.ldif)
trap 'rm -f "$SCHEMA_LDIF"' EXIT

cat > "$SCHEMA_LDIF" <<EOF
dn: CN=sudoUser,CN=Schema,CN=Configuration,${DOMAIN_BASE}
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

dn: CN=sudoHost,CN=Schema,CN=Configuration,${DOMAIN_BASE}
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

dn: CN=sudoCommand,CN=Schema,CN=Configuration,${DOMAIN_BASE}
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

dn: CN=sudoOption,CN=Schema,CN=Configuration,${DOMAIN_BASE}
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

dn: CN=sudoRunAsUser,CN=Schema,CN=Configuration,${DOMAIN_BASE}
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

dn: CN=sudoRunAsGroup,CN=Schema,CN=Configuration,${DOMAIN_BASE}
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

dn: CN=sudoRole,CN=Schema,CN=Configuration,${DOMAIN_BASE}
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

if samba-tool ldif-import "$SCHEMA_LDIF" \
    --option="dsdb:schema update allowed = true" \
    >> "$LOG_FILE" 2>&1; then
    log "sudoRole schema loaded successfully."
else
    IMPORT_EXIT=$?
    log "WARNING: sudoRole schema import exited with status ${IMPORT_EXIT}."
    log "         This is often harmless if the schema was already partially present —"
    log "         checking whether sudoUser is now queryable before deciding whether to retry later."
    if ! samba-tool schema attribute show sudoUser >/dev/null 2>&1; then
        log "ERROR: sudoUser attribute still not present after import attempt. Will retry on next restart."
        exit 1
    fi
    log "Confirmed sudoUser attribute exists despite non-zero exit — treating as success."
fi

# Create the ou=sudoers container. Don't fail the whole job if it already
# exists (e.g. a previous partial run already created it).
OU_LDIF=$(mktemp /tmp/sudo-ou-XXXXXX.ldif)
cat > "$OU_LDIF" <<EOF
dn: ou=sudoers,${DOMAIN_BASE}
changetype: add
objectClass: top
objectClass: organizationalUnit
ou: sudoers
description: Sudo rules for domain-joined Linux hosts
EOF
samba-tool ldif-import "$OU_LDIF" >> "$LOG_FILE" 2>&1 || log "Note: ou=sudoers create step reported non-zero exit (likely already exists) — continuing."
rm -f "$OU_LDIF"

# Verify before declaring success and writing the marker — this is the step
# that was missing before, which let failures slip past silently.
if samba-tool schema attribute show sudoUser >/dev/null 2>&1; then
    touch "$SUDO_SCHEMA_LOADED"
    log "ou=sudoers ready. sudoRole schema verified present. Marker written: ${SUDO_SCHEMA_LOADED}"
    exit 0
else
    log "ERROR: Verification failed — sudoUser attribute not queryable after setup. Marker NOT written, will retry on next restart."
    exit 1
fi
