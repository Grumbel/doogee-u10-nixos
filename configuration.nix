# Example system for the SD card image: console, SSH over USB and Wi-Fi,
# a touch GUI and a few tools. Wi-Fi credentials and SSH keys are read from
# files on the card's FAT partition, so the image itself contains nothing
# personal.
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:

{
  imports = [
    "${modulesPath}/profiles/minimal.nix"
    ./gui.nix # touch GUI (sway); remove for a console-only system
  ];

  hardware.doogee-u10.enable = true;

  system.stateVersion = "26.05";
  networking.hostName = "doogee-u10";

  boot.kernelModules = [ "g_ether" ]; # USB ethernet on the USB-C port
  boot.consoleLogLevel = 7;
  # Plain ext4 root: keep LVM and bcache out of the initrd
  services.lvm.enable = false;
  boot.bcache.enable = false;

  # --- SD card image ------------------------------------------------------

  sdImage = {
    compressImage = false;
    populateFirmwareCommands = ''
      cp ${./wifi.conf.example} firmware/wifi.conf.example
      cp ${./README-SDCARD.txt} firmware/README.txt
    '';
  };

  # Mount the FAT partition: wifi.conf, authorized_keys and boot logs
  fileSystems."/boot/firmware".options = lib.mkForce [ "nofail" ];

  # Boot logger: without a serial console, early failures leave no trace,
  # so dmesg is written to the FAT partition (readable on any PC).
  boot.initrd.systemd.extraBin.dmesg = "${pkgs.util-linux}/bin/dmesg";
  boot.initrd.systemd.services.doogee-bootlog = {
    description = "Write dmesg to the FIRMWARE partition";
    wantedBy = [ "initrd.target" ];
    unitConfig.DefaultDependencies = false;
    script = ''
      while [ ! -e /dev/disk/by-label/FIRMWARE ]; do sleep 1; done
      mkdir -p /run/bootlog
      mount -t vfat /dev/disk/by-label/FIRMWARE /run/bootlog
      while true; do
        dmesg > /run/bootlog/dmesg-initrd.txt
        sync
        sleep 2
      done
    '';
  };
  systemd.services.doogee-bootlog = {
    description = "Write dmesg to the FIRMWARE partition for the first minutes";
    wantedBy = [ "sysinit.target" ];
    unitConfig = {
      DefaultDependencies = false;
      RequiresMountsFor = "/boot/firmware";
    };
    path = [
      pkgs.util-linux
      pkgs.coreutils
    ];
    script = ''
      for i in $(seq 90); do
        dmesg > /boot/firmware/dmesg-stage2.txt
        sync
        sleep 2
      done
    '';
  };

  # --- Networking -----------------------------------------------------------

  networking.useNetworkd = true;
  # Keep the plain wlan0 / usb0 names used below
  networking.usePredictableInterfaceNames = false;

  # Wi-Fi: no networks are declared, so wpa_supplicant reads
  # /etc/wpa_supplicant/imperative.conf, copied from wifi.conf on the FAT
  # partition at boot.
  networking.wireless = {
    enable = true;
    interfaces = [ "wlan0" ];
  };
  systemd.services.doogee-wifi-config = {
    description = "Copy wifi.conf from the SD card FAT partition";
    wantedBy = [ "multi-user.target" ];
    before = [
      "wpa_supplicant-wlan0.service"
      "wpa_supplicant.service"
    ];
    unitConfig.RequiresMountsFor = "/boot/firmware";
    serviceConfig.Type = "oneshot";
    script = ''
      if [ -f /boot/firmware/wifi.conf ]; then
        mkdir -p /etc/wpa_supplicant
        install -m 0664 -o wpa_supplicant -g wpa_supplicant \
          /boot/firmware/wifi.conf /etc/wpa_supplicant/imperative.conf
      fi
    '';
  };
  systemd.network.networks."40-wlan0" = {
    matchConfig.Name = "wlan0";
    networkConfig.DHCP = "yes";
    # Ignore NTP servers from DHCP: timesyncd only tries those once it has
    # any, and many home routers announce one without answering
    dhcpV4Config.UseNTP = false;
    dhcpV6Config.UseNTP = false;
  };

  # USB: connect the USB-C port to a PC and `ssh root@10.42.0.1`.
  # The PC gets an address via DHCP from the tablet.
  systemd.network.networks."30-usb0" = {
    matchConfig.Name = "usb0";
    address = [ "10.42.0.1/24" ];
    networkConfig.DHCPServer = true;
    dhcpServerConfig = {
      PoolOffset = 100;
      PoolSize = 20;
      EmitDNS = false;
      EmitRouter = false;
    };
  };
  networking.firewall.allowedUDPPorts = [ 67 ];
  networking.nftables.enable = true;

  # mDNS, so it's reachable as doogee-u10.local over Wi-Fi
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    # IPv4 only: otherwise the PC often gets usb0's fe80:: address first,
    # and glibc on the PC drops its scope, so ssh fails with "connect:
    # Invalid argument". Over USB the tablet is doogee-u10-usb.local.
    ipv6 = false;
    extraConfig = ''
      [publish]
      publish-aaaa-on-ipv4=no
    '';
    publish = {
      enable = true;
      addresses = true;
      userServices = true; # lets avahi-publish (doogee-mdns-usb) register names
    };
  };

  # Leave mDNS to avahi (two responders on 5353 make it unreliable)
  services.resolved.settings.Resolve.MulticastDNS = false;
  # Fixed name for the USB link, so it works without Wi-Fi. A static
  # /etc/avahi/hosts entry collides with the host name's reverse record
  # for 10.42.0.1, hence avahi-publish --no-reverse.
  systemd.services.doogee-mdns-usb = {
    description = "Publish doogee-u10-usb.local for the USB link";
    wantedBy = [ "multi-user.target" ];
    requires = [ "avahi-daemon.service" ];
    after = [ "avahi-daemon.service" ];
    serviceConfig = {
      ExecStart = "${pkgs.avahi}/bin/avahi-publish --address --no-reverse doogee-u10-usb.local 10.42.0.1";
      Restart = "always"; # also exits 0 on errors
      RestartSec = 5;
    };
  };

  # --- Access -----------------------------------------------------------------

  # Keys only: the image ships with well-known console passwords
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
  };
  # SSH public keys from authorized_keys on the FAT partition
  systemd.services.doogee-ssh-keys = {
    description = "Copy authorized_keys from the SD card FAT partition";
    wantedBy = [ "multi-user.target" ];
    before = [ "sshd.service" ];
    unitConfig.RequiresMountsFor = "/boot/firmware";
    serviceConfig.Type = "oneshot";
    script = ''
      if [ -f /boot/firmware/authorized_keys ]; then
        install -d -m 0700 /root/.ssh
        install -m 0600 /boot/firmware/authorized_keys /root/.ssh/authorized_keys
      fi
    '';
  };
  # For logging in on the console (with a USB keyboard) or the serial port.
  # Change it with `passwd` after the first login.
  users.users.root.initialPassword = "doogee";

  # --- Tools ------------------------------------------------------------------

  environment.systemPackages = with pkgs; [
    kmscube
    libdrm # modetest
    mesa-demos # eglinfo
    alsa-utils # amixer, aplay, speaker-test
    evtest
    iw
    wpa_supplicant
    usbutils
    htop
    dtc
    # General tools
    rsync
    wget
    curl
    ripgrep
    fd
    bat
    jq
    tmux
    tree
    ncdu
    file
    unzip
    strace
    mpv
  ];

  # --- Memory -----------------------------------------------------------------

  # 4 GB RAM; compressed swap in RAM for the browser
  zramSwap = {
    enable = true;
    memoryPercent = 50;
  };

  documentation.enable = false;
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];
}
