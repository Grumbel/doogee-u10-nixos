# Hardware support for the Doogee U10 tablet (Rockchip RK3562).
#
# Rockchip BSP kernel 6.1 and vendor U-Boot with the board support from
# rk3562deb (device tree, Seekwave Wi-Fi/Bluetooth, PMIC fixes), Panfrost
# GPU, firmware, audio defaults, power key and DDR frequency pinning.
# Enable with `hardware.doogee-u10.enable = true;`.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.hardware.doogee-u10;

  # Packages used to build kernel and U-Boot. Cross-compiling from a fast
  # build machine is much quicker than building under emulation.
  buildPkgs =
    if cfg.kernelBuildPlatform == null then
      pkgs
    else
      import pkgs.path {
        localSystem = cfg.kernelBuildPlatform;
        crossSystem = pkgs.stdenv.hostPlatform;
      };

  sources = pkgs.callPackage ../sources.nix { };

  linux = import ../pkgs/linux-rk3562 {
    pkgs = buildPkgs;
    inherit sources;
  };

  uboot = import ../pkgs/u-boot-rk3562 {
    pkgs = buildPkgs;
    inherit sources;
  };

  # Bluetooth configuration (*.nvbin, loaded from /lib/firmware). The Wi-Fi
  # firmware is built into the kernel; the extra copies here are what
  # rk3562deb installs as well.
  boardFirmware = pkgs.runCommand "doogee-u10-firmware" { } ''
    mkdir -p $out/lib/firmware
    cp ${sources.rk3562deb}/overlay/firmware/*.bin $out/lib/firmware/
    cp ${sources.rk3562deb}/overlay/drivers/net/wireless/ea6621q/swtbt4l/*.nvbin $out/lib/firmware/
  '';

  # Write U-Boot to the SD card the system runs from. The GPT of the SD card
  # has partitions "idbloader" (sector 64) and "uboot" (8 MiB), like the
  # rk3562deb image; the eMMC (Android) has a "uboot" partition too, so the
  # partitions are looked up on the root file system's disk only.
  installUboot = pkgs.writeShellApplication {
    name = "doogee-install-uboot";
    runtimeInputs = with pkgs; [
      coreutils
      util-linux
    ];
    text = ''
      root=$(findmnt -n -o SOURCE /)
      disk=/dev/$(lsblk -no PKNAME "$root")
      part() {
        lsblk -lnpo PATH,PARTLABEL "$disk" | awk -v l="$1" '$2 == l { print $1 }'
      }
      idbloader=$(part idbloader)
      ubootpart=$(part uboot)
      if [ -z "$idbloader" ] || [ -z "$ubootpart" ]; then
        echo "No idbloader/uboot partitions on $disk" >&2
        exit 1
      fi
      for f in ${uboot}/idblock.bin:"$idbloader" ${uboot}/uboot.img:"$ubootpart"; do
        img=''${f%%:*} dev=''${f#*:}
        if [ "$(stat -c %s "$img")" -gt "$(blockdev --getsize64 "$dev")" ]; then
          echo "$img doesn't fit into $dev" >&2
          exit 1
        fi
      done
      backup=/root/uboot-backup-$(date +%Y%m%d-%H%M%S)
      mkdir -p "$backup"
      dd if="$idbloader" of="$backup/idbloader.bin" status=none
      dd if="$ubootpart" of="$backup/uboot.bin" status=none
      echo "Backed up the current loader to $backup"
      dd if=${uboot}/idblock.bin of="$idbloader" conv=fsync status=none
      dd if=${uboot}/uboot.img of="$ubootpart" conv=fsync status=none
      sync
      echo "Wrote U-Boot to $idbloader and $ubootpart"
    '';
  };

  # Power key: a short press suspends when the key is released, holding it
  # for 3 s powers off. logind suspends on key down, and the key up event
  # then woke the tablet again (rk3562deb handles the key itself too).
  powerKey = pkgs.writers.writePython3 "doogee-powerkey" {
    libraries = [ pkgs.python3Packages.evdev ];
    flakeIgnore = [ "E501" ];
  } ''
    import select
    import subprocess
    import time

    from evdev import InputDevice, ecodes, list_devices

    LONG_PRESS = 3.0
    # Ignore the key this long after resume: the press that woke the
    # tablet up must not suspend it again on release
    AFTER_RESUME = 1.5


    def find_key():
        for path in list_devices():
            dev = InputDevice(path)
            keys = dev.capabilities().get(ecodes.EV_KEY, [])
            if "pwrkey" in dev.name and ecodes.KEY_POWER in keys:
                return dev
        return None


    def time_suspended():
        # CLOCK_BOOTTIME keeps running during suspend, CLOCK_MONOTONIC not
        boottime = time.clock_gettime(time.CLOCK_BOOTTIME)
        return boottime - time.clock_gettime(time.CLOCK_MONOTONIC)


    dev = find_key()
    while dev is None:
        time.sleep(2)
        dev = find_key()

    pressed_at = None
    suspended_before = None  # set while waiting for a resume
    ignore_until = 0.0
    while True:
        timeout = None
        if pressed_at is not None:
            timeout = max(0.0, pressed_at + LONG_PRESS - time.monotonic())
        elif suspended_before is not None:
            timeout = 0.2
        ready, _, _ = select.select([dev.fd], [], [], timeout)

        if suspended_before is not None and time_suspended() > suspended_before + 0.5:
            suspended_before = None
            ignore_until = time.monotonic() + AFTER_RESUME

        if not ready:
            if pressed_at is not None and time.monotonic() >= pressed_at + LONG_PRESS:
                pressed_at = None
                subprocess.run(["systemctl", "poweroff"])
            continue

        for ev in dev.read():
            if ev.type != ecodes.EV_KEY or ev.code != ecodes.KEY_POWER:
                continue
            if time.monotonic() < ignore_until:
                pressed_at = None
            elif ev.value == 1:
                pressed_at = time.monotonic()
            elif ev.value == 0 and pressed_at is not None:
                pressed_at = None
                suspended_before = time_suspended()
                subprocess.run(["systemctl", "suspend"])
  '';
in
{
  options.hardware.doogee-u10 = {
    enable = lib.mkEnableOption "support for the Doogee U10 (RK3562) tablet";

    kernelBuildPlatform = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "x86_64-linux";
      description = ''
        Platform to cross-compile kernel and U-Boot on. null builds them
        natively for aarch64 (slow under emulation).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";

    # --- Boot -------------------------------------------------------------

    boot.kernelPackages = pkgs.linuxPackagesFor linux.kernel;
    hardware.deviceTree.name = "rockchip/rk3562-rk817-tablet-v10-panfrost.dtb";
    # Only copy this board's device trees to /boot
    hardware.deviceTree.filter = "rk3562-rk817-tablet-v10*.dtb";

    boot.loader.grub.enable = false;
    boot.loader.generic-extlinux-compatible.enable = true;
    # The U-Boot menu is only visible on the (internal) serial port
    boot.loader.timeout = lib.mkDefault 1;

    boot.kernelParams = [
      "earlycon=uart8250,mmio32,0xff210000"
      "console=ttyS0,1500000n8"
      # The panel is 800x1280 portrait; landscape console like rk3562deb
      "video=DSI-1:800x1280@60,rotate=90"
      "console=tty1"
    ];

    # The vendor kernel has most drivers built in
    boot.initrd.allowMissingModules = true;
    # No TPM on this board; saves tpm2-tss (and its deps) in the initrd
    boot.initrd.systemd.tpm2.enable = lib.mkDefault false;

    hardware.firmware = [ boardFirmware ];
    hardware.enableRedistributableFirmware = lib.mkForce false;

    # U-Boot lives in its own partitions, which nixos-rebuild doesn't
    # touch; `doogee-install-uboot` writes it.
    system.build.uboot = uboot;
    environment.systemPackages = [
      installUboot
      pkgs.i2c-tools
    ];

    # --- Display and GPU ----------------------------------------------------

    # Mesa Panfrost (Mali-G52). AFBC scanout crashes Wayland compositors on
    # the RK3562 VOP2.
    hardware.graphics.enable = lib.mkDefault true;
    environment.sessionVariables.PAN_MESA_DEBUG = "noafbc";

    # DDR frequency changes while the VOP2 scans out cause bus faults and
    # memory corruption: keep the memory controller at 920 MHz
    systemd.services.doogee-dmc-pin = {
      description = "Pin DDR frequency for display stability";
      wantedBy = [ "multi-user.target" ];
      before = [ "display-manager.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        for d in /sys/class/devfreq/*dmc*; do
          [ -e "$d/governor" ] && echo performance > "$d/governor"
        done
        true
      '';
    };

    # --- Wi-Fi and Bluetooth (Seekwave EA6621Q / SWT6621S) ------------------

    boot.kernelModules = [ "skwbt" ];

    systemd.services.doogee-rfkill-unblock = {
      description = "Unblock Wi-Fi and Bluetooth";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-rfkill.service" ];
      before = [
        "bluetooth.service"
        "network-pre.target"
      ];
      wants = [ "network-pre.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.util-linux}/bin/rfkill unblock all";
      };
    };

    # The driver logs a lot at its default level
    systemd.services.doogee-skwifi-loglevel = {
      description = "Set the Seekwave Wi-Fi log level to warn";
      wantedBy = [ "multi-user.target" ];
      serviceConfig.Type = "oneshot";
      script = ''
        for i in $(seq 20); do
          [ -w /proc/skwifi/log_level ] && echo warn > /proc/skwifi/log_level && exit 0
          sleep 1
        done
      '';
    };

    hardware.bluetooth = {
      enable = lib.mkDefault true;
      powerOnBoot = lib.mkDefault true;
    };

    # --- Accelerometer --------------------------------------------------------
    # SC7A20 or DA223 via the Rockchip sensor framework: /dev/mma8452_daemon,
    # read with ioctls (see gui.nix for screen rotation)
    services.udev.extraRules = ''
      KERNEL=="mma8452_daemon", MODE="0660", GROUP="video"
      # The sensors also show up as joysticks
      SUBSYSTEM=="input", KERNEL=="js[0-9]*", ATTRS{name}=="gsensor|mir3da", RUN+="${pkgs.coreutils}/bin/rm -f /dev/input/%k"
      SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="gsl3673", ENV{ID_INPUT}="1", ENV{ID_INPUT_TOUCHSCREEN}="1"
    '';

    # --- Power ------------------------------------------------------------

    services.logind.settings.Login = {
      HandlePowerKey = "ignore";
      HandlePowerKeyLongPress = "ignore";
    };
    systemd.services.doogee-powerkey = {
      description = "Power key: short press suspends, long press powers off";
      wantedBy = [ "multi-user.target" ];
      path = [ config.systemd.package ];
      serviceConfig = {
        ExecStart = powerKey;
        Restart = "always";
        RestartSec = 2;
      };
    };

    # The kernel patch sets DEV_OFF on power off as well; rk3562deb keeps
    # this hook as a second line, against power off ending in a reboot.
    systemd.shutdown.rk817-devoff = pkgs.writeShellScript "rk817-devoff" ''
      case "$1" in poweroff|halt) ;; *) exit 0 ;; esac
      raw=$(${pkgs.i2c-tools}/bin/i2cget -y -f 0 0x20 0xf4 b 2>/dev/null) || exit 0
      ${pkgs.i2c-tools}/bin/i2cset -y -f 0 0x20 0xf4 $(( (raw | 0x01) & 0xff )) b
      sleep 3
    '';

    # --- Audio (RK817 codec) ------------------------------------------------
    # The codec's routing controls (rk3562deb rk-audio-init.sh): speaker
    # path, main microphone and gains
    systemd.services.doogee-audio-defaults = {
      description = "Set ALSA mixer defaults for the RK817 codec";
      wantedBy = [ "multi-user.target" ];
      after = [ "sound.target" ];
      serviceConfig.Type = "oneshot";
      path = [
        pkgs.alsa-utils
        pkgs.gawk
        pkgs.coreutils
      ];
      script = ''
        card=
        for i in $(seq 20); do
          card=$(awk '/rk817/ { print $1; exit }' /proc/asound/cards)
          [ -n "$card" ] && break
          sleep 1
        done
        [ -n "$card" ] || exit 0
        a() { amixer -q -c "$card" "$@" || true; }
        a cset name='Playback Path' SPK
        a sset DAC 230,230
        a sset 'HP Output Gain' 3
        a cset name='Capture MIC Path' 'Main Mic'
        a sset ADC 255,255
        a sset 'ADC PGA Gain' 15,15
        a sset 'MIC Boost Gain' 3,3
      '';
    };
  };
}
