# home/nwg-bar.nix — declarative nwg-bar (power menu) config, sibling to home/waybar.nix.
# `buttons` is nwg-bar's own JSON array of {label,exec,icon} objects; `style` is raw CSS.
{ lib, config, ... }:
let
  cfg = config.nixdesktop.nwgBar;
in
{
  options.nixdesktop.nwgBar = {
    enable = lib.mkEnableOption "declarative nwg-bar config (~/.config/nwg-bar/{bar.json,style.css})";

    buttons = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      default = [ ];
      example = [
        { label = "Lock"; exec = "swaylock -f"; icon = "/usr/share/nwg-bar/images/system-lock-screen.svg"; }
      ];
      description = "List of {label, exec, icon} button definitions, serialized to bar.json verbatim.";
    };

    style = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Raw CSS for ~/.config/nwg-bar/style.css.";
    };
  };

  config = lib.mkIf cfg.enable {
    xdg.configFile."nwg-bar/bar.json".text = builtins.toJSON cfg.buttons;
    xdg.configFile."nwg-bar/style.css".text = cfg.style;
  };
}
