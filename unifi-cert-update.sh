#!/usr/bin/env bash
#
# unifi-cert-update.sh - Install an ACME certificate into UniFi OS Server
#
# Usage: sudo ./unifi-cert-update.sh [--timeout=SECONDS] [--force]
#
#   --timeout=SECONDS  Override CERT_FRESHNESS_TIMEOUT for this run
#   --force            Skip the freshness check and install the current certificate
#
# This script:
# 1. Verifies certificates are fresh (detects if new cert available)
# 2. Validates all certificate files
# 3. Copies certificates to UniFi container
# 4. Restarts UniFi
# 5. Verifies UniFi is serving the new certificate
#
# Certificate Freshness Detection:
#   - Compares current serial to last known serial
#   - If serial changed = new certificate (proceed immediately)
#   - If serial unchanged = wait for copy (poll hash for up to --timeout seconds)
#
# Recommended: Run only when ACME cert update completes and new certs copied

set -euo pipefail

# Set a full PATH for non-interactive SSH sessions (for example, an ACME client's remote command)
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

############################################################################################
################################### Configurable Settings: #################################
DOMAIN_NAME="device.example.com"
STAGING_DIR="/etc/letsencrypt/live"   # Directory the ACME client copies certificates into

# UniFi OS Server installation
UOS_SERVICE="uosserver.service"   # systemd unit that runs UniFi OS Server
UOS_USER="uosserver"              # User that owns the UniFi OS Server container
UOS_DATA_DIR="/home/uosserver/.local/share/containers/storage/volumes/uosserver_data/_data"
UOS_HTTPS_PORT="11443"            # Port the UniFi OS Server web interface listens on

# UniFi paths (derived from UOS_DATA_DIR)
UNIFI_DEST_CERT="${UOS_DATA_DIR}/custom_certificates/unifi-os.crt"
UNIFI_DEST_KEY="${UOS_DATA_DIR}/custom_certificates/unifi-os.key"
UNIFI_LOCAL_YML="${UOS_DATA_DIR}/unifi-core/config/overrides/local.yml"

# The same files as seen from inside the container (UOS_DATA_DIR is mounted at /data)
CONTAINER_CERT_PATH="/data/custom_certificates/unifi-os.crt"
CONTAINER_KEY_PATH="/data/custom_certificates/unifi-os.key"

# Certificate freshness tracking
SERIAL_BASELINE_FILE="${STAGING_DIR}/unifi-cert-serial.baseline"
HASH_BASELINE_FILE="${STAGING_DIR}/unifi-cert-hash.baseline"

# Timeouts and retry logic
CERT_FRESHNESS_TIMEOUT="${CERT_FRESHNESS_TIMEOUT:-300}"  # 5 minutes (wait for cert copy)
CERT_CHECK_MAX_RETRIES="${CERT_CHECK_MAX_RETRIES:-10}"    # Retries for initial file checks
UNIFI_RESTART_TIMEOUT="${UNIFI_RESTART_TIMEOUT:-60}"      # Max time to wait for UniFi restart
CERT_VERIFY_TIMEOUT="${CERT_VERIFY_TIMEOUT:-60}"          # Max time to confirm the served certificate

# Log file (written to the same directory as this script)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/unifi-cert-update.log"
LOG_MAX_BYTES=1048576             # Rotate the log file to .1 when it exceeds 1 MB

# Housekeeping
CONFIG_BACKUP_KEEP=10             # Number of local.yml backups to keep
LOCK_FILE="/run/unifi-cert-update.lock"

############################################################################################

# Runtime state
FORCE=0
UNIFI_STOPPED=0
CERT_COMPAT_ISSUES=""             # Differences from the tested certificate configuration

# =============================================================================
# Logging
# =============================================================================
rotate_log() {
    if [ -f "${LOG_FILE}" ]; then
        local size
        size=$(stat -c %s "${LOG_FILE}" 2>/dev/null || echo 0)
        if [ "${size}" -gt "${LOG_MAX_BYTES}" ]; then
            mv -f "${LOG_FILE}" "${LOG_FILE}.1" 2>/dev/null || true
        fi
    fi
}

