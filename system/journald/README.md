# journald

Persistent journal on the Pi (`homebridge`), 30 days / 1 GiB.

Raspberry Pi OS defaults to a volatile journal via
`/usr/lib/systemd/journald.conf.d/40-rpi-volatile-storage.conf`. That is
sensible on an SD card and wrong on this NVMe-booted host: until
2026-11-21 every log lived in `/run` and was lost on reboot or pushed out
within ~3 days, which cost evidence in the Thanos corruption incident
(`docs/postmortems/2026-11-21-thanos-silent-block-corruption.md`).

A drop-in with `Storage=persistent` had existed since 2026-09-15 but never
took effect: journald was not restarted and the host was not rebooted for
130 days. A second, older drop-in (`retention.conf`) silently overrode
`SystemMaxUse` to 500M. Both are replaced by the single file here.

## Install

```bash
sudo ln -sf /dev/null /etc/systemd/journald.conf.d/40-rpi-volatile-storage.conf
sudo install -m 0644 90-homelab-persistent.conf /etc/systemd/journald.conf.d/
sudo rm -f /etc/systemd/journald.conf.d/persistent.conf /etc/systemd/journald.conf.d/retention.conf
sudo systemctl restart systemd-journald
```

## Verify

```bash
systemd-analyze cat-config systemd/journald.conf | grep -E '^# /|^Storage|^SystemMax|^MaxRet'
journalctl --header | grep -m1 'File path'   # must be under /var/log/journal
journalctl --list-boots | tail -3            # previous boots must survive a reboot
```

Restart journald after any change here. A drop-in that was never applied
looks exactly like one that works until the next reboot.
