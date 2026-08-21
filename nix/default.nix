{
  pkgs,
  src,
  inputs,
}:

let
  inherit (pkgs) lib;
  python = pkgs.python312;
  py = python.pkgs;
  snapshotVersion = "2026.07.27.00";

  replaceCmakeFlag = prefix: flags: builtins.filter (flag: !(lib.hasPrefix prefix flag)) flags;

  # Folly's Python extension is a build-time requirement of the modern
  # thrift.python runtime.  Nixpkgs intentionally builds Folly without it,
  # so enable it on the source revision pinned by this repository.
  folly-python = pkgs.folly.overrideAttrs (old: {
    pname = "folly-python";
    version = snapshotVersion;
    src = inputs.folly-src;
    patches = [ ];
    nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [
      python
      py.cython
      py.pip
      py.setuptools
      py.wheel
    ];
    cmakeFlags = replaceCmakeFlag "-DBUILD_SHARED_LIBS" (old.cmakeFlags or [ ]) ++ [
      (lib.cmakeBool "BUILD_SHARED_LIBS" true)
      (lib.cmakeBool "PYTHON_EXTENSIONS" true)
      # Folly's CMake package and Python .pxd files then share one prefix,
      # which lets FBThrift discover the latter through FOLLY_PREFIX_DIR.
      (lib.cmakeFeature "PYTHON_PACKAGE_INSTALL_DIR" (placeholder "dev"))
    ];
    # Folly's CMake targets inherit this definition through glog::glog, but
    # its setuptools-driven extension compilation bypasses that target.  Glog
    # 0.7 requires the definition whenever its public headers are consumed.
    env = (old.env or { }) // {
      NIX_CFLAGS_COMPILE = (old.env.NIX_CFLAGS_COMPILE or "") + " -DGLOG_USE_GLOG_EXPORT";
    };
    postPatch = (old.postPatch or "") + ''
      # bdist_wheel invokes build_ext again.  Upstream's second setuptools
      # command omitted the include/library flags supplied to the first one.
      substituteInPlace folly/python/CMakeLists.txt \
        --replace-fail \
          "    bdist_wheel" \
          '    build_ext ''${incs} ''${libs} bdist_wheel'
    '';
    doCheck = false;
  });

  fizz-python = (pkgs.fizz.override { folly = folly-python; }).overrideAttrs (old: {
    version = snapshotVersion;
    src = inputs.fizz-src;
    patches = [ ];
    doCheck = false;
  });

  wangle-python =
    (pkgs.wangle.override {
      folly = folly-python;
      fizz = fizz-python;
    }).overrideAttrs
      (old: {
        version = snapshotVersion;
        src = inputs.wangle-src;
        patches = [ ];
        doCheck = false;
      });

  mvfst-python =
    (pkgs.mvfst.override {
      folly = folly-python;
      fizz = fizz-python;
    }).overrideAttrs
      (old: {
        version = snapshotVersion;
        src = inputs.mvfst-src;
        patches = [ ];
        doCheck = false;
      });

  # FBThrift's Python runtime deliberately embeds libevent with
  # --whole-archive.  Nixpkgs' default libevent output is shared-only and does
  # not install the upstream CMake package, so provide the exact static
  # libraries and imported targets expected by FBThrift.
  libevent-static = pkgs.libevent.override { static = true; };
  libevent-static-cmake = pkgs.runCommand "libevent-static-cmake-config" { } ''
    config_dir="$out/lib/cmake/Libevent"
    mkdir -p "$config_dir"
    cat > "$config_dir/LibeventConfig.cmake" <<'EOF'
    include(CMakeFindDependencyMacro)
    find_dependency(Threads)

    add_library(libevent::core STATIC IMPORTED)
    set_target_properties(libevent::core PROPERTIES
      IMPORTED_LOCATION "${libevent-static}/lib/libevent_core.a"
      INTERFACE_INCLUDE_DIRECTORIES "${libevent-static.dev}/include"
      INTERFACE_LINK_LIBRARIES "Threads::Threads"
    )

    add_library(libevent::extra STATIC IMPORTED)
    set_target_properties(libevent::extra PROPERTIES
      IMPORTED_LOCATION "${libevent-static}/lib/libevent_extra.a"
      INTERFACE_INCLUDE_DIRECTORIES "${libevent-static.dev}/include"
      INTERFACE_LINK_LIBRARIES "libevent::core"
    )

    set(Libevent_FOUND TRUE)
    EOF
  '';

  # This output contains thrift1, the native libraries, and the wheel produced
  # by FBThrift's thrift_python=ON build.  It deliberately uses the same fbcode
  # snapshot as Folly/Fizz/Wangle/mvfst above.
  fbthrift-python =
    (pkgs.fbthrift.override {
      folly = folly-python;
      fizz = fizz-python;
      wangle = wangle-python;
      mvfst = mvfst-python;
    }).overrideAttrs
      (old: {
        pname = "fbthrift-python";
        version = snapshotVersion;
        src = inputs.fbthrift-src;
        patches = [ ./fbthrift-nix-wheel.patch ];
        postPatch = "";

        nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [
          pkgs.pkg-config
          python
          py.auditwheel
          py.cython
          py.pip
          py.setuptools
          py.wheel
        ];

        buildInputs = (old.buildInputs or [ ]) ++ [
          pkgs.boost
          pkgs.fmt
          pkgs.libaio
          libevent-static
          libevent-static-cmake
          pkgs.libiberty
          pkgs.libsodium
          pkgs.libunwind
          pkgs.snappy
          pkgs.xz
          python
        ];

        cmakeFlags =
          replaceCmakeFlag "-DBUILD_SHARED_LIBS" (replaceCmakeFlag "-Dthriftpy" (old.cmakeFlags or [ ]))
          ++ [
            (lib.cmakeBool "BUILD_SHARED_LIBS" false)
            (lib.cmakeBool "enable_tests" false)
            (lib.cmakeBool "thriftpy" false)
            (lib.cmakeBool "thrift_python" true)
          ];

        # The CMake targets receive this through glog::glog.  The setuptools
        # extension compiler runs independently and consumes glog's headers
        # directly, where glog 0.7 requires its export macro to be selected.
        env = (old.env or { }) // {
          NIX_CFLAGS_COMPILE = (old.env.NIX_CFLAGS_COMPILE or "") + " -DGLOG_USE_GLOG_EXPORT";
        };

        # FBThrift's wheel builder normally discovers getdeps prefixes by scanning
        # GETDEPS_INSTALL_DIR.  Give it a small, deterministic view of the Nix
        # dependencies instead of allowing the fallback to scan all of /nix/store.
        preConfigure = (old.preConfigure or "") + ''
          taac_getdeps_dir="$NIX_BUILD_TOP/taac-getdeps-installed"
          mkdir -p "$taac_getdeps_dir"
          ln -s ${folly-python} "$taac_getdeps_dir/folly"
          ln -s ${folly-python.dev} "$taac_getdeps_dir/folly-dev"
          ln -s ${fizz-python} "$taac_getdeps_dir/fizz"
          ln -s ${wangle-python} "$taac_getdeps_dir/wangle"
          ln -s ${mvfst-python} "$taac_getdeps_dir/mvfst"
          ln -s ${libevent-static} "$taac_getdeps_dir/libevent"
          ln -s ${pkgs.libiberty} "$taac_getdeps_dir/libiberty"
          ln -s ${pkgs.libaio} "$taac_getdeps_dir/libaio"
          ln -s ${pkgs.snappy} "$taac_getdeps_dir/snappy"
          ln -s ${pkgs.libsodium} "$taac_getdeps_dir/libsodium"
          ln -s ${pkgs.libunwind} "$taac_getdeps_dir/libunwind"
          ln -s ${pkgs.xz} "$taac_getdeps_dir/xz"
          export GETDEPS_INSTALL_DIR="$taac_getdeps_dir"
        '';

        # Ninja's install target depends on the default target and therefore
        # reruns FBThrift's always-dirty wheel command.  Install the artifacts
        # already produced by buildPhase directly through CMake instead.
        installPhase = ''
          runHook preInstall
          cmake --install .
          runHook postInstall
        '';

        doCheck = false;
      });

  fbthrift-python-runtime = py.buildPythonPackage {
    pname = "fbthrift-python-runtime";
    version = snapshotVersion;
    format = "other";
    dontUnpack = true;

    nativeBuildInputs = [
      pkgs.autoPatchelfHook
      py.pip
    ];
    # The upstream manylinux wheel normally bundles these libraries with
    # auditwheel.  This Nix-native wheel keeps them in the store instead, so
    # autoPatchelf needs the matching library outputs while fixing its RPATHs.
    buildInputs = [
      fbthrift-python.lib
      folly-python
      pkgs.gflags
      pkgs.glog
      pkgs.libaio
      pkgs.libsodium
      pkgs.libunwind
      pkgs.openssl
      pkgs.snappy
      pkgs.xz
      python
    ];
    propagatedBuildInputs = [ fbthrift-python ];

    installPhase = ''
      runHook preInstall
      wheel_path=$(find ${fbthrift-python}/share/thrift/wheels -name 'thrift-*.whl' -print -quit)
      if [[ -z "$wheel_path" ]]; then
        echo "FBThrift did not produce a thrift Python wheel" >&2
        exit 1
      fi
      ${python.interpreter} -m pip install \
        --no-index --no-deps --prefix "$out" "$wheel_path"
      runHook postInstall
    '';

    pythonImportsCheck = [
      "folly.iobuf"
      "thrift.py3.types"
      "thrift.python.types"
    ];
  };

  pythonPackages = import ./python-packages.nix {
    inherit lib py;
  };

  # A handful of upstream tests still use Meta's `later.unittest` migration
  # namespace.  Its public surface in this repository is only TestCase, so a
  # development-only namespace shim keeps those tests runnable in OSS without
  # pretending the unavailable internal package is a runtime dependency.
  later-unittest-shim = py.buildPythonPackage {
    pname = "later-unittest-shim";
    version = "1.0.0";
    format = "other";
    dontUnpack = true;
    installPhase = ''
      runHook preInstall
      package_dir="$out/${python.sitePackages}/later"
      mkdir -p "$package_dir"
      touch "$package_dir/__init__.py"
      cat > "$package_dir/unittest.py" <<'PY'
      from unittest import *
      PY
      runHook postInstall
    '';
    pythonImportsCheck = [ "later.unittest" ];
  };

  fboss-thrift-defs = pkgs.runCommand "fboss-thrift-defs-a61b92c" { } ''
    mkdir -p "$out"
    cp -R ${inputs.fboss-src}/. "$out/"
  '';

  thrift-bindings = py.buildPythonPackage {
    pname = "taac-thrift-bindings";
    version = "1.0.0";
    format = "other";
    inherit src;

    nativeBuildInputs = [ fbthrift-python ];
    propagatedBuildInputs = [ fbthrift-python-runtime ];

    dontConfigure = true;
    buildPhase = ''
      runHook preBuild
      bash ${./generate-thrift-bindings.sh} \
        ${lib.escapeShellArg "${fbthrift-python}/bin/thrift1"} \
        ${lib.escapeShellArg "${inputs.fbthrift-src}"} \
        ${lib.escapeShellArg "${fboss-thrift-defs}"} \
        "$PWD" \
        "$PWD/nix-thrift-output"
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      mkdir -p "$out/${python.sitePackages}"
      cp -R nix-thrift-output/gen-python/. "$out/${python.sitePackages}/"
      runHook postInstall
    '';

    pythonImportsCheck = [
      "facebook.network.Address.thrift_types"
      "ixia.ixia.thrift_types"
      "neteng.fboss.bgp.client.canonical_rib_py3"
      "neteng.fboss.ctrl.thrift_types"
      "taac.test_as_a_config.thrift_types"
    ];
  };

  runtimePythonPackages = with py; [
    asyncssh
    cachetools
    pexpect
    pydantic
    pyre-extensions
    tabulate
    pythonPackages.ixnetwork-restpy
    pythonPackages.paramiko
    pythonPackages.snappi
    thrift-bindings
  ];

  taac = py.buildPythonPackage {
    pname = "dne-taac";
    version = "1.0.0";
    format = "other";
    inherit src;

    env.TAAC_OSS = "1";

    propagatedBuildInputs = runtimePythonPackages;
    dontConfigure = true;
    dontBuild = true;
    installPhase = ''
      runHook preInstall
      mkdir -p "$out/${python.sitePackages}" "$out/share/dne-taac"
      cp -R taac "$out/${python.sitePackages}/"
      cp -R examples "$out/share/dne-taac/"
      runHook postInstall
    '';

    pythonImportsCheck = [
      "taac.libs.taac_runner"
      "taac.runner.oss_entry_point"
    ];
  };

  python-environment = python.withPackages (_: [ taac ]);

  app = pkgs.writeShellApplication {
    name = "taac";
    runtimeInputs = [ python-environment ];
    text = ''
      export TAAC_OSS="''${TAAC_OSS:-1}"
      if [[ "$#" -eq 0 ]]; then
        set -- --help
      fi
      exec python -m taac.runner.oss_entry_point "$@"
    '';
  };

  checks = {
    imports =
      pkgs.runCommand "taac-nix-import-check"
        {
          nativeBuildInputs = [ python-environment ];
        }
        ''
          export TAAC_OSS=1
          python -c 'from neteng.fboss.ctrl.thrift_types import NdpEntryThrift; from taac.test_as_a_config.thrift_types import TestConfig'
          touch "$out"
        '';

    smoke =
      pkgs.runCommand "taac-nix-dry-run-smoke"
        {
          nativeBuildInputs = [ python-environment ];
        }
        ''
          export TAAC_OSS=1
          python -m taac.runner.oss_entry_point \
            --test-configs ${src}/examples/live_smoke_config.py \
            --dut fakedut123 \
            --device-info-csv ${src}/examples/topology/sample_device_info.csv \
            --circuit-info-csv ${src}/examples/topology/sample_circuit_info.csv \
            --dry-run
          touch "$out"
        '';

    unit =
      pkgs.runCommand "taac-nix-runner-unit-tests"
        {
          nativeBuildInputs = [
            python-environment
            py.pytest
          ];
        }
        ''
          export TAAC_OSS=1
          cp -R ${src} source
          chmod -R u+w source
          cd source
          pytest -q -p no:cacheprovider taac/runner/tests
          touch "$out"
        '';
  };

  devShell = pkgs.mkShell {
    packages = [
      app
      fbthrift-python
      python-environment
      py.pytest
      later-unittest-shim
    ];
    shellHook = ''
      export TAAC_OSS="''${TAAC_OSS:-1}"
      export PYTHONPATH="$PWD''${PYTHONPATH:+:$PYTHONPATH}"
      echo "DNE-TaaC development shell: use 'taac', 'python', or 'pytest'."
    '';
  };
in
{
  inherit
    app
    checks
    devShell
    fboss-thrift-defs
    fbthrift-python
    fbthrift-python-runtime
    folly-python
    later-unittest-shim
    python-environment
    taac
    thrift-bindings
    ;
}
