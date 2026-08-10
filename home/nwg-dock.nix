# home/nwg-dock.nix — declarative nwg-dock config, sibling to home/nwg-bar.nix.
#
# nwg-dock is configured from three places at once, and only ONE of them is a config file. That is
# the whole reason this module is more than a `style` option:
#
#   1. its CSS               ~/.config/nwg-dock/style.css        — ordinary, handled like any other
#   2. its COMMAND LINE      every knob that is not colour (position, icon size, output, autohide,
#                            launcher position, launcher command) is an argv flag. There is no
#                            config file for any of it, so a dock is only as reproducible as
#                            whatever started it.
#   3. its ICONS             the launcher glyph and the task indicators are SVG files nwg-dock
#                            reads from its own package directory, with no option to point
#                            elsewhere — see `icons` below.
#
# ── WHY THE COMMAND LINE IS MODELLED HERE AND NOT LEFT TO THE CONSUMER ────────────────────────
#
# Because a hand-started dock is a dock that exists until the next reboot and then does not, and
# nothing anywhere records why it looked the way it did. This module renders `command` from typed
# options so the invocation lives in the same file as the styling, and a session-service layer can
# run it. Recovering a lost invocation is otherwise archaeology: the flags exist only in the argv
# of a running process.
#
# ── THE ICONS, AND THE ONE HONEST THING THIS MODULE CANNOT DO ─────────────────────────────────
#
# nwg-dock loads `grid.svg` (the launcher glyph) and `task-{single,multiple,empty}.svg` (the
# running-app indicators) from `<datadir>/nwg-dock/images/`, resolved from a path COMPILED INTO THE
# BINARY. Verified the hard way rather than assumed: a replacement placed in
# `$XDG_DATA_HOME/nwg-dock/images/` is ignored, and so is one in `/usr/local/share/`, and so is
# prepending either to `XDG_DATA_DIRS` — tested with a deliberately magenta SVG, which never
# rendered. There is no flag for it.
#
# So `icons` writes the replacements somewhere a consumer can reach them, and PUBLISHES the sync
# command — it cannot install them itself, because on a foreign distro that directory belongs to
# the package manager and a home-manager module has no business writing there. A consumer that
# wants recoloured icons runs `iconSyncCommand` from its own privileged plane, and must re-run it
# after any nwg-dock upgrade, because the package will overwrite them. That is a real, permanent
# fragility of nwg-dock and this module states it rather than hiding it.
{ lib, pkgs, config, ... }:
let
  cfg = config.nixdesktop.nwgDock;

  iconFiles = lib.mapAttrs'
    (name: content: lib.nameValuePair "nwg-dock/images/${name}" { text = content; })
    cfg.icons;

  flag = name: value:
    if value == null then [ ]
    else if value == true then [ name ]
    else if value == false then [ ]
    else [ name (toString value) ];

  argv = lib.concatLists [
    [ cfg.package ]
    (flag "-d" cfg.autohide)
    (flag "-hd" cfg.hotspotDelay)
    (flag "-p" cfg.position)
    (flag "-i" cfg.iconSize)
    (flag "-o" cfg.output)
    (flag "-lp" cfg.launcherPosition)
    (flag "-nows" (!cfg.workspaceSwitcher))
    (flag "-nolauncher" (!cfg.launcher))
    (flag "-l" cfg.layer)
    (flag "-c" cfg.launcherCommand)
    cfg.extraArgs
  ];
