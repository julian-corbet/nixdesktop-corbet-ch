# Throwaway eval smoke test -- NOT part of the module surface. Confirms modules/nixos-backend.nix
# evaluates alongside the policy profile and that the DEFAULT `nixdesktop.want` (the same defaults
# eval-smoke-test.nix checks at the policy layer) actually resolves to real nixpkgs packages, not
# just role names -- plus that a compositor with no nixpkgs package can be supplied by the
# consumer via `extraCompositors` without editing this repo. Safe to delete; nothing imports this
# file.
#
# Uses a bare `lib.evalModules` with two STUB options (`environment.systemPackages`,
# `xdg.portal.{enable,extraPortals}`) rather than a real `nixosSystem`, for the same reason
# eval-smoke-test.nix uses evalModules over nixosSystem: cheap and self-contained. The stubs exist
# only because those two options are normally declared by nixpkgs' own NixOS modules (system-path,
# xdg), which a bare evalModules does not pull in -- assigning to an undeclared option path is a
# hard error ("It seems as if you're trying to declare an option by placing it into `config'
# rather than `options'!"), confirmed while writing this test. A real nixosSystem needs neither
# stub; both options already exist there.
#
#   nix-instantiate --eval --strict experiments/eval-nixos-backend.nix -A ok
{ nixpkgs ? <nixpkgs> }:
let
  pkgs = import nixpkgs { };
  lib = pkgs.lib;
  roles = import ../lib/nixos-roles.nix { inherit lib pkgs; };

  stubOptions = {
    options.environment.systemPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
    };
    options.xdg.portal = {
      enable = lib.mkOption { type = lib.types.bool; default = false; };
      extraPortals = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [ ];
      };
    };
  };

  eval = lib.evalModules {
    specialArgs = { inherit pkgs; };
    modules = [
      ../profiles/desktop.nix
      ../modules/nixos-backend.nix
      stubOptions
      {
        # `compositor` has no default at the policy layer -- this test states one, same as any
        # real consumer must.
        nixdesktop.desktop.enable = true;
        nixdesktop.desktop.compositor = "niri";
        nixdesktop.nixosBackend.enable = true;
      }
    ];
  };

  pnamesOf = pkgList: lib.sort (a: b: a < b) (map (p: p.pname or p.name) pkgList);

  installedPnames = pnamesOf eval.config.environment.systemPackages;

  # Every default role from profiles/desktop.nix, resolved. bar=waybar, notifications=mako,
  # fileManager=thunar (+ its floor: tumbler, gvfs, thunar-volman), polkitAgent=soteria,
  # keyring=gnome-keyring, launcher=fuzzel, terminal=foot, osd=null (nothing),
  # screenshots/xwayland/clipboardHistory/idleAndLock=true, compositor=niri (this test's own
  # explicit pick, + brightnessctl, playerctl). portals=true does NOT appear here -- it is not a
  # systemPackages role, see below.
  expectedDefaultPnames = pnamesOf [
    pkgs.waybar
    pkgs.mako
    pkgs.thunar
    pkgs.tumbler
    pkgs.gvfs
    pkgs.thunar-volman
    pkgs.soteria
    pkgs.gnome-keyring
    pkgs.fuzzel
    pkgs.foot
    pkgs.niri
    pkgs.brightnessctl
    pkgs.playerctl
    pkgs.xwayland-satellite
    pkgs.grim
    pkgs.slurp
    pkgs.cliphist
    pkgs.wl-clipboard
    pkgs.swayidle
    pkgs.swaylock
  ];
in
rec {
  inherit installedPnames expectedDefaultPnames;

  # The resolved package set for the profile's own defaults matches exactly -- no missing role,
  # nothing extra sneaking in.
  defaultsResolve = installedPnames == expectedDefaultPnames;

  # The polkit agent's command is built from the package's own store path, never a hardcoded
  # `/usr/lib/...` guess copied from the Arch table -- interpolating a derivation always yields
  # its store path, so equality with the expected string here doubles as proof of that, and the
  # negative check confirms no Arch-style path snuck in some other way.
  polkitCommandIsStorePath =
    roles.polkitAgents.soteria.command
    == "${pkgs.soteria}/bin/soteria"
    && !lib.hasPrefix "/usr/lib/" roles.polkitAgents.soteria.command;

  # `portals = true` (the profile default) is handled explicitly through the real xdg.portal
  # option, not silently dropped and not smuggled into systemPackages.
  portalsWiredThroughXdgPortal =
    eval.config.xdg.portal.enable == true
    && pnamesOf eval.config.xdg.portal.extraPortals == pnamesOf [
      pkgs.xdg-desktop-portal-gnome
      pkgs.xdg-desktop-portal-gtk
    ];

  # A disabled backend must install nothing, same no-op contract as nixarch's: enabling this
  # module without a desktop profile present is harmless, not an evaluation error.
  disabledBackendInstallsNothing =
    let
      off = lib.evalModules {
        specialArgs = { inherit pkgs; };
        modules = [
          ../profiles/desktop.nix
          ../modules/nixos-backend.nix
          stubOptions
          {
            nixdesktop.desktop.enable = true;
            nixdesktop.desktop.compositor = "niri";
            nixdesktop.nixosBackend.enable = false;
          }
        ];
      };
    in
    off.config.environment.systemPackages == [ ] && off.config.xdg.portal.enable == false;

  # A compositor with no nixpkgs package (scroll, in reality) resolves via `extraCompositors`,
  # threaded from the backend's own option into lib/nixos-roles.nix's `compositors` table, with
  # no edit to this repo required -- `pkgs.hello` stands in for "some package a sibling
  # compositor-module flake supplies", since the point under test is the plumbing, not any real
  # compositor's derivation.
  extraCompositorResolves =
    let
      extraEval = lib.evalModules {
        specialArgs = { inherit pkgs; };
        modules = [
          ../profiles/desktop.nix
          ../modules/nixos-backend.nix
          stubOptions
          {
            nixdesktop.desktop.enable = true;
            nixdesktop.desktop.compositor = "fakecomp";
            nixdesktop.nixosBackend.enable = true;
            nixdesktop.nixosBackend.extraCompositors.fakecomp = [ pkgs.hello ];
          }
        ];
      };
    in
    builtins.elem "hello" (pnamesOf extraEval.config.environment.systemPackages)
    # niri itself must still resolve out of the box, unaffected by another compositor's entry.
    && (import ../lib/nixos-roles.nix {
      inherit lib pkgs;
      extraCompositors = { fakecomp = [ pkgs.hello ]; };
    }).compositors.niri == roles.compositors.niri;

  ok =
    defaultsResolve
    && polkitCommandIsStorePath
    && portalsWiredThroughXdgPortal
    && disabledBackendInstallsNothing
    && extraCompositorResolves;
}
