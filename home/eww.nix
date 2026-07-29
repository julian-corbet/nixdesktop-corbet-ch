# home/eww.nix — declarative eww (ElKowar's Wacky Widgets) bar config, sibling to home/waybar.nix.
# LEAN BY DESIGN: eww's config isn't structured data like waybar's JSON, it's a full DSL (yuck for
# widgets/windows, SCSS for styling) plus arbitrary helper scripts referenced from that DSL --
# so, like a compositor module's own raw-text escape hatches (e.g. nixniri's
# `extraTopLevel`/`output`), this module takes raw text rather than trying to model yuck's
# grammar in Nix.
{ lib, config, ... }:
let
  cfg = config.nixdesktop.eww;

  scriptFiles = lib.mapAttrs'
    (name: content: lib.nameValuePair "eww/scripts/${name}" {
      text = content;
      executable = true;
    })
    cfg.scripts;
in
{
  options.nixdesktop.eww = {
    enable = lib.mkEnableOption "declarative eww config (~/.config/eww)";

    yuck = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Raw eww.yuck content (widget + window definitions).";
    };

    scss = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Raw eww.scss content (styling).";
    };

    scripts = lib.mkOption {
      type = lib.types.attrsOf lib.types.lines;
      default = { };
      example = { "getvol.sh" = "#!/usr/bin/env bash\n..."; };
      description = ''
        Helper scripts written executable to ~/.config/eww/scripts/<name>, referenced from
        yuck via deflisten/defpoll/onclick/onscroll etc.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    xdg.configFile = {
      "eww/eww.yuck".text = cfg.yuck;
      "eww/eww.scss".text = cfg.scss;
    } // scriptFiles;
  };
}
