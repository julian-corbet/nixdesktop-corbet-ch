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
    // (lib.optionalAttrs cfg.polkitAgent.enable {
      "polkit-agent" = lib.mkDefault {
        inherit (cfg.polkitAgent) command;
        description = "Polkit authentication agent";
      };
    })
    // (lib.optionalAttrs cfg.keyring.enable {
      keyring = lib.mkDefault {
        inherit (cfg.keyring) command;
        description = "Secret-service (org.freedesktop.secrets) provider";
        # See the `keyring` option below for why this is Type=forking and Restart=no.
        serviceType = "forking";
        restart = "no";
      };
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
          hand-typing it, the same way you would for `keyring.command` below.
        '';
      };
    };

    keyring = {
      enable = lib.mkEnableOption "a secret-service (org.freedesktop.secrets) provider, run as a systemd user service";
      command = lib.mkOption {
        type = lib.types.str;
        example = "gnome-keyring-daemon --start --components=secrets";
        description = ''
          Keyring daemon invocation -- same `lib/nixos-roles.nix`'s `keyrings.<name>.command`
          pointer as `polkitAgent.command` above. Only ever set one provider: two racing for the
          same D-Bus name is a confusing failure that presents as apps intermittently losing
          their stored secrets.

          DESIGN DECISION: rendered with `serviceType = "forking"` and `restart = "no"`, unlike
          every other well-known component here. gnome-keyring-daemon -- the well-known
          implementation of this role -- is a traditional double-forking UNIX daemon: the process
          this unit execs parses its flags, forks the real daemon into the background, and exits
          on its own, successfully, almost immediately. Under the default `serviceType = "simple"`
          systemd ties the unit's active/inactive state strictly to that first process, so it would
          go "inactive (dead)" seconds after a fully successful start -- correct process, wrong
          unit state. "forking" is systemd's own documented mechanism for exactly this pattern:
          without a PIDFile, it tracks whichever single process remains in the unit's cgroup once
          the original one exits. And a bootstrap step either wins once or doesn't: unlike a bar or
          a watcher, there is nothing to gain by retrying it in a loop, and something to lose (a
          missing binary or an already-registered D-Bus name would otherwise restart-loop
          indefinitely instead of failing once, visibly). If the binary in use runs in the
          foreground instead of forking (check its own flags -- some builds accept a
          `--foreground`-style option), set `nixdesktop.session.services.keyring.serviceType =
          "simple";` to match.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    nixdesktop.session.services = wellKnownServices;

    systemd.user.services =
      lib.mapAttrs toSystemdUnit (lib.filterAttrs (_: svc: svc.enable) cfg.services);
  };
}
