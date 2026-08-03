# modules/oo7-keyring-bootstrap.nix — closes the SECOND gap `home/session.nix`'s own `keyring.oo7`
# option group cannot: even with `modules/oo7-credential.nix` provisioning a readable credential,
# oo7-daemon 0.6.0 will not conjure a brand-new encrypted keyring from it on its own (see below).
# NixOS-ONLY, deliberately — read "WHY THIS IS THE ONE GENUINELY IRREDUCIBLE SPLIT" below before
# reaching for this on a system-manager host.
#
# ── THE GAP, MEASURED, NOT ASSUMED (ported from this module's own private per-host predecessor's
# "The bootstrap gap" section in the infra checkout — the live account this module generalises) ──
# On a data directory with no keyring file present, a correctly-credentialed oo7-daemon logs
# "Unlocking session keyring with user's systemd credentials" (it DID read the credential),
# immediately followed by "No default collection found, creating 'Login' keyring" / "Keyring file
# not found, creating a new one" / "Created default 'Login' collection (locked)" — the credential
# is read and then simply has nothing to unlock, so the daemon falls back to an in-memory LOCKED
# placeholder collection (`oo7::file::locked_keyring`, a distinct type from a real file-backed
# `Keyring` a password can unlock) that stays `Locked = true` regardless. `oo7-cli unlock -s ""`
# against it fails outright ("Keyring file doesn't support unlocking"), and a `store` call opens a
# D-Bus Prompt and blocks forever waiting for a `Completed` signal nothing on a headless/autologin
# host ever sends — no portal, no GUI, and the systemd credential is never consulted by that code
# path at all.
#
# THE FIX, proved live end-to-end: `oo7-cli -k <path> -s <password> repair` talks directly to a
# keyring FILE and never touches D-Bus or a Prompt at all — it creates a real, empty,
# password-encrypted keyring file with zero round-trip (a fresh path with no items needed came back
# "0 broken items were deleted", genuinely AES-encrypted, and a wrong password on lookup fails with
# "Item is not valid and cannot be decrypted" rather than silently succeeding). Land that file at
# the exact well-known path oo7-daemon's own startup scan looks for, BEFORE oo7-daemon ever starts,
# and its normal startup path (scan → find → unlock, zero prompts) takes over from there.
#
# ── WHY THIS IS THE ONE GENUINELY IRREDUCIBLE SPLIT, NOT A CONVENIENCE CHOICE ────────────────────
# This mechanism needs `systemd.user.services` — a `--user` unit, since oo7-daemon.service (nixpkgs'
# `services.oo7.enable`) is itself one, and `LoadCredentialEncrypted=`/ordering only compose against
# units in the SAME manager instance (see `home/session.nix`'s own `loadCredentialEncrypted` option
# doc and `modules/launcher.nix`'s header for the identical cross-manager-boundary fact). NixOS can
# render `systemd.user.services` DIRECTLY at the system level, with no home-manager involved at all
# — this module is exactly that, and this estate's own bare NixOS system with no home-manager
# composed for its user anywhere is the live proof it works. system-manager CANNOT:
# `modules/launcher.nix`'s own header states this as a read-from-source fact, not an assumption —
# "system-manager renders `systemd.services`... identically to NixOS... [but] has no
# `systemd.user.services` anywhere in its module tree" — and `checks/launcher.nix`'s own
# `systemHostStubSystemManager` fixture exists specifically to keep that absence provable rather
# than accidentally reintroduced. So a system-manager/Arch host has exactly ONE path to a `--user`
# unit at all: home-manager, layered on top as a genuinely separate module system — which is why
# THAT plane's equivalent of this mechanism is `home/session.nix`'s own `keyring.oo7.credential.
# bootstrap` convenience instead, not this file. Two module-system entry points, sharing the
# identical measured facts and the identical `oo7-cli ... repair` invocation shape, is the smallest
# split this gap actually forces — not two independently reinvented ones.
#
# ── WHAT THIS MODULE DELIBERATELY DOES NOT DO ────────────────────────────────────────────────────
# It does not declare `services.oo7.enable` or anything about the daemon unit itself — that is
# nixpkgs' own module (`nixos/modules/services/desktops/oo7.nix`), a host's job to turn on, and
# outside this repo's remit to duplicate (see `lib/nixos-roles.nix`'s own header for the parallel
# "this file states the fact, not the package" boundary). It only wires `wants`/`after` onto
# whichever unit `daemonServiceName` names, so the consuming host must actually have one — the same
# "hosts supply values" split every other role in this repo already draws.
{ lib, config, pkgs, ... }:
let
  cfg = config.nixdesktop.oo7.keyringBootstrap;

  # The script TEXT, separated out for the identical reason `modules/oo7-credential.nix`'s own
  # `scriptText` is: it is ALSO exposed as a plain string via the `renderedScript` option below, so
  # `checks/oo7-provisioning.nix` (and an operator inspecting a host live) can read it without
  # forcing a build of the real `ExecStart` derivation, which `nix flake check`'s pure evaluation
  # cannot do (import-from-derivation is unavailable there) -- see that sibling file's own comment
  # for the fuller account.
  scriptText = ''
    set -euo pipefail
    install -d -m 0700 "$(dirname ${lib.escapeShellArg cfg.keyringPath})"
    ${cfg.oo7CliCommand} -k ${lib.escapeShellArg cfg.keyringPath} \
      -s "$(cat "$CREDENTIALS_DIRECTORY/${cfg.credentialName}")" \
      repair
  '';
