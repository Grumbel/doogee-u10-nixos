# NixOS for the Doogee U10 tablet

Run NixOS on the **Doogee U10**, a 10.1" Android tablet with a Rockchip
**RK3562**. The system boots from a microSD card; Android on the internal
eMMC stays untouched. Take the card out and the tablet boots Android again.

The hardware support comes from
[rk3562deb](https://github.com/tech4bot/rk3562deb) (Debian 13 for the
same tablet): the Rockchip BSP kernel 6.1 with its device tree, drivers
and patches, and Rockchip's vendor U-Boot. This repository builds the same
kernel and boot loader with Nix and puts NixOS on top.

Inside: RK3562 (4× Cortex-A53, Mali-G52 GPU), 4 GB RAM, 128 GB eMMC,
800×1280 MIPI-DSI panel, GSL3673 touchscreen, Seekwave EA6621Q Wi-Fi and
Bluetooth, RK817 power management and audio codec.

## Status

| | |
|---|---|
| Kernel, U-Boot, SD card image | build |
| Everything else | not yet tested on the tablet |

What rk3562deb has working and this configuration sets up: display,
touchscreen, GPU (Mesa Panfrost), Wi-Fi, Bluetooth, speaker and
microphone, accelerometer (screen rotation), battery and charging, power
key and suspend, USB-C (host and device).

Not ported from rk3562deb: hardware video decoding (Rockchip MPP / VA-API,
prebuilt libraries), the NPU (RKLLM), cameras, the flashlight helper, the
Phosh desktop.

## What you need

