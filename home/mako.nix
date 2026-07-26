# home/mako.nix — declarative mako (notification daemon) config, sibling to home/niri.nix and
# home/waybar.nix. LEAN BY DESIGN: mechanism only, no default theme/settings -- mako's config
# format is flat `key=value` lines (or a bare `key` for boolean flags), so `settings` is an
# attrset where a null value renders as a bare flag and a string value renders as `key=value`.
{ lib, config, ... }:
let
  cfg = config.nixdesktop.mako;

  renderLine = key: value:
    if value == null then key else "${key}=${toString value}";
in
{
  options.nixdesktop.mako = {
    enable = lib.mkEnableOption "declarative mako config (~/.config/mako/config)";

    settings = lib.mkOption {
      type = lib.types.attrsOf (lib.types.nullOr (lib.types.oneOf [ lib.types.str lib.types.int lib.types.bool ]));
      default = { };
      example = {
        max-visible = 10;
        layer = "top";
        anchor = "top-right";
      };
      description = ''
        mako config (~/.config/mako/config) as an attrset. A null value renders as a bare flag
        line (e.g. for future boolean-flag-style keys); any other value renders as `key=value`.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    xdg.configFile."mako/config".text =
      lib.concatStringsSep "\n" (lib.mapAttrsToList renderLine cfg.settings) + "\n";
  };
}