log() {
    local timestamp level msg
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    level="$1"
    shift
    msg="$*"

    local line priority
    case "$level" in
        INFO)  line="[${timestamp}] ℹ️  ${msg}";          priority="info" ;;
        OK)    line="[${timestamp}] ✅ ${msg}";           priority="notice" ;;
        ERR)   line="[${timestamp}] ❌ ERROR: ${msg}";    priority="err" ;;
        WARN)  line="[${timestamp}] ⚠️  WARNING: ${msg}"; priority="warning" ;;
        *)     line="[${timestamp}] ${msg}";             priority="info" ;;
    esac

    # Print to the console (errors to stderr)
    if [ "$level" = "ERR" ]; then
        echo "${line}" >&2
    else
        echo "${line}"
    fi

    # Append to the log file
    echo "${line}" >> "${LOG_FILE}" 2>/dev/null || true

    # Also log to syslog
    logger -t "unifi-cert-update" -p "user.${priority}" "${msg}" 2>/dev/null || true
}

# =============================================================================
# Error Handling
# =============================================================================
cleanup() {
    local exit_code=$?
    trap - EXIT

    if [ ${exit_code} -ne 0 ]; then
        log ERR "Script failed (exit code: ${exit_code})"

        # Never leave UniFi OS Server stopped because of a failure
        if [ "${UNIFI_STOPPED}" -eq 1 ]; then
            log WARN "UniFi OS Server is stopped - attempting to restart it..."
            if systemctl start "${UOS_SERVICE}" >/dev/null 2>&1 9>&-; then
                log OK "UniFi OS Server restarted"
            else
                log ERR "Restart failed - start it manually: systemctl start ${UOS_SERVICE}"
            fi
        fi
    fi

    exit ${exit_code}
}

trap cleanup EXIT

fail() {
    log ERR "$*"
    exit 1
}

# =============================================================================
# Locking (prevents overlapping runs)
# =============================================================================
acquire_lock() {
    if ! command -v flock >/dev/null 2>&1; then
        log WARN "flock not available - continuing without a lock"
        return 0
    fi

    exec 9>"${LOCK_FILE}" || fail "Cannot open lock file: ${LOCK_FILE}"
    if ! flock -n 9; then
        fail "Another instance of this script is already running (lock: ${LOCK_FILE})"
    fi
}

# =============================================================================
# File Validation
# =============================================================================
require_file() {
    local path="$1" desc="$2" max_retries="${3:-3}"
    local retries=0

    while [ ${retries} -lt ${max_retries} ]; do
        if [ -f "${path}" ] && [ -r "${path}" ]; then
            log OK "Found: ${desc}"
            return 0
        fi

        retries=$((retries + 1))
        if [ ${retries} -lt ${max_retries} ]; then
            log WARN "${desc} not found (attempt ${retries}/${max_retries}), retrying in 2s..."
            sleep 2
        fi
    done

    fail "Required file not found or not readable: ${path} (${desc})"
}

# =============================================================================
# Certificate Utility Functions
# =============================================================================

# get_cert_serial - extract X.509 serial number
get_cert_serial() {
    local cert_path="$1"

    if [ ! -f "${cert_path}" ]; then
        echo "error"
        return 1
    fi

    local serial
    serial=$(openssl x509 -in "${cert_path}" -noout -serial 2>/dev/null | cut -d= -f2) || {
        log ERR "Failed to extract serial from: ${cert_path}"
        return 1
    }

    [ -n "${serial}" ] || {
        log ERR "Certificate serial is empty: ${cert_path}"
        return 1
    }

    echo "${serial}"
}

# get_cert_hash - compute SHA256 hash of certificate
get_cert_hash() {
    local cert_path="$1"

    if [ ! -f "${cert_path}" ]; then
        echo "error"
        return 1
    fi

    sha256sum "${cert_path}" 2>/dev/null | awk '{print $1}' || {
        log ERR "Failed to compute hash: ${cert_path}"
        return 1
    }
}

# get_served_serial - serial of the certificate UniFi OS Server is currently serving
get_served_serial() {
    local output
    output=$(timeout 10 openssl s_client -connect "localhost:${UOS_HTTPS_PORT}" \
                 -servername "${DOMAIN_NAME}" </dev/null 2>/dev/null \
             | openssl x509 -noout -serial 2>/dev/null) || true
    echo "${output#serial=}"
}

# =============================================================================
# Certificate Freshness Validation
# =============================================================================

