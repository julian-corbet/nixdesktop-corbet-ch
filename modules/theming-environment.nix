# modules/theming-environment.nix — the system-manager counterpart to the `QT_QPA_PLATFORMTHEME`
# wiring `modules/nixos-backend.nix` adds beside its `programs.thunar`/`xdg.portal` writes: the
# `theming` role installs `qt6ct` (nixarch's own resolution table, `nixarch.desktopBackend`'s Arch
# half of the split `modules/system-manager/desktop.nix` in the infra checkout documents) and,
# exactly as on NixOS, a Qt platform-theme CONFIGURATOR nothing points at configures nothing — Qt
# only loads the platform theme named by `QT_QPA_PLATFORMTHEME`, which nothing on a bare Wayland
# session sets on its own.
#
# WHY THIS IS ITS OWN FILE, NOT ONE MORE LINE IN `modules/nixos-backend.nix` OR A "BOTH PLANES, NO
# SPLIT NEEDED" MODULE LIKE `modules/oo7-credential.nix`. That shared shape works when the SAME
# config renders identically on both module trees (a plain `systemd.services` oneshot does — see
# that file's own header). This one cannot use it: `environment.sessionVariables` is NOT a
# plane-neutral choice here, even though the option exists — byte-identical name — on both. On
# NixOS it is documented as PAM-injected ("these variables will be set by PAM early in the login
# process", `nixos/modules/config/system-environment.nix`), which is what reaches a session started
# through `PAMName=` (nixdesktop.launcher's seated-unit shape, the one every host that turns
# `theming` on actually runs). system-manager's OWN vendored copy of the same-named option states
# the opposite of itself, in its own doc comment: "unlike NixOS, system-manager does not manage PAM
# on the host, so these variables are not injected by pam_env into non-shell sessions (e.g.
# graphical logins)" (`system-manager/nix/modules/environment.nix`). Confirmed live, not merely
# read off that comment: the Elitebook's actual PAM stack for `PAMName = "login"` resolves through
# `/etc/pam.d/login` -> `system-local-login` -> `system-login`, which ends in an unconditional
# `session required pam_env.so` with no `envfile=` override — pam_env's own default in that
# configuration is to read the FLAT `/etc/environment` file, not the `environment.d/*.conf`
# directory system-manager's `environment.sessionVariables` actually writes to
# (`environment.etc."environment.d/10-system-manager.conf"`, consulted only by `systemd --user`'s
# OWN environment generator per `environment.d(5)` — a completely different reader, for a
# completely different unit class than the seated PAMName= unit the compositor itself runs as).
# So on system-manager, `environment.sessionVariables.QT_QPA_PLATFORMTHEME` would render into a
# file this estate's actual PAM stack never reads, and the bug this file exists to fix would
# survive unchanged behind an option that LOOKS like the fix.
#
# THE ACTUAL FIX: write the literal `/etc/environment` file pam_env already reads, via
# `environment.etc.environment` directly — the one write that is genuinely plane-specific rather
# than a shared option with two different, silently-diverging meanings.
#
# `replaceExisting = true`, NOT the option's own `false` default, and that default is exactly why
# this needs stating rather than leaving implicit: `/etc/environment` is not a nixdesktop-owned
# path materializing for the first time — it ships as part of Arch's own `filesystem`/`pambase`
# packaging (confirmed live on the Elitebook: a real file already sits there, its content the
# stock pambase header comment, "This file is parsed by pam_env module ..."). Leaving
# `replaceExisting` at its default on a target that already exists is precisely the case that
# option's own doc names — system-manager backs the pre-existing file up and refuses to converge
# without being told to replace it outright, so an unset `replaceExisting` here would not be a
# smaller, safer version of this fix; it would be a build-time refusal the first time this module
# ever activates on a host that has ever booted Arch.
{ lib, config, ... }:
{
  config = lib.mkIf (config.nixdesktop.want.theming or false) {
    environment.etc.environment = {
      text = "QT_QPA_PLATFORMTHEME=qt6ct\n";
      replaceExisting = true;
    };
  };
}
