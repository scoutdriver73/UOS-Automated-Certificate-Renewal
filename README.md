# unifi-cert-update

A bash script that installs an ACME certificate (for example, one issued by Let's Encrypt) into UniFi OS Server.

The script runs after a certificate renewal, once the new certificate files have been copied to the UniFi OS Server host, so the HTTPS certificate stays current without manual intervention. Any ACME client or automation that can place the files on the host and then run the script can trigger it. OPNsense is one example; see Wiring it up to OPNsense ACME.

## What it does

1. **Detects a fresh certificate** — compares the current certificate's serial number (and, if needed, its hash) against a stored baseline to confirm a new cert has actually been issued/copied, rather than blindly reinstalling the same one.
2. **Validates the certificate** — checks that the cert and key are valid PEM files, that the key matches the cert, and that the cert isn't expired or not-yet-valid.
3. **Installs the certificate** — stops the UniFi OS Server, copies the new cert/key into UniFi's `custom_certificates` directory, sets correct permissions, and updates UniFi's `local.yml` config to point at them (backing up the previous config first).
4. **Restarts UniFi** and waits for it to come back up.
5. **Updates the baseline** so the next run can detect the next renewal.

All steps are logged with timestamps to stdout and syslog, and the script fails loudly (non-zero exit) if any step doesn't succeed.

## Requirements

- Run as root (it stops/starts a systemd service and writes to another user's files).
- `openssl`, `systemctl`, `curl`, standard coreutils.
- UniFi OS Server installed with Ubiquiti's official installer. The host can be bare metal, a virtual machine, or an LXC container. The official installer runs UniFi OS Server as a rootless Podman container under the `uosserver` user, and the default paths in the script point into that container's data volume.
- Certificate files on the UniFi OS Server host at `/etc/letsencrypt/live/<domain>/{cert,fullchain,key}.pem`. The location is set by `CONFIG_DIR` and `DOMAIN_NAME`, and any ACME client can produce the files.

## Certificate requirements

UniFi OS Server rejects a certificate it considers invalid and generates a self-signed certificate in its place. The script has been tested with the following certificate configuration:

- **Key type:** RSA 2048-bit. EC keys (for example, EC 384) are not accepted through the override method used by this script, even though the web interface accepts them.
- **Subject Alternative Names:** None beyond the UniFi OS Server host name. The certificate is issued for a single host name only.
- **Files:** PEM-encoded `cert.pem`, `fullchain.pem`, and `key.pem`. The script installs `fullchain.pem` as the certificate so the intermediate chain is served to clients.

Note: during testing, both the key type and the SAN were changed at the same time. It is possible that only one of these changes is required.

## Configuration

Edit the variables near the top of the script:

| Variable | Purpose |
|---|---|
| `DOMAIN_NAME` | Domain the certificate was issued for |
| `CONFIG_DIR` | Directory containing the Let's Encrypt certs |
| `UNIFI_DEST_KEY` / `UNIFI_DEST_CERT` | Destination paths inside the UniFi container's data volume |
| `CERT_FRESHNESS_TIMEOUT` | How long (seconds) to wait for a cert copy to finish before giving up |
| `CERT_CHECK_MAX_RETRIES` | Retries when checking that cert files exist |
| `UNIFI_RESTART_TIMEOUT` | How long to wait for UniFi to come back up after restart |

## Web interface configuration

No configuration in the UniFi OS web interface is required. The Console certificate setting (Settings → Control Plane → Console → Certificates) remains at its default.

The script is expected to take precedence over a certificate uploaded through the web interface, since it points UniFi OS at its own certificate files through `local.yml`. This behavior has not been tested.

## Usage

```bash
sudo ./unifi-cert-update.sh [--timeout=SECONDS]
```

`--timeout` overrides `CERT_FRESHNESS_TIMEOUT` for that run.

### Wiring it up to OPNsense ACME

The OPNsense ACME client (the os-acme-client plugin) can renew the certificate, copy it to the UniFi OS Server host, and run the script through two automations attached to the certificate.

1. **Certificate settings:** Set the key length to RSA 2048 and leave the alternate names empty, as described in Certificate requirements.
2. **Upload automation:** Add an "Upload certificate via SFTP" automation. Set the host to the UniFi OS Server, the user to root (or an account with write access to `CONFIG_DIR`), and the remote path to `/etc/letsencrypt/live`. The plugin places the files in a subdirectory named for the certificate, and that name must match `DOMAIN_NAME`. In Advanced Mode, set the file names to `cert.pem`, `key.pem`, and `fullchain.pem`.
3. **Command automation:** Add an SSH remote command automation for the same host that runs the full path to `unifi-cert-update.sh`. The command runs as root, or with `sudo` for a non-root account that has passwordless sudo.
4. **Automation order:** Attach both automations to the certificate, with the upload first and the command second.
5. **SSH identity:** The ACME client uses its own SSH identity, stored on OPNsense under `/var/etc/acme-client/sftp-config`. Add its public key to `authorized_keys` for the SSH user on the UniFi OS Server host.

The automations run in a non-interactive SSH session with a minimal environment. The script sets its own `PATH` so `systemctl`, `openssl`, and `curl` resolve correctly. If the script starts before the upload finishes, it polls the certificate for up to `CERT_FRESHNESS_TIMEOUT` seconds (300 by default) and exits with an error if no new certificate appears.

## Notes

- Paths and service names in this script match a standard UniFi OS Server installation. Adjust `UNIFI_DEST_KEY`, `UNIFI_DEST_CERT`, and the config path in `update_unifi_config` if your setup differs.
- The script assumes a systemd unit named `uosserver.service` manages the UniFi container.
- On the very first run there's no stored baseline, so it skips freshness detection and installs whatever certificate is present.

## Acknowledgments

The certificate installation method in this script is based on the UniFi Easy Encrypt script by Glenn R. (@AmazedMender16 on the Ubiquiti Community). This script follows the same approach: the certificate and key are copied into the `custom_certificates` directory, and `local.yml` points UniFi OS Server at them. UniFi Easy Encrypt is available at [glennr.nl](https://glennr.nl/s/unifi-lets-encrypt).

## License

MIT
