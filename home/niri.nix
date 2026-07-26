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
      description = "Screen locker, bound to Super+Alt+L and used by the idle-lock startup line.";
    };

    idle = {
      lockAfterSeconds = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = 300;
        description = "Seconds of inactivity before locking. Null disables the swayidle startup line entirely.";
      };
      suspendAfterSeconds = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = 600;
        description = ''
          Seconds of inactivity before suspending. Null drops the suspend action while
          keeping the idle lock -- the right setting on any machine that must not suspend
          but should still lock, e.g. a desktop running in a container that shares its
          kernel (and therefore its power state) with the host. Ignored entirely if
          lockAfterSeconds is null, which disables the whole swayidle line.
        '';
      };
    };

    clipboardHistory = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Wire cliphist (wl-paste watchers at startup + a Mod+Alt+V picker through the
        configured launcher). Requires the `cliphist` and `wl-clipboard` packages present
        (see profiles/niri-desktop.nix).
      '';
    };

    polkitAgentCommand = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/usr/lib/mate-polkit/polkit-mate-authentication-agent-1";
      description = ''
        Command spawned at startup to provide a polkit authentication agent, or null for none.

        A COMMAND, not a role name, because every agent ships its binary at a different
        platform-specific path — the platform backend (nixarch's, for Arch/CachyOS) resolves
        `nixdesktop.niriDesktop.polkitAgent` into the right string and sets it here. Consumers
        managing their own packages can set it directly.

        This exists as a first-class option rather than an `extraStartup` line because niri does
        not process XDG autostart, so a desktop with no agent has no privileged-prompt path at
        all — and the failure is silent (the dialog never appears; nothing is logged). That is
        too sharp an edge to leave to an escape hatch.
      '';
    };

    keyringCommand = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "gnome-keyring-daemon --start --components=secrets";
      description = ''
        Command spawned at startup to provide `org.freedesktop.secrets`, or null for none.
        Same reasoning as `polkitAgentCommand`: platform-specific invocation, supplied by the
        backend. Only ever set one provider — two racing for the D-Bus name is a confusing
        failure that presents as apps intermittently losing their stored secrets.
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
      description = "Extra raw keybind lines, verbatim, appended inside the `binds {}` block.";
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

      ${lib.optionalString (cfg.polkitAgentCommand != null) ''
      spawn-at-startup "${cfg.polkitAgentCommand}"
      ''}

      ${lib.optionalString (cfg.keyringCommand != null) ''
      spawn-sh-at-startup "${cfg.keyringCommand}"
      ''}

      ${lib.optionalString cfg.clipboardHistory ''
      spawn-sh-at-startup "wl-paste --type text  --watch cliphist store"
      spawn-sh-at-startup "wl-paste --type image --watch cliphist store"
      ''}

      ${lib.optionalString (cfg.idle.lockAfterSeconds != null) ''
      spawn-sh-at-startup "swayidle -w timeout ${toString cfg.idle.lockAfterSeconds} '${cfg.lockCommand} -f'${lib.optionalString (cfg.idle.suspendAfterSeconds != null) " timeout ${toString cfg.idle.suspendAfterSeconds} 'systemctl suspend'"} before-sleep '${cfg.lockCommand} -f' lock '${cfg.lockCommand} -f' unlock 'pkill -USR1 ${cfg.lockCommand}'"
      ''}

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
          Mod+Shift+Slash { show-hotkey-overlay; }

          Mod+T hotkey-overlay-title="Open a Terminal" { spawn "${cfg.terminal}"; }
          Mod+D hotkey-overlay-title="Run an Application" { spawn "${cfg.launcher}"; }
          Super+Alt+L hotkey-overlay-title="Lock the Screen" { spawn "${cfg.lockCommand}"; }

          ${if cfg.osd == "swayosd" then ''
          XF86AudioRaiseVolume allow-when-locked=true { spawn "${osdClient}" "--output-volume=raise"; }
          XF86AudioLowerVolume allow-when-locked=true { spawn "${osdClient}" "--output-volume=lower"; }
          XF86AudioMute        allow-when-locked=true { spawn "${osdClient}" "--output-volume=mute-toggle"; }
          XF86AudioMicMute     allow-when-locked=true { spawn "${osdClient}" "--input-volume=mute-toggle"; }
          '' else ''
          XF86AudioRaiseVolume allow-when-locked=true { spawn-sh "wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.1+ -l 1.0"; }
          XF86AudioLowerVolume allow-when-locked=true { spawn-sh "wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.1-"; }
          XF86AudioMute        allow-when-locked=true { spawn-sh "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"; }
          XF86AudioMicMute     allow-when-locked=true { spawn-sh "wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle"; }
          ''}

          XF86AudioPlay allow-when-locked=true { spawn-sh "playerctl play-pause"; }
          XF86AudioStop allow-when-locked=true { spawn-sh "playerctl stop"; }
          XF86AudioPrev allow-when-locked=true { spawn-sh "playerctl previous"; }
          XF86AudioNext allow-when-locked=true { spawn-sh "playerctl next"; }

          ${if cfg.osd == "swayosd" then ''
          XF86MonBrightnessUp   allow-when-locked=true { spawn "${osdClient}" "--brightness=raise"; }
          XF86MonBrightnessDown allow-when-locked=true { spawn "${osdClient}" "--brightness=lower"; }
          '' else ''
          XF86MonBrightnessUp   allow-when-locked=true { spawn "brightnessctl" "--class=backlight" "set" "+10%"; }
          XF86MonBrightnessDown allow-when-locked=true { spawn "brightnessctl" "--class=backlight" "set" "10%-"; }
          ''}

          Mod+O repeat=false { toggle-overview; }
          Mod+Q repeat=false { close-window; }

          Mod+Left  { focus-column-left; }
          Mod+Down  { focus-window-or-workspace-down; }
          Mod+Up    { focus-window-or-workspace-up; }
          Mod+Right { focus-column-right; }
          Mod+H     { focus-column-left; }
          Mod+J     { focus-window-or-workspace-down; }
          Mod+K     { focus-window-or-workspace-up; }
          Mod+L     { focus-column-right; }

          Mod+Ctrl+Left  { move-column-left; }
          Mod+Ctrl+Down  { move-window-down-or-to-workspace-down; }
          Mod+Ctrl+Up    { move-window-up-or-to-workspace-up; }
          Mod+Ctrl+Right { move-column-right; }
          Mod+Ctrl+H     { move-column-left; }
          Mod+Ctrl+J     { move-window-down-or-to-workspace-down; }
          Mod+Ctrl+K     { move-window-up-or-to-workspace-up; }
          Mod+Ctrl+L     { move-column-right; }

          Mod+Home { focus-column-first; }
          Mod+End  { focus-column-last; }

          Mod+Page_Down { focus-workspace-down; }
          Mod+Page_Up   { focus-workspace-up; }
          Mod+U         { focus-workspace-down; }
          Mod+I         { focus-workspace-up; }

          Mod+1 { focus-workspace 1; }
          Mod+2 { focus-workspace 2; }
          Mod+3 { focus-workspace 3; }
          Mod+4 { focus-workspace 4; }
          Mod+5 { focus-workspace 5; }
          Mod+6 { focus-workspace 6; }
          Mod+7 { focus-workspace 7; }
          Mod+8 { focus-workspace 8; }
          Mod+9 { focus-workspace 9; }

          Mod+BracketLeft  { consume-or-expel-window-left; }
          Mod+BracketRight { consume-or-expel-window-right; }
          Mod+Comma  { consume-window-into-column; }
          Mod+Period { expel-window-from-column; }

          Mod+R { switch-preset-column-width; }
          Mod+Shift+R { switch-preset-column-width-back; }

          Mod+F { maximize-column; }
          Mod+Shift+F { fullscreen-window; }
          Mod+M { maximize-window-to-edges; }
          Mod+C { center-column; }

          Mod+Minus { set-column-width "-10%"; }
          Mod+Equal { set-column-width "+10%"; }

          Mod+V       { toggle-window-floating; }
          Mod+Shift+V { switch-focus-between-floating-and-tiling; }

          ${lib.optionalString cfg.clipboardHistory ''Mod+Alt+V { spawn-sh "cliphist list | ${cfg.launcher} --dmenu | cliphist decode | wl-copy"; }''}

          Mod+W { toggle-column-tabbed-display; }

          Print { screenshot; }
          Ctrl+Print { screenshot-screen; }
          Alt+Print { screenshot-window; }

          Mod+Escape allow-inhibiting=false { toggle-keyboard-shortcuts-inhibit; }
          Mod+Shift+E { quit; }
          Mod+Shift+P { power-off-monitors; }

          ${cfg.extraBinds}
      }

      ${cfg.extraTopLevel}
    '';
  };
}
