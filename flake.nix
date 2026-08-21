{
  description = "DNE-TaaC with its FBThrift and Python dependency stack";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Keep the native fbcode family on the same snapshot recorded in
    # getdeps/FBCODE_SNAPSHOT and getdeps/manifests/*.  These repositories
    # make coordinated changes and cannot safely be updated independently.
    folly-src = {
      url = "github:facebook/folly/3a38b74989093f7c61932212bc494376011f086c";
      flake = false;
    };
    fizz-src = {
      url = "github:facebookincubator/fizz/ddb1b60503999c763fd31b18eb0d95faa62c6e3b";
      flake = false;
    };
    wangle-src = {
      url = "github:facebook/wangle/c0ab72eacf113dcb3cf57380a25ef554d4b8f8f6";
      flake = false;
    };
    mvfst-src = {
      url = "github:facebook/mvfst/60f627255356ae51c8bc1bbd7f3c1e1a61480bcb";
      flake = false;
    };
    fbthrift-src = {
      url = "github:facebook/fbthrift/0215ea4e57004131f0eb7e092770f95659a15136";
      flake = false;
    };
    fboss-src = {
      url = "github:facebook/fboss/a61b92c23e6e8a97db2ff58006d34f0224434da6";
      flake = false;
    };
  };

  outputs =
    inputs@{ self, nixpkgs, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      projectSource = builtins.path {
        path = self;
        name = "dne-taac-source";
        filter =
          path: _type:
          let
            name = builtins.baseNameOf path;
          in
          name != ".git"
          && name != ".direnv"
          && name != ".pytest_cache"
          && name != "__pycache__"
          && name != "result"
          && !(nixpkgs.lib.hasPrefix "result-" name)
          && !(nixpkgs.lib.hasSuffix ".pyc" name);
      };
      mkTaac =
        system:
        import ./nix {
          pkgs = import nixpkgs { inherit system; };
          src = projectSource;
          inherit inputs;
        };
    in
    {
      packages = forAllSystems (
        system:
        let
          taac = mkTaac system;
        in
        {
          default = taac.app;
          inherit (taac)
            app
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
      );

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.app}/bin/taac";
          meta.description = "Run the DNE-TaaC OSS test runner";
        };
        taac = self.apps.${system}.default;
      });

      devShells = forAllSystems (system: {
        default = (mkTaac system).devShell;
      });

      checks = forAllSystems (system: (mkTaac system).checks);
    };
}
