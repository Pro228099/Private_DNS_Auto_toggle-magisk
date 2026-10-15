# Changelog

## v1.1.13
- Added an update button in the Magisk app (`updateJson` in `module.prop`).
  Magisk now checks `update.json` and offers a one-tap update when a newer
  version is released. CI refreshes `update.json` on every release so the button
  never goes stale.

## v1.1.12
- Fix: a VPN visible only through `dumpsys` (no `tun*` interface, no `Vpn` log
  line) waited for the old 30s safety poll. Default `POLL_INTERVAL` is now 5s,
  and the installer lowers a stale `POLL_INTERVAL=30` on upgrade, so the update
  takes effect without a reinstall.
- The interface watch still catches a tunnel interface within a second.

## v1.1.11
- Added an always-on interface watch so a tunnel appearing is noticed within a
  second even when the `Vpn` log stream is silent, buffered, or dead.

## v1.1.10
- CI: one build per version (tag-triggered), not two.

## v1.1.9
- Instant disable: the event path no longer calls `dumpsys`; ~1s restore.

## v1.1.8
- Shaved ~2s off the VPN toggle latency.

## v1.1.7
- Run the watcher as a detached daemon so the auto-restore survives.