in
{
  options.nixdesktop.nwgDock = {
    enable = lib.mkEnableOption "declarative nwg-dock config (~/.config/nwg-dock/style.css) and its rendered invocation";

    package = lib.mkOption {
      type = lib.types.str;
      default = "nwg-dock";
      description = ''
        The executable, as it appears in the rendered command. A bare name resolves through $PATH;
        give an absolute path on a host where the dock is started from a unit with a restricted
        environment. This module installs nothing.
      '';
    };

    style = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = ''
        Raw CSS for ~/.config/nwg-dock/style.css.

        TWO TRAPS THAT ARE NOT OBVIOUS FROM THE WIDGET TREE, both worth writing into whatever CSS
        a consumer supplies:

        `window` must stay fully transparent and carry no margin. The visible slab is `#box`; a
        background on `window` shows square corners behind the rounding, and a margin there lifts
        the autohide hotspot off the screen edge and makes the dock unreachable. A visual gap under
        the dock belongs in `#box`'s margin, never in `-mb`.

        nwg-dock nests each task in its own single-child box, so EVERY wrapper is `:nth-child(1)`.
        A rule written for "the first item" therefore matches every item — including the launcher
        and every application alike. A separator between the launcher and the apps has to be
        written as a `border-left` on `:nth-child(2)`, and needs `:not(image)` because each task is
        `[button][indicator]` and the indicator is also an `:nth-child(2)`.
      '';
    };

    icons = lib.mkOption {
      type = lib.types.attrsOf lib.types.lines;
      default = { };
      example = lib.literalExpression ''
        { "grid.svg" = "<svg …>"; "task-single.svg" = "<svg …>"; }
      '';
      description = ''
        Replacement SVGs for nwg-dock's own images, written to
        `~/.local/share/nwg-dock/images/<name>`. Keys are nwg-dock's own filenames: `grid.svg` is
        the launcher glyph, `task-single.svg`/`task-multiple.svg`/`task-empty.svg` are the
        running-app indicators, `icon-missing.svg` is the fallback for an app whose `app_id`
        matches no icon theme entry, and `1.svg`…`20.svg` are the workspace numbers.

        WRITING THEM HERE IS NOT ENOUGH, and that is nwg-dock's limitation rather than a choice
        made here: it reads these from a compiled-in package directory and honours no override
        path. See `iconSyncCommand`.
      '';
    };

    iconSyncCommand = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = "cp ${config.xdg.dataHome}/nwg-dock/images/*.svg ${cfg.systemImageDir}/";
      description = ''
        The command that makes `icons` actually take effect, to be run by a consumer's own
        privileged plane (a system activation step, or a package-manager hook).

        It must be re-run after every nwg-dock upgrade. The package owns that directory and will
        overwrite the replacements, silently — the only symptom is the launcher glyph reverting to
        its stock colour, which is easy to mistake for a theming regression somewhere else
        entirely.
      '';
    };

    systemImageDir = lib.mkOption {
      type = lib.types.str;
      default = "/usr/share/nwg-dock/images";
      description = ''
        Where the running nwg-dock actually reads its images from. Distro-dependent, which is why
        it is an option: this is the path a package manager installed, not one this module chose.
      '';
    };

    # ── the invocation ────────────────────────────────────────────────────────────────────────
    autohide = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        `-d`: keep the dock hidden and reveal it when the pointer reaches a hotspot at the screen
        edge. False leaves it permanently visible (nwg-dock's `-r`), which is worth having while
        styling it, since a hidden dock cannot be screenshotted.
      '';
    };

    hotspotDelay = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = null;
      example = 0;
      description = ''
        `-hd`, in milliseconds: how slowly the pointer may enter the hotspot and still trigger it.
        `0` disables the delay entirely, so the dock appears the instant the edge is touched.
        Only meaningful with `autohide`.
      '';
    };

    position = lib.mkOption {
      type = lib.types.enum [ "bottom" "top" "left" ];
      default = "bottom";
      description = "`-p`: which screen edge the dock lives on.";
    };

    iconSize = lib.mkOption {
      type = lib.types.ints.positive;
      default = 48;
      description = "`-i`: application icon size in px. The dock's height follows from this plus the CSS padding.";
    };

    output = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "DP-1";
      description = ''
        `-o`: pin the dock to one output, by connector name. `null` lets nwg-dock choose, which on
        a multi-head desk is rarely what anyone wants — a dock on a pivoted secondary panel is
        most of that panel's width.
      '';
    };

    launcher = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to show the launcher button at all (false renders nwg-dock's `-nolauncher`).";
    };

    launcherPosition = lib.mkOption {
      type = lib.types.enum [ "start" "end" ];
      default = "end";
      description = "`-lp`: which end of the dock the launcher button sits at.";
    };

    launcherCommand = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "rofi -show drun";
      description = ''
        `-c`: what the launcher button runs. `null` lets nwg-dock auto-detect one, which finds
        whichever nwg-* launcher happens to be installed.

        PREFER A PATH THAT FOLLOWS THE ACTIVE GENERATION (a profile path, or a bare name resolved
        through $PATH) over a bare store path. A store path baked in here is correct only until
        the next switch rebuilds the launcher, after which the button silently does nothing — the
        dock reports no error for a command that does not exist.
      '';
    };

    workspaceSwitcher = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to show nwg-dock's workspace switcher (false renders `-nows`).";
    };

    layer = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [ "overlay" "top" "bottom" ]);
      default = null;
      description = "`-l`: layer-shell layer. `null` leaves nwg-dock's own default (overlay).";
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "-g" "foot Alacritty" ];
      description = "Any further nwg-dock flags, appended verbatim.";
    };

    command = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = lib.escapeShellArgs argv;
      description = ''
        The rendered invocation. Hand this to a session-service layer rather than starting the dock
        by hand: nwg-dock has no config file for any of these flags, so a hand-started dock is one
        whose configuration exists nowhere but in its own argv, and disappears with the process.
      '';
    };
  };

  config = lib.mkIf cfg.enable ({
    xdg.dataFile = iconFiles;
  } // lib.optionalAttrs (cfg.style != "") {
    xdg.configFile."nwg-dock/style.css".text = cfg.style;
  });
}
