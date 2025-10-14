{
  pkgs ?
    import
      # nixos-unstable (neovim@0.11.4):
      (fetchTarball {
        url = "https://github.com/nixos/nixpkgs/archive/0b4defa2584313f3b781240b29d61f6f9f7e0df3.tar.gz";
        sha256 = "0p3rrd8wwlk0iwgzm7frkw1k98ywrh0avi7fqjjk87i68n3inxrs";
      })
      { },
}:
pkgs.mkShell {
  packages = [
    pkgs.git
    pkgs.gnumake
    pkgs.emmylua-check
    pkgs.lua51Packages.busted
    pkgs.lua51Packages.luacov
    pkgs.lua51Packages.luarocks
    pkgs.neovim
    pkgs.stylua
    pkgs.watchexec
  ];
}
