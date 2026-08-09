# home/swaync.nix — declarative SwayNotificationCenter config, sibling to home/mako.nix.
# Compositor-neutral, like every other home/*.nix here.
#
# WHY A SECOND NOTIFICATION MODULE, next to home/mako.nix. mako is a notification DAEMON and
# nothing else: it shows a popup and forgets it. swaync is a daemon plus a control centre — a
# persistent, scrollable history you can reopen, and a panel of toggles/sliders beside it. Two
# consequences decide between them, neither of them cosmetic:
#
#  1. HISTORY. A notification that arrives while a fullscreen window is up, or while the screen is
#     locked, is simply lost with mako. swaync keeps it.
#  2. AN INTERFACE OTHER THINGS CAN READ. swaync exposes `org.erikreider.swaync.cc` on the session
#     bus — unread count, DND state, open/close. That is the ONLY notification interface ironbar's
#     `notifications` module speaks; mako, dunst and fnott expose nothing comparable, so a bar
#     cannot show an unread badge for any of them. If a bar has that module, the daemon choice is
#     already made.
#
# It costs more than mako (a GTK4 process rather than a wlroots-native one), so both modules stay
# and both are `enable`-gated: a consumer who wants popups and nothing else should keep mako.
#
# LEAN BY DESIGN, same doctrine as home/waybar.nix: mechanism only. `settings` is an arbitrary
# attrset serialised to JSON, because swaync's `widget-config` is a per-widget schema (a dozen
# widget types, no shared shape) that would rot here within a release; `style` is raw CSS text.
# The consumer owns which widgets exist, in what order, and what they look like.
{ lib, config, ... }:
let
  cfg = config.nixdesktop.swaync;
in
{
  options.nixdesktop.swaync = {
    enable = lib.mkEnableOption "declarative swaync config (~/.config/swaync/{config.json,style.css})";

    settings = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      example = {
        positionX = "right";
        positionY = "top";
        widgets = [ "title" "buttons-grid" "volume" "dnd" "notifications" ];
      };
      description = ''
        The whole of ~/.config/swaync/config.json, as an attrset, serialised to JSON verbatim.

        Two keys carry more weight than the rest. `widgets` is an ordered list AND an allow-list —
        a widget absent from it is not rendered no matter what `widget-config` says about it, which
        is how you remove one without deleting its settings. `widget-config.<widget>` then
        configures each; a key there for a widget not in `widgets` is inert rather than an error,
        so a stale one is invisible until someone reads the file.

        Setting `$schema` to the packaged `configSchema.json` is worthwhile: swaync validates
        against it and an editor will too, which is the only checking this attrset gets — nothing
        in Nix knows what a valid swaync widget is.
      '';
    };

    style = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = ''
        Raw CSS for ~/.config/swaync/style.css.

        swaync is GTK4 + libadwaita. libadwaita deliberately ignores `gtk-theme-name`, so a
        stylesheet here cannot inherit a system theme's palette and has to state its own colours —
        expect this to restate what a sibling bar's CSS already says rather than share with it.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    xdg.configFile = {
      "swaync/config.json".text = builtins.toJSON cfg.settings;
    }
    # Same treatment as the ironbar module's stylesheet: no style, no file. swaync ships a default
    # stylesheet of its own and falls back to it, which is a real configuration; an empty file
    # would instead render an unstyled panel that looks like someone meant it.
    // lib.optionalAttrs (cfg.style != "") {
      "swaync/style.css".text = cfg.style;
    };
  };
}
