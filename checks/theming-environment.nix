# checks/theming-environment.nix — proves modules/theming-environment.nix (the system-manager half
# of the QT_QPA_PLATFORMTHEME fix; see that file's own header for the full, measured account of why
# it cannot share `environment.sessionVariables` with the NixOS half in modules/nixos-backend.nix)
# against a REAL `system-manager.lib.makeSystemConfig` evaluation, not a stand-in.
#
# WHY A REAL `makeSystemConfig` AND NOT `lib.evalModules` + A STUB, same reasoning as
# checks/launcher.nix's own third/fourth layers and checks/file-manager.nix's header: the entire
# claim this module makes is that `environment.etc.environment` is a real, correctly-shaped option
# on system-manager's OWN vendored module tree (`environment.etc`'s submodule, with its
# `replaceExisting` default) -- a stub declaring `environment.etc` as `attrsOf anything` would
# accept this module's write and prove nothing about whether it actually type-checks against the
# real thing. `nix flake check` on its own only confirms `systemManagerModules.themingEnvironment`
# IS a module.
{ pkgs, systemManagerLib, lib ? pkgs.lib }:
let
  support = import ./support.nix { inherit pkgs lib; };
  inherit (support) report;

  configFor = wantTheming: systemManagerLib.makeSystemConfig {
    modules = [
      ../profiles/desktop.nix
      ../modules/theming-environment.nix
      {
        nixdesktop.desktop = {
          enable = true;
          compositor = "scroll"; # irrelevant to this module; mandatory the moment the profile is on
          theming = wantTheming;
        };
        nixpkgs.hostPlatform = pkgs.system;
      }
    ];
  };

  themed = (configFor true).config;
  untheme = (configFor false).config;
in
report "theming-environment" {
  "theming on writes /etc/environment naming qt6ct" =
    themed.environment.etc.environment.text == "QT_QPA_PLATFORMTHEME=qt6ct\n";

  # The load-bearing line -- see modules/theming-environment.nix's own header for why an unset
  # `replaceExisting` here is not a smaller version of this fix, it's a build-time refusal on any
  # host where Arch's own pambase packaging has already put a real file at this path.
  "...and states replaceExisting = true, not the option's own false default" =
    themed.environment.etc.environment.replaceExisting == true;

  "theming off writes no /etc/environment entry at all -- nothing installed for it to name" =
    !(untheme.environment.etc ? environment);

  # A disabled profile publishes an empty `nixdesktop.want` (see profiles/desktop.nix) -- proves
  # this module's own `or false` fallback treats "profile absent" identically to "theming off"
  # rather than throwing on a missing attribute.
  "the profile disabled entirely is indistinguishable from theming off, not a missing-attr error" =
    !((systemManagerLib.makeSystemConfig {
      modules = [
        ../profiles/desktop.nix
        ../modules/theming-environment.nix
        {
          # `compositor` still stated even though the profile is disabled -- see
          # checks/file-manager.nix's own `disabled` fixture for the same choice: a consumer's
          # real config would still be carrying it, disabled or not.
          nixdesktop.desktop = { enable = false; compositor = "scroll"; };
          nixpkgs.hostPlatform = pkgs.system;
        }
      ];
    }).config.environment.etc ? environment);
}
