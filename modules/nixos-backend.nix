# modules/nixos-backend.nix — the NixOS platform backend for nixdesktop.
#
# nixdesktop declares WHAT a desktop session needs (roles: a file manager, a polkit agent, a bar).
# This module answers WITH WHAT, for NixOS: it reads the read-only `nixdesktop.want` attrset that
# nixdesktop's own profile publishes, resolves every role through lib/nixos-roles.nix, and feeds
# the result straight into `environment.systemPackages` — there is no NixOS-side equivalent of
# nixarch's `nixarch.packages.pacman` reconciler to hand off to, so this module IS the last step.
#
# WHY THIS BACKEND LIVES IN nixdesktop ITSELF, UNLIKE nixarch's. nixarch ships the Arch/CachyOS
# backend as a module in *its own* repo, not here, because resolving a role into a pacman package
# name requires knowing Arch's package repos — knowledge nixdesktop otherwise has no reason to
# carry. A NixOS backend needs no such foreign knowledge: nixpkgs is already nixdesktop's only
# flake input (see flake.nix's header), so this module and lib/nixos-roles.nix are a data table
# over an input this project already has, not a new dependency. That asymmetry is why the Arch
# backend lives in nixarch and this one lives here — say so explicitly, because a reader who has
# seen the Arch split would otherwise reasonably expect this one to live in a hypothetical
# "nixnixos" sibling too, and there is deliberately no such thing.
#
# IMPORT ORDER: this module reads an option that nixdesktop's own profile declares, so both must be
# in the same evaluation. Import `nixdesktop.nixosModules.desktop` alongside it.
{ lib, config, pkgs, ... }:
let
  cfg = config.nixdesktop.nixosBackend;
  roles = import ../lib/nixos-roles.nix { inherit lib pkgs; extraCompositors = cfg.extraCompositors; };
  want = config.nixdesktop.want or { };
  resolved = roles.packagesFor want;
in
{
  options.nixdesktop.nixosBackend = {
    enable = lib.mkEnableOption ''
      resolving nixdesktop's declared roles into NixOS packages.

      Requires nixdesktop's own profile in the same evaluation (it declares the
      `nixdesktop.want` option this reads)
    '';

    extraPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = ''
        Packages appended verbatim, for host-specific desktop needs that are not a nixdesktop
        role — a Bluetooth applet, a GTK theme, an audio mixer. Prefer nixdesktop's own
        `extraComponents` when the thing is genuinely part of the desktop policy (it stays a role
        name, resolved the same way as everything else); use this when it is specific to one host
        or when the package has no sensible top-level nixpkgs attribute name to hand to
        `extraComponents`.
      '';
    };

    extraCompositors = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf lib.types.package);
      default = { };
      example = lib.literalExpression ''{ scroll = [ nixscroll.packages.''${pkgs.system}.scroll ]; }'';
      description = ''
        Additional entries for `lib/nixos-roles.nix`'s `compositors` table, keyed by the same
        string you set as `nixdesktop.desktop.compositor`. Needed for any compositor with no
        nixpkgs package — scroll, for instance, has none, so a consumer supplies their own
        derivation here (e.g. from nixscroll's own `packages` flake output) instead of editing
        this repo. `"niri"` already resolves out of the box and needs no entry here, though an
        entry for it here would still take precedence over the built-in one if you supplied one.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # A no-op when nixdesktop's profile is absent or disabled: `want` is then `{}` and
    # packagesFor yields nothing, so enabling this module without a desktop is harmless rather
    # than an evaluation error — same contract as nixarch's backend.
    environment.systemPackages = resolved ++ cfg.extraPackages;

    # `portals` has no entry in lib/nixos-roles.nix's `capabilities` table (see that file's
    # comment) because a portal backend installed via `environment.systemPackages` alone is not a
    # working portal — it needs `xdg.portal.enable` and to be listed in `xdg.portal.extraPortals`
    # to actually be registered. Wire it through the real option instead of pretending the package
    # list was ever going to be enough.
    xdg.portal = lib.mkIf (want.portals or false) {
      enable = true;
      extraPortals = roles.portalPackages;
    };
  };
}