# validate_cert_freshness - ensures certificate is fresh (new renewal detected)
# Uses serial number first (fast), then hash polling if needed
# On first run (no baseline), skips freshness check and proceeds to install
validate_cert_freshness() {
    local cert_file="$1"
    local timeout_secs="${2:-300}"

    log INFO "Validating certificate freshness (timeout: ${timeout_secs}s)..."

    # Get current certificate serial
    local current_serial
    current_serial=$(get_cert_serial "${cert_file}") || return 1
    log INFO "Current certificate serial: ${current_serial}"

    # Check if baseline exists (first run detection)
    if [ ! -f "${SERIAL_BASELINE_FILE}" ]; then
        log INFO "First run: no baseline stored - proceeding with installation"
        log INFO "Baseline will be created at end of script for future runs"
        return 0
    fi

    # Baseline exists - check if serial changed
    local baseline_serial
    baseline_serial=$(cat "${SERIAL_BASELINE_FILE}" 2>/dev/null || echo "")

    if [ -z "${baseline_serial}" ]; then
        log INFO "Baseline serial is empty - treating as first run"
        return 0
    fi

    if [ "${baseline_serial}" != "${current_serial}" ]; then
        log OK "Certificate serial changed: ${baseline_serial} → ${current_serial} (NEW CERT DETECTED)"
        return 0
    fi

    # Serial unchanged - cert copy might be in progress
    log WARN "Certificate serial unchanged: ${current_serial} (waiting for copy...)"
    log INFO "Polling for hash change (up to ${timeout_secs}s). Use --force to install the current certificate."

    local initial_hash current_hash start_time elapsed_secs
    initial_hash=$(get_cert_hash "${cert_file}") || return 1
    log INFO "Initial certificate hash: ${initial_hash}"
    start_time=$(date +%s)

    while true; do
        current_hash=$(get_cert_hash "${cert_file}") || return 1
        elapsed_secs=$(( $(date +%s) - start_time ))

        # Log progress periodically (every 10 seconds)
        if [ $((elapsed_secs % 10)) -eq 0 ] && [ ${elapsed_secs} -gt 0 ]; then
            log INFO "Still waiting for certificate update... (${elapsed_secs}s/${timeout_secs}s)"
        fi

        if [ "${current_hash}" != "${initial_hash}" ]; then
            log OK "Certificate hash changed - new certificate detected"
            log OK "Hash: ${initial_hash} → ${current_hash}"
            return 0
        fi

        if [ ${elapsed_secs} -ge ${timeout_secs} ]; then
            log ERR "Timeout waiting for certificate update (${timeout_secs}s elapsed)"
            log ERR "Certificate is stale or copy did not complete"
            return 1
        fi

        sleep 1
    done
}

# =============================================================================
# Certificate Validation
# =============================================================================

validate_cert_format() {
    local cert_file="$1" key_file="$2"

    log INFO "Validating certificate format and key pair..."

    # Validate certificate format
    if ! openssl x509 -in "${cert_file}" -noout >/dev/null 2>&1; then
        fail "Certificate is not valid PEM format: ${cert_file}"
    fi
    log OK "Certificate format valid"

    # Validate key format
    if ! openssl pkey -in "${key_file}" -noout >/dev/null 2>&1; then
        fail "Private key is not valid PEM format: ${key_file}"
    fi
    log OK "Private key format valid"

    # Validate cert/key pair match by comparing public keys
    local cert_pubkey key_pubkey

    cert_pubkey=$(openssl x509 -noout -pubkey -in "${cert_file}" 2>/dev/null | \
                  openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}') || {
        fail "Failed to extract public key from certificate"
    }

    key_pubkey=$(openssl pkey -in "${key_file}" -pubout 2>/dev/null | \
                 openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}') || {
        fail "Failed to extract public key from private key (ensure key is RSA/EC format)"
    }

    if [ "${cert_pubkey}" != "${key_pubkey}" ]; then
        log ERR "Certificate public key:   ${cert_pubkey}"
        log ERR "Private key public key:   ${key_pubkey}"
        fail "Certificate and key do not match (public keys differ)"
    fi
    log OK "Certificate and key pair match"
}

