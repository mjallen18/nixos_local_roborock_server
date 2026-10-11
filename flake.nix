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
      nixosModules.default = import ./nix/modules/default.nix { inherit self; };

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
          package-build = rls;

          module-eval =
            let
              eval =
                extra:
                nixpkgs.lib.nixosSystem {
                  inherit system;
                  modules = [
                    self.nixosModules.default
                    {
                      boot.loader.grub.enable = false;
                      fileSystems."/" = {
                        device = "none";
                        fsType = "tmpfs";
                      };
                      system.stateVersion = "25.05";
                      services.roborock-local-server = {
                        enable = true;
                        protocolLoginEmail = "test@example.com";
                        adminPasswordHashFile = "/run/secrets/admin";
                        protocolLoginPinHashFile = "/run/secrets/pin";
                      }
                      // extra;
                    }
                  ];
                };
              acme = eval {
                baseDomain = "example.com";
                acmeEmail = "test@example.com";
                cloudflareTokenFile = "/run/secrets/cf";
                acmeServer = "actalis";
                acmeEabKidFile = "/run/secrets/kid";
                acmeEabHmacKeyFile = "/run/secrets/hmac";
              };
              provided = eval {
                stackFqdn = "api-roborock.example.com";
                tls = {
                  mode = "provided";
                  certFile = "/run/secrets/cert";
                  keyFile = "/run/secrets/key";
                };
              };
              proxied = eval {
                stackFqdn = "api-roborock.example.com";
                listenerMode = "external_tls";
                tls.mode = "provided";
                advertisedPort = 443;
                trustedProxies = [ "192.168.1.10" ];
              };
              units = map (c: c.config.systemd.services.roborock-local-server.serviceConfig.ExecStart) [
                acme
                provided
                proxied
              ];
              failed = nixpkgs.lib.concatMap (
                c: map (a: a.message) (builtins.filter (a: !a.assertion) c.config.assertions)
              ) [ acme provided proxied ];
            in
            assert failed == [ ];
            pkgs.writeText "module-eval" (builtins.concatStringsSep "\n" units);
        }
      );
    };
}