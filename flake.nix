{
  description = "A writable, snapshotting overlay on top of compressed archives";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      pkgsFor = system: nixpkgs.legacyPackages.${system};

      dependencies = pkgs: with pkgs; [
        ratarmount
        util-linux
        fuse3
        fuse-overlayfs
        rsync
        gnutar
        zstd
        coreutils
      ];
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = pkgsFor system;
        in
        {
          ratarfs = pkgs.writeShellApplication {
            name = "ratarfs";
            runtimeInputs = dependencies pkgs;
            text = builtins.readFile ./ratarafs.sh;
          };
          default = self.packages.${system}.ratarfs;
        });

      apps = forAllSystems (system: {
        ratarfs = {
          type = "app";
          program = "${self.packages.${system}.ratarfs}/bin/ratarfs";
        };
        default = self.apps.${system}.ratarfs;
      });

      devShells = forAllSystems (system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.mkShell {
            packages = [ pkgs.shellcheck pkgs.bubblewrap ] ++ (dependencies pkgs);
          };
        });
    };
}