validate_cert_validity() {
    local cert_file="$1"

    log INFO "Checking certificate validity dates..."

    local not_before not_after now
    not_before=$(openssl x509 -in "${cert_file}" -noout -startdate 2>/dev/null | cut -d= -f2) \
        || fail "Could not read certificate start date"
    not_after=$(openssl x509 -in "${cert_file}" -noout -enddate 2>/dev/null | cut -d= -f2) \
        || fail "Could not read certificate end date"
    now=$(date +%s)

    local not_before_epoch not_after_epoch
    not_before_epoch=$(date -d "${not_before}" +%s 2>/dev/null) || fail "Could not parse start date: ${not_before}"
    not_after_epoch=$(date -d "${not_after}" +%s 2>/dev/null) || fail "Could not parse end date: ${not_after}"

    # Check if cert is not yet valid
    if [ "${not_before_epoch}" -gt "${now}" ]; then
        fail "Certificate is not yet valid (valid from ${not_before})"
    fi

    # Check if cert is expired
    if [ "${not_after_epoch}" -le "${now}" ]; then
        fail "Certificate is expired (expired ${not_after})"
    fi
    log OK "Certificate validity dates OK (expires ${not_after})"

    # Warn if expiring soon
    local days_until_expiry=$(( (not_after_epoch - now) / 86400 ))
    if [ "${days_until_expiry}" -lt 30 ]; then
        log WARN "Certificate expires in ${days_until_expiry} days"
    fi
}

# check_cert_compatibility - warn when the certificate differs from the tested
# configuration (RSA 2048-bit or larger, single host name). UniFi OS Server may reject other
# certificates and generate a self-signed one. This check never stops the install.
check_cert_compatibility() {
    local cert_file="$1"
    local text algo bits sans san_count

    log INFO "Checking certificate against the tested configuration (RSA 2048-bit or larger, single host name)..."

    if ! text=$(openssl x509 -in "${cert_file}" -noout -text 2>/dev/null); then
        log WARN "Could not read certificate details - skipping compatibility check"
        return 0
    fi

    # Key type and size
    algo=$(printf '%s\n' "${text}" | grep -m1 'Public Key Algorithm:' | sed 's/.*Public Key Algorithm: *//') || true
    bits=$(printf '%s\n' "${text}" | grep -m1 -oE 'Public-Key: [(][0-9]+ bit[)]' | grep -oE '[0-9]+') || true

    case "${algo}" in
        rsaEncryption)
            if ! [[ "${bits}" =~ ^[0-9]+$ ]]; then
                CERT_COMPAT_ISSUES+="RSA key of unknown size; "
                log WARN "Could not determine the RSA key size. RSA 2048-bit or larger is recommended."
            elif [ "${bits}" -lt 2048 ]; then
                CERT_COMPAT_ISSUES+="RSA ${bits}-bit key; "
                log WARN "Certificate uses an RSA ${bits}-bit key. RSA 2048-bit or larger is recommended."
            fi
            ;;
        id-ecPublicKey)
            CERT_COMPAT_ISSUES+="EC ${bits:-unknown}-bit key; "
            log WARN "Certificate uses an EC ${bits:-unknown}-bit key. UniFi OS Server may reject EC keys and generate a self-signed certificate. RSA 2048-bit or larger is recommended."
            ;;
        *)
            CERT_COMPAT_ISSUES+="key type ${algo:-unknown}; "
            log WARN "Certificate key type is ${algo:-unknown}. RSA 2048-bit or larger is recommended."
            ;;
    esac

    # Subject Alternative Names
    sans=$(printf '%s\n' "${text}" | grep -A1 'X509v3 Subject Alternative Name' | tail -n +2 \
           | tr ',' '\n' | sed 's/^ *//' | grep -v '^$') || true
    san_count=$(printf '%s\n' "${sans}" | grep -c .) || true

    if [ "${san_count:-0}" -gt 1 ]; then
        CERT_COMPAT_ISSUES+="${san_count} Subject Alternative Names; "
        log WARN "Certificate has ${san_count} Subject Alternative Names ($(printf '%s\n' "${sans}" | paste -sd ',' - | sed 's/,/, /g')). Only a certificate for a single host name has been tested."
    fi

    if [ -z "${CERT_COMPAT_ISSUES}" ]; then
        log OK "Certificate matches the tested configuration"
    else
        log WARN "Continuing with installation. If UniFi OS Server reverts to a self-signed certificate, see Certificate requirements in the README."
    fi
}

# =============================================================================
# UniFi Operations
# =============================================================================

