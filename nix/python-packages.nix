{ lib, py }:

let
  ixnetwork-restpy = py.buildPythonPackage rec {
    pname = "ixnetwork-restpy";
    version = "1.11.0";
    pyproject = true;

    src = py.fetchPypi {
      pname = "ixnetwork_restpy";
      inherit version;
      hash = "sha256-Ag8RGuWUr/hbQ5S/IpHhWivTuhd8L5eYAuAS8lOhesI=";
    };

    build-system = [ py.setuptools ];
    dependencies = with py; [
      packaging
      requests
      setuptools
      websocket-client
    ];

    # Retain the older generated BGP module hash referenced by this TAAC source
    # snapshot.  The current package exports the same class under a new hash.
    postInstall = ''
      ixnetwork_pkg=$(find "$out" -type d \
        -path '*/site-packages/ixnetwork_restpy' -print -quit)
      if [[ -z "$ixnetwork_pkg" ]]; then
        echo "could not locate the installed ixnetwork_restpy package" >&2
        exit 1
      fi

      topology="$ixnetwork_pkg/testplatform/sessions/ixnetwork/topology"
      printf '%s\n' \
        'from .bgpipv6peer_a694a7d5a34a173f8506f998534564ea import *' \
        > "$topology/bgpipv6peer_8b9aa9838ebd53702954aa471913ed1e.py"
    '';
    pythonImportsCheck = [ "ixnetwork_restpy" ];
  };

  # The repository deliberately constrains Paramiko below 4.  Nixpkgs has
  # already moved beyond that API boundary, so retain the latest 3.x release.
  paramiko = py.buildPythonPackage rec {
    pname = "paramiko";
    version = "3.5.1";
    pyproject = true;

    src = py.fetchPypi {
      inherit pname version;
      hash = "sha256-ssZlvEWyshW9fX8DmQGxSwZ9oA86EeZkCZX9WPJmSCI=";
    };

    build-system = [ py.setuptools ];
    dependencies = with py; [
      bcrypt
      cryptography
      pynacl
    ];
    pythonImportsCheck = [ "paramiko" ];
  };

  snappi = py.buildPythonPackage rec {
    pname = "snappi";
    version = "1.61.0";
    pyproject = true;

    src = py.fetchPypi {
      inherit pname version;
      hash = "sha256-Iut1DllMv2foI9rKx8uhx169duRkJZx0e36ccHu6hEE=";
    };

    build-system = with py; [
      setuptools
      wheel
    ];
    dependencies = with py; [
      grpcio
      grpcio-tools
      protobuf
      pyyaml
      requests
      semantic-version
      urllib3
    ];

    # Snappi pins its generated gRPC stack to a compatible minor series.
    # Nixpkgs updates that stack atomically; accepting its newer coherent set
    # avoids carrying three redundant native Python builds in this flake.
    pythonRelaxDeps = [
      "grpcio"
      "grpcio-tools"
      "protobuf"
    ];
    pythonImportsCheck = [ "snappi" ];
  };
in
{
  inherit ixnetwork-restpy paramiko snappi;
}
