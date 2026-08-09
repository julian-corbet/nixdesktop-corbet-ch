# Evaluates home/ironbar.nix and home/swaync.nix for real, plus the one piece of home/session.nix
# plumbing they need (`unsetEnvironment`).
#
# WHY THIS FILE EXISTS AT ALL, SAME REASONING AS EVERY SIBLING CHECK HERE: `nix flake check` does
# not evaluate `homeManagerModules` — it lists them as unchecked and moves on.
#
# WHAT IS WORTH PROVING IN A FILE-GENERATOR MODULE, AND WHAT IS NOT. `settings` goes through
# `pkgs.formats.toml`/`builtins.toJSON`, both upstream and both well covered where they live;
# re-testing them here would only prove that nixpkgs works. What is genuinely this module's own,
# and what is quiet when wrong, is everything AROUND the serialiser:
#
#   · WHERE each file lands. A path typo produces a perfectly valid file that the program never
#     reads, and the only symptom is an unstyled bar.
#   · THE EXECUTABLE BIT. A `custom` module's dynamic string runs its command through a shell; a
#     helper script without +x fails with a permission error that surfaces as an empty label and
#     nothing else. This is the single most likely way this module is wrong in practice, and it is
#     invisible from the config file.
#   · THE ASSETS/SCRIPTS SPLIT. The `cairo` module's Lua is READ by ironbar, not executed by it.
#     Marking it executable would be a false claim about it, and the two option names exist so that
#     distinction is stated rather than lost.
#   · THE EMPTY-STYLESHEET CASE. Both modules deliberately write NO file when `style` is empty, so
#     the program falls back to its own default rather than rendering against a blank sheet. An
#     `lib.optionalAttrs` is exactly the kind of line that gets "simplified" into always writing.
{ pkgs, lib ? pkgs.lib }:
let
  support = import ./support.nix { inherit pkgs lib; };
  inherit (support) report;

  # Same host stub the sibling checks use, plus `xdg.configHome` — which these two modules read
  # (the read-only `configDir`/`scriptsDir` are derived from it) and the shared `hostStub` does not
  # declare. home-manager sets it for real; a literal here keeps the expected paths legible below.
  stubs = { lib, ... }: {
    options = {
      xdg.configHome = lib.mkOption { type = lib.types.str; default = "/home/u/.config"; };
      xdg.configFile = lib.mkOption {
        type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
        default = { };
      };
      home.packages = lib.mkOption { type = lib.types.listOf lib.types.anything; default = [ ]; };
      home.file = lib.mkOption { type = lib.types.attrsOf lib.types.anything; default = { }; };
      assertions = lib.mkOption { type = lib.types.listOf lib.types.anything; default = [ ]; };
      warnings = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
      systemd.user = lib.mkOption { type = lib.types.anything; default = { }; };
    };
  };

  evalWith = module: settings: (lib.evalModules {
    modules = [ stubs module settings ];
    specialArgs = { inherit pkgs; };
  }).config;

  # ── ironbar ──────────────────────────────────────────────────────────────────────────────────
  ironbarFull = evalWith ../home/ironbar.nix {
    nixdesktop.ironbar = {
      enable = true;
      settings.monitors.DP-1 = {
        name = "main";
        position = "top";
        start = [{ type = "launcher"; icon_size = 18; }];
      };
      style = ".background { color: #fff; }";
      scripts."weather.sh" = "#!/bin/sh\necho sunny";
      assets."sys_graph.lua" = "function draw(cr) end";
    };
  };

  ironbarNoStyle = evalWith ../home/ironbar.nix {
    nixdesktop.ironbar = { enable = true; settings.icon_theme = "Adwaita"; };
  };

  ironbarOff = evalWith ../home/ironbar.nix {
    nixdesktop.ironbar = { enable = false; style = "ignored"; };
  };

  ironFiles = ironbarFull.xdg.configFile;

  # ── swaync ───────────────────────────────────────────────────────────────────────────────────
  swayncFull = evalWith ../home/swaync.nix {
    nixdesktop.swaync = {
      enable = true;
      settings = {
        positionX = "right";
        widgets = [ "title" "dnd" "notifications" ];
      };
      style = ".control-center { background: #000; }";
    };
  };

  swayncNoStyle = evalWith ../home/swaync.nix {
    nixdesktop.swaync = { enable = true; settings.positionX = "left"; };
  };

  swayncOff = evalWith ../home/swaync.nix {
    nixdesktop.swaync = { enable = false; style = "ignored"; };
  };

  # `settings` is serialised with `builtins.toJSON`, so the rendered text IS readable at evaluation
  # time — unlike ironbar's TOML, which is a derivation. Parsing it back and comparing to the input
  # proves the round trip rather than string-matching a fragment of it.
  swayncRoundTrip = builtins.fromJSON swayncFull.xdg.configFile."swaync/config.json".text;

  # ── the session plumbing these two need ──────────────────────────────────────────────────────
  sessionUnits = settings: (lib.evalModules {
    modules = [
      stubs
      ../home/session.nix
      { nixdesktop.session = { enable = true; } // settings; }
    ];
    specialArgs = { inherit pkgs; };
  }).config.systemd.user.services;

  barUnsetting = (sessionUnits {
    bar.enable = true;
    bar.command = "ironbar";
    services.bar.unsetEnvironment = [ "SCROLLSOCK" "I3SOCK" ];
    services.bar.environment.SWAYSOCK = "%t/scroll-swaycompat.sock";
  }).bar.Service;

  barPlain = (sessionUnits { bar.enable = true; bar.command = "waybar"; }).bar.Service;

  results = {
    # ── ironbar: placement ────────────────────────────────────────────────────────────────────
    "ironbar writes config.toml under ~/.config/ironbar" =
      ironFiles ? "ironbar/config.toml";
    "ironbar writes style.css when a stylesheet is given" =
      ironFiles ? "ironbar/style.css";
    "ironbar puts scripts in the scripts/ subdirectory, not beside the config" =
      ironFiles ? "ironbar/scripts/weather.sh" && !(ironFiles ? "ironbar/weather.sh");
    "ironbar puts assets beside the config, not in scripts/" =
      ironFiles ? "ironbar/sys_graph.lua" && !(ironFiles ? "ironbar/scripts/sys_graph.lua");

    # ── ironbar: the executable bit, the thing that is invisible from the config file ─────────
    "a script is executable — a dynamic string cannot run one that is not" =
      ironFiles."ironbar/scripts/weather.sh".executable == true;
    "an asset is NOT executable — ironbar reads the cairo Lua, it does not exec it" =
      (ironFiles."ironbar/sys_graph.lua".executable or false) == false;

    # ── ironbar: the empty-stylesheet and disabled cases ──────────────────────────────────────
    "no stylesheet means no style.css at all, so ironbar falls back to the GTK theme" =
      !(ironbarNoStyle.xdg.configFile ? "ironbar/style.css");
    "...but the config itself is still written" =
      ironbarNoStyle.xdg.configFile ? "ironbar/config.toml";
    "disabled ironbar writes nothing, even with a stylesheet set" =
      ironbarOff.xdg.configFile == { };

    # ── ironbar: the published paths ──────────────────────────────────────────────────────────
    "configDir is derived from xdg.configHome, not hardcoded" =
      ironbarFull.nixdesktop.ironbar.configDir == "/home/u/.config/ironbar";
    "scriptsDir names the same directory scripts are actually written to" =
      ironbarFull.nixdesktop.ironbar.scriptsDir == "/home/u/.config/ironbar/scripts";

    # ── swaync ────────────────────────────────────────────────────────────────────────────────
    "swaync writes config.json under ~/.config/swaync" =
      swayncFull.xdg.configFile ? "swaync/config.json";
    "swaync writes style.css when a stylesheet is given" =
      swayncFull.xdg.configFile ? "swaync/style.css";
    "swaync's JSON round-trips: the widget ORDER survives serialisation" =
      swayncRoundTrip.widgets == [ "title" "dnd" "notifications" ];
    "...and so do scalar settings" =
      swayncRoundTrip.positionX == "right";
    "no stylesheet means no style.css, so swaync keeps its own packaged one" =
      !(swayncNoStyle.xdg.configFile ? "swaync/style.css");
    "disabled swaync writes nothing, even with a stylesheet set" =
      swayncOff.xdg.configFile == { };

    # ── unsetEnvironment: the directive a shimmed IPC client cannot work without ──────────────
    "unsetEnvironment renders UnsetEnvironment= with every name given" =
      barUnsetting.UnsetEnvironment == [ "SCROLLSOCK" "I3SOCK" ];
    "...alongside Environment=, not instead of it" =
      barUnsetting.Environment == [ "SWAYSOCK=%t/scroll-swaycompat.sock" ];
    "a service that never asked for it renders an empty list, so no directive appears" =
      barPlain.UnsetEnvironment == [ ];
  };
in
report "gtk4-shell" results
