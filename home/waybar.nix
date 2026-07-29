# home/waybar.nix — declarative waybar config (home-manager), sibling to the other home/*.nix
# modules in this repo. Compositor-neutral: waybar itself doesn't care which compositor is
# feeding it, so nothing here names one. (The "niri/workspaces" module name that shows up in the
# examples below is only an example -- waybar ships a `<compositor>/workspaces` module per
# supported compositor, and which one a consumer wires up is entirely their own `settings`/
# `modules` values, never a default this file picks for them.)
#
# LEAN BY DESIGN, same doctrine as every other home/*.nix module here: this module owns the
# mechanism (JSON/CSS generation, file placement), not a specific theme or module list.
# `settings`/`modules` accept arbitrary attrsets (waybar has dozens of module types with
# different shapes -- a fully-typed schema for all of them isn't worth it), and `style` is raw
# CSS text. A consumer's actual bar layout, module choices, and color scheme belong in their own
# config layer, not this file.
{ lib, config, ... }:
let
  cfg = config.nixdesktop.waybar;
in
{
  options.nixdesktop.waybar = {
    enable = lib.mkEnableOption "declarative waybar config (~/.config/waybar/{config,modules.json,style.css})";

    settings = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      example = {
        layer = "top";
        modules-left = [ "niri/workspaces" ];
        modules-right = [ "tray" "clock" ];
      };
      description = ''
        Top-level waybar config (~/.config/waybar/config), as an attrset -- serialized to JSON
        verbatim. This module always injects `include = [ "~/.config/waybar/modules.json" ]`
        alongside whatever's set here.
      '';
    };

    modules = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      example = {
        "niri/workspaces" = { on-click = "activate"; };
        "tray" = {
          icon-size = 21;
          spacing = 10;
        };
      };
      description = ''
        Module definitions (~/.config/waybar/modules.json), as an attrset -- serialized to JSON
        verbatim. Keys are waybar module names (e.g. "tray", "custom/exit").
      '';
    };

    style = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Raw CSS for ~/.config/waybar/style.css.";
    };
  };

  config = lib.mkIf cfg.enable {
    xdg.configFile."waybar/config".text = builtins.toJSON (
      cfg.settings // { include = [ "~/.config/waybar/modules.json" ]; }
    );
    xdg.configFile."waybar/modules.json".text = builtins.toJSON cfg.modules;
    xdg.configFile."waybar/style.css".text = cfg.style;
  };
}
