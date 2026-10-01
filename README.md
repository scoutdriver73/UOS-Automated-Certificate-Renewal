# unifi-cert-update

A bash script that installs an ACME certificate (for example, one issued by Let's Encrypt) into UniFi OS Server.

The script runs after a certificate renewal, once the new certificate files have been copied to the UniFi OS Server host, so the HTTPS certificate stays current without manual intervention. Any ACME client or automation that can place the files on the host and then run the script can trigger it. OPNsense is one example; see Wiring it up to OPNsense ACME.

## What it does

1. **Detects a fresh certificate** — compares the current certificate's serial number (and, if needed, its hash) against a stored baseline to confirm a new cert has actually been issued/copied, rather than blindly reinstalling the same one.
2. **Validates the certificate** — checks that the cert and key are valid PEM files, that the key matches the cert, and that the cert isn't expired or not-yet-valid. It also logs a warning if the certificate differs from the tested configuration described in Certificate requirements.
3. **Installs the certificate** — stops the UniFi OS Server, copies the new cert/key into UniFi's `custom_certificates` directory, sets permissions and `uosserver` ownership, and updates UniFi's `local.yml` config to point at them (backing up the previous config first).
4. **Restarts UniFi** and waits for it to come back up.
5. **Verifies the served certificate** — connects to UniFi OS Server and confirms it is serving the new certificate rather than a self-signed replacement.
6. **Updates the baseline** so the next run can detect the next renewal.

All steps are logged with timestamps to the console, to syslog, and to `unifi-cert-update.log` in the same directory as the script. The script exits with a non-zero status if any step fails. If a step fails after UniFi OS Server has been stopped, the script restarts it before exiting.

## Requirements

- Run as root (it stops/starts a systemd service and writes to another user's files).
- `openssl`, `systemctl`, `curl`, `timeout`, standard coreutils. `flock` (part of util-linux) is used to prevent overlapping runs; the script continues without a lock if it is missing.
- UniFi OS Server installed with Ubiquiti's official installer. The host can be bare metal, a virtual machine, or an LXC container. The official installer runs UniFi OS Server as a rootless Podman container under the `uosserver` user, and the default paths in the script point into that container's data volume. The script has been tested with UniFi OS Server 5.1.42.
- Certificate files on the UniFi OS Server host at `/etc/letsencrypt/live/<domain>/{cert,fullchain,key}.pem`. The location is set by `STAGING_DIR` and `DOMAIN_NAME`, and any ACME client can produce the files.

## Certificate requirements

UniFi OS Server rejects a certificate it considers invalid and generates a self-signed certificate in its place. The script has been tested with the following certificate configuration:

- **Key type:** RSA, 2048-bit or larger (2048-bit and 4096-bit keys have been tested). EC keys (for example, EC 384) are not accepted through the override method used by this script, even though the web interface accepts them.
- **Subject Alternative Names:** None beyond the UniFi OS Server host name. The certificate is issued for a single host name only.
- **Files:** PEM-encoded `cert.pem`, `fullchain.pem`, and `key.pem`. The script installs `fullchain.pem` as the certificate so the intermediate chain is served to clients.

Note: during testing, both the key type and the SAN were changed at the same time. It is possible that only one of these changes is required.

The script checks the certificate against this configuration before installing it. An EC key, an RSA key smaller than 2048 bits, or more than one Subject Alternative Name produces a warning in the log. The warning does not stop the installation. If UniFi OS Server then serves a self-signed certificate, the error message lists these differences as the likely cause.

## Configuration

Edit the variables near the top of the script:

| Variable | Purpose |
|---|---|
| `DOMAIN_NAME` | Domain the certificate was issued for |
| `STAGING_DIR` | Directory the ACME client copies certificates into; each certificate is in a subdirectory named for `DOMAIN_NAME` |
| `UOS_SERVICE` | systemd unit that runs UniFi OS Server (default `uosserver.service`) |
| `UOS_USER` | User that owns the UniFi OS Server container (default `uosserver`) |
| `UOS_DATA_DIR` | UniFi OS Server data volume on the host; the certificate, key, and `local.yml` paths are derived from it |
| `UOS_HTTPS_PORT` | Port the UniFi OS Server web interface listens on (default `11443`) |
| `CERT_FRESHNESS_TIMEOUT` | How long (seconds) to wait for a cert copy to finish before giving up |
| `CERT_CHECK_MAX_RETRIES` | Retries when checking that cert files exist |
| `UNIFI_RESTART_TIMEOUT` | How long (seconds) to wait for UniFi to come back up after restart |
| `CERT_VERIFY_TIMEOUT` | How long (seconds) to wait for UniFi to serve the new certificate |
| `LOG_MAX_BYTES` | Size at which the log file is rotated to `unifi-cert-update.log.1` (default 1 MB) |
| `CONFIG_BACKUP_KEEP` | Number of `local.yml` backups to keep (default 10) |
| `LOCK_FILE` | Lock file that prevents overlapping runs |

## Web interface configuration

No configuration in the UniFi OS web interface is required. The Console certificate setting (Settings → Control Plane → Console → Certificates) remains at its default.

The script is expected to take precedence over a certificate uploaded through the web interface, since it points UniFi OS at its own certificate files through `local.yml`. This behavior has not been tested.

## Usage

```bash
sudo ./unifi-cert-update.sh [--timeout=SECONDS] [--force]
```

- `--timeout` overrides `CERT_FRESHNESS_TIMEOUT` for that run.
- `--force` skips the freshness check and installs the current certificate. Use it to rerun the script by hand when the certificate has not changed.

### Wiring it up to OPNsense ACME

The OPNsense ACME client (the os-acme-client plugin) can renew the certificate, copy it to the UniFi OS Server host, and run the script through two automations attached to the certificate.

1. **Certificate settings:** Set the key length to RSA 2048 or RSA 4096 and leave the alternate names empty, as described in Certificate requirements.
2. **Upload automation:** Add an "Upload certificate via SFTP" automation. Set the host to the UniFi OS Server, the user to root (or an account with write access to `STAGING_DIR`), and the remote path to `/etc/letsencrypt/live`. The plugin places the files in a subdirectory named for the certificate, and that name must match `DOMAIN_NAME`.
3. **Command automation:** Add an SSH remote command automation for the same host that runs the full path to `unifi-cert-update.sh`. The command runs as root, or with `sudo` for a non-root account that has passwordless sudo.
4. **Automation order:** Attach both automations to the certificate, with the upload first and the command second.
5. **SSH identity:** The ACME client uses its own SSH identity, stored on OPNsense under `/var/etc/acme-client/sftp-config`. Add its public key to `authorized_keys` for the SSH user on the UniFi OS Server host.

The automations run in a non-interactive SSH session with a minimal environment. The script sets its own `PATH` so `systemctl`, `openssl`, and `curl` resolve correctly. If the script starts before the upload finishes, it polls the certificate for up to `CERT_FRESHNESS_TIMEOUT` seconds (300 by default) and exits with an error if no new certificate appears.

## Notes

- Paths and service names in this script match a standard UniFi OS Server installation. If your setup differs, adjust `UOS_DATA_DIR`, `UOS_USER`, and `UOS_SERVICE`.
- The script stops and starts UniFi OS Server through the systemd unit named in `UOS_SERVICE`.
- The log file `unifi-cert-update.log` is created in the same directory as the script, and each run adds its entries to the end of the file. The file is rotated when it exceeds `LOG_MAX_BYTES`.
- Baseline files and `local.yml` backups are stored in `STAGING_DIR`. Only the newest `CONFIG_BACKUP_KEEP` backups are kept.
- When updating an existing `local.yml`, the script changes only the `crt` and `key` entries inside the top-level `ssl:` section. All other settings are left as they are.
- If UniFi OS Server rejects the certificate and serves a self-signed one instead, the script reports the expected and served serial numbers and exits with an error.
- On the very first run there's no stored baseline, so it skips freshness detection and installs whatever certificate is present.

## Acknowledgments

The certificate installation method in this script is based on the UniFi Easy Encrypt script by Glenn R. (@AmazedMender16 on the Ubiquiti Community). This script follows the same approach: the certificate and key are copied into the `custom_certificates` directory, and `local.yml` points UniFi OS Server at them. UniFi Easy Encrypt is available at [glennr.nl](https://glennr.nl/s/unifi-lets-encrypt).

## License

MIT
