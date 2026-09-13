# unifi-cert-update

A bash script that automates installing Let's Encrypt certificates (issued via OPNsense's ACME client) into a UniFi OS Server / UniFi Network Application.

It's meant to be triggered by OPNsense after a certificate renewal, so your UniFi controller's HTTPS certificate stays up to date without manual intervention.

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
- A UniFi OS Server running in a container (path defaults assume a rootless Podman setup under `uosserver`'s home directory).
- Certificates issued by OPNsense's ACME client and available locally at `/etc/letsencrypt/live/<domain>/{cert,fullchain,key}.pem`.

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

## Usage

```bash
sudo ./unifi-cert-update.sh [--timeout=SECONDS]
```

`--timeout` overrides `CERT_FRESHNESS_TIMEOUT` for that run.

### Wiring it up to OPNsense ACME

Add it as a "Run Command" action on the relevant ACME certificate in OPNsense, so it runs automatically after each renewal (over SSH, if OPNsense and UniFi are on separate hosts). The script exports a safe `PATH` at the top specifically to handle sessionless SSH invocations from cron-like ACME triggers.

## Notes

- Paths and service names in this script are specific to a rootless Podman-based UniFi OS Server install — adjust `UNIFI_DEST_KEY`, `UNIFI_DEST_CERT`, and the config path in `update_unifi_config` if your setup differs.
- The script assumes a systemd unit named `uosserver.service` manages the UniFi container.
- On the very first run there's no stored baseline, so it skips freshness detection and installs whatever certificate is present.

## License

MIT
