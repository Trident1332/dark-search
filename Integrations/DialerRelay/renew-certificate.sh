#!/bin/sh
set -eu
# Certbot deploy hook. Copy only this hostname's existing certificate; no output.
[ "${RENEWED_LINEAGE:-}" = /etc/letsencrypt/live/sip.investigate.agency ] || exit 0
task_tls_dir=/etc/search-dialer-relay/tls
task_tls_tmp=$(mktemp -d /etc/search-dialer-relay/.tls.XXXXXXXX)
trap 'rm -rf "$task_tls_tmp"' EXIT HUP INT TERM
chown root:turnserver "$task_tls_tmp"
chmod 0750 "$task_tls_tmp"
install -o root -g turnserver -m 0640 "$RENEWED_LINEAGE/fullchain.pem" "$task_tls_tmp/fullchain.pem"
install -o root -g turnserver -m 0640 "$RENEWED_LINEAGE/privkey.pem" "$task_tls_tmp/privkey.pem"
openssl x509 -in "$task_tls_tmp/fullchain.pem" -noout -checkend 3600 >/dev/null
# The old directory is only removed after both files have been copied successfully.
task_tls_old=/etc/search-dialer-relay/.tls.previous
rm -rf "$task_tls_old"
[ ! -d "$task_tls_dir" ] || mv "$task_tls_dir" "$task_tls_old"
mv "$task_tls_tmp" "$task_tls_dir"
rm -rf "$task_tls_old"
systemctl try-restart search-dialer-turn.service
