{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    types
    ;
  cfg = config.services.roborock-local-server;
  acme = cfg.tls.mode == "cloudflare_acme" && cfg.listenerMode == "local_tls";
  stateDir = "/var/lib/roborock-local-server";
  configPath = "${stateDir}/config.toml";

  tlsLines = lib.concatStringsSep "\n" (
    if cfg.tls.mode == "provided" then
      lib.optionals (cfg.listenerMode == "local_tls") [
        "cert_file = \"@CREDENTIALS_DIRECTORY@/tls-cert\""
        "key_file = \"@CREDENTIALS_DIRECTORY@/tls-key\""
      ]
    else
      [
        "base_domain = \"${cfg.baseDomain}\""
        "email = \"${cfg.acmeEmail}\""
        "cloudflare_token_file = \"@CREDENTIALS_DIRECTORY@/cloudflare-token\""
        "renew_days_before = 30"
        "renew_check_seconds = 43200"
        "acme_server = \"${cfg.acmeServer}\""
      ]
      ++ lib.optionals (cfg.acmeEabKidFile != null) [
        "acme_eab_kid_file = \"@CREDENTIALS_DIRECTORY@/eab-kid\""
        "acme_eab_hmac_key_file = \"@CREDENTIALS_DIRECTORY@/eab-hmac-key\""
      ]
  );

  # Everything non-secret. Secrets are substituted at start-up from
  # systemd credentials so they never reach the world-readable Nix store.
  configTemplate = pkgs.writeText "roborock-config.toml.in" ''
    [network]
    stack_fqdn = "${cfg.stackFqdn}"
    bind_host = "${cfg.listenAddress}"
    https_port = ${toString cfg.port}
    mqtt_tls_port = ${toString cfg.mqttPort}
    region = "${cfg.region}"
    listener_mode = "${cfg.listenerMode}"
    advertised_https_port = ${toString (if cfg.advertisedPort != null then cfg.advertisedPort else cfg.port)}
    advertised_mqtt_tls_port = ${toString (if cfg.advertisedMqttPort != null then cfg.advertisedMqttPort else cfg.mqttPort)}
    ${lib.optionalString (cfg.trustedProxies != null) "trusted_proxies = ${builtins.toJSON cfg.trustedProxies}"}

    [broker]
    mode = "embedded"
    host = "127.0.0.1"
    port = 18830
    mosquitto_binary = "mosquitto"
    enable_topic_bridge = true

    [storage]
    data_dir = "${stateDir}"

    [tls]
    mode = "${cfg.tls.mode}"
    ${tlsLines}

    [admin]
    password_hash = "@ADMIN_PASSWORD_HASH@"
    session_secret = "@SESSION_SECRET@"
    session_ttl_seconds = 86400
    protocol_auth_enabled = ${lib.boolToString cfg.protocolAuthEnabled}
    new_connections_enabled = ${lib.boolToString cfg.newConnectionsEnabled}
    protocol_login_email = "${cfg.protocolLoginEmail}"
    protocol_login_pin_hash = "@PIN_HASH@"
  '';

  prepareConfig = pkgs.writeShellScript "roborock-prepare-config" ''
    set -euo pipefail
    umask 077
    cred="$CREDENTIALS_DIRECTORY"

    # The session secret only needs to be stable and private; generate it once
    # unless the user supplies one.
    if [ -r "$cred/session-secret" ]; then
      session_secret="$(tr -d '\n' < "$cred/session-secret")"
    else
      if [ ! -s ${stateDir}/session-secret ]; then
        ${lib.getExe cfg.package} generate-secret > ${stateDir}/session-secret
      fi
      session_secret="$(tr -d '\n' < ${stateDir}/session-secret)"
    fi

    admin_hash="$(tr -d '\n' < "$cred/admin-password-hash")"
    pin_hash="$(tr -d '\n' < "$cred/pin-hash")"

    # Hashes/secrets are base64url or pbkdf2 strings: no characters special
    # to sed (we use '|' as delimiter) or TOML.
    ${pkgs.gnused}/bin/sed \
      -e "s|@CREDENTIALS_DIRECTORY@|$cred|g" \
      -e "s|@ADMIN_PASSWORD_HASH@|$admin_hash|g" \
      -e "s|@SESSION_SECRET@|$session_secret|g" \
      -e "s|@PIN_HASH@|$pin_hash|g" \
      ${configTemplate} > ${configPath}.tmp
    mv ${configPath}.tmp ${configPath}
  '';
in
{
  options.services.roborock-local-server = {
    enable = mkEnableOption "the local Roborock cloud emulator (HTTPS + MQTT)";

    package = mkOption {
      type = types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
      defaultText = lib.literalExpression "roborock-local-server flake package";
      description = "The roborock-local-server package to run.";
    };

    baseDomain = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "example.com";
      description = "Base domain for the wildcard certificate (Cloudflare DNS-01). Required when `tls.mode = \"cloudflare_acme\"`; also the default for `stackFqdn`.";
    };

    stackFqdn = mkOption {
      type = types.str;
      default = "api-roborock.${toString cfg.baseDomain}";
      defaultText = lib.literalExpression ''"api-roborock.''${config.services.roborock-local-server.baseDomain}"'';
      description = "The single hostname the robots and apps connect to.";
    };

    region = mkOption {
      type = types.enum [
        "us"
        "eu"
        "cn"
        "ru"
      ];
      default = "us";
      description = "Roborock region to emulate.";
    };

    listenAddress = mkOption {
      type = types.str;
      default = "0.0.0.0";
      description = "Address the HTTPS and MQTT listeners bind to.";
    };

    port = mkOption {
      type = types.port;
      default = 555;
      description = "HTTPS port.";
    };

    mqttPort = mkOption {
      type = types.port;
      default = 8881;
      description = "MQTT TLS port.";
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Open the HTTPS and MQTT TLS ports in the firewall.";
    };

    listenerMode = mkOption {
      type = types.enum [
        "local_tls"
        "external_tls"
      ];
      default = "local_tls";
      description = ''
        `local_tls` terminates TLS in the server. `external_tls` expects a reverse
        proxy to terminate TLS and forward plain traffic; this requires `tls.mode = "provided"`
        and the server then needs no certificate files.
      '';
    };

    advertisedPort = mkOption {
      type = types.nullOr types.port;
      default = null;
      description = "HTTPS port advertised to clients when a proxy maps a different public port. Defaults to `port`.";
    };

    advertisedMqttPort = mkOption {
      type = types.nullOr types.port;
      default = null;
      description = "MQTT TLS port advertised to clients when a proxy maps a different public port. Defaults to `mqttPort`.";
    };

    trustedProxies = mkOption {
      type = types.nullOr (types.listOf types.str);
      default = null;
      example = [ "192.168.1.10" ];
      description = "IPs/CIDRs of reverse proxies trusted for forwarded headers. Null keeps the server default.";
    };

    tls = {
      mode = mkOption {
        type = types.enum [
          "cloudflare_acme"
          "provided"
        ];
        default = "cloudflare_acme";
        description = "Obtain certificates via Cloudflare DNS-01 ACME, or use a provided certificate/key pair.";
      };

      certFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "PEM certificate chain (for `provided` mode with `local_tls`).";
      };

      keyFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "PEM private key (for `provided` mode with `local_tls`).";
      };
    };

    acmeEmail = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Email address for the ACME account (cloudflare_acme mode).";
    };

    acmeServer = mkOption {
      type = types.enum [
        "zerossl"
        "letsencrypt"
        "actalis"
      ];
      default = "zerossl";
      description = "ACME CA. Actalis requires `acmeEabKidFile` and `acmeEabHmacKeyFile`.";
    };

    acmeEabKidFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "File containing the ACME External Account Binding key ID.";
    };

    acmeEabHmacKeyFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "File containing the ACME External Account Binding HMAC key.";
    };

    cloudflareTokenFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "File containing a Cloudflare API token with DNS edit rights (e.g. an agenix/sops path).";
    };

    adminPasswordHashFile = mkOption {
      type = types.path;
      description = ''
        File containing the admin password hash, as produced by
        `roborock-local-server hash-password`.
      '';
    };

    sessionSecretFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        File containing the admin session secret (at least 24 characters).
        If null, one is generated once and kept in the state directory.
      '';
    };

    protocolLoginEmail = mkOption {
      type = types.str;
      description = "Email used by the Roborock app / Home Assistant to log in to this server.";
    };

    protocolLoginPinHashFile = mkOption {
      type = types.path;
      description = ''
        File containing the hash of the 6-digit login PIN, as produced by
        `roborock-local-server hash-password --password <PIN>`.
      '';
    };

    protocolAuthEnabled = mkOption {
      type = types.bool;
      default = true;
      description = "Initial value of protocol authentication. Resets on restart if toggled in the admin UI.";
    };

    newConnectionsEnabled = mkOption {
      type = types.bool;
      default = true;
      description = "Initial value of allowing new connections. Resets on restart if toggled in the admin UI.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.listenerMode != "external_tls" || cfg.tls.mode == "provided";
        message = "services.roborock-local-server: listenerMode = \"external_tls\" requires tls.mode = \"provided\".";
      }
      {
        assertion = !acme || (cfg.baseDomain != null && cfg.acmeEmail != null && cfg.cloudflareTokenFile != null);
        message = "services.roborock-local-server: tls.mode = \"cloudflare_acme\" requires baseDomain, acmeEmail and cloudflareTokenFile.";
      }
      {
        assertion = !acme || (cfg.acmeEabKidFile != null) == (cfg.acmeEabHmacKeyFile != null);
        message = "services.roborock-local-server: acmeEabKidFile and acmeEabHmacKeyFile must be set together.";
      }
      {
        assertion = !acme || cfg.acmeServer != "actalis" || cfg.acmeEabKidFile != null;
        message = "services.roborock-local-server: acmeServer = \"actalis\" requires the EAB key files.";
      }
      {
        assertion =
          cfg.tls.mode != "provided"
          || cfg.listenerMode == "external_tls"
          || (cfg.tls.certFile != null && cfg.tls.keyFile != null);
        message = "services.roborock-local-server: tls.mode = \"provided\" with local_tls requires tls.certFile and tls.keyFile.";
      }
    ];

    networking.firewall.allowedTCPPorts = mkIf cfg.openFirewall [
      cfg.port
      cfg.mqttPort
    ];

    systemd.services.roborock-local-server = {
      description = "Local Roborock cloud server";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      environment.HOME = stateDir;

      serviceConfig = {
        ExecStartPre = prepareConfig;
        ExecStart = "${lib.getExe cfg.package} serve --config ${configPath}";
        Restart = "on-failure";
        RestartSec = 5;

        DynamicUser = true;
        StateDirectory = "roborock-local-server";
        StateDirectoryMode = "0700";
        LoadCredential = [
          "admin-password-hash:${cfg.adminPasswordHashFile}"
          "pin-hash:${cfg.protocolLoginPinHashFile}"
        ]
        ++ lib.optional (cfg.sessionSecretFile != null) "session-secret:${cfg.sessionSecretFile}"
        ++ lib.optionals acme [
          "cloudflare-token:${cfg.cloudflareTokenFile}"
        ]
        ++ lib.optionals (acme && cfg.acmeEabKidFile != null) [
          "eab-kid:${cfg.acmeEabKidFile}"
          "eab-hmac-key:${cfg.acmeEabHmacKeyFile}"
        ]
        ++ lib.optionals (cfg.tls.mode == "provided" && cfg.listenerMode == "local_tls") [
          "tls-cert:${cfg.tls.certFile}"
          "tls-key:${cfg.tls.keyFile}"
        ];

        AmbientCapabilities = lib.optional (cfg.port < 1024 || cfg.mqttPort < 1024) "CAP_NET_BIND_SERVICE";
        CapabilityBoundingSet = lib.optional (cfg.port < 1024 || cfg.mqttPort < 1024) "CAP_NET_BIND_SERVICE";

        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        RestrictNamespaces = true;
        LockPersonality = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        SystemCallArchitectures = "native";
        UMask = "0077";
      };
    };
  };
}
