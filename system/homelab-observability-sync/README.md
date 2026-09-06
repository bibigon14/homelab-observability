# homelab-observability-sync

Systemd timer that keeps `/home/bibigon88/homelab-observability`
on the Pi in lockstep with GitHub `origin/main`. Runs every 5
minutes, `git fetch` + `git reset --hard origin/main`.

## Scope

**Pull-only, no deploy.** The timer keeps the repo on disk fresh,
but does NOT copy files into `/etc/systemd/system/`,
`/etc/prometheus/rules/`, `/etc/prometheus/prometheus.yml`, or
anywhere else. Deploy stays manual and explicit - see each
component's own README for install steps.

Rationale: full GitOps for bare-metal is a bigger commitment
(state reconciliation, drift detection, rollback), and manual
deploy after `git pull` is already fast enough.

## Behavior

- Runs first 2 min after boot, then every 5 min while active.
- `git reset --hard` means any local modifications are wiped.
  If you edit a file on the Pi and don't commit within 5 min,
  it's gone. Prefer editing on the Mac (source of truth) and
  pushing.
- Untracked files (like `*.bak` local backups) are preserved.
- No auth needed - the repo is public, HTTPS remote.

## History

- 2026-08-05: initially set up alongside the Thanos remediate
  script, per the postmortem commit. Never committed to git.
- 2026-09-06: discovered missing during Prometheus WAL bug
  follow-up. Pi repo was 3+ weeks behind origin because there
  was no auto-sync, and manual `git pull` was not being run.
  Timer + service vendored here, reinstalled.

## Install

    sudo cp homelab-observability-sync.{timer,service} /etc/systemd/system/
    sudo systemctl daemon-reload
    sudo systemctl enable --now homelab-observability-sync.timer
    systemctl list-timers homelab-observability-sync.timer

## Verify

    # Sync ran, no errors
    journalctl -u homelab-observability-sync.service -n 20 --no-pager

    # Repo up to date
    cd ~/homelab-observability && git log -1 --oneline