unifi_stop() {
    log INFO "Stopping UniFi OS Server (${UOS_SERVICE})..."

    local retries=0 max_retries=3 stop_output
    while [ ${retries} -lt ${max_retries} ]; do
        if stop_output=$(systemctl stop "${UOS_SERVICE}" 2>&1 9>&-); then
            UNIFI_STOPPED=1
            log OK "UniFi OS Server stopped"
            return 0
        fi

        retries=$((retries + 1))
        log WARN "UniFi stop failed (attempt ${retries}/${max_retries}). Output: ${stop_output}"

        if [ ${retries} -lt ${max_retries} ]; then
            log INFO "Retrying in 2s..."
            sleep 2
        fi
    done

    fail "Failed to stop UniFi OS Server after ${max_retries} attempts"
}

unifi_start() {
    log INFO "Starting UniFi OS Server (${UOS_SERVICE})..."

    local start_output
    if ! start_output=$(systemctl start "${UOS_SERVICE}" 2>&1 9>&-); then
        fail "Failed to start UniFi OS Server. Output: ${start_output}"
    fi
    UNIFI_STOPPED=0

    log INFO "Waiting for UniFi to fully start..."
    local start_time elapsed_secs
    start_time=$(date +%s)

    while true; do
        elapsed_secs=$(( $(date +%s) - start_time ))

        if curl -s -k --max-time 5 "https://localhost:${UOS_HTTPS_PORT}" >/dev/null 2>&1; then
            log OK "UniFi OS Server started and responsive"
            return 0
        fi

        if [ ${elapsed_secs} -ge ${UNIFI_RESTART_TIMEOUT} ]; then
            log WARN "UniFi startup timeout (${UNIFI_RESTART_TIMEOUT}s) - may still be starting"
            return 0
        fi

        sleep 2
    done
}

# verify_served_cert - confirm UniFi OS Server is serving the installed certificate
# UniFi OS Server replaces a certificate it rejects with a self-signed one, so a
# successful restart alone does not prove the new certificate is in use.
verify_served_cert() {
    local cert_file="$1"
    local expected_serial served_serial start_time elapsed_secs

    expected_serial=$(get_cert_serial "${cert_file}") || return 1
    log INFO "Verifying UniFi is serving the new certificate (up to ${CERT_VERIFY_TIMEOUT}s)..."
    start_time=$(date +%s)

    while true; do
        served_serial=$(get_served_serial)
        elapsed_secs=$(( $(date +%s) - start_time ))

        if [ "${served_serial}" = "${expected_serial}" ]; then
            log OK "UniFi is serving the new certificate (serial ${served_serial})"
            return 0
        fi

        if [ ${elapsed_secs} -ge ${CERT_VERIFY_TIMEOUT} ]; then
            break
        fi

        sleep 5
    done

    if [ -z "${served_serial}" ]; then
        log WARN "Could not connect to https://localhost:${UOS_HTTPS_PORT} to verify the served certificate"
        return 0
    fi

    log ERR "Expected serial: ${expected_serial}"
    log ERR "Served serial:   ${served_serial}"
    if [ -n "${CERT_COMPAT_ISSUES}" ]; then
        log ERR "Likely cause - certificate differs from the tested configuration: ${CERT_COMPAT_ISSUES%; }"
    fi
    fail "UniFi is not serving the new certificate. It most likely rejected the certificate and generated a self-signed one. See Certificate requirements in the README."
}

# =============================================================================
# Certificate Installation
# =============================================================================

