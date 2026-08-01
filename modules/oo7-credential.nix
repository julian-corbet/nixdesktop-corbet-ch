# modules/oo7-credential.nix — provisions the systemd credential oo7-daemon needs to unlock a
# Secret Service keyring with NO typed password, exactly once, idempotently, at the SYSTEM level
# (a root-run oneshot) — the first of the two mechanisms `home/session.nix`'s own `keyring.oo7`
# option group cannot supply by itself (see that file's header, "oo7: THE org.freedesktop.secrets
# PROVIDER" and its `credential` sub-option's own doc): a home-manager module runs AS THE USER, and
# generating this credential means writing a root-owned encryption operation whose OUTPUT then has
# to be handed over (`chown`) to a user who is not the one running it. That is inherently a
# system-layer act on every host that has ever needed it (`hosts/nixnas-devhome.nix`,
# `hosts/archlxc/keyring.nix`, `hosts/elitebook/keyring.nix` in the infra checkout this ports
# from), and every one of those three hosts hand-rolled it — this file is the mechanism, so the
# next host only supplies values.
#
# ONE MODULE, BOTH PLANES, NO SPLIT NEEDED. Unlike the keyring-bootstrap half of this same problem
# (`modules/oo7-keyring-bootstrap.nix`, NixOS-only — see that file's own header for why), this one
# needs nothing beyond `systemd.services` — a plain root-run oneshot — which flake.nix's own
# `nixosModules.launcher`/`systemManagerModules.launcher` comment already establishes renders
# through the IDENTICAL nixpkgs unit code on system-manager as on NixOS (confirmed there by reading
# numtide/system-manager's own `nix/modules/systemd.nix`, not assumed). So this file is exported as
# BOTH `nixosModules.oo7Credential` and `systemManagerModules.oo7Credential` in `flake.nix`, the
# same pattern `sessionModule`/`monitors`/`layouts` already use for policy that touches nothing
# platform-specific — this module is the first one in that shared category to touch `pkgs` and
# `systemd.services` and still not need a plane split.
#
# ── THE THREE MEASURED FACTS THIS SCRIPT ENCODES (all cost real debugging time on a live host;
# see hosts/nixnas-devhome.nix's own "oo7: values the keyring block below needs by name" and
# "CREDENTIAL DELIVERY, MEASURED, NOT ASSUMED" comments in the infra checkout for the full account
# of each, including exact error text) ──────────────────────────────────────────────────────────
#
#   1. THE CREDENTIAL MUST LIVE IN THE USER'S OWN `~/.config/credstore.encrypted/`, NEVER THE
#      SYSTEM-WIDE `/etc/credstore.encrypted/`. A `--user` unit's `ImportCredential=`/
#      `LoadCredentialEncrypted=` is resolved by the UNPRIVILEGED per-user manager itself
#      (`user@<uid>.service`, running as that user, never as root) — and systemd's own upstream
#      `tmpfiles.d` default leaves `/etc/credstore.encrypted` `0700 root root`, which that
#      unprivileged manager structurally cannot `open()`. Measured live, twice, on a real host:
#      `$CREDENTIALS_DIRECTORY` came back completely empty for a transient `systemd-run --user`
#      probe sourced from the system-wide directory, and again from inside a REAL daemon's own
#      mount namespace (`/proc/<pid>/root/$CREDENTIALS_DIRECTORY`), so this was never a
#      wrong-vantage-point false negative. `$HOME/.config/credstore.encrypted/` is the per-user
#      counterpart `systemd.exec(5)` documents for exactly this case, and it round-trips correctly
#      (proved the same two ways). This module's own `path` option therefore has NO default at all
#      — a consumer pointing it at `/etc/credstore.encrypted/anything` gets a credential that will
#      never import into any `--user` unit, silently, with nothing here able to catch that mistake
#      (it is just a string this module writes to; it cannot see what will try to read it back).
#
#   2. THE UID MUST BE RESOLVED AT RUNTIME (`id -u <user>`), NEVER FROM NIX-EVAL-TIME CONFIG.
#      `config.users.users.<name>.uid` reads back `null` on any host whose account is dynamically
#      allocated (no explicit `uid = N;`) — the allocation happens during system ACTIVATION, after
#      Nix eval has already finished. `toString null` compounds this silently rather than erroring:
#      Nix coerces it to `""` (confirmed: `nix eval --expr 'builtins.toString null'` → `""`), so
#      `--uid=${toString uid}` would render as the syntactically valid but semantically empty
#      `--uid=`, and `systemd-creds encrypt --user --uid=` with nothing after `=` does NOT reject
#      that as an error — it silently drops the `--user` scoping and produces a SYSTEM-scoped blob
#      instead. This was a real, live, load-bearing bug on one host in this estate: a credential
#      produced this way decrypted fine as `systemd-creds decrypt` (no `--uid`, system scope) and
#      failed as `systemd-creds decrypt --uid=1000` with "Encrypted file is scoped to the system,
#      but user scope selected" — i.e. it was never actually user-scoped despite every comment
#      written before that measurement claiming otherwise. This module's own script asks the LIVE
#      system with `id -u`, at the moment it actually runs, never Nix eval.
#
#   3. THE PASSWORD MUST BE base64, TRAILING NEWLINE STRIPPED. Raw `/dev/urandom` bytes are not
#      valid UTF-8 (essentially guaranteed to contain a byte sequence that isn't), and `oo7-cli`'s
#      argument parser rejects that outright ("invalid UTF-8 was detected in one or more
#      arguments") — `base64` makes the plaintext text-safe. The trailing newline matters more
#      subtly: `base64`'s own output always ends in one, and if that newline stayed part of the
#      ENCRYPTED plaintext, a consumer reading it back via `$(cat "$CREDENTIALS_DIRECTORY/...")`
#      (ordinary shell command substitution, which the paired `modules/oo7-keyring-bootstrap.nix`
#      and `home/session.nix`'s own bootstrap convenience both use) would silently STRIP it, while
#      oo7-daemon's own credential read does not — two consumers of the identically-encrypted
#      credential ending up using two DIFFERENT effective passwords, one with a trailing newline
#      and one without, and whichever bootstraps the keyring FILE first would leave it unable to
#      unlock for the other. Stripped at the SOURCE, once, here, so every consumer looking at this
#      credential sees the exact same bytes.
#
# ── WHY EVERY BINARY BELOW IS A BARE NAME, RESOLVED VIA `PATH=`, NEVER `${pkgs.x}/bin/y` ────────
# This is the one place this module makes an explicit, considered choice rather than leaving it
# a consumer value, and it is the direct answer to "aim for ONE mechanism that both planes
# consume": `systemd-creds encrypt --with-key=host` must be run by the SAME systemd that will later
# decrypt it (the live, running PID1 on that exact host) — on NixOS that IS nixpkgs' own systemd
# (no mismatch risk, `${pkgs.systemd}/bin/systemd-creds` would be identical to what PATH finds
# anyway), but on a system-manager/Arch host the LIVE systemd is the DISTRO's own package, and
# nixpkgs' pinned `pkgs.systemd` version is not guaranteed to speak an identical on-disk credential
# format — using it to ENCRYPT would risk producing a blob the host's own, different, REAL systemd
# cannot decrypt later. Rather than branch this module's own Nix code on which plane it is
# composed into (which is exactly the kind of per-plane duplication "one mechanism" exists to
# avoid), `Environment = "PATH=..."` below lists BOTH planes' canonical binary locations in one
# fixed, portable value — `/run/current-system/sw/bin` (NixOS's own system profile, where its
# `systemd`/`coreutils` always are) ahead of `/usr/bin`/`/bin` (where a real Arch/system-manager
# host's own always are) — and PATH resolution alone picks whichever actually exists on the live
# host, with zero Nix-level branching and zero package name (`coreutils`, `systemd`) this file
# would otherwise have to hardcode. `oo7-cli`/`oo7-daemon` themselves are NOT resolved this way —
# see `home/session.nix`'s own `keyring.oo7.command`/`credential.bootstrap.oo7CliCommand` options
# for why those two specifically stay consumer-supplied values instead (their install location is
# genuinely platform-specific in a way base coreutils and systemd itself are not: nixpkgs'
# `oo7-server` installs the daemon to `$out/libexec/oo7-daemon`, off PATH by construction, and this
# module never touches oo7 itself at all — only the credential oo7-daemon later reads).
{ lib, config, pkgs, ... }:
let
  cfg = config.nixdesktop.oo7.credential;

  # Both planes' canonical bin dirs, NixOS's own system profile first — see the header's own
  # account of why this single value is the whole "one mechanism, no plane branch" trick.
  sharedPath = lib.concatStringsSep ":" [
    "/run/current-system/sw/bin"
    "/usr/local/sbin"
    "/usr/local/bin"
    "/usr/sbin"
    "/usr/bin"
    "/sbin"
    "/bin"
  ];

  # The script TEXT, computed here rather than inline inside `pkgs.writeShellScript` below, so it
  # is ALSO reachable as a plain string via `renderedScript` (an option, further down) without
  # forcing a build. This matters for more than symmetry with `deviceFence` (modules/launcher.nix's
  # own "read the policy without parsing a rendered unit" precedent): `checks/oo7-provisioning.nix`
  # asserts on the three measured facts this script encodes by matching substrings of this exact
  # value, and `nix flake check` evaluates flakes in PURE mode, where reading a derivation's build
  # OUTPUT back via `builtins.readFile` is import-from-derivation and structurally unavailable —
  # so a check that needs to see this content has no way to ask the built `ExecStart` derivation
  # for it. A plain string option sidesteps that entirely: nothing about it needs building.
  scriptText = ''
    set -euo pipefail
    install -d -m 0700 -o ${lib.escapeShellArg cfg.user} -g ${lib.escapeShellArg cfg.user} \
      "$(dirname ${lib.escapeShellArg cfg.path})"
    umask 077

    # Fact 2 (header comment): the live system, not Nix eval.
    uid=$(id -u ${lib.escapeShellArg cfg.user})

    # Fact 3 (header comment): base64 for UTF-8 safety, trailing newline stripped so every
    # consumer of this credential sees identical bytes. Piped straight from /dev/urandom through
    # systemd-creds via stdin ("-") so the plaintext is never written to disk unencrypted at any
    # point. --user --uid=, never the plain host-key form (fact 2's own consequence) --
    # --with-key=host, never tpm2: the host key (/var/lib/systemd/credential.secret) lives on the
    # same LUKS-encrypted volume the disk passphrase already unlocks at boot on a real host, so
    # this credential is decryptable only there and only after that passphrase, with no TPM
    # anywhere in the chain.
    head -c 32 /dev/urandom | base64 | tr -d '\n' \
      | systemd-creds encrypt --user --uid="$uid" --with-key=host \
          --name=${lib.escapeShellArg cfg.name} - ${lib.escapeShellArg cfg.path}

    chown ${lib.escapeShellArg cfg.user}:${lib.escapeShellArg cfg.user} ${lib.escapeShellArg cfg.path}

    echo "[oo7-credential] generated ${cfg.path} (user-scoped, uid=$uid, host-key-encrypted)"
  '';