in
{
  options.nixdesktop.oo7.keyringBootstrap = {
    enable = lib.mkEnableOption ''
      run `oo7-cli -k <keyringPath> -s <password> repair` once, at system level, gated on
      `keyringPath` not already existing, ordered strictly before `<daemonServiceName>.service` —
      see the header comment for the gap this closes and why it is a NixOS-only mechanism (a
      system-manager host needs `home/session.nix`'s own `keyring.oo7.credential.bootstrap`
      instead, the one case in this migration where the NixOS and Arch/system-manager planes
      genuinely cannot share a single module).

      Pairs with `nixdesktop.oo7.credential.enable` (a separate, plane-shared module — see that
      option's own doc) for the credential this reads via `credentialName`/`credentialPath`; this
      module does not provision that credential itself, only consumes it.
    '';

    keyringPath = lib.mkOption {
      type = lib.types.str;
      example = "/home/alice/.local/share/keyrings/login.keyring";
      description = ''
        The keyring FILE to create if (and only if) it does not exist yet — the exact well-known
        path oo7-daemon's own startup scan looks for. NO DEFAULT: the filename is not fixed across
        hosts (gnome-keyring's own convention names the default collection `login.keyring`, and
        oo7 stays compatible with that — confirmed live via oo7-daemon's own DEBUG log, "Found v0
        keyring: login" — but a host migrated from a differently-named collection, e.g. an existing
        `Default_keyring.keyring` already holding real secrets, must point here instead). This
        mechanism only ever CREATES an empty keyring at a path that does not yet exist; it never
        touches, renames, or shadows one already there under a different name — point this at the
        file that is actually meant to be the login keyring, never at a fresh name alongside it.
      '';
    };

    oo7CliCommand = lib.mkOption {
      type = lib.types.str;
      example = lib.literalExpression ''"''${pkgs.oo7}/bin/oo7-cli"'';
      description = ''
        `oo7-cli` invocation. NO DEFAULT, deliberately — this repo names no package (see
        `lib/nixos-roles.nix`'s own header); `oo7-cli`'s install location is a value the consuming
        host supplies. On nixpkgs' own `oo7` package it installs to `$out/bin/oo7-cli`, on PATH —
        unlike `oo7-daemon` itself (`$out/libexec/oo7-daemon`, off PATH; see `lib/nixos-roles.nix`'s
        `keyrings.oo7.command` for that verified finding) — so `"${pkgs.oo7}/bin/oo7-cli"` (or, on a
        host where it is already on PATH some other way, a bare `"oo7-cli"`) both work; this option
        stays mandatory anyway rather than special-casing the one binary that happens to resolve via
        PATH, matching `home/session.nix`'s own `keyring.oo7.command` convention.
      '';
    };

    credentialName = lib.mkOption {
      type = lib.types.str;
      default = "oo7.keyring-encryption-password";
      description = ''
        The credential ID to read via `LoadCredentialEncrypted=`. Matches
        `nixdesktop.oo7.credential.name`'s own default — oo7-server's fixed contract, not a free
        naming choice (see that option's own doc). Change this only alongside the matching
        `nixdesktop.oo7.credential.name`, and only if a future oo7 release renames its own contract.
      '';
    };

    credentialPath = lib.mkOption {
      type = lib.types.str;
      example = "/home/alice/.config/credstore.encrypted/oo7.keyring-encryption-password";
      description = ''
        Where the encrypted credential blob lives on disk — must be the SAME path
        `nixdesktop.oo7.credential.path` (or whatever else provisioned it) actually wrote to. The
        two modules are not cross-wired automatically: a consumer using both states this value
        once in each place, the same deliberate byte-identical-by-hand duplication this module's
        own private per-host sibling home-manager file already documents in its header,
        and for the identical reason — a NixOS system module and this repo's own
        `nixdesktop.oo7.credential` module are two separate option trees with no shared state to
        read the other's value back from, so restating it explicitly beats an implicit coupling
        neither side could verify.
      '';
    };

    daemonServiceName = lib.mkOption {
      type = lib.types.str;
      default = "oo7-daemon";
      description = ''
        The BARE name (no `.service` suffix) of the `systemd.user.services` unit this bootstrap
        step must complete before. Defaults to `"oo7-daemon"` — the exact name nixpkgs' own
        `services.oo7.enable` installs its packaged unit under (`systemd.packages = [
        pkgs.oo7-server ]`, confirmed by reading that module directly). This module wires
        `wants`/`after` onto `systemd.user.services."''${daemonServiceName}"` on top of whatever else
        defines it — it does not declare `services.oo7.enable` itself (see the header comment,
        "WHAT THIS MODULE DELIBERATELY DOES NOT DO"), so a host using this module is expected to
        also turn that on, or to override this to name whatever else actually owns the daemon unit.
      '';
    };

    # See `modules/oo7-credential.nix`'s own `renderedScript` option for why this exists and why
    # it is not gated on `cfg.enable` -- identical reasoning, restated there rather than here.
    renderedScript = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      description = ''
        The exact shell script text `ExecStart` wraps via `pkgs.writeShellScript`, exposed as a
        plain string for inspection without building anything -- see this file's own header for
        the gap it closes.
      '';
    };
  };

  config = lib.mkMerge [
    { nixdesktop.oo7.keyringBootstrap.renderedScript = scriptText; }
    (lib.mkIf cfg.enable {
      systemd.user.services."oo7-keyring-bootstrap" = {
        description = "Create the oo7 login keyring FILE, once, so oo7-daemon's credential-based unlock has something to unlock (idempotent, non-destructive)";
        # Never touches a keyring that already exists -- the only condition under which this is
        # permitted to act at all. A later start with the file present sees the condition fail, is
        # marked "skipped" (not failed), and touches nothing.
        unitConfig.ConditionPathExists = "!${cfg.keyringPath}";
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          LoadCredentialEncrypted = [ "${cfg.credentialName}:${cfg.credentialPath}" ];
          # `-s` only takes the password as a literal argv string -- no stdin form exists (checked:
          # a correct and a wrong password piped via `-s -` behaved identically to the literal
          # string "-", proving it does not consult stdin). ARGV EXPOSURE, ACKNOWLEDGED NOT HIDDEN:
          # the plaintext is briefly visible via `/proc/<pid>/cmdline` for the sub-second life of
          # this one process. Accepted: the only local reader capable of seeing another user's
          # cmdline on a default `hidepid=0` host is root, who already holds this exact plaintext
          # more directly (root encrypted it, and can `systemd-creds decrypt` the credential file
          # at any time) -- this unit's argv adds no new capability to that actor.
          ExecStart = pkgs.writeShellScript "oo7-keyring-bootstrap" scriptText;
        };
        wantedBy = [ "default.target" ];
      };

      # Pulls the bootstrap unit in front of the daemon unit -- an ordinary same-manager,
      # user-to-user edge (both units live in `user@<uid>.service`), unlike the cross-boundary
      # problem a SYSTEM unit gating a --user one would be (see this module's own private per-host
      # predecessor's "ALSO wait for the wrapper itself" section in the infra checkout for that
      # different, harder case, which this module does not attempt to solve -- a host racing its
      # own autologin unit against `suid-sgid-wrappers.service` needs its own host-specific fix,
      # same as that predecessor's own file states plainly rather than papering over). `wants`
      # (soft), not `requires`: a
      # provisioning hiccup should degrade to a daemon with nothing to unlock, visibly, not take a
      # session down.
      systemd.user.services."${cfg.daemonServiceName}" = {
        wants = [ "oo7-keyring-bootstrap.service" ];
        after = [ "oo7-keyring-bootstrap.service" ];
      };
    })
  ];
}
