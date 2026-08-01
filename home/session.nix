# home/session.nix — turns desktop session components (a bar, a notifier, watchers, an idle
# daemon, a polkit agent, a keyring) into systemd user services, compositor-neutral itself and
# sibling to the other home/*.nix modules in this repo.
#
# THE PROBLEM THIS REPLACES. A compositor's own config module (nixniri's home/niri.nix, say)
# would otherwise emit `spawn-at-startup` / `spawn-sh-at-startup` lines into config.kdl for
# exactly these components. Those run once, at compositor session start, and niri (the
# compositor this was originally verified against) has no way to run them again later. This
# breaks in three concrete ways, all observed on a real running session:
#
#   1. niri live-reloads config.kdl on every change, so a `home-manager switch` updates binds and
#      layout in a running session immediately -- but anything started only via spawn-at-startup
#      keeps running the OLD build (or, if it wasn't running yet, never starts at all), because
#      spawn-at-startup cannot fire into a session that already started. The fix people reach for
#      is "log out and back in", which defeats the entire point of a live-reloading compositor.
#   2. Some of these components need to wait for something else before they make sense to start
#      (a bar needs niri's IPC socket to exist). spawn-sh-at-startup has no ordering primitive, so
#      the config resorts to `sleep 1 && waybar` -- a guess about how long startup takes, not a
#      guarantee.
#   3. A spawn line for a binary that isn't installed fails once, silently, with nothing logged
#      anywhere. There is no `systemctl status` for a spawn-at-startup line -- it simply never
#      happened, and nothing says so.
#
# THE MECHANISM. systemd user services fix all three: `home-manager switch` restarts changed
# services and starts newly-enabled ones as a normal part of activation (this is
# `systemd.user.startServices`, a home-manager option defaulting to true/"sd-switch" -- verified
# via `man 5 home-configuration.nix` on this checkout, not assumed); ordering is a real
# `After=`/`Requires=` graph instead of a sleep; and a missing binary produces a loud, journaled,
# `systemctl --user status`-visible failure instead of nothing at all.
#
# THE ORDERING TARGET. niri ships its own `niri.service` (confirmed by reading the unit shipped
# with the niri package on this machine, not inferred from documentation) with:
#
#   BindsTo=graphical-session.target
#   Before=graphical-session.target
#   Type=notify
#   ExecStart=niri --session
#
# `Type=notify` means systemd does not consider niri.service (and therefore, via BindsTo+Before,
# graphical-session.target) reached until niri itself signals readiness -- a real guarantee, not a
# guess, and the direct fix for the `sleep 1` workaround. `graphical-session.target` is not a
# niri invention: it is a generic systemd target (`man 7 systemd.special`, confirmed present as a
# shipped unit) whose documented contract is "active whenever any graphical session is running...
# used to stop user services which only apply to a graphical session when the session is
# terminated. Such services should have PartOf=graphical-session.target in their [Unit] section."
# The manual's own worked example is a service started by being WantedBy the session's own target;
# this module gets the same effect in the other direction, by putting `WantedBy=` on each
# component instead of `Wants=` on the target -- the man page explicitly names per-service
# `.wants/` symlinks (which is what `Install.WantedBy` produces) as the alternative to a hand-
# maintained `Wants=` list, for exactly this "independently enabled services" case.
#
# Every component below is therefore, by default: `PartOf=graphical-session.target` (stop with the
# session), `After=graphical-session.target` (start only once niri has confirmed it is actually
# ready, replacing the sleep), `WantedBy=graphical-session.target` (pulled in automatically, no
# separate enable step). `graphical-session-pre.target` also exists (services that export
# environment into the whole session before it starts, e.g. an SSH/GPG agent, per the same man
# page) but nothing here uses it: niri's own session script already imports the login manager's
# environment before starting niri.service, and none of the components below need to inject
# environment into sibling processes -- they only need to be running and reachable over D-Bus/IPC,
# which `graphical-session.target` ordering already gives them.
#
# LEAN BY DESIGN, same doctrine as the other home/*.nix modules: `services.<name>` is the
# mechanism (arbitrary command -> systemd unit), and the named blocks below (`bar`, `notifications`,
# ...) are convenience that populate it with commands for the components this desktop actually
# has -- not a different code path. A consumer wanting some other component not listed below adds
# it directly under `services`. The reserved names the convenience blocks use are: `bar`,
# `notifications`, `osd`, `cliphist-text`, `cliphist-image`, `idle`, `polkit-agent`, `keyring`.
#
# Nothing here installs anything, same reasoning as every other module in this project: package
# names and binary paths are platform-specific, so `command` is always a string the consumer (or a
# platform backend, via profiles/desktop.nix) supplies.
{ lib, config, ... }:
let
  cfg = config.nixdesktop.session;

  # ── The swayidle invocation, assembled HERE ────────────────────────────────────────────────
  #
  # Assembled in this module, not in a compositor's own config module, for three reasons:
  #
  #   - swayidle is not compositor-specific in any way. It is a generic wlroots-adjacent idle
  #     daemon, and the invocation is character-for-character identical whether niri or scroll is
  #     running. Nothing about the assembly needs to know which compositor it is under.
  #   - Idle timeouts are POLICY -- "lock after 30 minutes, never suspend" is a statement about the
  #     host, not about a compositor's config syntax. Policy is this repo's whole remit.
  #   - Assembling it per-compositor would not avoid duplication, it would GUARANTEE it: one copy
  #     per compositor repo, N copies for N compositors, each free to drift. Owning it once here is
  #     what actually makes it one place.
  #
  # Bar layout, by contrast, genuinely is the user's business (see waybar.nix's own `settings`
  # attrset) -- a swayidle command line has exactly one correct shape, so there is nothing of the
  # user's to preserve by NOT assembling it centrally.
  #
  # `command` remains available as a verbatim override, for an idle daemon that is not swayidle at
  # all (hypridle, or a hand-rolled script). When it is null -- the default -- the invocation below
  # is used, and when `lockAfterSeconds` is also null there is no idle daemon at all and the service
  # is not created.
  lockBin = cfg.idleAndLock.lockCommand;

  assembledIdleCommand =
    if cfg.idleAndLock.lockAfterSeconds == null
    then null
    else
      "swayidle -w"
      + " timeout ${toString cfg.idleAndLock.lockAfterSeconds} '${lockBin} -f'"
      + lib.optionalString (cfg.idleAndLock.suspendAfterSeconds != null)
        " timeout ${toString cfg.idleAndLock.suspendAfterSeconds} 'systemctl suspend'"
      + " before-sleep '${lockBin} -f'"
      + " lock '${lockBin} -f'"
      # -USR1 tells swaylock to re-show its indicator; the pkill target is the locker's process
      # name, which is why this uses the bare command rather than a path.
      + " unlock 'pkill -USR1 ${lockBin}'";

  effectiveIdleCommand =
    if cfg.idleAndLock.command != null
    then cfg.idleAndLock.command
    else assembledIdleCommand;

  # ── The keyring PROVIDER, assembled HERE ───────────────────────────────────────────────────
  #
  # THE DECISION THIS REPLACES. Until this pass, `keyring` took one bare `command` string (an
  # arbitrary invocation, same shape as `polkitAgent.command`) and hardcoded `serviceType =
  # "forking"; restart = "no";` unconditionally -- correct for gnome-keyring-daemon, the only
  # provider this module had ever run, but silently WRONG the moment a second provider with a
  # different process shape showed up. oo7 IS THE DECISION (operator-mandated): it replaces
  # gnome-keyring as the Secret Service (`org.freedesktop.secrets`) provider on every host that
  # autologins with no PAM auth phase -- see modules/launcher.nix's own header, "DESIGN A", for the
  # full account of why autologin exists at all and why it leaves gnome-keyring only one option,
  # an EMPTY keyring password (secrets unencrypted at rest). oo7's own server README documents a
  # SECOND unlock path -- a systemd credential named `oo7.keyring-encryption-password` -- that
  # needs no typed password at all, so the keyring stays genuinely encrypted on an autologin host.
  # `credential` below is that path, wired exactly as proved live (see its own comment for the
  # proof and the gotcha it uncovered).
  #
  # WHY TWO NAMED BOOLEANS (`oo7.enable` / `gnomeKeyring.enable`), NOT ONE `provider = "oo7" |
  # "gnome-keyring"` ENUM. An enum was the first shape tried and rejected for two concrete reasons:
  #
  #   1. "Exactly one provider may ever be active" is meant to be an ASSERTABLE, catchable
  #      misconfiguration -- a consumer editing a host's config wrong should get a named build
  #      failure, not a silently-accepted last-write-wins value. A `provider` enum cannot express
  #      "two are set" AT ALL (an option holds one value), so there would be nothing to assert --
  #      the failure mode this change exists to make loud would go back to being structurally
  #      unrepresentable, which reads as "solved" but only hides the seam: a consumer who reaches
  #      past the enum into `nixdesktop.session.services.keyring` directly (the same generic
  #      escape hatch every other well-known block documents) can still start a second daemon under
  #      a different unit name with nothing here to notice. Two independent booleans, checked in
  #      `config.assertions` below, make "both on" a real, reachable, caught state instead.
  #   2. Each provider needs its OWN configuration surface -- oo7 has `credential.*` (nothing
  #      remotely like it applies to gnome-keyring), and a future third provider will have its own
  #      shape again. `bar`/`notifications`/`osd` already solve exactly this with one named
  #      `enable`+`command` block per implementation choice (see the header comment's own "reserved
  #      names" list) rather than a closed enum plus scattered `lib.mkIf (provider == "x")` guards
  #      -- `keyring` now follows the same idiom instead of being the one outlier.
  #
  # PROVIDER-SPECIFIC Type=/Restart=, VERIFIED PER PROVIDER, NOT ASSUMED TO MATCH:
  #
  #   gnome-keyring-daemon -- UNCHANGED from before this pass: `Type=forking`/`Restart=no`. See the
  #   `gnomeKeyring` option below for the (unmodified) reasoning, carried over from the original
  #   single-provider `keyring.command` doc.
  #
  #   oo7-daemon -- DOES NOT MATCH gnome-keyring's shape, confirmed by inspecting the REAL package,
  #   not assumed from gnome-keyring's precedent: `nix build nixpkgs#oo7-server` (0.6.0 -- the
  #   exact version the operator's mandate names as the available official package) and reading
  #   both files it ships under `share/systemd/user/oo7-daemon.service`:
  #
  #     [Service]
  #     Type=simple
  #     ExecStart=/run/wrappers/bin/oo7-daemon
  #     Restart=on-failure
  #     ImportCredential=oo7.keyring-encryption-password
  #     ...
  #
  #   `Type=simple`, never forking -- oo7-daemon is a modern, systemd-native Rust daemon that stays
  #   in the foreground; wrapping it in `Type=forking` here would be the EXACT bug gnome-keyring's
  #   own comment warns about for the opposite case (systemd ties unit state to a process that
  #   exits immediately -- for `Type=forking` with no PIDFile that means the FIRST process to exit
  #   in the unit's cgroup, which for a true `Type=simple` daemon is the real, only process, so the
  #   unit would flip to "inactive (dead)" milliseconds after a fully successful start). `Restart=
  #   on-failure`, never `no` -- oo7-daemon is a genuine long-running service meant to survive a
  #   crash and come back, not gnome-keyring's-forking-launcher's one-shot bootstrap step; `no`
  #   would leave a crashed keyring dead for the rest of the session with nothing bringing it back.
  #
  #   NOT COPIED HERE: `ExecStart=/run/wrappers/bin/oo7-daemon` and everything below `Restart=` in
  #   the block above. That path is nixpkgs' own choice (`oo7-server`'s `useWrappedDaemon = true`
  #   default, confirmed in `pkgs/by-name/oo/oo7-server/package.nix`: a `postFixup` step rewrites
  #   the shipped unit's `ExecStart=` from the real store path to that fixed `/run/wrappers/...`
  #   one), and it only resolves to a real binary on a host whose SYSTEM config also declares
  #   `security.wrappers.oo7-daemon` -- confirmed by reading nixpkgs' own paired NixOS module,
  #   `nixos/modules/services/desktops/oo7.nix` (`services.oo7.enable`): it grants the wrapped
  #   binary `CAP_IPC_LOCK` (mlock, so decrypted secrets can never be swapped to disk -- the same
  #   protection gnome-keyring's own daemon gets for free via a plain `mlockall()` call it is
  #   permitted to make as an ordinary unprivileged process using a DIFFERENT mechanism). A
  #   home-manager module has no `pkgs`, no root, and no route to `security.wrappers` -- there is
  #   structurally no way for `nixdesktop.session.keyring.oo7` to reproduce that wrapper from here.
  #   `oo7.command` below therefore points at the real, UNWRAPPED `libexec` path (see that option's
  #   own doc) and runs without `CAP_IPC_LOCK`. Flagged explicitly, not silently accepted as
  #   equivalent: a host that needs the mlock guarantee should prefer NixOS's own `services.oo7`
  #   over this module for the keyring role specifically, or accept the gap knowingly.
  #
  # THE CREDENTIAL DIRECTIVE: `LoadCredentialEncrypted=`, NOT UPSTREAM'S OWN `ImportCredential=`.
  # The unit text above shows oo7-daemon's OWN packaged unit already carries
  # `ImportCredential=oo7.keyring-encryption-password` unconditionally -- a systemd directive that
  # searches a small set of WELL-KNOWN credential-store directories (`/etc/credstore.encrypted`,
  # `$XDG_CONFIG_HOME/credstore.encrypted` for a user manager, per `systemd.exec(5)`) for a file
  # matching that name and imports it if present, silently skipping it otherwise. This module's own
  # `credential` option (see below) renders `LoadCredentialEncrypted=<id>:<path>` instead -- an
  # explicit id+path, not a glob over a search path -- because that is the EXACT directive the live
  # proof this pass implements actually exercised end-to-end on corbet-server (`systemd-run --user`
  # with `LoadCredentialEncrypted=` against a `--user --uid=1000`-scoped blob), and this module has
  # no way to guarantee a consumer's credential lands in one of `ImportCredential=`'s well-known
  # directories rather than wherever their own provisioning chose to put it. A consumer who DOES
  # keep the file at oo7's own default search location gets identical behaviour either way, since
  # oo7-daemon's packaged unit's `ImportCredential=` line fires independently of anything this
  # module renders -- the two are complementary belt-and-braces, not competing.
  keyringProviderCommand =
    if cfg.keyring.oo7.enable then cfg.keyring.oo7.command
    else if cfg.keyring.gnomeKeyring.enable then cfg.keyring.gnomeKeyring.command
    else null;

  effectiveKeyringCommand =
    if cfg.keyring.command != null
    then cfg.keyring.command
    else keyringProviderCommand;

  # See the header block above for why these two differ per provider, verified against the real
  # packaged units rather than assumed identical. Falls through to gnome-keyring's own shape
  # (`forking`/`no`) whenever oo7 specifically is not the one enabled -- this is also the fallback
  # for a consumer using the `command` escape hatch with neither box ticked, preserving this
  # module's pre-existing behaviour for anyone not opting into oo7.
  keyringServiceType = if cfg.keyring.oo7.enable then "simple" else "forking";
  keyringRestart = if cfg.keyring.oo7.enable then "on-failure" else "no";

  # `LoadCredentialEncrypted=` entries for the rendered unit -- populated from `oo7.credential.*`
  # when that convenience is enabled, empty otherwise (which `toSystemdUnit` below renders as no
  # directive at all, same as an empty `environment`). A plain attrset, not gated on
  # `cfg.keyring.oo7.enable` here -- the credential sub-option is namespaced under `oo7` already
  # (nested under a disabled `oo7.enable` it can still be defined but inert, since nothing reads it
  # unless `credential.enable` is also true), so re-checking the parent here would only duplicate
  # that guard, not add a new one.
  keyringLoadCredentialEncrypted =
    lib.optionalAttrs cfg.keyring.oo7.credential.enable {
      ${cfg.keyring.oo7.credential.name} = cfg.keyring.oo7.credential.path;
    };

  # systemd's own ExecStart= line grammar is NOT shell quoting (`man 7 systemd.syntax`, section
  # QUOTING, confirmed locally): a whole item can be wrapped in single OR double quotes, and
  # within a quoted span backslash introduces a small fixed set of C-style escapes, one of which
  # is literally `\'` for a single quote. `lib.escapeShellArg` produces POSIX shell quoting, which
  # is a different dialect (its embedded-quote trick relies on shell concatenating adjacent quoted
  # and unquoted spans, a mechanism systemd's parser does not have) -- using it here would be
  # reaching for the wrong tool. This escapes only what systemd's own grammar treats specially.
  escapeExecArg = s:
    "'" + builtins.replaceStrings [ "\\" "'" ] [ "\\\\" "\\'" ] s + "'";

  # Whether a command needs `sh -c` is not only "does it have a pipe": swayidle's own argument
  # syntax needs multi-word lock commands grouped into one argument each (`lock 'swaylock -f'`),
  # which is shell quoting, not a pipe, and equally requires a shell to do the grouping.
  #
  # The leading `:` is systemd's own documented prefix (`man 5 systemd.service`, COMMAND LINES)
  # to disable ITS environment-variable substitution for that command. Without it, systemd would
  # try to expand any `$FOO` in the shell one-liner itself, before `sh` ever sees it -- the man
  # page's own fix for "I want a literal dollar sign" is either doubling it (`$$`) or, as done
  # here, opting the whole line out with `:`. Substitution stays enabled for the non-shell,
  # plain-argv path, since there `$FOO`/`${FOO}` expansion against this unit's own `Environment=`
  # is a legitimate systemd feature a consumer may want, and there is no shell downstream to
  # double-interpret it.
  execStartFor = svc:
    if svc.runShell
    then ":sh -c ${escapeExecArg svc.command}"
    else svc.command;

  toSystemdUnit = _name: svc: {
    Unit = {
      Description = svc.description;
      PartOf = svc.partOf;
      After = svc.after;
      Requires = svc.requires;
    };
    Service = {
      Type = svc.serviceType;
      ExecStart = execStartFor svc;
      Restart = svc.restart;
      RemainAfterExit = svc.remainAfterExit;
      Environment = lib.mapAttrsToList (k: v: "${k}=${v}") svc.environment;
      # One `LoadCredentialEncrypted=ID:PATH` line per attr, same "always present, empty list
      # renders no directive" treatment as `Environment=` immediately above -- see
      # `loadCredentialEncrypted`'s own option doc for the mechanism this populates, and the
      # keyring assembly's header comment for the one convenience that fills it in today.
      LoadCredentialEncrypted =
        lib.mapAttrsToList (id: path: "${id}:${path}") svc.loadCredentialEncrypted;
    };
    Install = {
      WantedBy = svc.wantedBy;
    };
  };

  # The convenience blocks below only ever set the fields they have an actual opinion about;
  # everything else falls through to the generic submodule's own defaults. `lib.mkDefault` on each
  # so that a consumer who also reaches into `nixdesktop.session.services.bar.*` directly (the
  # same generic mechanism these compile down to) overrides cleanly instead of hitting a
  # "conflicting definition" error.
  wellKnownServices =
    (lib.optionalAttrs cfg.bar.enable {
      bar = lib.mkDefault {
        inherit (cfg.bar) command;
        description = "Status bar";
      };
    })
    // (lib.optionalAttrs cfg.notifications.enable {
      notifications = lib.mkDefault {
        inherit (cfg.notifications) command;
        description = "Notification daemon";
      };
    })
    // (lib.optionalAttrs cfg.osd.enable {
      osd = lib.mkDefault {
        inherit (cfg.osd) command;
        description = "On-screen-display server";
      };
    })
    // (lib.optionalAttrs cfg.clipboardHistory.enable {
      # TWO units, not one. Text and image clipboard events are two independent wl-paste watcher
      # processes with two independent failure domains -- a stuck/crashed image watcher (large
      # binary payloads, more likely to hit a cliphist/wl-clipboard edge case) has no reason to
      # take the text watcher down with it, and one unit per watcher means `systemctl --user
      # status`/the journal tell you which mime class actually broke instead of a single combined
      # unit where you'd have to guess. Neither command has a pipe or needs argument grouping, so
      # both run as plain argv (runShell defaults to false) rather than through a needless shell.
      "cliphist-text" = lib.mkDefault {
        command = "wl-paste --type text --watch cliphist store";
        description = "Clipboard history watcher (text)";
      };
      "cliphist-image" = lib.mkDefault {
        command = "wl-paste --type image --watch cliphist store";
        description = "Clipboard history watcher (image)";
      };
    })
    # `effectiveIdleCommand` is null when there is no idle daemon to run at all (either
    # `lockAfterSeconds = null`, or an explicit `command = null` with no timeouts). Guarding on it
    # here rather than asserting keeps "enable the session layer, but this host never idle-locks" a
    # valid configuration instead of a build failure.
    // (lib.optionalAttrs (cfg.idleAndLock.enable && effectiveIdleCommand != null) {
      idle = lib.mkDefault {
        command = effectiveIdleCommand;
        runShell = true;
        description = "Idle/lock daemon";
      };
    })
    # Gated on `lockAtStart` ALONE, never on `lockAfterSeconds` -- "gate the start, never lock on
    # idle" is a legitimate configuration (see the option's own doc), and tying this to the idle
    # daemon's existence would silently drop the only gate such a session has.
    #
    # Type=forking because `swaylock -f` daemonizes: it forks once the screen is actually covered,
    # which is precisely the event worth ordering on -- systemd treats the unit as started only
    # then, so anything ordered after this cannot paint to an unlocked screen first. `restart =
    # "no"` for the same reason the keyring component's gnome-keyring provider sets it (see that
    # option group's own header -- this is now provider-dependent there, but still universally true
    # here): this is a one-shot gate, and a locker that exits because the human unlocked it has
    # SUCCEEDED, not failed. Restarting it would re-lock the session the instant they got in.
    // (lib.optionalAttrs (cfg.idleAndLock.enable && cfg.idleAndLock.lockAtStart) {
      "lock-at-start" = lib.mkDefault {
        command = "${lockBin} -f";
        description = "Lock the session at start (the one password this desk asks for)";
        serviceType = "forking";
        restart = "no";
      };
    })
    // (lib.optionalAttrs cfg.polkitAgent.enable {
      "polkit-agent" = lib.mkDefault {
        inherit (cfg.polkitAgent) command;
        description = "Polkit authentication agent";
      };
    })
    # Guarded on `effectiveKeyringCommand != null` too, the same shape as the idle daemon above --
    # NOT to make "enabled, no provider chosen" a legitimate silent no-op (unlike idle, it isn't:
    # see the `nixdesktop.session.keyring: enabled with nothing to run` assertion in `config`
    # below, which turns exactly this case into a named build failure), but so a misconfigured
    # value never reaches `command`'s own `str` (non-nullable) option type first -- that would fail
    # as a raw, unlabelled "option is not of type string" error, reached before this module's own
    # assertions are ever consulted. This guard is the difference between that and the clean,
    # named message the assertion produces instead.
    // (lib.optionalAttrs (cfg.keyring.enable && effectiveKeyringCommand != null) {
      keyring = lib.mkDefault (
        {
          command = effectiveKeyringCommand;
          description = "Secret-service (org.freedesktop.secrets) provider";
          # See the keyring assembly's header comment (above, by `keyringServiceType`) for why
          # this is provider-dependent and verified per provider rather than a single assumed
          # shape.
          serviceType = keyringServiceType;
          restart = keyringRestart;
        }
        // lib.optionalAttrs (keyringLoadCredentialEncrypted != { }) {
          loadCredentialEncrypted = keyringLoadCredentialEncrypted;
        }
      );
    });
