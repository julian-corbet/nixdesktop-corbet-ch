# home/niri.nix — declarative niri desktop config (home-manager). Complements
# profiles/niri-desktop.nix (the POLICY layer — which roles the session wants filled); this
# module owns the user's ~/.config/niri/config.kdl, generated from structured options instead
# of hand-edited KDL.
#
# Nothing here installs anything. nixdesktop never names a package or an absolute binary path:
# both are platform-specific (`thunar` on Arch vs `xfce.thunar` in nixpkgs; mate-polkit's agent
# binary lives at a different path on every distro). A platform backend — nixarch's for
# Arch/CachyOS — resolves the roles declared in profiles/niri-desktop.nix into real packages,
# and supplies the binary paths this module spawns via `binPaths`.
#
# LEAN BY DESIGN, same doctrine as home/shell.nix and home/dev.nix: the skeleton (input/layout/
# workspaces/binds) is niri's own well-known suggested defaults (straight from its upstream
# example config — Mod+arrows, Mod+1-9, the standard media/volume/brightness keys), not this
# author's personal taste. Every value is a real option with a neutral default; nothing here
# assumes a specific keyboard layout, terminal brand, or app list. A consumer wanting kitty
# instead of foot, a different keyboard layout, messenger auto-launch, or extra keybinds does so
# via the options below, not by forking this file.
{ lib, config, ... }:
let
  cfg = config.nixdesktop.niri;

  outputSection =
    if cfg.output != null
    then cfg.output
    else ''
      // No output declared -- niri auto-detects. Run `niri msg outputs` on-box to find the
      // real name if you want to pin mode/scale/position.
    '';

  presetWidthsSection = lib.concatMapStringsSep "\n        " (p: "proportion ${toString p}") cfg.presetColumnWidths;

  osdClient = "swayosd-client";

  # A bind is either a bare action string -- shorthand for "no hotkey-overlay title, no
  # flags", which covers most movement/layout binds -- or the full submodule below, for
  # when a bind needs a title or one of the flags niri supports on a bind. `action` is raw
  # KDL, written exactly as it appears inside the bind's `{ }` block (`close-window`,
  # `spawn "foo"`, `spawn-sh "foo | bar"`, `toggle-overview`, ...); this module supplies the
  # surrounding `{ ...; }` and the trailing semicolon.
  bindType = lib.types.submodule {
    options = {
      action = lib.mkOption {
        type = lib.types.str;
        example = ''spawn "foot"'';
        description = "The niri action this bind runs, written exactly as it appears inside the bind's `{ }` block.";
      };

      hotkeyOverlayTitle = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "Open a Terminal";
        description = ''
          Label shown for this bind in niri's hotkey overlay (Mod+Shift+Slash). Null, the
          default, omits the field -- niri leaves untitled binds out of the overlay
          entirely, rather than listing them with a blank label.
        '';
      };

      allowWhenLocked = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Whether the bind still fires while the session is locked. niri's own default is
          false; the volume/brightness/media-key and lock binds below flip this to true so
          they keep working at the lock screen.
        '';
      };

      repeat = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether holding the key repeats the action. niri's own default is true; set
          false for actions that only make sense once per press, like closing a window.
        '';
      };

      allowInhibiting = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether an application requesting exclusive keyboard-shortcut access (a game, a
          VM viewer) is allowed to swallow this bind. niri's own default is true; the bind
          that toggles shortcuts-inhibit itself flips this to false so there is always a
          way to back out of an inhibited session.
        '';
      };
    };
  };

  # Render the flags that go between a bind's key combo and its `{ }` block. Only ever
  # emits a flag when it differs from niri's own default (see the options above), the same
  # convention the hand-written config this replaces already followed -- e.g. plain
  # `Mod+Left { focus-column-left; }`, never `Mod+Left repeat=true { ...; }`.
  renderBindFlags = b: lib.concatStringsSep " " (
    lib.optional (b.hotkeyOverlayTitle != null) ''hotkey-overlay-title="${b.hotkeyOverlayTitle}"''
    ++ lib.optional b.allowWhenLocked "allow-when-locked=true"
    ++ lib.optional (!b.repeat) "repeat=false"
    ++ lib.optional (!b.allowInhibiting) "allow-inhibiting=false"
  );

  # Render one `binds { }` line for one `cfg.binds` entry. `null` -- a removed bind -- drops
  # out via the `lib.filter` in `bindsSection` below.
  renderBind = name: value:
    if value == null then
      null
    else if builtins.isString value then
      "${name} { ${value}; }"
    else
      let
        flags = renderBindFlags value;
      in
      "${name}${lib.optionalString (flags != "") " ${flags}"} { ${value.action}; }";

  # `lib.mapAttrsToList` walks `cfg.binds` in `builtins.attrNames` order, which Nix
  # guarantees is sorted -- so the rendered block is alphabetical by key combo rather than
  # grouped by topic the way the old hand-written block was. Cosmetic only: niri does not
  # care what order binds appear in within `binds { }`.
  bindsSection = lib.concatStringsSep "\n    " (
    lib.filter (l: l != null) (lib.mapAttrsToList renderBind cfg.binds)
  );
