#!/bin/bash
set -e

# =============================================================================
# Environment variables
# =============================================================================
SAMBA_REALM=${SAMBA_REALM:-"SAMDOM.EXAMPLE.COM"}
SAMBA_DOMAIN=${SAMBA_DOMAIN:-"SAMDOM"}
SAMBA_ADMIN_PASSWORD=${SAMBA_ADMIN_PASSWORD:-""}
SAMBA_DNS_FORWARDER=${SAMBA_DNS_FORWARDER:-"8.8.8.8"}
SAMBA_SERVER_ROLE=${SAMBA_SERVER_ROLE:-"dc"}
DATA_DIR=${DATA_DIR:-"/data"}

PORT=${PORT:-3000}

TEMPLATES_DIR="/etc/supervisor/templates"
CONF_DIR="/etc/supervisor/conf.d"

# =============================================================================
# Determine which services to start
# =============================================================================
ENABLE_WEBAPP=false
ENABLE_MONGODB=false

if [ -n "${ROOT_URL}" ]; then
  ENABLE_WEBAPP=true
  if [ -z "${MONGO_URL}" ]; then
    ENABLE_MONGODB=true
    MONGO_URL="mongodb://127.0.0.1:27017/samba-conductor"
  fi
fi

# =============================================================================
# Setup directories
# =============================================================================
SAMBA_LOGS="${DATA_DIR}/logs/samba"
mkdir -p "${SAMBA_LOGS}"

if [ "${ENABLE_MONGODB}" = true ]; then
  mkdir -p "${DATA_DIR}/mongodb" "${DATA_DIR}/logs/mongodb"
  chown -R conductor:conductor "${DATA_DIR}/mongodb" "${DATA_DIR}/logs/mongodb"
fi

if [ "${ENABLE_WEBAPP}" = true ]; then
  mkdir -p "${DATA_DIR}/logs/app"
  chown -R conductor:conductor "${DATA_DIR}/logs/app"
fi

# =============================================================================
# Run shared Samba setup (provision, kerberos, TLS, schema)
# setup_sudo_schema() runs here, offline via ldbmodify, before supervisord
# starts samba — the only correct window for Samba AD schema updates.
# =============================================================================
source /usr/local/lib/samba-setup.sh
setup_samba

# =============================================================================
# Assemble supervisor config from templates
# =============================================================================
rm -f "${CONF_DIR}"/*.conf

cp "${TEMPLATES_DIR}/samba.conf" "${CONF_DIR}/"

if [ "${ENABLE_MONGODB}" = true ]; then
  cp "${TEMPLATES_DIR}/mongodb.conf" "${CONF_DIR}/"
fi

if [ "${ENABLE_WEBAPP}" = true ]; then
  cp "${TEMPLATES_DIR}/webapp.conf" "${CONF_DIR}/"

  if [ -z "${METEOR_SETTINGS}" ]; then
    SAMBA_REALM_LOWER=$(echo "${SAMBA_REALM}" | tr '[:upper:]' '[:lower:]')
    BASE_DN="DC=$(echo "${SAMBA_REALM_LOWER}" | sed 's/\./,DC=/g')"
    METEOR_SETTINGS='{"samba":{"ldapUrl":"ldaps://127.0.0.1:636","baseDn":"'"${BASE_DN}"'","realm":"'"${SAMBA_REALM}"'","tlsRejectUnauthorized":false,"sessionTtlMinutes":30},"public":{"appInfo":{"name":"Samba Conductor"}}}'
  fi

  cat > /etc/samba-conductor.env <<ENVEOF
export ROOT_URL="${ROOT_URL}"
export PORT="${PORT}"
export MONGO_URL="${MONGO_URL}"
export METEOR_SETTINGS='${METEOR_SETTINGS}'
ENVEOF
fi

# =============================================================================
# Start
# =============================================================================
echo "=== Samba Conductor All-in-One ==="
echo "  Realm:    ${SAMBA_REALM}"
echo "  Services: samba$([ "${ENABLE_MONGODB}" = true ] && echo ', mongodb')$([ "${ENABLE_WEBAPP}" = true ] && echo ', webapp')"
[ "${ENABLE_WEBAPP}" = true ] && echo "  Web UI:   ${ROOT_URL}"
[ "${ENABLE_MONGODB}" = true ] && echo "  MongoDB:  internal" || ([ "${ENABLE_WEBAPP}" = true ] && echo "  MongoDB:  ${MONGO_URL}")
echo "  Data:     ${DATA_DIR}"

exec /usr/bin/supervisord -c /etc/supervisord.conf
