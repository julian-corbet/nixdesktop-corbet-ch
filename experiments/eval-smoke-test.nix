# Throwaway eval smoke test -- NOT part of the module surface. Confirms the policy profile
# evaluates and that `nixdesktop.want` actually resolves to the role set a backend would consume,
# before any of it is published. Safe to delete; nothing imports this file.
#
# Uses lib.evalModules rather than nixosSystem on purpose: the profile is pure options plus one
# computed attrset and touches nothing NixOS- or system-manager-specific, so a bare module
# evaluation is both sufficient and far cheaper than instantiating a whole system.
#
#   nix-instantiate --eval --strict experiments/eval-smoke-test.nix -A want
{ nixpkgs ? <nixpkgs> }:
let
  lib = (import nixpkgs { }).lib;

  eval = lib.evalModules {
    modules = [
      ../profiles/niri-desktop.nix
      {
        nixdesktop.niriDesktop = {
          enable = true;
          # Override two defaults so the test would catch a profile that silently ignores input.
          fileManager = "nautilus";
          osd = "swayosd";
          extraComponents = [ "blueman" ];
        };
      }
    ];
  };

  want = eval.config.nixdesktop.want;
in
{
  inherit want;

  # Defaults survive when not overridden.
  defaultsHold =
    want.bar == "waybar"
    && want.polkitAgent == "mate-polkit"
    && want.keyring == "gnome-keyring"
    && want.terminal == "foot";

  # Consumer overrides actually reach `want` -- the whole contract with a backend.
  overridesApply =
    want.fileManager == "nautilus"
    && want.osd == "swayosd"
    && want.extraComponents == [ "blueman" ];

  # Disabled profile must publish nothing, so a backend can key off an empty attrset.
  disabledIsEmpty =
    let
      off = lib.evalModules {
        modules = [ ../profiles/niri-desktop.nix { nixdesktop.niriDesktop.enable = false; } ];
      };
    in
    off.config.nixdesktop.want == { };
}