in
{
  options.nixdesktop.niri = {
    enable = lib.mkEnableOption "declarative niri config (~/.config/niri/config.kdl)";

    keyboard = {
      layout = lib.mkOption {
        type = lib.types.str;
        default = "us";
        example = "ch";
        description = "XKB keyboard layout.";
      };
      variant = lib.mkOption {
        type = lib.types.str;
        default = "";
        example = "de_nodeadkeys";
        description = "XKB keyboard variant. Empty string omits the field.";
      };
    };

    output = lib.mkOption {
      type = lib.types.nullOr lib.types.lines;
      default = null;
      example = ''
        output "HDMI-A-1" {
            mode "3840x2160@60"
        }
      '';
      description = ''
        Raw KDL for one or more `output {}` blocks. Null (default) leaves output
        configuration to niri's own auto-detection.
      '';
    };

    workspaceCount = lib.mkOption {
      type = lib.types.ints.positive;
      default = 9;
      description = ''
        Number of named, always-present workspaces ("1".."N"). Declared in ascending order --
        workspace "1" is niri's own index 1 (top of the vertical stack), counting down to "N"
        at the bottom, matching left-to-right ascending order in a workspace-indicator bar
        (waybar's niri/workspaces module lists by niri index, not by name).
      '';
    };

    presetColumnWidths = lib.mkOption {
      type = lib.types.listOf lib.types.float;
      default = [ 0.33333 0.5 0.66667 ];
      example = [ 0.25 0.33333 0.5 0.66667 0.75 ];
      description = ''
        Widths (as a fraction of output width) that Mod+R (switch-preset-column-width)
        cycles through. The niri-upstream default is thirds/half/two-thirds; add 0.25/0.75
        for a 3-column 25:50:25-style layout.
      '';
    };

    terminal = lib.mkOption {
      type = lib.types.str;
      default = "foot";
      example = "kitty";
      description = "Terminal emulator bound to Mod+T.";
    };

    launcher = lib.mkOption {
      type = lib.types.str;
      default = "fuzzel";
      description = "App launcher bound to Mod+D (and used by the clipboard-history bind).";
    };

    lockCommand = lib.mkOption {
      type = lib.types.str;
      default = "swaylock";
      description = "Screen locker, bound to Super+Alt+L.";
    };

    idle = {
      lockAfterSeconds = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = 300;
        description = "Seconds of inactivity before locking. Null means `command` below is always null (no idle daemon at all).";
      };
      suspendAfterSeconds = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = 600;
        description = ''
          Seconds of inactivity before suspending. Null drops the suspend action while
          keeping the idle lock -- the right setting on any machine that must not suspend
          but should still lock, e.g. a desktop running in a container that shares its
          kernel (and therefore its power state) with the host. Ignored entirely if
          lockAfterSeconds is null, which drops `command` below to null too.
        '';
      };

      command = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        readOnly = true;
        description = ''
          READ-ONLY, computed from `lockAfterSeconds`/`suspendAfterSeconds`/`lockCommand`:
          the full swayidle invocation (timeouts and lock command already assembled into
          one shell command), or null when `lockAfterSeconds` is null.

          This module used to emit that assembled string itself, as its own
          spawn-sh-at-startup line -- niri has no way to restart a spawn-at-startup command
          when a running session's config changes, so idle/lock now runs as a systemd user
          service instead (home/session.nix's `idleAndLock`, whose `command` option wants a
          finished command, not raw timeouts, precisely so this ASSEMBLY stays in exactly
          one place instead of being duplicated between the two modules). This option is
          that one place; consume it rather than reimplementing the assembly.
        '';
      };
    };

    clipboardHistory = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Wire the Mod+Alt+V clipboard-history picker bind (through the configured launcher).
        The wl-paste watcher processes that actually feed cliphist's history run elsewhere
        now -- home/session.nix starts them as a systemd user service -- so this option
        only controls the picker bind, and does nothing useful without that service also
        running. Requires the `cliphist` and `wl-clipboard` packages present (see
        profiles/niri-desktop.nix).
      '';
    };

    binds = lib.mkOption {
      type = lib.types.attrsOf (lib.types.nullOr (lib.types.either lib.types.str bindType));
      default = { };
      example = {
        "Mod+T" = ''spawn "kitty"'';
        "Print" = null;
        "Mod+Z" = ''spawn "my-script"'';
      };
      description = ''
        Keybindings, keyed by the exact niri key-combo string ("Mod+T",
        "XF86AudioRaiseVolume", ...). Every binding this module ships lives here as a
        CONFIG-side default (see the `config` block below), never in this option's own
        `default` (which stays `{ }`) -- an `attrsOf` option's `default` is discarded in
        full the instant a consumer defines the option at all, even for one unrelated key,
        whereas config-side definitions merge attribute-by-attribute against it. Same trap
        nixk3s's tenancy module documents for its `projects` option.

        A plain string is shorthand for a bind with no hotkey-overlay title and no flags --
        the common case. Use the submodule (`action`, `hotkeyOverlayTitle`,
        `allowWhenLocked`, `repeat`, `allowInhibiting`) when a bind needs either.

        - ADD a bind: define a new key.
        - OVERRIDE a shipped bind: redefine its key with a new value. This replaces the
          shipped entry WHOLESALE -- string or submodule, every field -- rather than
          merging field-by-field against the shipped one. See the `config` block for why:
          for this option's type, partial field overrides and clean null-removal are in
          tension, and removal is the one this module can't do without.
        - REMOVE a shipped bind: redefine its key as `null`.
      '';
    };

    extraStartup = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ ''spawn-at-startup "mako"'' ];
      description = "Extra raw spawn-at-startup / spawn-sh-at-startup lines, verbatim.";
    };

    extraWindowRules = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Extra raw `window-rule {}` blocks, verbatim, appended after the built-in ones.";
    };

    extraBinds = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = ''
        Extra raw keybind lines, verbatim, appended inside the `binds {}` block after every
        entry from the `binds` option above. Kept as an escape hatch even though `binds`
        now covers add/override/remove for ordinary bindings: this module's bind submodule
        only models the flags this file's own shipped binds actually use
        (`hotkey-overlay-title`, `allow-when-locked`, `repeat`, `allow-inhibiting`), and
        niri's bind syntax was not exhaustively re-verified against its own docs while
        writing it -- a property it supports that isn't modelled here (e.g. `cooldown-ms`)
        has no home in `binds` and belongs here instead.
      '';
    };

    osd = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [ "swayosd" ]);
      default = null;
      description = ''
        On-screen-display for volume/brightness/mic-mute. `"swayosd"` swaps the volume/
        brightness/mic-mute binds below from raw wpctl/brightnessctl calls to swayosd-client,
        which performs the same action AND shows a popup. Requires the `swayosd` package and a
        running `swayosd-server` (spawn it yourself via extraStartup -- this profile doesn't).
        Null keeps the original silent wpctl/brightnessctl binds.
      '';
    };

    extraTopLevel = lib.mkOption {
      type = lib.types.lines;
      default = "";
      example = ''
        debug {
            enable-overlay-planes
        }
      '';
      description = ''
        Extra raw top-level KDL blocks, verbatim, appended at the end of the file (outside
        `binds {}`/`window-rule {}` -- for things like a `debug {}` block).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # The shipped keybindings. Two rules, both non-obvious, both required for the
    # override/remove/add contract on the `binds` option above to actually hold:
    #
    #  1. Every entry lives here, config-side, as its own `lib.mkDefault` -- not gathered
    #     into the option's own `default = { }`. An `attrsOf` option's `default` is
    #     discarded WHOLESALE the instant a consumer defines the option at all (even for
    #     one unrelated key), so a shipped default can only survive a consumer's own
    #     additions by living in `config`, where definitions merge attribute-by-attribute.
    #     Same trap, same fix, as nixk3s's tenancy module and its `projects` option.
    #
    #  2. `mkDefault` has to wrap the WHOLE VALUE at each key, not each field within it.
    #     `binds`' element type is `nullOr (either str submodule)`, and `nullOr`'s merge
    #     THROWS ("defined both null and not null") if a null definition and a non-null
    #     definition for the same key ever reach it at the SAME priority. A consumer's
    #     plain (normal-priority) `binds.NAME = null;` removal would race the shipped
    #     entry for that exact key -- UNLESS the shipped entry sits at strictly lower
    #     (`mkDefault`) priority, so ordinary priority resolution drops it before `nullOr`
    #     ever runs, leaving only the consumer's `null` behind. The price is that override
    #     is whole-key, not whole-field: redefining "Mod+T" replaces its action, title and
    #     flags together, because a per-FIELD `mkDefault` here would let a consumer's
    #     single-field redefinition outrank -- and silently drop -- the shipped entry's
    #     OTHER fields, which is the opposite of what an override should do.
    nixdesktop.niri.binds = {
      "Mod+Shift+Slash" = lib.mkDefault "show-hotkey-overlay";

      "Mod+T" = lib.mkDefault {
        action = ''spawn "${cfg.terminal}"'';
        hotkeyOverlayTitle = "Open a Terminal";
      };
      "Mod+D" = lib.mkDefault {
        action = ''spawn "${cfg.launcher}"'';
        hotkeyOverlayTitle = "Run an Application";
      };
      "Super+Alt+L" = lib.mkDefault {
        action = ''spawn "${cfg.lockCommand}"'';
        hotkeyOverlayTitle = "Lock the Screen";
      };

      "XF86AudioRaiseVolume" = lib.mkDefault {
        allowWhenLocked = true;
        action =
          if cfg.osd == "swayosd"
          then ''spawn "${osdClient}" "--output-volume=raise"''
          else ''spawn-sh "wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.1+ -l 1.0"'';
      };
      "XF86AudioLowerVolume" = lib.mkDefault {
        allowWhenLocked = true;
        action =
          if cfg.osd == "swayosd"
          then ''spawn "${osdClient}" "--output-volume=lower"''
          else ''spawn-sh "wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.1-"'';
      };
      "XF86AudioMute" = lib.mkDefault {
        allowWhenLocked = true;
        action =
          if cfg.osd == "swayosd"
          then ''spawn "${osdClient}" "--output-volume=mute-toggle"''
          else ''spawn-sh "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"'';
      };
      "XF86AudioMicMute" = lib.mkDefault {
        allowWhenLocked = true;
        action =
          if cfg.osd == "swayosd"
          then ''spawn "${osdClient}" "--input-volume=mute-toggle"''
          else ''spawn-sh "wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle"'';
      };

      "XF86AudioPlay" = lib.mkDefault { allowWhenLocked = true; action = ''spawn-sh "playerctl play-pause"''; };
      "XF86AudioStop" = lib.mkDefault { allowWhenLocked = true; action = ''spawn-sh "playerctl stop"''; };
      "XF86AudioPrev" = lib.mkDefault { allowWhenLocked = true; action = ''spawn-sh "playerctl previous"''; };
      "XF86AudioNext" = lib.mkDefault { allowWhenLocked = true; action = ''spawn-sh "playerctl next"''; };

      "XF86MonBrightnessUp" = lib.mkDefault {
        allowWhenLocked = true;
        action =
          if cfg.osd == "swayosd"
          then ''spawn "${osdClient}" "--brightness=raise"''
          else ''spawn "brightnessctl" "--class=backlight" "set" "+10%"'';
      };
      "XF86MonBrightnessDown" = lib.mkDefault {
        allowWhenLocked = true;
        action =
          if cfg.osd == "swayosd"
          then ''spawn "${osdClient}" "--brightness=lower"''
          else ''spawn "brightnessctl" "--class=backlight" "set" "10%-"'';
      };

      "Mod+O" = lib.mkDefault { action = "toggle-overview"; repeat = false; };
      "Mod+Q" = lib.mkDefault { action = "close-window"; repeat = false; };

      "Mod+Left" = lib.mkDefault "focus-column-left";
      "Mod+Down" = lib.mkDefault "focus-window-or-workspace-down";
      "Mod+Up" = lib.mkDefault "focus-window-or-workspace-up";
      "Mod+Right" = lib.mkDefault "focus-column-right";
      "Mod+H" = lib.mkDefault "focus-column-left";
      "Mod+J" = lib.mkDefault "focus-window-or-workspace-down";
      "Mod+K" = lib.mkDefault "focus-window-or-workspace-up";
      "Mod+L" = lib.mkDefault "focus-column-right";

      "Mod+Ctrl+Left" = lib.mkDefault "move-column-left";
      "Mod+Ctrl+Down" = lib.mkDefault "move-window-down-or-to-workspace-down";
      "Mod+Ctrl+Up" = lib.mkDefault "move-window-up-or-to-workspace-up";
      "Mod+Ctrl+Right" = lib.mkDefault "move-column-right";
      "Mod+Ctrl+H" = lib.mkDefault "move-column-left";
      "Mod+Ctrl+J" = lib.mkDefault "move-window-down-or-to-workspace-down";
      "Mod+Ctrl+K" = lib.mkDefault "move-window-up-or-to-workspace-up";
      "Mod+Ctrl+L" = lib.mkDefault "move-column-right";

      "Mod+Home" = lib.mkDefault "focus-column-first";
      "Mod+End" = lib.mkDefault "focus-column-last";

      "Mod+Page_Down" = lib.mkDefault "focus-workspace-down";
      "Mod+Page_Up" = lib.mkDefault "focus-workspace-up";
      "Mod+U" = lib.mkDefault "focus-workspace-down";
      "Mod+I" = lib.mkDefault "focus-workspace-up";

      "Mod+BracketLeft" = lib.mkDefault "consume-or-expel-window-left";
      "Mod+BracketRight" = lib.mkDefault "consume-or-expel-window-right";
      "Mod+Comma" = lib.mkDefault "consume-window-into-column";
      "Mod+Period" = lib.mkDefault "expel-window-from-column";

      "Mod+R" = lib.mkDefault "switch-preset-column-width";
      "Mod+Shift+R" = lib.mkDefault "switch-preset-column-width-back";

      "Mod+F" = lib.mkDefault "maximize-column";
      "Mod+Shift+F" = lib.mkDefault "fullscreen-window";
      "Mod+M" = lib.mkDefault "maximize-window-to-edges";
      "Mod+C" = lib.mkDefault "center-column";

      "Mod+Minus" = lib.mkDefault ''set-column-width "-10%"'';
      "Mod+Equal" = lib.mkDefault ''set-column-width "+10%"'';

      "Mod+V" = lib.mkDefault "toggle-window-floating";
      "Mod+Shift+V" = lib.mkDefault "switch-focus-between-floating-and-tiling";

      "Mod+W" = lib.mkDefault "toggle-column-tabbed-display";

      "Print" = lib.mkDefault "screenshot";
      "Ctrl+Print" = lib.mkDefault "screenshot-screen";
      "Alt+Print" = lib.mkDefault "screenshot-window";

      "Mod+Escape" = lib.mkDefault { action = "toggle-keyboard-shortcuts-inhibit"; allowInhibiting = false; };
      "Mod+Shift+E" = lib.mkDefault "quit";
      "Mod+Shift+P" = lib.mkDefault "power-off-monitors";
    }
    # The clipboard-history picker bind, gated on `clipboardHistory` like the rest of that
    # feature. This is a normal user-invoked keybinding, not a startup daemon, so it is
    # unaffected by the wl-paste watchers moving to home/session.nix below.
    // lib.optionalAttrs cfg.clipboardHistory {
      "Mod+Alt+V" = lib.mkDefault ''spawn-sh "cliphist list | ${cfg.launcher} --dmenu | cliphist decode | wl-copy"'';
    }
    # The per-workspace focus binds (Mod+1..Mod+N) are generated from `workspaceCount`, but
    # they land in this SAME `binds` set, each its own `mkDefault` entry, rather than a
    # separately-rendered block outside it. Deliberately: that keeps them subject to the
    # identical override/remove/add rules as every hand-written bind above -- a consumer who
    # wants Mod+9 to do something else, or wants it gone, redefines or nulls "Mod+9" exactly
    # like they would "Mod+T", with no second escape hatch to learn for "generated" binds.
    // lib.listToAttrs (map
      (n: lib.nameValuePair "Mod+${toString n}" (lib.mkDefault "focus-workspace ${toString n}"))
      (lib.range 1 cfg.workspaceCount));

    # The assembled swayidle command -- see the `idle.command` option doc for why this
    # module still owns the assembly even though it no longer spawns the daemon itself.
    nixdesktop.niri.idle.command =
      if cfg.idle.lockAfterSeconds == null
      then null
      else "swayidle -w timeout ${toString cfg.idle.lockAfterSeconds} '${cfg.lockCommand} -f'${lib.optionalString (cfg.idle.suspendAfterSeconds != null) " timeout ${toString cfg.idle.suspendAfterSeconds} 'systemctl suspend'"} before-sleep '${cfg.lockCommand} -f' lock '${cfg.lockCommand} -f' unlock 'pkill -USR1 ${cfg.lockCommand}'";

    xdg.configFile."niri/config.kdl".text = ''
      // Managed by home-manager (nixdesktop's home/niri.nix). Hand edits will be overwritten by
      // the next `home-manager switch` -- set options instead.

      input {
          keyboard {
              xkb {
                  layout "${cfg.keyboard.layout}"
                  ${lib.optionalString (cfg.keyboard.variant != "") ''variant "${cfg.keyboard.variant}"''}
              }
              numlock
          }

          touchpad {
              tap
              natural-scroll
          }
      }

      ${outputSection}

      layout {
          gaps 16
          center-focused-column "never"

          preset-column-widths {
              ${presetWidthsSection}
          }

          default-column-width { proportion 0.5; }

          focus-ring {
              width 4
              active-color "#7fc8ff"
              inactive-color "#505050"
          }

          border {
              off
              width 4
              active-color "#ffc87f"
              inactive-color "#505050"
              urgent-color "#9b0000"
          }
      }

      ${lib.concatMapStringsSep "\n" (n: ''workspace "${toString n}"'') (lib.range 1 cfg.workspaceCount)}

      ${lib.concatStringsSep "\n" cfg.extraStartup}

      // The polkit authentication agent, the org.freedesktop.secrets keyring, the cliphist
      // wl-paste watchers, and the idle/lock daemon used to be spawned from here via
      // spawn-at-startup / spawn-sh-at-startup. All four now run as systemd user services
      // owned by home/session.nix instead (started as units, not niri spawn-at-startup
      // lines) -- this module no longer names a polkit/keyring binary or a cliphist watcher
      // command at all. The one exception is the idle daemon's swayidle invocation: this
      // module still assembles that string (see the `idle.command` option) since niri.nix's
      // three idle-related options (`idle.lockAfterSeconds`/`idle.suspendAfterSeconds`/
      // `lockCommand`) are its inputs, and home/session.nix deliberately takes a finished
      // command rather than duplicating the assembly.

      screenshot-path "~/Pictures/Screenshots/Screenshot from %Y-%m-%d %H-%M-%S.png"

      animations { }

      // Work around WezTerm's initial configure bug (niri-upstream default rule).
      window-rule {
          match app-id=r#"^org\.wezfurlong\.wezterm$"#
          default-column-width {}
      }

      // Open Firefox picture-in-picture as floating (niri-upstream default rule).
      window-rule {
          match app-id=r#"firefox$"# title="^Picture-in-Picture$"
          open-floating true
      }

      ${cfg.extraWindowRules}

      binds {
          ${bindsSection}

          ${cfg.extraBinds}
      }

      ${cfg.extraTopLevel}
    '';
  };
}