- A **microSD card**, 8 GB or larger (the image is about 7 GB)
- A **Linux PC with [Nix](https://nixos.org/download/)** and flakes enabled
- To build on an x86_64 PC: aarch64 emulation. On NixOS:
  `boot.binfmt.emulatedSystems = [ "aarch64-linux" ];`
  The kernel and boot loader are cross-compiled; everything else comes
  prebuilt from the NixOS binary cache.
- A **USB-C cable** (for SSH access without Wi-Fi)

## Installation

### 1. Build the SD card image

```sh
nix build .#sdImage -L
```

The image ends up in `result/sd-image/`.

### 2. Write it to the microSD card

Check the device name of your card reader first (`lsblk`), then:

```sh
sudo dd if=result/sd-image/nixos-image-sd-card-*.img of=/dev/sdX bs=4M conv=fsync status=progress
```

### 3. Wi-Fi and SSH key

Plug the card back into the PC. It has a small FAT partition called
`FIRMWARE`, readable on any computer. Put two files there:

- **`wifi.conf`**: copy `wifi.conf.example` and fill in your network:
  ```
  network={
      ssid="MyNetwork"
      psk="MyPassword"
  }
  ```
- **`authorized_keys`**: your SSH public key, e.g. a copy of
  `~/.ssh/id_ed25519.pub`. Without it you can't log in over SSH.

### 4. Boot

Insert the card into the tablet and switch it on. The boot ROM prefers
the SD card, so NixOS starts instead of Android. On the first boot the
root partition is grown to fill the card.

## Using it

### Logging in

- **Over Wi-Fi**: `ssh root@doogee-u10.local`
- **Over USB**: connect the tablet's USB-C port to your PC. A new network
  interface appears on the PC; then `ssh root@10.42.0.1` (or
  `ssh root@doogee-u10-usb.local`).
- **On the tablet**: with a USB keyboard, log in as `root`, password
  `doogee`. Change it with `passwd`.
- **Serial console** (inside the case): 1500000 baud, as in rk3562deb.

### Power button

- Short press: suspend (on release); press again to wake up
- Hold for 3 s: power off

### Touch GUI

The example system starts a minimal [sway](https://swaywm.org/) session
as user `tablet` (password `doogee`). Every window fills the screen; the
top bar has buttons for the app launcher (☰), the on-screen keyboard (⌨),
rotating the screen (⟳), brightness (☀) and closing the window (✕). The
screen rotates by itself when you turn the tablet; the ⟳ button overrides
that until the tablet is turned again. The screen turns off after 10
minutes; touch it to turn it back on. The setup is in `gui.nix`; remove
its import from `configuration.nix` for a console-only system.

### Back to Android

Switch off, remove the SD card, switch on.

## Updating

After changing the configuration, update the running tablet over USB or
Wi-Fi instead of reflashing:

```sh
./deploy.sh switch            # most changes
./deploy.sh boot --reboot     # kernel or device tree changes
```

The boot loader (U-Boot) is not updated by `nixos-rebuild`. If it changed,
run `doogee-install-uboot` on the tablet; it saves a backup of the old one
in `/root`.

## Using it in your own configuration

```nix
{
  inputs.doogee-u10.url = "path:/path/to/doogee10-nixos";

  outputs = { nixpkgs, doogee-u10, ... }: {
    nixosConfigurations.mytablet = nixpkgs.lib.nixosSystem {
      modules = [
        doogee-u10.nixosModules.default
        doogee-u10.nixosModules.sdImage # if you want the SD card image
        {
          hardware.doogee-u10.enable = true;
          # Cross-compile kernel and U-Boot on your x86_64 PC (recommended)
          hardware.doogee-u10.kernelBuildPlatform = "x86_64-linux";
        }
        ./configuration.nix
      ];
    };
  };
}
```

| Option | Default | |
|---|---|---|
| `hardware.doogee-u10.enable` | `false` | Enable hardware support |
| `hardware.doogee-u10.kernelBuildPlatform` | `null` | Build kernel and U-Boot on this platform (e.g. `"x86_64-linux"`); `null` builds natively |

## How it works

| Part | |
|---|---|
| `sources.nix` | Pinned sources: rk3562deb, Rockchip kernel, U-Boot, rkbin (the revisions rk3562deb's `build.sh` pins) |
| `pkgs/linux-rk3562/` | Kernel: Rockchip `develop-6.1` with rk3562deb's overlay and patches, built with GCC 14 |
| `kernel/doogee-u10.fragment` | Changes to rk3562deb's defconfig: what `build.sh` sets, plus what NixOS needs |
| `kernel/doogee-u10.config` | Full config generated from defconfig + fragment |
| `pkgs/u-boot-rk3562/` | Vendor U-Boot (`make.sh rk3562`) and the idblock with rkbin's DDR init and SPL |
| `modules/doogee-u10.nix` | Hardware support (kernel, device tree, firmware, Wi-Fi/Bluetooth, audio, power key, DDR pinning) |
| `modules/sd-image.nix` | SD card layout |
| `configuration.nix` | Example system for the SD card image |
| `gui.nix` | Minimal touch GUI (sway) for the example system |

### SD card layout

Same as rk3562deb's image, GPT:

| Partition | Start | Contents |
|---|---|---|
| `idbloader` | 32 KiB | DDR init + SPL (`idblock.bin`) |
| `uboot` | 8 MiB | U-Boot, TF-A and OP-TEE (FIT, `uboot.img`); the SPL finds it by this name |
| `FIRMWARE` | 16 MiB | FAT: `wifi.conf`, `authorized_keys`, boot logs |
| `nixos` | | ext4 root with `/boot/extlinux/extlinux.conf`; marked bootable, so U-Boot's distro boot reads it |

### Kernel config

After editing `kernel/doogee-u10.fragment`:

```sh
nix build .#kernelConfig && install -m644 result kernel/doogee-u10.config
```

The build fails if an option from the fragment doesn't end up in the
config (usually a missing dependency).

### Differences to rk3562deb's build

- The kernel is built with `O=` (out of tree); the Seekwave Wi-Fi Makefile
  needed its source paths made explicit.
- U-Boot: `decode_bl31.py` runs with Python 3 (without it the FIT image
  has no TF-A); the USB download loader (`rk3562_spl_loader_*.bin`, packed
  with rkbin's prebuilt x86 `boot_merger`) is skipped, the SD card doesn't
  need it.
- `build.sh` also enables a few kernel options that have no effect there
  (missing dependencies); the fragment leaves them out or adds the
  dependency (`NF_CONNTRACK`).

## License

The hardware support is derived from
[rk3562deb](https://github.com/tech4bot/rk3562deb) (MIT). The kernel,
U-Boot and rkbin keep their own licenses; rkbin and the Seekwave firmware
are binary blobs.
