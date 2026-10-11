{
  description = "Local HTTPS and MQTT cloud emulator for Roborock vacuums";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    {
      self,
      nixpkgs,
    }:
    let
      linuxSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forLinux = nixpkgs.lib.genAttrs linuxSystems;
    in
    {
      packages = forLinux (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          rls = pkgs.callPackage ./nix/packages/default.nix { };
        in
        {
          default = rls;
          roborock-local-server = rls;
        }
      );

      checks = forLinux (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          rls = pkgs.callPackage ./nix/packages/default.nix { };
        in
        {
          package-build = rls.package;

          # module-eval =
          #   (hmLib.homeManagerConfiguration {
          #     inherit pkgs;
          #     modules = [
          #       self.homeManagerModules.default
          #       {
          #         home = {
          #           username = "test";
          #           homeDirectory = "/home/test";
          #           stateVersion = "24.11";
          #         };
          #         programs.steam-rom-manager = {
          #           enable = true;
          #           steamUsername = "testuser";
          #           emulators = {
          #             # ROM parsers
          #             retroarch.enable = true; # cross-platform
          #             mgba.enable = true; # cross-platform
          #             # Platform parsers (no package)
          #             epic.enable = true;
          #             "itch.io".enable = true;
          #             # Disabled flag
          #             flycast = {
          #               enable = true;
          #               disabled = true;
          #             };
          #           };
          #         };
          #       }
          #     ];
          #   }).activationPackage;
        }
      );
    };
}