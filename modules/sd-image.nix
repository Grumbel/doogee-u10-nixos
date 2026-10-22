# SD card image for the Doogee U10, laid out like rk3562deb's image:
#
#   sector 64 (32 KiB)  idbloader  DDR init + SPL     (partition 1)
#   8 MiB               uboot      U-Boot FIT image   (partition 2)
#   16 MiB              FIRMWARE   FAT: wifi.conf, SSH keys, boot logs
#   ...                 NIXOS_SD   ext4 root with /boot/extlinux
#
# The partition table is GPT: the RK3562 SPL finds U-Boot by the partition
# name "uboot". The root partition carries the legacy BIOS bootable flag,
# which is where U-Boot's distro boot looks for extlinux.conf.
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:

let
  uboot = config.system.build.uboot;
in
{
  imports = [ "${modulesPath}/installer/sd-card/sd-image.nix" ];

  # sd-image.nix pulls in the modules for every kind of hardware
  hardware.enableAllHardware = lib.mkForce false;

  sdImage = {
    firmwarePartitionOffset = 16;
    postBuildCommands = ''
      # Replace the MBR from sd-image.nix by a GPT with the same FAT and
      # root partitions, plus the two loader partitions in front
      eval $(partx $img -o START,SECTORS --nr 1 --pairs)
      fwStart=$START fwSectors=$SECTORS
      eval $(partx $img -o START,SECTORS --nr 2 --pairs)
      rootStart=$START rootSectors=$SECTORS
      # Room for the backup GPT at the end
      truncate -s +1M $img
      sfdisk --no-reread --no-tell-kernel --wipe never $img <<EOF
      label: gpt
      label-id: 7D5F1A04-9E0B-4D6C-8B57-2C1F7A3E6B10
      first-lba: 34

      start=64, size=16320, name=idbloader, uuid=A1F2C3D4-0001-4E5F-8A9B-0C1D2E3F4A51
      start=16384, size=16384, name=uboot, uuid=A1F2C3D4-0002-4E5F-8A9B-0C1D2E3F4A52
      start=$fwStart, size=$fwSectors, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, name=FIRMWARE, uuid=A1F2C3D4-0003-4E5F-8A9B-0C1D2E3F4A53
      start=$rootStart, size=$rootSectors, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name=nixos, uuid=A1F2C3D4-0004-4E5F-8A9B-0C1D2E3F4A54, attrs=LegacyBIOSBootable
      EOF
      dd if=${uboot}/idblock.bin of=$img seek=64 conv=notrunc
      dd if=${uboot}/uboot.img of=$img seek=16384 conv=notrunc
    '';
    populateRootCommands = ''
      mkdir -p ./files/boot
      ${config.boot.loader.generic-extlinux-compatible.populateCmd} -c ${config.system.build.toplevel} -d ./files/boot
    '';
  };

  # sd-image.nix takes the partition number from the minor device number,
  # which is only right for mmcblk0 (the SD card is mmcblk1 here). The GPT
  # backup header also has to move to the end of the card first.
  systemd.services.expand-root-partition.script = lib.mkForce ''
    rootPart=$(${lib.getExe' pkgs.util-linux "findmnt"} -n -o SOURCE /)
    bootDevice=$(${lib.getExe' pkgs.util-linux "lsblk"} -npo PKNAME $rootPart)
    partNum=$(cat /sys/class/block/$(basename $rootPart)/partition)

    ${lib.getExe' pkgs.util-linux "sfdisk"} --relocate gpt-bak-std $bootDevice
    echo ",+," | ${lib.getExe' pkgs.util-linux "sfdisk"} -N$partNum --no-reread $bootDevice
    ${lib.getExe' pkgs.parted "partprobe"}
    ${lib.getExe' pkgs.e2fsprogs "resize2fs"} $rootPart
  '';
}