in
{
  options.nixdesktop.oo7.credential = {
    enable = lib.mkEnableOption ''
      provision the oo7 keyring-encryption-password systemd credential for `user` at the system
      level, idempotently (a root-run oneshot, gated on `path` not already existing — never
      regenerated once it exists, since the plaintext it wraps is genuinely the password that
      unlocks an already-encrypted keyring: overwriting it after the fact would brick the keyring,
      not rotate a credential cleanly). Renders `systemd.services."oo7-credential-provision-<user>"`.
      See the header comment for the three measured facts this script encodes and why this one
      module serves BOTH the NixOS and the system-manager plane with no split.

      Pairs with the KEYRING-FILE bootstrap step, a separate concern this module does not cover:
      on a host with home-manager composed, `home/session.nix`'s own `keyring.oo7.credential.
      bootstrap` (a `--user` unit, structurally reachable only via home-manager or plain NixOS —
      see `modules/oo7-keyring-bootstrap.nix`'s own header for why system-manager alone cannot
      render one); on a host with none, `nixdesktop.oo7.keyringBootstrap` (NixOS-only, this
      repo's own system-level equivalent).
    '';

    user = lib.mkOption {
      type = lib.types.str;
      example = "richc";
      description = ''
        The account whose own `--user` manager will later import this credential. Also names the
        rendered service (`oo7-credential-provision-<user>`) and is resolved to a live uid AT
        SCRIPT-RUN TIME via `id -u` — never read back from `config.users.users.<user>.uid`, which
        is `null` at Nix-eval time on any host with no explicit `uid = N;` for that account (see
        the header comment, fact 2, for the silent-corruption failure mode that produced).
      '';
    };

    path = lib.mkOption {
      type = lib.types.str;
      example = "/home/richc/.config/credstore.encrypted/oo7.keyring-encryption-password";
      description = ''
        Where the user-scoped encrypted blob lands. MUST be under that user's own
        `~/.config/credstore.encrypted/`, never `/etc/credstore.encrypted/` — see the header
        comment, fact 1, for the live-measured reason a `--user` unit cannot read the latter at
        all. NO DEFAULT: this module has no opinion on that user's home directory (a plain
        `/home/<user>` default would be WRONG the moment any host's home layout differs, and
        getting it wrong here fails SILENTLY — a credential written to a path nothing ever reads
        back from — which is worse than a build-time error over guessing).
      '';
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "oo7.keyring-encryption-password";
      description = ''
        The credential ID. NOT a free naming choice — this is oo7-server's OWN fixed contract
        (its README: "the daemon will try to load a credential named
        `oo7.keyring-encryption-password`"; confirmed a second way in its packaged 0.6.0 unit's own
        unconditional `ImportCredential=oo7.keyring-encryption-password` line). Change this only if
        a future oo7 release renames its own contract, and confirm against that release's own
        source first.
      '';
    };

    # READ-ONLY, computed. See `scriptText`'s own comment (above, in the `let`) for why this
    # exists: it is what lets a check (or an operator debugging live, without decrypting anything)
    # read the exact provisioning script's text without needing to build the real `ExecStart`
    # derivation first -- the same "read the policy without parsing a rendered unit" precedent
    # `modules/launcher.nix`'s own `deviceFence` already established for this repo.
    #
    # NOT gated on `cfg.enable` itself -- a consumer who set `user`/`path` but left `enable =
    # false` (say, staging a value ahead of flipping the switch) can still read this back. It IS,
    # unavoidably, still gated on `user`/`path` actually being SET: both are mandatory options with
    # no default (see their own docs for why a default would be actively wrong), so reading this
    # option while they are unset throws the same "used but not defined" error reading `cfg.user`
    # anywhere else in this module would -- exactly as it should: a script this repo cannot
    # honestly render without knowing who it is for is not something a default should paper over.
    renderedScript = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      description = ''
        The exact shell script text `ExecStart` wraps via `pkgs.writeShellScript`, exposed as a
        plain string for inspection without building anything -- see this file's own header for
        the three measured facts it encodes.
      '';
    };
  };

  config = lib.mkMerge [
    { nixdesktop.oo7.credential.renderedScript = scriptText; }
    (lib.mkIf cfg.enable {
      systemd.services."oo7-credential-provision-${cfg.user}" = {
        description = "Generate ${cfg.user}'s oo7 keyring-encryption-password credential, once (idempotent, non-destructive)";
        # Runs at boot (multi-user.target is reached well before any seated/graphical session on
        # every host this has been ported to) so the credential exists before anything user-side
        # ever tries to load it. A host whose own session unit races this ordinary boot order (an
        # autologin unit started unusually early, say) should add its own explicit `wants`/`after`
        # onto `systemd.services."oo7-credential-provision-${cfg.user}"` from its own config -- this
        # module cannot know that host's own session unit's name, so it does not guess one.
        wantedBy = [ "multi-user.target" ];
        unitConfig.ConditionPathExists = "!${cfg.path}";
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          Environment = "PATH=${sharedPath}";
          # Runs as root (no User= override) -- root writing INTO the target user's home is fine;
          # `scriptText`'s own `install -o/-g` and `chown` are what hand ownership over, since
          # neither `install -d` nor `systemd-creds encrypt` infers it from the containing
          # directory, and leaving both at their defaults would land root:root -- silently
          # recreating the exact unreadable-by-the-user-manager failure this mechanism exists to
          # avoid.
          ExecStart = pkgs.writeShellScript "oo7-credential-provision-${cfg.user}" scriptText;
        };
      };
    })
  ];
}
