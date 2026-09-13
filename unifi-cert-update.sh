#!/usr/bin/env bash
#
# unifi-cert-update.sh - Update UniFi certificates from Let's Encrypt (OPNsense ACME)
#
# Usage: sudo ./unifi-cert-update.sh [--timeout=SECONDS]
#
# This script:
# 1. Verifies certificates are fresh (detects if new cert available)
# 2. Validates all certificate files
# 3. Copies certificates to UniFi container
# 4. Restarts UniFi
#
# Certificate Freshness Detection (OPNsense ACME):
#   - Compares current serial to last known serial
#   - If serial changed = new certificate (proceed immediately)
#   - If serial unchanged = wait for copy (poll hash for up to --timeout seconds)
#
# Recommended: Run only when ACME cert update completes and new certs copied

set -eu

# Fix for sessionless SSH execution (OPNsense ACME client)
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

############################################################################################
################################### Configurable Settings: #################################
DOMAIN_NAME="device.example.com"
CONFIG_DIR="/etc/letsencrypt/live"

# UniFi paths
UNIFI_DEST_KEY="/home/uosserver/.local/share/containers/storage/volumes/uosserver_data/_data/custom_certificates/unifi-os.key"
UNIFI_DEST_CERT="/home/uosserver/.local/share/containers/storage/volumes/uosserver_data/_data/custom_certificates/unifi-os.crt"

# Certificate freshness tracking
SERIAL_BASELINE_FILE="/etc/letsencrypt/live/unifi-cert-serial.baseline"
HASH_BASELINE_FILE="/etc/letsencrypt/live/unifi-cert-hash.baseline"

# Timeouts and retry logic
CERT_FRESHNESS_TIMEOUT="${CERT_FRESHNESS_TIMEOUT:-300}"  # 5 minutes (wait for cert copy)
CERT_CHECK_MAX_RETRIES="${CERT_CHECK_MAX_RETRIES:-10}"    # Retries for initial file checks
UNIFI_RESTART_TIMEOUT="${UNIFI_RESTART_TIMEOUT:-60}"      # Max time to wait for UniFi restart

############################################################################################

# =============================================================================
# Logging
# =============================================================================
log() {
    local timestamp level msg
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    level="$1"
    shift
    msg="$*"

    case "$level" in
        INFO)  echo "[${timestamp}] ℹ️  ${msg}" ;;
        OK)    echo "[${timestamp}] ✅ ${msg}" ;;
        ERR)   echo "[${timestamp}] ❌ ERROR: ${msg}" >&2 ;;
        WARN)  echo "[${timestamp}] ⚠️  WARNING: ${msg}" ;;
        *)     echo "[${timestamp}] ${msg}" ;;
    esac

    # Also log to syslog
    logger -t "unifi-cert-update" -p "user.${level,,}" "${msg}" 2>/dev/null || true
}

# =============================================================================
# Error Handling
# =============================================================================
cleanup() {
    local exit_code=$?
    if [ ${exit_code} -ne 0 ]; then
        log ERR "Script failed (exit code: ${exit_code})"
    fi
}

trap cleanup EXIT ERR

fail() {
    log ERR "$*"
    exit 1
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

require_dir() {
    local path="$1" desc="$2"

    if [ ! -d "${path}" ]; then
        fail "Required directory not found: ${path} (${desc})"
    fi

    if [ ! -r "${path}" ]; then
        fail "Required directory not readable: ${path} (${desc})"
    fi

    log OK "Found: ${desc}"
}

# =============================================================================
# Certificate Utility Functions
# =============================================================================

# get_cert_serial — extract X.509 serial number
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

# get_cert_hash — compute SHA256 hash of certificate
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

# =============================================================================
# Certificate Freshness Validation
# =============================================================================

# validate_cert_freshness — ensures certificate is fresh (new renewal detected)
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
    log INFO "Polling for hash change (up to ${timeout_secs}s)..."

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
    # Extract public key from cert and from key file, then compare
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

    # Check if cert is not yet valid
    if openssl x509 -in "${cert_file}" -noout -text 2>/dev/null | grep -q "Not Before.*Future"; then
        fail "Certificate is not yet valid (future date)"
    fi

    # Check if cert is expired
    if ! openssl x509 -in "${cert_file}" -noout -checkend 0 >/dev/null 2>&1; then
        fail "Certificate is expired"
    fi
    log OK "Certificate validity dates OK"

    # Warn if expiring soon
    local days_until_expiry
    days_until_expiry=$(openssl x509 -in "${cert_file}" -noout -checkend $((30*86400)) >/dev/null 2>&1 && echo "30+" || \
                        openssl x509 -in "${cert_file}" -noout -dates 2>/dev/null | grep notAfter | cut -d= -f2 | xargs -I {} date -d {} +%s | xargs -I {} echo $((({} - $(date +%s)) / 86400))) || echo "unknown"

    if [[ "${days_until_expiry}" =~ ^[0-9]+$ && "${days_until_expiry}" -lt 30 ]]; then
        log WARN "Certificate expires in ${days_until_expiry} days"
    fi
}

