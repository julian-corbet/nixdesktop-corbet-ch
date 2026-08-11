# home/ironbar.nix — declarative ironbar config (home-manager), sibling to home/waybar.nix.
# Compositor-neutral, like every other home/*.nix here: ironbar talks to whichever compositor is
# running (it has sway, Hyprland and niri backends of its own), so nothing in this file names one.
#
# WHY A SECOND BAR MODULE AT ALL, next to home/waybar.nix. The two are not redundant and this is
# not a taste split. waybar is GTK3, and GTK3 has never implemented `wp_fractional_scale_v1`: on a
# fractionally-scaled output it renders at the next whole integer scale and the compositor
# downsamples the result, so on a 1.5 output every glyph in the bar is a 2x bitmap squeezed to
# 0.75. ironbar is GTK4 and negotiates the real 1.5, so its text is drawn at the size it is
# displayed at. That is the entire reason this module exists; anything with the same property
# would have done. Both modules stay because they are both `enable`-gated and consumers on
# integer-scaled outputs have no reason to move.
#
# LEAN BY DESIGN, same doctrine as home/waybar.nix and home/eww.nix: this module owns the
# MECHANISM (serialisation, file placement, the executable bit), not a bar layout, not a module
# list and not a palette. `settings` is an arbitrary attrset because ironbar has upwards of twenty
# module types whose shapes have nothing in common, and modelling all of them in Nix would be a
# schema this repo then has to chase across an alpha's releases. `style` is raw CSS text.
#
# COMMENTS DO NOT SURVIVE. `settings` is serialised from an attrset, so any explanatory comment in
# the resulting config.toml is gone by construction. That is not a loss to work around — it is the
# reason to keep the reasoning in the CONSUMER's Nix file, where it sits next to the value it
# explains and where `nix` is the thing reading it. A generated config.toml is an artefact; do not
# hand-edit it and do not put knowledge in it.
{ lib, pkgs, config, ... }:
let
  cfg = config.nixdesktop.ironbar;

  tomlFormat = pkgs.formats.toml { };

  scriptFiles = lib.mapAttrs'
    (name: content: lib.nameValuePair "ironbar/scripts/${name}" {
      text = content;
      executable = true;
    })
    cfg.scripts;

  assetFiles = lib.mapAttrs'
    (name: content: lib.nameValuePair "ironbar/${name}" { text = content; })
    cfg.assets;
in
{
  options.nixdesktop.ironbar = {
    enable = lib.mkEnableOption "declarative ironbar config (~/.config/ironbar/{config.toml,style.css})";

    settings = lib.mkOption {
      type = tomlFormat.type;
      default = { };
      example = lib.literalExpression ''
        {
          icon_theme = "Adwaita";
          monitors.DP-1 = {
            name = "main";
            position = "top";
            height = 34;
            start = [ { type = "launcher"; icon_size = 18; } ];
            end = [ { type = "clock"; format = "%a %d %b  %H:%M"; } ];
          };
        }
      '';
      description = ''
        The whole of ~/.config/ironbar/config.toml, as an attrset, serialised to TOML verbatim.

        `monitors.<output>` is an ALLOW-LIST in ironbar: name an output and it gets a bar, leave it
        out and it never does. Naming an output that is currently disconnected is harmless — it
        simply gets a bar on the days it is plugged in — which makes a single value correct across
        a docked and an undocked laptop without a conditional.

        A bar definition is per-output and ironbar has no "same on every monitor" primitive of its
        own, so the repetition is real in the file and belongs in Nix rather than in the TOML: build
        one attrset for the bar and `lib.genAttrs` it over the outputs.
      '';
    };

    style = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = ''
        Raw CSS for ~/.config/ironbar/style.css.

        GTK4 CSS, which is a strictly smaller dialect than the GTK3 one waybar takes: no custom
        properties, no `calc()` over variables, no box-shadow spread. `@define-color` is the only
        indirection available, so derived numbers have to be written out — or computed here in Nix
        and interpolated, which is the one advantage this module has over a hand-written file.
      '';
    };

    scripts = lib.mkOption {
      type = lib.types.attrsOf lib.types.lines;
      default = { };
      example = { "weather.sh" = "#!/usr/bin/env bash\n..."; };
      description = ''
        Helper scripts, written EXECUTABLE to ~/.config/ironbar/scripts/<name>. These are what a
        `custom` module's dynamic strings (`{{interval:command}}`) and a module's `on_click_*`
        actually run. Reference them through `scriptsDir` rather than restating the path.
      '';
    };

    assets = lib.mkOption {
      type = lib.types.attrsOf lib.types.lines;
      default = { };
      example = { "sys_graph.lua" = "function draw(cr) ... end"; };
      description = ''
        Companion files written NON-executable to ~/.config/ironbar/<name>. Separate from `scripts`
        because these are read by ironbar itself rather than exec'd by it — the `cairo` module's
        Lua drawing script is the case this exists for, and marking it executable would be a claim
        about it that is not true.
      '';
    };

    configDir = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = "${config.xdg.configHome}/ironbar";
      description = ''
        Where this module puts everything. Read-only, and published for the same reason the
        scripts directory below is: a consumer has to name absolute paths inside `settings` (the
        `cairo` module's `path`, a dynamic string's command), and deriving them from here means the
        layout is stated once instead of once per reference.
      '';
    };

    scriptsDir = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = "${config.xdg.configHome}/ironbar/scripts";
      description = "Where `scripts` land. Read-only; see `configDir`.";
    };
  };

  config = lib.mkIf cfg.enable {
    xdg.configFile = {
      "ironbar/config.toml" = {
        source = tomlFormat.generate "ironbar-config.toml" cfg.settings;

        # Tell the RUNNING bar that its config moved under it.
        #
        # ironbar reads config.toml once, at startup, and watches only the stylesheet afterwards.
        # So a switch that changes a module or a button's command writes the new file and changes
        # nothing visible, and the bar keeps serving the old config until it is next restarted --
        # which on a desktop is "at the next login", possibly days later. The failure has no error
        # and no symptom except that the change did not happen, so it reads as a broken config
        # rather than a stale process, and that is a genuinely expensive hour to lose.
        #
        # Guarded three ways, because activation must never fail or hang over a cosmetic reload:
        #   * `command -v` -- this module renders config for a binary it does not install (there is
        #     deliberately no `package` option; ironbar comes from the host's own distro), so a host
        #     may legitimately have the config and not the program.
        #   * exit code ignored -- with no instance running, `ironbar reload` returns 3 immediately
        #     rather than blocking on the absent IPC socket. Verified, not assumed: a subcommand
        #     that waited for a socket would turn every headless switch into a hung activation.
        #   * no restart fallback -- if the reload does not land, the bar keeps running the old
        #     config, which is strictly better than a switch that can leave the session with no bar.
        onChange = ''
          if command -v ironbar > /dev/null 2>&1; then
            ironbar reload > /dev/null 2>&1 || true
          fi
        '';
      };
    }
    # An empty stylesheet is not written at all. ironbar falls back to the GTK theme's own
    # rendering when there is no style.css, which is a legitimate configuration; writing an empty
    # file instead would leave it unstyled AND make `ls` claim someone had styled it.
    // lib.optionalAttrs (cfg.style != "") {
      "ironbar/style.css".text = cfg.style;
    }
    // scriptFiles
    // assetFiles;
  };
}
