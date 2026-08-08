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

  # `null` both when no file manager was asked for AND when the whole profile is disabled (`want`
  # is then `{}`), which is what keeps every block below a no-op in the disabled case without a
  # second guard.
  fileManager = want.fileManager or null;
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

    # THE SAME GAP AS `portals`, one role over — see lib/nixos-roles.nix's `fileManagers` comment
    # for the full account. A file manager needs gvfs to browse or mount ANYTHING, and gvfs as a
    # package is inert: `GIO_EXTRA_MODULES` stays unset (so no uri scheme resolves at all — not
    # smb://, not mtp://, not even trash://), `programs.fuse.enable` and `services.udisks2.enable`
    # stay off (so nothing mounts, including a plain USB stick), and the libmtp udev rules a phone
    # never arrive. All of that is `services.gvfs.enable` and nothing else, so it is wired here
    # rather than smuggled into a package list.
    #
    # Keyed on "a file manager was named at all", not on which one: every entry in that table wants
    # gvfs, and so does any free-form name resolved through the fallthrough.
    services.gvfs.enable = lib.mkIf (fileManager != null) true;

    # Thunar specifically. `programs.thunar.enable` is what builds the wrapper that sets
    # `THUNARX_DIRS` — without it the `plugins` handed over here would be `.so` files nothing ever
    # loads — what rewrites thunar's systemd user unit and its `org.xfce.*` D-Bus activation files
    # to point at that wrapper rather than at the plugin-less binary, and what turns on
    # `programs.xfconf.enable`, without which Thunar persists no settings at all.
    programs.thunar = lib.mkIf (fileManager == "thunar") {
      enable = true;
      plugins = lib.optionals (want.fileManagerExtras or false) roles.thunarPlugins;
    };

    # The thumbnailer, without which Thunar shows a generic icon for every image, video and PDF.
    # Unlike the two options above, this one is nearly a formality: all it does is add the package
    # and a D-Bus service directory that the system path already is, so `pkgs.tumbler` in a package
    # list would very nearly work. Nearly is the point — the real option is where the answer lives
    # if that ever stops being true, and it costs nothing to use it.
    #
    # ffmpegthumbnailer is deliberately NOT added alongside: `pkgs.tumbler` takes it as a buildInput
    # and ships `tumbler-ffmpeg-thumbnailer.so` already, so naming it here would install nothing but
    # the standalone CLI. On Arch it IS a separate install (an optdepend), which is why the two
    # backends legitimately differ on this one.
    services.tumbler.enable = lib.mkIf (fileManager == "thunar") true;

    # THE SAME GAP AS `portals`/`services.gvfs` ABOVE, one role over. `lib/nixos-roles.nix`'s
    # `inputRemappers` table puts `pkgs.keyd` into the package list for its client binaries, and
    # that is deliberately only half the answer: the daemon, the `keyd` group and `/etc/keyd`
    # itself all come from this option and nothing else — nixpkgs' `services.keyd` does not even
    # add the package to `environment.systemPackages`, so neither half is redundant with the other.
    # Installing the package alone would be the exact `pkgs.gvfs`-without-`services.gvfs.enable`
    # trap: a remapping daemon that is present, looks configured and never runs.
    #
    # Keyed on the role being filled at all rather than on the implementation name, matching
    # `services.gvfs.enable` above — `input` is a closed enum with one member today, and a second
    # remapper would want its own wiring here rather than silently inheriting keyd's.
    services.keyd.enable = lib.mkIf ((want.input or null) == "keyd") true;

    # THE SAME GAP AS `portals`/`programs.thunar` ABOVE, one role over: `roles.theming` (see
    # lib/nixos-roles.nix) puts `qt6Packages.qt6ct` — a Qt platform-theme CONFIGURATOR — into
    # `environment.systemPackages`, and a configurator nothing points at configures nothing. Qt
    # only loads a platform theme plugin that `QT_QPA_PLATFORMTHEME` names; there is no default,
    # no auto-detection, and no bare Wayland session sets it on its own. Installing qt6ct without
    # this is exactly the `pkgs.gvfs`-without-`services.gvfs.enable` trap this whole file exists
    # to close for every other role — a package the desktop never actually asked anything to use.
    #
    # `environment.sessionVariables`, not `environment.variables`: the doc on that option states
    # the reason directly — these are "set by PAM early in the login process", which is what
    # reaches a session started through `PAMName=` (nixdesktop.launcher's seated unit shape, the
    # one every host that turns `theming` on actually runs), not merely a login shell's `/etc/
    # profile`. `environment.variables` alone would style a terminal-launched Qt app and leave
    # everything the compositor itself spawns unstyled — the one class of app this role is for.
    environment.sessionVariables = lib.mkIf (want.theming or false) {
      QT_QPA_PLATFORMTHEME = "qt6ct";
    };
  };
}