# =============================================================================
# UniFi Operations
# =============================================================================

unifi_stop() {
    log INFO "Stopping UniFi OS Server..."

    local retries=0 max_retries=3 stop_output
    while [ ${retries} -lt ${max_retries} ]; do
        # Use systemctl to stop the service
        if stop_output=$(systemctl stop uosserver.service 2>&1); then
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
    log INFO "Starting UniFi OS Server..."

    local start_output
    # Use systemctl to start the service
    if ! start_output=$(systemctl start uosserver.service 2>&1); then
        fail "Failed to start UniFi OS Server. Output: ${start_output}"
    fi

    log INFO "Waiting for UniFi to fully start..."
    local start_time elapsed_secs
    start_time=$(date +%s)

    while true; do
        elapsed_secs=$(( $(date +%s) - start_time ))

        if curl -s -k https://localhost:11443 >/dev/null 2>&1; then
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

# =============================================================================
# Certificate Installation
# =============================================================================

install_certs() {
    local cert_file="$1" key_file="$2"

    log INFO "Preparing certificate installation..."

    # Create target directories
    local cert_dir key_dir
    cert_dir=$(dirname "${UNIFI_DEST_CERT}")
    key_dir=$(dirname "${UNIFI_DEST_KEY}")

    if ! mkdir -p "${cert_dir}" >/dev/null 2>&1; then
        fail "Failed to create certificate directory: ${cert_dir}"
    fi

    if ! mkdir -p "${key_dir}" >/dev/null 2>&1; then
        fail "Failed to create key directory: ${key_dir}"
    fi

    log INFO "Copying certificate to UniFi..."
    if ! cp "${cert_file}" "${UNIFI_DEST_CERT}"; then
        fail "Failed to copy certificate to ${UNIFI_DEST_CERT}"
    fi

    log INFO "Copying private key to UniFi..."
    if ! cp "${key_file}" "${UNIFI_DEST_KEY}"; then
        fail "Failed to copy key to ${UNIFI_DEST_KEY}"
    fi

    # Fix permissions
    if ! chmod 600 "${UNIFI_DEST_KEY}" >/dev/null 2>&1; then
        fail "Failed to set key permissions"
    fi

    if ! chmod 644 "${UNIFI_DEST_CERT}" >/dev/null 2>&1; then
        fail "Failed to set certificate permissions"
    fi

    log OK "Certificates copied and permissions set"
}

update_unifi_config() {
    local local_yml="/home/uosserver/.local/share/containers/storage/volumes/uosserver_data/_data/unifi-core/config/overrides/local.yml"
    local config_dir backup_dir
    config_dir=$(dirname "${local_yml}")
    backup_dir="${CONFIG_DIR}/unifi-os/config_backups"

    log INFO "Updating UniFi configuration..."

    # Create config directory
    if ! mkdir -p "${config_dir}" >/dev/null 2>&1; then
        fail "Failed to create config directory: ${config_dir}"
    fi

    # Create backup directory
    if ! mkdir -p "${backup_dir}" >/dev/null 2>&1; then
        log WARN "Could not create backup directory: ${backup_dir} (continuing anyway)"
    fi

    if [ ! -f "${local_yml}" ]; then
        # Create new config file
        log INFO "Creating new UniFi config file..."
        if ! tee "${local_yml}" &>/dev/null << 'SSL'
# File created by unifi-cert-update.sh
ssl:
  crt: '/data/custom_certificates/unifi-os.crt'
  key: '/data/custom_certificates/unifi-os.key'
SSL
        then
            fail "Failed to create config file: ${local_yml}"
        fi
    else
        # Backup existing config
        log INFO "Backing up existing config..."
        if ! cp "${local_yml}" "${backup_dir}/local.yml_$(date +%Y%m%d_%H%M%S)" 2>/dev/null; then
            log WARN "Could not backup existing config (continuing anyway)"
        fi

        # Check if SSL section exists
        if ! grep -iq "ssl:" "${local_yml}"; then
            log INFO "Adding SSL section to config..."
            if ! tee -a "${local_yml}" &>/dev/null << 'SSL'

# Added by unifi-cert-update.sh
ssl:
  crt: '/data/custom_certificates/unifi-os.crt'
  key: '/data/custom_certificates/unifi-os.key'
SSL
            then
                fail "Failed to add SSL section to config: ${local_yml}"
            fi
        else
            log INFO "Updating existing SSL section..."
            # Update paths (be careful with sed escaping)
            if ! sed -i "s|.*crt:.*|  crt: '/data/custom_certificates/unifi-os.crt'|" "${local_yml}"; then
                fail "Failed to update cert path in config"
            fi
            if ! sed -i "s|.*key:.*|  key: '/data/custom_certificates/unifi-os.key'|" "${local_yml}"; then
                fail "Failed to update key path in config"
            fi
        fi
    fi

    # Fix permissions
    if ! chown -R uosserver:uosserver "${config_dir}" >/dev/null 2>&1; then
        fail "Failed to set config directory ownership"
    fi

    log OK "UniFi configuration updated"
}

# =============================================================================
# Baseline Update (Serial/Hash for future comparisons)
# =============================================================================

update_baselines() {
    local cert_file="$1"

    log INFO "Updating baselines for next run..."

    # Update serial baseline
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

    # Update hash baseline
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
    # Parse arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --timeout=*)
                CERT_FRESHNESS_TIMEOUT="${1#*=}"
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
    log INFO "Certificate path: ${CONFIG_DIR}/${DOMAIN_NAME}"
    log INFO "Freshness timeout: ${CERT_FRESHNESS_TIMEOUT}s"

    # Ensure running as root
    if [ "$(id -u)" -ne 0 ]; then
        fail "This script must be run as root"
    fi

    local cert_dir="${CONFIG_DIR}/${DOMAIN_NAME}"
    local cert_file="${cert_dir}/cert.pem"
    local chain_file="${cert_dir}/fullchain.pem"
    local key_file="${cert_dir}/key.pem"

    # Step 1: Verify certificate files exist
    require_file "${cert_file}" "Certificate" "${CERT_CHECK_MAX_RETRIES}"
    require_file "${chain_file}" "Full chain certificate" "${CERT_CHECK_MAX_RETRIES}"
    require_file "${key_file}" "Private key" "${CERT_CHECK_MAX_RETRIES}"

    # Step 2: Validate certificate freshness
    if ! validate_cert_freshness "${cert_file}" "${CERT_FRESHNESS_TIMEOUT}"; then
        fail "Certificate freshness validation failed"
    fi

    # Step 3: Validate certificate format and validity
    if ! validate_cert_format "${cert_file}" "${key_file}"; then
        fail "Certificate validation failed"
    fi

    if ! validate_cert_validity "${cert_file}"; then
        fail "Certificate validity check failed"
    fi

    # Step 4: Stop UniFi
    if ! unifi_stop; then
        fail "Could not stop UniFi"
    fi

    # Step 5: Install certificates
    if ! install_certs "${chain_file}" "${key_file}"; then
        log ERR "Certificate installation failed - attempting to restart UniFi"
        unifi_start || true
        fail "Certificate installation failed"
    fi

    # Step 6: Update UniFi config
    if ! update_unifi_config; then
        log ERR "Config update failed - attempting to restart UniFi"
        unifi_start || true
        fail "Config update failed"
    fi

    # Step 7: Start UniFi
    if ! unifi_start; then
        fail "Could not start UniFi"
    fi

    # Step 8: Update baselines for next run
    update_baselines "${cert_file}"

    # Success!
    log OK "=========================================="
    log OK "Certificate update completed successfully!"
    log OK "=========================================="

    # Show cert details
    log INFO "Installed certificate details:"
    openssl x509 -in "${chain_file}" -noout -subject -issuer -serial -enddate 2>/dev/null | sed 's/^/  /'

    exit 0
}

main "$@"
