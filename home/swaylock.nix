# home/swaylock.nix — declarative swaylock (screen locker) config, sibling to home/mako.nix.
# Same attrset-with-nullable-values mechanism: swaylock's config mixes bare boolean flags
# (e.g. `indicator`, `clock`) with `key=value` lines, so null renders as a bare flag.
{ lib, config, ... }:
let
  cfg = config.nixdesktop.swaylock;

  renderLine = key: value:
    if value == null then key else "${key}=${toString value}";
in
{
  options.nixdesktop.swaylock = {
    enable = lib.mkEnableOption "declarative swaylock config (~/.config/swaylock/config)";

    settings = lib.mkOption {
      type = lib.types.attrsOf (lib.types.nullOr (lib.types.oneOf [ lib.types.str lib.types.int lib.types.bool ]));
      default = { };
      example = {
        indicator = null;
        clock = null;
        "ring-color" = "4C566A";
      };
      description = ''
        swaylock config (~/.config/swaylock/config) as an attrset. A null value renders as a
        bare flag line (e.g. `indicator`); any other value renders as `key=value`.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    xdg.configFile."swaylock/config".text =
      lib.concatStringsSep "\n" (lib.mapAttrsToList renderLine cfg.settings) + "\n";
  };
}
