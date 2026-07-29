# home/noctalia.nix — glue over noctalia-dev/noctalia's own upstream home-manager module
# (imported alongside it by flake.nix's homeManagerModules.noctalia). The upstream module already
# handles package selection, settings.toml/palette generation, and an optional systemd unit --
# this file supplies exactly the two things it doesn't:
#
# 1. THE EGL-VENDOR-ICD FIX. nixpkgs' own Mesa doesn't self-register an EGL vendor ICD the way
#    NixOS's system module does -- any nix-built GPU/EGL client fails outright on a non-NixOS host
#    with `eglGetDisplay failed` unless __EGL_VENDOR_LIBRARY_FILENAMES points at it explicitly.
#    Proven live on an Arch container 2026-07-23: both `eglinfo` and niri itself (nix-built, nested) hit the
#    identical crash; both fixed by the same one variable. With it set, noctalia went on to render
#    a real bar on the real 4K output with a real "AMD Radeon RX 6800 (radeonsi, navi21...) OpenGL
#    ES 3.2 Mesa" context, connected to upower/logind/pipewire/wireplumber/bluetooth cleanly, and
#    shut down without error.
#
# 2. STARTUP. This stack doesn't run a compositor session target that noctalia's own bundled
#    systemd unit could hang PartOf/After off (see home/session.nix for that story on niri), so
#    rather than writing directly into one compositor's own startup option -- which would hard-fail
#    to evaluate for any consumer not importing that compositor's module, and has no path at all
#    for a compositor this repo has never heard of -- this module appends a plain shell command to
#    nixdesktop's own compositor-neutral `nixdesktop.startup` list (home/startup.nix). Whichever
#    compositor module the consumer pairs this with (nixniri, nixscroll, ...) is expected to read
#    `config.nixdesktop.startup` and wrap each entry in its own native startup syntax; see that
#    option's own doc and the README's startup-contract section. The sleep-1 startup-race guard
#    waybar historically needed is baked straight into the command string below.
#    programs.noctalia.systemd.enable is left off.
{ lib, config, pkgs, ... }:
let
  cfg = config.nixdesktop.noctalia;
  eglVendorFix = "__EGL_VENDOR_LIBRARY_FILENAMES=${pkgs.mesa}/share/glvnd/egl_vendor.d/50_mesa.json";
in
{
  imports = [ ./startup.nix ];

  options.nixdesktop.noctalia = {
    enable = lib.mkEnableOption "noctalia v5 as the desktop shell (bar/tray/notifications), replacing waybar+mako";

    networkWidget = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Show the network bar widget. Noctalia's network backend only speaks to NetworkManager,
        wpa_supplicant, or iwd over D-Bus -- confirmed from its own source
        (src/dbus/network/{network_manager,wpa_supplicant,iwd}_service.cpp): there is no
        systemd-networkd backend at all. Set false on hosts that run systemd-networkd instead
        (a common container setup), where the widget would otherwise sit permanently empty for nothing it can
        ever show.
      '';
    };

    settings = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = ''
        Extra noctalia settings (Nix attrset, converted to TOML), merged over this module's own
        bar.main.end default. See programs.noctalia.settings upstream for the full shape.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    programs.noctalia = {
      enable = true;
      settings = lib.mkMerge [
        {
          # Upstream's own default (example.toml) minus "network" when networkWidget = false --
          # not a redesign, just the same list with one entry conditionally dropped.
          bar.main.end =
            [ "media" "tray" "notifications" "clipboard" ]
            ++ lib.optional cfg.networkWidget "network"
            ++ [ "bluetooth" "volume" "brightness" "battery" "control-center" "session" ];
        }
        cfg.settings
      ];
    };

    # Plain shell command, no compositor-specific wrapping -- see home/startup.nix and the
    # header comment above for why this no longer writes into a specific compositor's own
    # namespace.
    nixdesktop.startup = [
      "sleep 1 && ${eglVendorFix} ${lib.getExe config.programs.noctalia.package}"
    ];
  };
}
