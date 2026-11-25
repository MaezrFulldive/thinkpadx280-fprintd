# thinkpadx280-fprintd

Fingerprint login for the **Lenovo ThinkPad X280** (Synaptics `06cb:009a`, "Metallica MIS"), packaged for **NixOS** (flake + module) and **Arch Linux** (PKGBUILDs).

Stock libfprint has no driver for this sensor. This repo packages libfprint with the native **validity/VCSFW driver** from [libfprint MR !626](https://gitlab.freedesktop.org/libfprint/libfprint/-/merge_requests/626), plus the runtime data it needs. The driver runs inside fprintd, so you don't need python-validity or open-fprintd.

The same driver also covers other Synaptics/Validity match-on-chip sensors:

| USB ID | Silicon | Device | Status in !626 |
|---|---|---|---|
| `06cb:009a` | 0x199 | Lenovo ThinkPad X280 | hardware-validated |
| `138a:00ab` | 0x969 / 0xd51 | HP ZBook Studio x360 G5 | hardware-validated |
| `06cb:00cb` | 0x969 | HP Pavilion x360 14-dh | hardware-validated |
| `06cb:00b7` | 0xd51 | HP EliteBook 840 G6, x360 1040 G6 | hardware-validated |
| `06cb:00d2` | 0x969 | HP ENVY 13-aq | hardware-validated |
| `138a:0090`, `138a:0097`, `138a:009d` | | (from !579) | untested |

Check yours with `lsusb | grep -iE '06cb|138a'`.

## What's pinned

| Component | Source | Commit |
|---|---|---|
| libfprint + validity driver | [`ggiesen/libfprint` `wip/validity-vcsfw-driver`](https://gitlab.freedesktop.org/ggiesen/libfprint/-/tree/wip/validity-vcsfw-driver) (MR !626 head, 2026-11-05) | `5db7da9` |
| Runtime data blobs | [`ggiesen/libfprint-validity-data`](https://gitlab.freedesktop.org/ggiesen/libfprint-validity-data) `main` (v0.2.0) | `687c5ea` |
| fprintd | nixpkgs / Arch repos, unmodified | — |

The X280-specific fix (the open path skipped sensor identify when the firmware-extension upload failed, so the first capture crashed) is now upstream in the MR as `e7bd4e7`. No local patches are applied. The only change on NixOS is the data search path (below).

## NixOS

Add the flake and enable the module:

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    thinkpadx280-fprintd = {
      url = "github:MaezrFulldive/thinkpadx280-fprintd";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, thinkpadx280-fprintd, ... }: {
    nixosConfigurations.x280 = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        thinkpadx280-fprintd.nixosModules.default
        {
          services.fprintd.validity.enable = true;
        }
      ];
    };
  };
}
```

`services.fprintd.validity.enable` does the following:

- enables `services.fprintd`, with `services.fprintd.package` set to fprintd built against the patched libfprint;
- installs the patched libfprint's udev hwdb (USB autosuspend entries for these sensors);
- on NixOS's defaults, turns on PAM fingerprint auth for login, sudo, etc. via `services.fprintd`. Tune that per-service with `security.pam.services.<name>.fprintAuth`.

It can't be combined with `services.fprintd.tod`.

Then rebuild and enroll:

```sh
sudo nixos-rebuild switch --flake .#x280
fprintd-enroll          # 8 nominal stages; the chip may finish in 5–8
fprintd-verify -f any   # what PAM does
```

KDE and GNOME fingerprint settings panels work too, since they talk to fprintd over D-Bus.

### Options

| Option | Default | Description |
|---|---|---|
| `services.fprintd.validity.enable` | `false` | Enable the above. |
| `services.fprintd.validity.package` | this flake's `fprintd` | fprintd linked against the patched libfprint. |
| `services.fprintd.validity.libfprint` | this flake's `libfprint` | Patched libfprint (for its udev hwdb). |
| `services.fprintd.validity.fwextFile` | `null` | Optional vendor `.xpfwext` firmware extension, installed to `/etc/libfprint/validity/`. Not needed on a sensor that has been used before (see below). |

### Packages and overlay

```sh
nix build github:MaezrFulldive/thinkpadx280-fprintd#fprintd                  # default
nix build github:MaezrFulldive/thinkpadx280-fprintd#libfprint
nix build github:MaezrFulldive/thinkpadx280-fprintd#libfprint-validity-data
```

`overlays.default` adds `libfprint-validity`, `libfprint-validity-data` and `fprintd-validity` to `pkgs` without replacing the stock `libfprint`, so nothing else gets rebuilt.

### How the data path is handled

The driver hardcodes `/usr/share/libfprint/validity`, which doesn't exist on NixOS. The derivation patches the search list to:

1. `${libfprint-validity-data}/share/libfprint/validity` (store path, always present)
2. `/etc/libfprint/validity`
3. `/usr/share/libfprint/validity`, `/usr/local/share/libfprint/validity` (stock)

The `.xpfwext` lookup also checks `/etc/libfprint/validity` first, and still checks `/var/lib/python-validity`.

## Arch Linux

```sh
cd arch/libfprint-validity-data && makepkg -si
cd ../libfprint-validity && makepkg -si     # replaces the repo libfprint
sudo systemctl restart fprintd
```

`libfprint-validity` provides/conflicts `libfprint`, so `fprintd` keeps working against it. It isn't in any repo, so `pacman -Syu` won't update it: rebuild after bumping the pinned commit.

## Things to know

- **Pairing.** The sensor holds TLS pairing keys, protected with a key derived from DMI (`product_name` + `product_serial`). A sensor already paired on this laptop, by Windows, python-validity, or an earlier Linux install including the Arch build above, is reused as-is. Reinstalling or switching distro on the same machine keeps the pairing. A factory-empty sensor (no partitions) is paired automatically on first open. The driver **never** factory-resets: a sensor with blank or partial keys fails the open with an explanation instead.
- **Prints live on the chip.** fprintd also keeps its own records in `/var/lib/fprint`. After a fresh install, run `fprintd-delete $USER` (or clear prints from the settings panel) and re-enroll, rather than leaving orphaned on-chip records. Deleting the last print erases the on-chip DB partition and reclaims its flash. A full partition fails enroll cleanly with "data full".
- **Firmware extension (`.xpfwext`).** Optional. It isn't redistributable, and on a sensor that's been used before the driver skips the upload and continues. That is the normal case for the X280.
- **First-boot flakiness.** These sensors sometimes drop off the bus during first-time init or around suspend/resume ([#852](https://gitlab.freedesktop.org/libfprint/libfprint/-/issues/852)). If enroll fails right after the first boot, restart fprintd (`systemctl restart fprintd`) and retry. It settles after a couple of cycles.
- **Finger numbering** follows libfprint's `FpFinger` (left thumb = 1). Windows and python-validity use right thumb = 1, so prints enrolled there don't map to the same finger names.
- `fprintd-verify` without `-f` checks only the first enrolled finger. Use `-f any` to match what PAM does.

## Updating to a newer MR head

1. Bump `rev` in `nix/libfprint-validity.nix` (and/or `nix/libfprint-validity-data.nix`), set `hash = lib.fakeHash;`, run `nix build .#fprintd`, and paste the reported hash.
2. Bump `_commit` / `pkgver` in the matching `arch/*/PKGBUILD`.
3. `nix flake update` to move nixpkgs.

## Credits

The driver is by [@lewohart](https://gitlab.freedesktop.org/lewohart) (!579), continued by [@ggiesen](https://gitlab.freedesktop.org/ggiesen) (!626), with hardware validation and fixes from the testers listed in the MR. The protocol reference is [python-validity](https://github.com/uunicorn/python-validity) by uunicorn (MIT). [`docs/protocol-spec.md`](docs/protocol-spec.md) contains notes on the 06cb:009a protocol, distilled from python-validity.

Packaging in this repo is MIT-licensed. libfprint is LGPL-2.1-or-later; the data package is MIT.