in
{
  options.nixdesktop.session = {
    enable = lib.mkEnableOption "session components as systemd user services, bound to the compositor's graphical-session.target (verified against niri's own shipped unit; see the header comment)";

    services = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
        options = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Whether this declared component is actually emitted as a unit.";
          };

          command = lib.mkOption {
            type = lib.types.str;
            example = "waybar";
            description = ''
              What to run: either a bare argv line (space-separated, no shell features -- the
              default, and the cheaper path since it skips a shell hop) or a full shell one-liner
              when `runShell` is true.
            '';
          };

          runShell = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = ''
              Whether `command` needs a shell to run -- pipes, redirection, `$VAR` expansion, or
              (as with swayidle's own lock-command arguments) grouping a multi-word value into one
              argument. False runs `command` as a plain argv line; true wraps it as `sh -c
              '<command>'`.
            '';
          };

          description = lib.mkOption {
            type = lib.types.str;
            default = "nixdesktop session component: ${name}";
            description = "Unit description, shown by `systemctl --user status` and in the journal.";
          };

          serviceType = lib.mkOption {
            type = lib.types.enum [ "simple" "exec" "forking" "oneshot" "dbus" "notify" "notify-reload" "idle" ];
            default = "simple";
            description = ''
              systemd's `Type=`. Almost every session component is a plain foreground process
              (the default, "simple"); the exception is a double-forking traditional UNIX daemon
              such as gnome-keyring-daemon, which needs "forking" so systemd tracks the real
              backgrounded process instead of the short-lived launcher that forked it and exited.
            '';
          };

          restart = lib.mkOption {
            type = lib.types.enum [ "no" "on-success" "on-failure" "on-abnormal" "on-watchdog" "on-abort" "always" ];
            default = "on-failure";
            description = ''
              systemd's `Restart=`. "on-failure" is the right default for the common case -- a bar
              or notification daemon that crashes should come back, but one that is deliberately
              stopped (a clean exit, e.g. as part of session teardown) should stay stopped rather
              than fight it. A one-shot bootstrap step that should never loop (see the `keyring`
              convenience below) overrides this to "no".

              A component whose binary is simply missing is deliberately NOT special-cased here:
              this module does not check for the binary's existence before running it, because the
              entire point of moving off spawn-at-startup is to make that failure visible. With
              "on-failure" and systemd's own default start-limiting (five attempts in ten seconds,
              not reconfigured here), a missing binary fails loudly a handful of times and then
              parks in a `systemctl --user --failed`-visible failed state -- instead of the
              current behaviour, which is nothing, forever, with no diagnostic anywhere.
            '';
          };

          remainAfterExit = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = ''
              systemd's `RemainAfterExit=`. Only meaningful with `serviceType = "oneshot"`: keeps
              the unit counted as active (for other units' `After=`/`PartOf=` purposes) after its
              one-shot process exits, instead of immediately reverting to inactive.
            '';
          };

          partOf = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ "graphical-session.target" ];
            description = ''
              Stop (and restart, if the target restarts) together with these units. See the
              header comment: this is `man 7 systemd.special`'s own documented convention for a
              service that only makes sense while a graphical session is running.
            '';
          };

          after = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ "graphical-session.target" ];
            description = ''
              Start only once these units are active. Ordering after graphical-session.target
              specifically means "only once the compositor's own session unit has confirmed
              startup" (niri.service, on niri -- see the header comment -- binds and precedes the
              target, and is Type=notify, so the target is not reached until the compositor
              itself says it is ready) -- this is what replaces a `sleep 1` guess.
            '';
          };

          requires = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = ''
              Hard dependency, not just ordering: if a listed unit fails to start, this one does
              not start either. Empty by default -- `partOf`+`after`+being pulled in via
              `wantedBy` is already the documented pattern (see header), and a hard `Requires=` on
              graphical-session.target would mean any hiccup in the compositor's own startup takes
              every session component down with it rather than just this one failing on its own.
            '';
          };

          wantedBy = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ "graphical-session.target" ];
            description = ''
              Which targets pull this unit in. This is what makes the component start without a
              separate `systemctl --user enable` step: home-manager's systemd activation
              (`systemd.user.startServices`, default true/"sd-switch") creates the `.wants/`
              symlink and starts/restarts the unit as part of every `home-manager switch`.
            '';
          };

          environment = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = { };
            example = { NO_AT_BRIDGE = "1"; };
            description = "Extra environment variables for the executed process.";
          };

          loadCredentialEncrypted = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = { };
            example = {
              "oo7.keyring-encryption-password" = "/etc/credstore.encrypted/oo7.keyring-encryption-password";
            };
            description = ''
              systemd's `LoadCredentialEncrypted=`, one `ID = PATH;` entry per directive (systemd
              permits repeating this key; this option therefore takes an attrset, not a single
              string, the same shape as `environment` above). THE MECHANISM the `keyring.oo7.
              credential.*` convenience below populates for oo7's autologin-safe unlock (see the
              keyring assembly's header comment) -- exposed generically here, on the same
              "mechanism vs convenience" split as `command`/`environment`, for any other unit that
              needs a systemd-encrypted-credential-backed secret and isn't already one of the named
              blocks.

              THE `--user`/`--uid` SCOPE GOTCHA, PROVED LIVE, NOT ASSUMED. A credential encrypted
              the "obvious" way -- `systemd-creds encrypt --with-key=host <input> <path>`, no scope
              flag -- fails hard when loaded into a systemd `--user` unit: `Scope mismatch` /
              `Failed to set up credentials: Wrong medium type`, exit 243/CREDENTIALS. Verified live
              on corbet-server (richc/uid 1000, via SSH from CORBET-ELITEBOOK): a `systemd-run
              --user` unit given exactly this option's own directive, fed a host-key-encrypted blob
              produced WITHOUT `--user --uid=`, failed with precisely that error; re-encrypting the
              identical plaintext with `systemd-creds encrypt --user --uid=1000 --with-key=host ...`
              -- a USER-SCOPED blob -- and changing nothing else made the same unit work. This
              option cannot enforce that scoping from here: it only wires an already-encrypted PATH
              into the unit, the same way `command` only wires an already-built invocation. Getting
              the encryption step right is the consumer's (or the host's own provisioning's) job.

              THE HOST KEY, DELIBERATELY, NEVER THE TPM. `--with-key=host` (not `--with-key=tpm2`)
              was the mandate this proof implements, not an oversight this module quietly went
              along with: the host key (`/var/lib/systemd/credential.secret`) lives on the same
              LUKS-encrypted volume the disk passphrase already unlocks at boot, so the credential
              is decryptable only on that one host and only after that one passphrase -- no TPM
              involved, matching an estate that deliberately rejected TPM for LUKS itself. This
              option has no opinion about HOW the referenced file was encrypted (it just names a
              path); documented here because getting that flag wrong is the single most likely way
              to reproduce the exact failure this comment describes.
            '';
          };
        };
      }));
      default = { };
      description = ''
        The mechanism: an arbitrary named session component, rendered as one systemd user
        service. The `bar`/`notifications`/`osd`/etc. options below are convenience that populate
        this same attrset with the commands for the components this desktop actually has --
        add anything else this project has no opinion about directly here.
      '';
    };

    bar = {
      enable = lib.mkEnableOption "a status bar, run as a systemd user service (e.g. waybar)";
      command = lib.mkOption {
        type = lib.types.str;
        default = "waybar";
        description = "Status bar command.";
      };
    };

    notifications = {
      enable = lib.mkEnableOption "a notification daemon, run as a systemd user service (e.g. mako)";
      command = lib.mkOption {
        type = lib.types.str;
        default = "mako";
        description = "Notification daemon command.";
      };
    };

    osd = {
      enable = lib.mkEnableOption "an on-screen-display server, run as a systemd user service (e.g. swayosd-server)";
      command = lib.mkOption {
        type = lib.types.str;
        default = "swayosd-server";
        description = ''
          OSD server command. Pairs with a compositor module's own `osd = "swayosd"`-style option
          (nixniri's `niri.osd`, for instance), which binds the volume/brightness/mic-mute keys
          to swayosd-client -- the client has nothing to talk to until this server is running.
        '';
      };
    };

    clipboardHistory = {
      enable = lib.mkEnableOption "cliphist watcher services (two -- see the header comment for why)";
    };

    idleAndLock = {
      enable = lib.mkEnableOption "an idle/lock daemon, run as a systemd user service (e.g. swayidle)";

      lockAfterSeconds = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = 300;
        description = ''
          Seconds of inactivity before the screen locks. `null` means no idle daemon at all: the
          service is not created, and `lockCommand` is then only reachable through a compositor's
          own lock keybind.
        '';
      };

      lockAtStart = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Lock the session the moment it starts, before anything is visible on screen -- not only
          after `lockAfterSeconds` of idleness.

          ⚠ THIS IS OFF BY DEFAULT AND MUST STAY THAT WAY, because on most hosts it costs a SECOND
          password immediately after the first. The estate this module was written for holds one
          rule above ergonomics: every path to a usable desktop costs exactly ONE password entry,
          never zero and never two in a row. On a machine you boot yourself, the disk passphrase IS
          that one entry, and the session that comes up right after it must NOT then demand another
          -- the human typing the second one was, provably, standing there ten seconds ago typing
          the first.

          Turn it on exactly where that reasoning inverts: a session whose host was unlocked at
          some other time, in some other place, so that nothing has ever authenticated anyone AT
          THIS SCREEN. The motivating case is a desktop in a container, which has no disk
          passphrase of its own (its storage rides the host's) and no boot of its own -- started
          deliberately, hours or weeks after the host was. There, an unlocked session is not
          convenience, it is a desktop sitting open on a monitor with no gate in front of it at
          all, and locking at start is what supplies the one password that desk would otherwise
          never ask for.

          Independent of `lockAfterSeconds`: this fires once at session start, the idle daemon
          handles everything after. Setting this with `lockAfterSeconds = null` is legitimate --
          "gate the start, never lock on idle" -- and creates no idle daemon.
        '';
      };

      suspendAfterSeconds = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = 600;
        description = ''
          Seconds of inactivity before suspending. `null` drops the suspend action while keeping
          the idle lock -- the right setting on any host that must not suspend but should still
          lock, e.g. a desktop in a container sharing its kernel (and therefore its power state)
          with its host. Ignored entirely when `lockAfterSeconds` is null.
        '';
      };

      lockCommand = lib.mkOption {
        type = lib.types.str;
        default = "swaylock";
        description = ''
          The screen locker. Used both in the assembled idle invocation and, read defensively by
          the compositor modules, for their own lock keybind -- so it is stated once here rather
          than once per compositor. Must be a bare command name, not a path: the assembled
          invocation ends with `pkill -USR1 <this>`, which matches on process name.
        '';
      };

      command = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "hypridle";
        description = ''
          ESCAPE HATCH ONLY. A verbatim idle-daemon invocation, used as-is and bypassing the
          assembly from the three options above. `null`, the default, means "assemble a swayidle
          invocation", which is what almost every consumer wants.

          Set this only for an idle daemon that is not swayidle and therefore does not take
          swayidle's timeout/action grammar. Setting it makes `lockAfterSeconds` and
          `suspendAfterSeconds` inert for the daemon (they no longer describe what runs), so
          prefer the assembled form unless you actually need a different daemon.
        '';
      };
    };

    polkitAgent = {
      enable = lib.mkEnableOption "a polkit authentication agent, run as a systemd user service";
      command = lib.mkOption {
        type = lib.types.str;
        example = "/usr/lib/mate-polkit/polkit-mate-authentication-agent-1";
        description = ''
          Polkit agent invocation -- realistically a full binary path, since every agent ships at
          a different location on every platform. A platform backend that resolves
          `nixdesktop.want.polkitAgent` already knows this path (this repo's own
          `modules/nixos-backend.nix`, via `lib/nixos-roles.nix`'s `polkitAgents.<name>.command`;
          nixarch's Arch backend has the equivalent) -- wire it through from there rather than
          hand-typing it, the same way you would for `keyring.gnomeKeyring.command`/`keyring.oo7.
          command` below.
        '';
      };
    };

    # ── keyring: PROVIDER CHOICE, NOT A BARE COMMAND ────────────────────────────────────────────
    # See the keyring assembly's own header comment above (by `keyringProviderCommand`) for the
    # full account of why this moved from one `command` string to a provider choice, why that
    # choice is two independent booleans rather than an enum, and the verified-not-assumed facts
    # behind each provider's own `serviceType`/`restart`.
    keyring = {
      enable = lib.mkEnableOption "a secret-service (org.freedesktop.secrets) provider, run as a systemd user service";

      # ── oo7: THE MODERN PATH, OPERATOR-MANDATED ───────────────────────────────────────────────
      oo7 = {
        enable = lib.mkEnableOption ''
          oo7-server (`oo7-daemon`, nixpkgs `oo7-server`/Arch `extra/oo7`, both official, no AUR)
          as this host's Secret Service provider. THE DECISION for any host that autologins with
          no PAM auth phase (Design A -- see modules/launcher.nix's own header): gnome-keyring's
          only autologin-compatible mode is a BLANK keyring password (secrets unencrypted at
          rest); oo7 can stay genuinely encrypted under autologin instead, via `credential` below.
          Mutually exclusive with `gnomeKeyring.enable` -- see `config.assertions`.

          SECRETS ONLY, BY DESIGN, NOT A GAP THIS OPTION COULD CLOSE: oo7's own upstream repo ships
          no PKCS#11 store and no ssh-agent -- unlike gnome-keyring-daemon, which CAN provide both
          (though see `gnomeKeyring.command`'s own doc: this module has never actually asked it
          to). A host that genuinely needs a PKCS#11 store or an ssh-agent needs a DIFFERENT,
          separately-run component regardless of which keyring provider it picks here (p11-kit for
          the former; `gpg-agent --enable-ssh-support`, or plain `ssh-agent`, for the latter) --
          neither is modelled as a role by this module today, so wire it yourself via the generic
          `services.<name>` mechanism if a host needs it.
        '';

        command = lib.mkOption {
          type = lib.types.str;
          example = lib.literalExpression ''"''${pkgs.oo7-server}/libexec/oo7-daemon"'';
          description = ''
            oo7-daemon invocation -- NO DEFAULT, deliberately, unlike `gnomeKeyring.command`
            below. Confirmed by building the real package and listing its output
            (`nix build nixpkgs#oo7-server` + `find $out -type f`): the binary installs to
            `$out/libexec/oo7-daemon`, NOT `$out/bin`, so -- unlike gnome-keyring-daemon and
            kwalletd6, which both land in `$out/bin` and resolve via a bare name on PATH -- a
            bare `"oo7-daemon"` here would NOT resolve unless something else already put it on
            PATH. Same `lib/nixos-roles.nix`'s `keyrings.<name>.command` pointer as
            `polkitAgent.command`/`gnomeKeyring.command`: wire it through
            `keyrings.oo7.command` for the real interpolated store path rather than hand-typing
            one that will only work by accident.

            NOT the wrapped `/run/wrappers/bin/oo7-daemon` path either, even though that is what
            nixpkgs' OWN packaged unit points at (`share/systemd/user/oo7-daemon.service`,
            `useWrappedDaemon = true` by default) -- see the keyring assembly's header comment for
            why: that path only resolves on a host whose SYSTEM config also runs NixOS's own
            `services.oo7.enable` (which supplies the `security.wrappers.oo7-daemon` CAP_IPC_LOCK
            wrapper), a capability this home-manager module cannot reach. `keyrings.oo7.command`
            in `lib/nixos-roles.nix` therefore points at the real, unwrapped `libexec` path, and
            this option inherits that same limitation whenever set to anything else.
          '';
        };

        # ── the credential-based unlock: THE REASON oo7 replaces gnome-keyring at all ───────────
        credential = {
          enable = lib.mkEnableOption ''
            load the `oo7.keyring-encryption-password` systemd credential into this unit
            (`LoadCredentialEncrypted=`, via the generic `loadCredentialEncrypted` mechanism --
            see that option's own doc for the full proof and the `--user`/`--uid` scope gotcha it
            uncovered), so oo7-daemon can unlock the session keyring with NO typed password even
            though this session autologins. Requires `oo7.enable`; meaningless otherwise (nothing
            reads it unless the oo7 branch of the assembly is the one active).
          '';

          name = lib.mkOption {
            type = lib.types.str;
            default = "oo7.keyring-encryption-password";
            description = ''
              The credential ID. NOT a free naming choice -- this is oo7-server's OWN contract,
              confirmed two ways: its README ("the daemon will try to load a credential named
              `oo7.keyring-encryption-password`") and the literal `ImportCredential=
              oo7.keyring-encryption-password` line in its packaged 0.6.0 unit (see the keyring
              assembly's header comment). Renaming it here produces a unit that loads a credential
              oo7-daemon never looks for -- change this only if a future oo7 release renames its
              own contract, and confirm against the new version's own source before doing so.
            '';
          };

          path = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "/etc/credstore.encrypted/oo7.keyring-encryption-password";
            description = ''
              Where the USER-SCOPED encrypted blob lives on disk. Mandatory (build failure via
              `config.assertions` if left `null`) once `credential.enable` is true -- there is no
              sane default location this module could assume across hosts.

              MUST be produced with `systemd-creds encrypt --user --uid=<uid> --with-key=host
              <input> <this path>` -- NOT the plain `systemd-creds encrypt --with-key=host` form
              (no `--user`/`--uid`) a first attempt reaches for. Proved live, not assumed: a blob
              encrypted the plain way loaded into a `systemd-run --user` unit via this exact
              directive failed with `Scope mismatch` / `Failed to set up credentials: Wrong medium
              type`, exit 243/CREDENTIALS; re-encrypting the identical plaintext with `--user
              --uid=` and changing nothing else made the identical unit work. `--with-key=host`,
              never `--with-key=tpm2` -- the operator's own mandate rejects TPM for LUKS, and the
              host key (`/var/lib/systemd/credential.secret`) already lives on the LUKS-encrypted
              volume the disk passphrase unlocks at boot, so this credential is decryptable only
              on that host and only after that passphrase, with no TPM anywhere in the chain.
            '';
          };
        };
      };

      # ── gnome-keyring: THE PREVIOUS PROVIDER, KEPT SELECTABLE, NOT DELETED ────────────────────
      gnomeKeyring = {
        enable = lib.mkEnableOption ''
          gnome-keyring-daemon as this host's Secret Service provider -- the previous default,
          kept selectable for a host not yet migrated to oo7, or one that genuinely still needs
          the PKCS#11/ssh-agent components gnome-keyring can ALSO provide (this module's own
          `command` below still only ever asks it for `--components=secrets`, though -- see the
          note under `command`). Mutually exclusive with `oo7.enable` -- see `config.assertions`.
        '';

        command = lib.mkOption {
          type = lib.types.str;
          default = "gnome-keyring-daemon --start --components=secrets";
          description = ''
            gnome-keyring-daemon invocation. Defaulted, unlike `oo7.command` above, because
            `lib/nixos-roles.nix`'s own comment confirms it: gnome-keyring-daemon installs
            straight to `$out/bin`, so a bare name resolved via PATH is correct as-is, with no
            store-path interpolation required.

            `--components=secrets` ONLY -- this module has NEVER asked gnome-keyring for its
            PKCS#11 store or its ssh-agent (see `lib/nixos-roles.nix`'s own `keyrings.gnome-keyring`
            comment: "this is the secret-service role, not the ssh-agent or pkcs11 ones"). That
            means the "PKCS#11/ssh-agent" boundary mentioned throughout this option group was
            already true of THIS module before oo7 ever entered the picture -- if a host actually
            gets either from gnome-keyring today, it is coming from something OUTSIDE this
            module's own rendering (a different invocation, `pam_gnome_keyring`'s own broader
            activation, a distro default service), not from anything `keyring.gnomeKeyring.command`
            has ever started. Worth confirming per-host before assuming there is nothing to lose
            by switching to oo7 -- this module cannot see that from here.

            DESIGN DECISION, UNCHANGED FROM BEFORE THIS OPTION GROUP EXISTED: rendered with
            `serviceType = "forking"` and `restart = "no"` (see `keyringServiceType`/
            `keyringRestart` above). gnome-keyring-daemon is a traditional double-forking UNIX
            daemon: the process this unit execs parses its flags, forks the real daemon into the
            background, and exits on its own, successfully, almost immediately. Under the default
            `serviceType = "simple"` systemd ties the unit's active/inactive state strictly to
            that first process, so it would go "inactive (dead)" seconds after a fully successful
            start -- correct process, wrong unit state. "forking" is systemd's own documented
            mechanism for exactly this pattern: without a PIDFile, it tracks whichever single
            process remains in the unit's cgroup once the original one exits. And a bootstrap step
            either wins once or doesn't: unlike a bar or a watcher, there is nothing to gain by
            retrying it in a loop, and something to lose (a missing binary or an
            already-registered D-Bus name would otherwise restart-loop indefinitely instead of
            failing once, visibly).
          '';
        };
      };

      # ── ESCAPE HATCH, UNCHANGED IN SPIRIT, WIDENED IN TYPE ────────────────────────────────────
      command = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "secret-tool-alternative-daemon --foreground";
        description = ''
          ESCAPE HATCH. A verbatim keyring daemon invocation, used as-is instead of whichever
          provider's own command `oo7.enable`/`gnomeKeyring.enable` would otherwise select.
          `null`, the default, means "use the enabled provider's own command" -- what almost every
          consumer wants.

          Before this option group existed, THIS was the only option (mandatory, no default) --
          kept here, now optional, for a provider this module has no built-in entry for at all.
          Setting it does NOT also change `serviceType`/`restart`: those still follow
          `oo7.enable` (see `keyringServiceType`/`keyringRestart` above), on the reasoning that
          enabling a provider block is a statement about WHICH DAEMON is actually running
          (forking vs. not), independent of the exact string used to start it -- override
          `nixdesktop.session.services.keyring.serviceType`/`.restart` directly (the same generic
          escape hatch every well-known block documents) if that coupling is wrong for your case.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    nixdesktop.session.services = wellKnownServices;

    systemd.user.services =
      lib.mapAttrs toSystemdUnit (lib.filterAttrs (_: svc: svc.enable) cfg.services);

    # ── keyring provider assertions ──────────────────────────────────────────────────────────
    assertions = [
      {
        # Checked unconditionally, independent of `keyring.enable` -- see the keyring assembly's
        # header comment for why this had to become a real, catchable assertion rather than
        # something an enum's own shape ruled out structurally: a consumer reaching past this
        # option group into `nixdesktop.session.services.keyring` directly could otherwise still
        # produce two competing daemons with nothing here to notice, and setting both booleans is
        # never a legitimate state regardless of whether the umbrella `enable` happens to be on.
        assertion = !(cfg.keyring.oo7.enable && cfg.keyring.gnomeKeyring.enable);
        message = ''
          nixdesktop.session.keyring: choose exactly one provider -- both `oo7.enable` and
          `gnomeKeyring.enable` are true. Two Secret Service daemons racing for the same D-Bus
          name (org.freedesktop.secrets) is a confusing, intermittent failure -- apps losing their
          stored secrets depending on which one won the race -- never a working configuration.
          Disable one.
        '';
      }
      {
        assertion = !(cfg.keyring.enable && effectiveKeyringCommand == null);
        message = ''
          nixdesktop.session.keyring.enable is true but nothing tells it what to run: neither
          `oo7.enable` nor `gnomeKeyring.enable` is set, and `command` is null. Enable a provider,
          or set `command` directly as the escape hatch.
        '';
      }
      {
        assertion = !(cfg.keyring.oo7.credential.enable && cfg.keyring.oo7.credential.path == null);
        message = ''
          nixdesktop.session.keyring.oo7.credential.enable is true but `credential.path` is null.
          There is no sane default location for the encrypted credential blob across hosts -- set
          it to wherever `systemd-creds encrypt --user --uid=<uid> --with-key=host` actually wrote
          it (see that option's own doc for the full proof).
        '';
      }
    ];
  };
}
