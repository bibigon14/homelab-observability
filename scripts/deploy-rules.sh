#!/usr/bin/env bash
# Deploy prometheus/rules/*.yml from this repo to both HA Prometheus replicas.
#
# Why: rule files used to be hand-copied to /etc/prometheus/rules on the Pi
# (replica a) and OCI (replica b). Since alerts from both replicas are merged
# into one (alert_relabel_configs drops the replica label), a stale rule on
# either host keeps a fixed alert firing. 2026-11-23: KubePodNotReady was
# fixed on the Pi but kept re-notifying hourly from OCI's old copy.
#
# What it does, per host:
#   1. stage the repo rule files in /tmp on the host
#   2. show a diff against /etc/prometheus/rules (and host-only files)
#   3. promtool check rules on the staged copy
#   4. install, SIGHUP Prometheus, verify the reload succeeded
#
# Usage (from the repo root, on the Mac):
#   scripts/deploy-rules.sh --dry-run      # diff only, change nothing
#   scripts/deploy-rules.sh                # deploy to pi and oci
#   scripts/deploy-rules.sh pi             # one host
#   FORCE=1 scripts/deploy-rules.sh        # skip the "deploying from origin/main" guard
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

PI_SSH=${PI_SSH:-malina}
OCI_SSH=${OCI_SSH:-"-i $HOME/.ssh/id_ed25519_oracle ubuntu@163.192.1.153"}
PROMTOOL=${PROMTOOL:-/opt/prometheus/promtool}
RULES_DIR=prometheus/rules
DEST=/etc/prometheus/rules
STAGE=/tmp/rules-deploy

DRY_RUN=0
HOSTS=()
for a in "$@"; do
    case "$a" in
        --dry-run) DRY_RUN=1 ;;
        pi|oci) HOSTS+=("$a") ;;
        *) echo "usage: $0 [--dry-run] [pi] [oci]" >&2; exit 2 ;;
    esac
done
[ ${#HOSTS[@]} -eq 0 ] && HOSTS=(pi oci)

# Guard: deploy only what is on origin/main. On 2026-11-21 a post-merge
# install run before the merge silently rolled a fix back.
if [ "${FORCE:-0}" != 1 ] && [ "$DRY_RUN" = 0 ]; then
    git fetch -q origin main
    if [ -n "$(git status --porcelain -- "$RULES_DIR")" ]; then
        echo "error: uncommitted changes in $RULES_DIR (commit or FORCE=1)" >&2; exit 1
    fi
    if [ "$(git rev-parse HEAD:"$RULES_DIR")" != "$(git rev-parse origin/main:"$RULES_DIR")" ]; then
        echo "error: $RULES_DIR differs from origin/main (push/pull first, or FORCE=1)" >&2; exit 1
    fi
fi

ssh_to() { # host, remote command
    local target
    if [ "$1" = pi ]; then target=$PI_SSH; else target=$OCI_SSH; fi
    # shellcheck disable=SC2086
    ssh $target "$2"
}

for host in "${HOSTS[@]}"; do
    echo "==> [$host] staging $(ls "$RULES_DIR"/*.yml | wc -l | tr -d ' ') rule files"
    tar -C "$RULES_DIR" -cf - $(cd "$RULES_DIR" && ls *.yml) \
        | ssh_to "$host" "rm -rf $STAGE && mkdir -p $STAGE && tar -C $STAGE -xf -"

    echo "==> [$host] diff $DEST vs repo"
    ssh_to "$host" "sudo diff -ru -x '*.bak*' -x '*~' $DEST $STAGE" | sed 's/^/    /' \
        || true
    # /etc/prometheus/alerts.yml is loaded too but not managed by this repo
    # yet; print its hash so drift between the two hosts is at least visible.
    ssh_to "$host" "echo \"    alerts.yml (unmanaged) sha256: \$(sudo sha256sum /etc/prometheus/alerts.yml 2>/dev/null | cut -c1-12)\""

    if [ "$DRY_RUN" = 1 ]; then continue; fi

    echo "==> [$host] promtool check"
    ssh_to "$host" "sudo $PROMTOOL check rules $STAGE/*.yml" | grep -E "FAILED|SUCCESS" | sed 's/^/    /'

    echo "==> [$host] install + reload"
    ssh_to "$host" "set -e
        before=\$(curl -s localhost:9090/metrics | awk '/^prometheus_config_last_reload_success_timestamp_seconds/{print \$2}')
        sudo install -m 0644 $STAGE/*.yml $DEST/
        sudo systemctl kill -s HUP prometheus
        for i in 1 2 3 4 5 6 7 8 9 10; do
            sleep 1
            after=\$(curl -s localhost:9090/metrics | awk '/^prometheus_config_last_reload_success_timestamp_seconds/{print \$2}')
            ok=\$(curl -s localhost:9090/metrics | awk '/^prometheus_config_last_reload_successful/{print \$2}')
            [ \"\$after\" != \"\$before\" ] && break
        done
        echo \"    reload_successful=\$ok rules_loaded=\$(curl -s localhost:9090/api/v1/rules | grep -oE '\"type\":\"(alerting|recording)\"' | wc -l)\"
        [ \"\$ok\" = 1 ] && [ \"\$after\" != \"\$before\" ]
        rm -rf $STAGE"
done
echo "==> done"