install_certs() {
    local cert_file="$1" key_file="$2"

    log INFO "Preparing certificate installation..."

    local cert_dir key_dir
    cert_dir=$(dirname "${UNIFI_DEST_CERT}")
    key_dir=$(dirname "${UNIFI_DEST_KEY}")

    mkdir -p "${cert_dir}" >/dev/null 2>&1 || fail "Failed to create certificate directory: ${cert_dir}"
    mkdir -p "${key_dir}" >/dev/null 2>&1 || fail "Failed to create key directory: ${key_dir}"

    log INFO "Copying certificate to UniFi..."
    cp "${cert_file}" "${UNIFI_DEST_CERT}" || fail "Failed to copy certificate to ${UNIFI_DEST_CERT}"

    log INFO "Copying private key to UniFi..."
    cp "${key_file}" "${UNIFI_DEST_KEY}" || fail "Failed to copy key to ${UNIFI_DEST_KEY}"

    # Fix permissions
    chmod 600 "${UNIFI_DEST_KEY}" >/dev/null 2>&1 || fail "Failed to set key permissions"
    chmod 644 "${UNIFI_DEST_CERT}" >/dev/null 2>&1 || fail "Failed to set certificate permissions"

    # The rootless container runs as UOS_USER and cannot read root-owned files
    chown "${UOS_USER}:${UOS_USER}" "${cert_dir}" "${UNIFI_DEST_CERT}" >/dev/null 2>&1 \
        || fail "Failed to set certificate ownership to ${UOS_USER}"
    if [ "${key_dir}" != "${cert_dir}" ]; then
        chown "${UOS_USER}:${UOS_USER}" "${key_dir}" >/dev/null 2>&1 \
            || fail "Failed to set key directory ownership to ${UOS_USER}"
    fi
    chown "${UOS_USER}:${UOS_USER}" "${UNIFI_DEST_KEY}" >/dev/null 2>&1 \
        || fail "Failed to set key ownership to ${UOS_USER}"

    log OK "Certificates copied, permissions and ownership set"
}

prune_config_backups() {
    local backup_dir="$1"
    local count=0 file

    [ -d "${backup_dir}" ] || return 0

    # Newest first; delete everything beyond CONFIG_BACKUP_KEEP
    while IFS= read -r file; do
        count=$((count + 1))
        if [ ${count} -gt ${CONFIG_BACKUP_KEEP} ]; then
            rm -f "${file}" 2>/dev/null || true
        fi
    done < <(ls -1t "${backup_dir}"/local.yml_* 2>/dev/null || true)
}

