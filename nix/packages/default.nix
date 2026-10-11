{
  lib,
  python313Packages,
  makeWrapper,
  mosquitto,
  openssl,
  gawk,
  acme-sh,
  fetchFromGitHub,
  ...
}:
let
  python-roborock-4 = python313Packages.python-roborock.overridePythonAttrs rec {
    version = "4.20.0";
    src = fetchFromGitHub {
      owner = "Python-roborock";
      repo = "python-roborock";
      rev = "v${version}";
      hash = "sha256-64yzlVYjyj9iHtdFXcRFn4YifpBOnSchZyI57iKyDTk=";
    };
    doCheck = false;
    pythonRelaxDeps = true;
    dontCheckRuntimeDeps = true;
  };
in
python313Packages.buildPythonApplication {
  pname = "roborock-local-server";
  version = "1.2.0";
  src = lib.cleanSource ../..;

  pyproject = true;

  build-system = [ python313Packages.hatchling ];

  dependencies = with python313Packages; [
    aiohttp
    cryptography
    fastapi
    gmpy2
    pycryptodome
    python-multipart
    uvicorn
    python-roborock-4
  ];

  nativeBuildInputs = [ makeWrapper ];

  # certs.py hardcodes the container image's acme.sh location.
  postPatch = ''
    substituteInPlace src/roborock_local_server/certs.py \
      --replace-fail '/opt/acme.sh/acme.sh' '${acme-sh}/bin/acme.sh'
  '';

  pythonRelaxDeps = true;
  dontCheckRuntimeDeps = true;

  # gawk: acme.sh 3.1.x calls awk (incl. gawk-only strftime) during ZeroSSL
  # account registration, but nixpkgs' acme-sh wrapper doesn't supply it and a
  # systemd unit's default PATH has none.
  makeWrapperArgs = [
    "--prefix"
    "PATH"
    ":"
    (lib.makeBinPath [
      mosquitto
      openssl
      gawk
    ])
  ];

  pythonImportsCheck = [ "roborock_local_server" ];
  doCheck = false;

  meta = {
    description = "Local HTTPS and MQTT cloud emulator for Roborock vacuums";
    homepage = "https://github.com/Python-roborock/local_roborock_server";
    license = lib.licenses.mit;
    mainProgram = "roborock-local-server";
  };
}
