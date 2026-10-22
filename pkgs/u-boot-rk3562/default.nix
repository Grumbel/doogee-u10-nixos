# Rockchip vendor U-Boot for the RK3562, built the way rk3562deb's
# build.sh does it (`./make.sh rk3562` and `./make.sh --idblock`).
#
# Outputs:
#   idblock.bin  DDR init + SPL (rkbin blobs), at sector 64 of the SD card
#   uboot.img    FIT image with U-Boot, TF-A (BL31) and OP-TEE (BL32),
#                in the GPT partition named "uboot" (the SPL looks it up)
{ pkgs, sources }:

let
  inherit (pkgs) buildPackages;
  # Old code base: like Debian trixie, which rk3562deb is built with
  stdenv = pkgs.gcc14Stdenv;
in
stdenv.mkDerivation {
  pname = "u-boot-rk3562";
  version = "2017.09-firefly-${builtins.substring 0 7 sources.u-boot.rev}";

  src = sources.u-boot;

  patches = [
    "${sources.rk3562deb}/patches/0001-u-boot-make.sh-only-require-python2-for-legacy-generators.patch"
  ];

  # Host tools (mkimage etc.) with GCC 14 too; GCC 15 defaults to C23
  depsBuildBuild = [
    buildPackages.gcc14Stdenv.cc
    buildPackages.openssl
  ];
  nativeBuildInputs = with buildPackages; [
    bc
    bison
    flex
    dtc
    python3
    which
  ];

  # Like nixpkgs' buildUBoot; the SPL doesn't fit into SRAM otherwise
  hardeningDisable = [ "all" ];

  postPatch = ''
    # Splits TF-A into its load segments for the FIT image. It's Python 3
    # compatible; without it the FIT has no TF-A and doesn't boot.
    substituteInPlace arch/arm/mach-rockchip/decode_bl31.py \
      --replace-fail "/usr/bin/env python2" "/usr/bin/env python3"
    patchShebangs make.sh scripts arch/arm/mach-rockchip tools
  '';

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild

    # make.sh expects rkbin next to the source tree (and writes into it)
    mkdir -p ../rkbin/bin/rk35 ../rkbin/tools
    cp -r ${sources.rkbin}/RKBOOT ${sources.rkbin}/RKTRUST ../rkbin/
    cp ${sources.rkbin}/bin/rk35/rk3562_* ../rkbin/bin/rk35/
    chmod -R u+w ../rkbin
    # make.sh also packs the USB download loader (rk3562_spl_loader_*.bin,
    # for rkdeveloptool) with rkbin's prebuilt x86 boot_merger. The SD card
    # doesn't need it.
    printf '#!/bin/sh\necho "boot_merger: skipped"\n' > ../rkbin/tools/boot_merger
    chmod +x ../rkbin/tools/boot_merger

    export KCFLAGS="-Wno-error"
    ./make.sh rk3562 CROSS_COMPILE=${stdenv.cc.targetPrefix}
    ./make.sh --idblock

    # The FIT must contain TF-A
    ./tools/mkimage -l uboot.img | grep -q 'ARM Trusted Firmware'

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm644 -t $out idblock.bin uboot.img
    runHook postInstall
  '';

  # The output is firmware for the SoC, not something to run on the build host
  dontStrip = true;
  dontPatchELF = true;

  meta.platforms = [ "aarch64-linux" ];
}