update_unifi_config() {
    local local_yml="${UNIFI_LOCAL_YML}"
    local overrides_dir backup_dir
    overrides_dir=$(dirname "${local_yml}")
    backup_dir="${STAGING_DIR}/unifi-os/config_backups"

    log INFO "Updating UniFi configuration..."

    mkdir -p "${overrides_dir}" >/dev/null 2>&1 || fail "Failed to create config directory: ${overrides_dir}"

    if ! mkdir -p "${backup_dir}" >/dev/null 2>&1; then
        log WARN "Could not create backup directory: ${backup_dir} (continuing anyway)"
    fi

    if [ ! -f "${local_yml}" ]; then
        log INFO "Creating new UniFi config file..."
        if ! cat > "${local_yml}" <<SSL
# File created by unifi-cert-update.sh
ssl:
  crt: '${CONTAINER_CERT_PATH}'
  key: '${CONTAINER_KEY_PATH}'
SSL
        then
            fail "Failed to create config file: ${local_yml}"
        fi
    else
        log INFO "Backing up existing config..."
        if cp "${local_yml}" "${backup_dir}/local.yml_$(date +%Y%m%d_%H%M%S)" 2>/dev/null; then
            prune_config_backups "${backup_dir}"
        else
            log WARN "Could not backup existing config (continuing anyway)"
        fi

        if ! grep -q '^ssl:' "${local_yml}"; then
            log INFO "Adding SSL section to config..."
            if ! cat >> "${local_yml}" <<SSL

# Added by unifi-cert-update.sh
ssl:
  crt: '${CONTAINER_CERT_PATH}'
  key: '${CONTAINER_KEY_PATH}'
SSL
            then
                fail "Failed to add SSL section to config: ${local_yml}"
            fi
        else
            log INFO "Updating existing SSL section..."
            # Rewrite crt/key only inside the top-level ssl: block
            local tmp_yml
            tmp_yml=$(mktemp) || fail "Failed to create temporary file"
            if ! awk -v crt="${CONTAINER_CERT_PATH}" -v key="${CONTAINER_KEY_PATH}" '
                /^ssl:/                  { in_ssl = 1; print; next }
                in_ssl && /^[^[:space:]#]/ { in_ssl = 0 }
                in_ssl && /^[[:space:]]+crt:/ { print "  crt: \x27" crt "\x27"; next }
                in_ssl && /^[[:space:]]+key:/ { print "  key: \x27" key "\x27"; next }
                { print }
            ' "${local_yml}" > "${tmp_yml}"; then
                rm -f "${tmp_yml}"
                fail "Failed to update SSL section in config: ${local_yml}"
            fi
            # Write back in place so the file keeps its ownership
            cat "${tmp_yml}" > "${local_yml}" || { rm -f "${tmp_yml}"; fail "Failed to write config: ${local_yml}"; }
            rm -f "${tmp_yml}"
        fi
    fi

    chown -R "${UOS_USER}:${UOS_USER}" "${overrides_dir}" >/dev/null 2>&1 \
        || fail "Failed to set config directory ownership"

    log OK "UniFi configuration updated"
}

# =============================================================================
# Baseline Update (Serial/Hash for future comparisons)
# =============================================================================

update_baselines() {
    local cert_file="$1"

    log INFO "Updating baselines for next run..."

    local serial
    serial=$(get_cert_serial "${cert_file}") || return 1

    if ! mkdir -p "$(dirname "${SERIAL_BASELINE_FILE}")" >/dev/null 2>&1; then
        log WARN "Could not create baseline directory"
        return 0
    fi

    if echo "${serial}" > "${SERIAL_BASELINE_FILE}"; then
        log OK "Updated serial baseline: ${serial}"
    else
        log WARN "Could not write serial baseline"
    fi

    local hash
    hash=$(get_cert_hash "${cert_file}") || return 1

    if echo "${hash}" > "${HASH_BASELINE_FILE}"; then
        log OK "Updated hash baseline"
    else
        log WARN "Could not write hash baseline"
    fi
}

# =============================================================================
# Main Execution
# =============================================================================

main() {
    rotate_log

    # Parse arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --timeout=*)
                CERT_FRESHNESS_TIMEOUT="${1#*=}"
                [[ "${CERT_FRESHNESS_TIMEOUT}" =~ ^[0-9]+$ ]] || fail "Invalid --timeout value: ${CERT_FRESHNESS_TIMEOUT}"
                ;;
            --force)
                FORCE=1
                ;;
            *)
                fail "Unknown option: $1"
                ;;
        esac
        shift
    done

    log INFO "=========================================="
    log INFO "  UniFi Certificate Update"
    log INFO "=========================================="
    log INFO "Domain: ${DOMAIN_NAME}"
    log INFO "Log file: ${LOG_FILE}"
    log INFO "Certificate path: ${STAGING_DIR}/${DOMAIN_NAME}"
    log INFO "Freshness timeout: ${CERT_FRESHNESS_TIMEOUT}s"

    # Ensure running as root
    if [ "$(id -u)" -ne 0 ]; then
        fail "This script must be run as root"
    fi

    acquire_lock

    local cert_dir="${STAGING_DIR}/${DOMAIN_NAME}"
    local cert_file="${cert_dir}/cert.pem"
    local chain_file="${cert_dir}/fullchain.pem"
    local key_file="${cert_dir}/key.pem"

    # Step 1: Verify certificate files exist
    require_file "${cert_file}" "Certificate" "${CERT_CHECK_MAX_RETRIES}"
    require_file "${chain_file}" "Full chain certificate" "${CERT_CHECK_MAX_RETRIES}"
    require_file "${key_file}" "Private key" "${CERT_CHECK_MAX_RETRIES}"

    # Step 2: Validate certificate freshness
    if [ "${FORCE}" -eq 1 ]; then
        log WARN "--force given: skipping freshness check"
    elif ! validate_cert_freshness "${cert_file}" "${CERT_FRESHNESS_TIMEOUT}"; then
        fail "Certificate freshness validation failed"
    fi

    # Step 3: Validate certificate format and validity
    validate_cert_format "${cert_file}" "${key_file}"
    validate_cert_validity "${cert_file}"
    check_cert_compatibility "${cert_file}"

    # Step 4: Stop UniFi (from here on, a failure restarts UniFi automatically)
    unifi_stop

    # Step 5: Install certificates
    install_certs "${chain_file}" "${key_file}"

    # Step 6: Update UniFi config
    update_unifi_config

    # Step 7: Start UniFi
    unifi_start

    # Step 8: Confirm UniFi is serving the new certificate
    verify_served_cert "${cert_file}"

    # Step 9: Update baselines for next run
    update_baselines "${cert_file}"

    # Success!
    log OK "=========================================="
    log OK "Certificate update completed successfully!"
    log OK "=========================================="

    # Show cert details
    log INFO "Installed certificate details:"
    openssl x509 -in "${chain_file}" -noout -subject -issuer -serial -enddate 2>/dev/null | sed 's/^/  /' | tee -a "${LOG_FILE}"

    exit 0
}

main "$@"
