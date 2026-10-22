{
  description = "NixOS for the Doogee U10 tablet (Rockchip RK3562)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    { self, nixpkgs }:
    let
      buildSystem = "x86_64-linux";
      system = self.nixosConfigurations.doogee-u10;

      # For packages.kernelConfig: the same cross package set the module
      # builds the kernel with
      crossPkgs = import nixpkgs {
        localSystem = buildSystem;
        crossSystem = "aarch64-linux";
      };
      linux = import ./pkgs/linux-rk3562 {
        pkgs = crossPkgs;
        sources = crossPkgs.buildPackages.callPackage ./sources.nix { };
      };
    in
    {
      # Hardware support, for use in your own configuration
      nixosModules.default = ./modules/doogee-u10.nix;
      nixosModules.doogee-u10 = ./modules/doogee-u10.nix;
      # SD card layout (GPT with the Rockchip loader partitions)
      nixosModules.sdImage = ./modules/sd-image.nix;

      # Example system / SD card image. The userland is native aarch64 and
      # comes from the binary cache; kernel and U-Boot are cross-compiled on
      # x86_64 (needs binfmt emulation for the few local aarch64
      # derivations).
      nixosConfigurations.doogee-u10 = nixpkgs.lib.nixosSystem {
        modules = [
          self.nixosModules.default
          self.nixosModules.sdImage
          ./configuration.nix
          { hardware.doogee-u10.kernelBuildPlatform = buildSystem; }
        ];
      };

      packages.${buildSystem} = {
        default = system.config.system.build.sdImage;
        sdImage = system.config.system.build.sdImage;
        toplevel = system.config.system.build.toplevel;
        kernel = system.config.boot.kernelPackages.kernel;
        uboot = system.config.system.build.uboot;
        # Regenerate kernel/doogee-u10.config after changing the fragment:
        #   nix build .#kernelConfig && install -m644 result kernel/doogee-u10.config
        kernelConfig = linux.configfileGenerated;
      };
    };
}
