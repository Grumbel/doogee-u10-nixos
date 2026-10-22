# Rockchip BSP kernel 6.1 with the Doogee U10 board support from rk3562deb.
#
# `pkgs` is the package set the kernel is built with (cross-compiling from
# x86_64 is much faster than building under emulation).
{
  pkgs,
  sources,
  configfile ? ../../kernel/doogee-u10.config,
}:

let
  inherit (pkgs) lib buildPackages;

  version = "6.1.162";

  # Like Debian trixie, which rk3562deb is built and tested with. The vendor
  # tree and drivers aren't tested with GCC 15.
  stdenv = pkgs.gcc14Stdenv;

  # Kernel tree with rk3562deb's overlay applied, the way build.sh does it:
  # device trees, defconfig, Seekwave Wi-Fi/Bluetooth, HUSB320 Type-C,
  # cameras, sensor headers and the Wi-Fi firmware for EXTRA_FIRMWARE.
  src = buildPackages.runCommand "linux-rk3562-${version}-source" { } ''
    cp -r ${sources.kernel} $out
    chmod -R u+w $out
    cd $out
    overlay=${sources.rk3562deb}/overlay
    cp -r $overlay/arch $overlay/drivers $overlay/include $overlay/firmware .
    chmod -R u+w .
    # build.sh keeps the upstream PMIC drivers by default
    cp ${sources.kernel}/drivers/mfd/rk808.c drivers/mfd/rk808.c
    cp ${sources.kernel}/drivers/power/supply/rk817_battery.c drivers/power/supply/rk817_battery.c
    echo 'dtb-$(CONFIG_ARCH_ROCKCHIP) += rk3562-rk817-tablet-v10-panfrost.dtb' \
      >> arch/arm64/boot/dts/rockchip/Makefile
    # nixpkgs builds in a separate output directory (O=), where $(src) is
    # not the source directory
    sed -i -e 's|\$(PERL) -s \$(src)/genver.pl|$(PERL) -s $(srctree)/$(src)/genver.pl|' \
      -e 's|-I\$(src)$|-I$(srctree)/$(src)|' \
      drivers/net/wireless/ea6621q/skwifi/Makefile
  '';

  # The fifth patch in kernel-patches/ (rk817-charger-vbus-safety) is
  # already contained in the overlay's rk817_charger.c.
  kernelPatches =
    map
      (name: {
        inherit name;
        patch = "${sources.rk3562deb}/overlay/kernel-patches/${name}.patch";
      })
      [
        "rk817-dev-off-poweroff" # poweroff instead of an immediate reboot
        "rk817-boot-ocv-calibration" # battery level from the OCV at boot
        "rk8xx-clkout-name-match" # RK817 clock outputs (Wi-Fi/BT 32 kHz clock)
        "panfrost-rk3562-clocks" # GPU bus clocks
      ];

  makeFlags = [
    "ARCH=arm64"
    "CROSS_COMPILE=${stdenv.cc.targetPrefix}"
    "CC=${stdenv.cc}/bin/${stdenv.cc.targetPrefix}cc"
    "HOSTCC=${buildPackages.stdenv.cc}/bin/cc"
  ];

  # defconfig + kernel/doogee-u10.fragment. Its output is committed as
  # kernel/doogee-u10.config, so evaluating the system doesn't need a build.
  configfileGenerated = stdenv.mkDerivation {
    pname = "linux-rk3562-config";
    inherit version src;
    depsBuildBuild = [ buildPackages.stdenv.cc ];
    nativeBuildInputs = with buildPackages; [
      bison
      flex
      bc
      perl
    ];
    fragment = ../../kernel/doogee-u10.fragment;
    dontConfigure = true;
    buildPhase = ''
      runHook preBuild
      patchShebangs scripts
      scripts/kconfig/merge_config.sh -m arch/arm64/configs/rockchip_linux_defconfig $fragment
      make ${lib.escapeShellArgs makeFlags} olddefconfig

      # Every option from the fragment must have taken effect
      missing=0
      while IFS= read -r line; do
        case $line in
          CONFIG_*=*) grep -qxF "$line" .config ;;
          "# CONFIG_"*" is not set")
            opt=''${line#\# }; opt=''${opt%% *}
            ! grep -q "^$opt=" .config ;;
          *) continue ;;
        esac || { echo "not in .config: $line"; missing=1; }
      done < $fragment
      [ $missing = 0 ]
      runHook postBuild
    '';
    installPhase = ''
      cp .config $out
    '';
  };

in
{
  inherit configfileGenerated;

  kernel = pkgs.linuxManualConfig {
    inherit
      version
      src
      kernelPatches
      configfile
      stdenv
      ;
    modDirVersion = version;
    extraMeta.platforms = [ "aarch64-linux" ];
  };
}
