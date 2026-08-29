# home/session.nix — turns desktop session components (a bar, a notifier, watchers, an idle
# daemon, a polkit agent, a keyring) into systemd user services, compositor-neutral itself and
# sibling to the other home/*.nix modules in this repo.
#
# THE PROBLEM THIS REPLACES. A compositor integration would otherwise emit one-shot startup
# commands into its native configuration for exactly these components. Those run once, at
# compositor session start, and cannot be replayed reliably after a configuration change. This
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
# guess, and the direct fix for the `sleep 1` workaround. That guarantee is supplied by THAT
# COMPOSITOR'S OWN UNIT, though; it is never a property of the target. Where the unit pulling the
# target in is `Type=simple` (or is no service at all), no readiness gate exists anywhere in the
# chain and the ordering buys nothing -- see "⚠ THE READINESS GUARANTEE IS CONDITIONAL" below for
# the compositor that is measured on, and for what covers the gap there instead.
#
# `graphical-session.target` is not a niri invention: it is a generic systemd target
# (`man 7 systemd.special`, confirmed present as a shipped unit) whose documented contract is
# "active whenever any graphical session is running...
# used to stop user services which only apply to a graphical session when the session is
# terminated. Such services should have PartOf=graphical-session.target in their [Unit] section."
# The manual's own worked example is a service started by being WantedBy the session's own target;
# this module gets the same effect in the other direction, by putting `WantedBy=` on each
# component instead of `Wants=` on the target -- the man page explicitly names per-service
# `.wants/` symlinks (which is what `Install.WantedBy` produces) as the alternative to a hand-
# maintained `Wants=` list, for exactly this "independently enabled services" case.
#
# Every component below is therefore, by default: `PartOf=graphical-session.target` (stop with the
# session), `After=graphical-session.target` (start only once the target is reached -- on niri that
# means once niri has confirmed it is actually ready, replacing the sleep; on a `Type=simple`
# compositor it means considerably less, which is what the restart backoff below exists to survive),
# `WantedBy=graphical-session.target` (pulled in automatically, no separate enable step).
# `graphical-session-pre.target` also exists (services that export
# environment into the whole session before it starts, e.g. an SSH/GPG agent, per the same man
# page) but nothing here uses it: niri's own session script already imports the login manager's
# environment before starting niri.service, and none of the components below need to inject
# environment into sibling processes -- they only need to be running and reachable over D-Bus/IPC,
# which `graphical-session.target` ordering already gives them.
#
# ⚠ THE READINESS GUARANTEE IS CONDITIONAL, AND ON SOME HOSTS IT DOES NOT EXIST AT ALL.
# `After=graphical-session.target` orders a component after the TARGET, and a target is reached the
# moment the units that pull it in report started -- so the ordering is worth exactly as much as
# the readiness semantics of whatever unit that is, and not one bit more. On niri it is the
# `Type=notify` unit quoted above, and the semantics are real. On scroll they are not, and that is
# measured rather than suspected, twice over:
#
#   - The compositor's own unit is `Type=simple`. A seated session runs the compositor as a SYSTEM
#     unit rendered by nixdesktop.launcher (`PAMName=`/`User=` is the only route to a real seat --
#     that module's own header), and `mkSeatedUnit` renders `Type=` from
#     `nixdesktop.launcher.compositors.<name>.supportsNotify`, which is `true` for niri and `false`
#     for scroll (that option's own doc: measured per compositor, never assumed). `Type=simple`
#     counts a unit as started the instant its process is FORKED -- long before the compositor has
#     created, bound, and begun accepting on its Wayland socket.
#   - Nothing downstream restores the gate either. What pulls `graphical-session.target` in on such
#     a host is a plain target of the compositor's own (`scroll-session.target`:
#     `BindsTo=graphical-session.target`, no service, no `ExecStart`, no readiness of any kind), and
#     a plain target goes active instantly. There is no unit anywhere in that chain that waits for
#     the socket, so `After=graphical-session.target` resolves the moment the fork happens.
#
# WHAT THAT COSTS, MEASURED (the laptop, a seated scroll session, 2026-08-10). The user units
# started at 12:43:46; `/usr/bin/scroll`, the compositor every one of them connects to, started at
# 12:43:47 -- a full second LATER. Every component ran against a Wayland socket that did not exist
# yet and failed. That alone should have been survivable, since retrying is precisely what
# `Restart=on-failure` is for -- except that this file configured nothing else, and systemd's own
# unconfigured defaults are `RestartSec=100ms`, `StartLimitBurst=5`, `StartLimitIntervalSec=10s`.
# Five attempts spaced 100ms apart fit inside HALF A SECOND, so every component spent its entire
# restart budget inside that one-second window, hit `start-limit-hit`, and stayed dead for the whole
# session with nothing left that would ever retry it: no bar, no dock, no notification daemon, under
# a compositor that was by then perfectly healthy. `kanshi.service` is the one the journal caught
# mid-flight (`restart counter is at 6` -> `Start request repeated too quickly` -> `Failed with
# result 'start-limit-hit'`), but every component in this file shared its fate for the same reason.
#
# THE FIX: RESTART BACKOFF WIDE ENOUGH TO OUTLAST A LATE COMPOSITOR. `restartSec` /
# `startLimitBurst` / `startLimitIntervalSec` (all three declared on the generic service submodule
# below) default to 2 s / 10 / 60 s for EVERY component, with no call site opting in -- a racing
# component is a property of this whole class of unit, not of any one of them, so a default each
# consumer had to remember to set would be the same bug with an extra step. Ten permitted starts
# spaced two seconds apart span roughly eighteen seconds of wall clock, so a compositor arriving a
# second late -- or fifteen -- is simply retried through, and the component comes up. The failure
# above becomes a handful of journal lines and a working desktop.
#
# WHY NOT `StartLimitIntervalSec=0` (RETRY FOREVER), WHICH ALSO FIXES THE RACE. It fixes it by
# deleting the end-stop, and the end-stop is load-bearing here. A component whose binary is simply
# MISSING is deliberately not special-cased anywhere in this file -- making that failure visible is
# the entire reason for moving off spawn-at-startup (see reason 3 at the top, and `restart`'s own
# option doc) -- and the place it becomes visible is `systemctl --user --failed`. With no start
# limit there is no such place: a missing binary would exec-fail every two seconds for the rest of
# the session, never appear in `--failed`, and be diagnosable only from a journal it is
# simultaneously flooding. That trades spawn-at-startup's silence for spawn-at-startup's noise and
# recovers none of the diagnostic value the move was made for. A WIDENED window keeps both
# properties at once: transient lateness is retried through, permanent breakage still parks in
# `--failed` -- in roughly eighteen seconds instead of half a second. A host that genuinely wants the
# infinite retry can still have it: `startLimitIntervalSec = 0` is systemd's own spelling for "no
# rate limiting at all", and that option passes the value straight through.
#
# The 60 s window is also not merely a bigger number than systemd's 10 s -- it catches a class the
# default silently misses. A unit that fails every three seconds never fits five failures into a
# rolling ten-second window, so stock systemd restart-loops it forever, all session, with no failed
# state and no end. Ten failures inside sixty seconds is a real thrash signature, and this parks it.
#
# ⚠ THE ONE EXCEPTION: A SEATED SESSION NEVER RUNS niri.service AT ALL. nixdesktop.launcher
# renders a seated compositor as a SYSTEM unit (`PAMName=`/`User=` is the only way to a real
# seat -- that module's own header) precisely BYPASSING the packaged `--user niri.service` this
# section describes. Nothing else was ever going to start it or its target, so on a seated host
# every component below sits dead for the whole session until `readinessBridge` (below) closes
# that gap -- see its own header for the full mechanism, measured live 2026-08-02.
#
# LEAN BY DESIGN, same doctrine as the other home/*.nix modules: `services.<name>` is the
# mechanism (arbitrary command -> systemd unit), and the named blocks below (`bar`, `notifications`,
# ...) are convenience that populate it with commands for the components this desktop actually
# has -- not a different code path. A consumer wanting some other component not listed below adds
# it directly under `services`. The reserved names the convenience blocks use are: `bar`,
# `notifications`, `osd`, `cliphist-text`, `cliphist-image`, `idle`, `polkit-agent`, `keyring`,
# `patchbay`.
#
# Nothing here installs a desktop component: component commands remain strings supplied by the
# consumer (or a platform backend). Private glue may close over portable command-line tools from
# `pkgs` so its runtime dependencies never depend on a foreign user manager's PATH.
{ lib, config, pkgs, ... }:
let
  cfg = config.nixdesktop.session;
  readinessSocketVariable = "$" + cfg.readinessBridge.socketEnvironment;

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

  # A lock-at-start unit is a SESSION gate, not a long-running owner of the locker process. Keep a
  # systemd oneshot latch active for the graphical session lifetime: the first start either finds
  # this exact locker already holding this Wayland display, or starts it according to the
  # configured command's declared process contract. Both paths then return success, and
  # RemainAfterExit keeps later Home Manager activations from re-locking a session whose human has
  # already unlocked it.
  #
  # `-f` has no universal process contract, but it IS `--daemonize` for the default command,
  # swaylock 1.8.6 (`-F`, not `-f`, is `--show-failed-attempts`), and for nixlock >= 0.1.3. Their
  # launcher's successful EXIT is the readiness protocol: its parent waits until the compositor
  # confirms the child holds the session lock. Process presence cannot substitute for that
  # handshake because the not-yet-ready parent has the same executable and display as the eventual
  # child. A custom or legacy command whose `-f` genuinely remains in the foreground instead needs
  # backgrounding, or the oneshot and whole user manager remain in `starting` until human unlock.
  # `lockAtStartCommandMode` makes the consumer state that command contract explicitly.
  #
  # Enumerate by UID only, then compare the untruncated executable basename as an ordinary quoted
  # string. `pgrep -x` compares Linux's 15-byte `comm` field and is therefore wrong for valid names
  # such as `swaylock-effects`; feeding the configured name to pgrep as a regex is also wrong for a
  # bare executable containing `[`, `.`, or `*`. The environment check prevents another Wayland
  # display owned by the same user from suppressing this display's gate. Every runtime tool is an
  # absolute store path, so the wrapper does not depend on a foreign user manager's ambient PATH.
  lockAtStartScript =
    let
      lockerName = lib.escapeShellArg lockBin;
      id = lib.getExe' pkgs.coreutils "id";
      pgrep = lib.getExe' pkgs.procps "pgrep";
      readlink = lib.getExe' pkgs.coreutils "readlink";
      sleep = lib.getExe' pkgs.coreutils "sleep";
      tr = lib.getExe' pkgs.coreutils "tr";
      grep = lib.getExe pkgs.gnugrep;
    in
    pkgs.writeShellScript "nixdesktop-lock-at-start" ''
      current_uid="$(${id} -u)"
      locker_is_running() {
        for candidate_pid in $(${pgrep} -u "$current_uid" -f .); do
          candidate_exe="$(${readlink} "/proc/$candidate_pid/exe" 2>/dev/null || true)"
          [ "''${candidate_exe##*/}" = ${lockerName} ] || continue
          if ${tr} '\0' '\n' < "/proc/$candidate_pid/environ" 2>/dev/null \
            | ${grep} -Fqx -- "WAYLAND_DISPLAY=$WAYLAND_DISPLAY"; then
            return 0
          fi
        done
        return 1
      }

      if locker_is_running; then
        exit 0
      fi

      ${
        if cfg.idleAndLock.lockAtStartCommandMode == "foreground"
        then ''
          ${lockerName} -f &
          launcher_pid=$!

          # A foreground command has no completion handshake. Require two consecutive sightings of
          # the configured executable on this display, rejecting exec-then-immediate-failure.
          attempt=0
          while [ "$attempt" -lt 100 ]; do
            if locker_is_running; then
              ${sleep} 0.05
              if locker_is_running; then
                exit 0
              fi
            fi
            attempt=$((attempt + 1))
            ${sleep} 0.05
          done

          echo "nixdesktop: foreground locker ${lockerName} did not stay running on $WAYLAND_DISPLAY" >&2
          if kill -0 "$launcher_pid" 2>/dev/null; then
            kill "$launcher_pid" 2>/dev/null || true
          fi
          wait "$launcher_pid" 2>/dev/null || true
          exit 1
        ''
        else ''
          ${lockerName} -f &
          launcher_pid=$!

          # The configured command promises that this launcher exits zero only after its child has
          # acquired the session lock. Wait for that exact handshake; observing either the parent
          # or child is not readiness. Bound a broken implementation so it cannot leave the user
          # manager in `starting` forever.
          attempt=0
          while kill -0 "$launcher_pid" 2>/dev/null; do
            if [ "$attempt" -ge 100 ]; then
              echo "nixdesktop: daemonizing locker ${lockerName} did not complete its readiness handshake on $WAYLAND_DISPLAY" >&2
              kill "$launcher_pid" 2>/dev/null || true
              wait "$launcher_pid" 2>/dev/null || true
              exit 1
            fi
            attempt=$((attempt + 1))
            ${sleep} 0.05
          done

          launcher_status=0
          wait "$launcher_pid" || launcher_status=$?
          if [ "$launcher_status" -ne 0 ]; then
            echo "nixdesktop: daemonizing locker ${lockerName} failed its readiness handshake on $WAYLAND_DISPLAY (status=$launcher_status)" >&2
            exit 1
          fi
          if ! locker_is_running; then
            echo "nixdesktop: daemonizing locker ${lockerName} reported readiness without a surviving child on $WAYLAND_DISPLAY" >&2
            exit 1
          fi
          exit 0
        ''
      }
    '';

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
  #   home-manager module has no root and no route to `security.wrappers` -- there is
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
  # proof this pass implements actually exercised end-to-end on the server (`systemd-run --user`
  # with `LoadCredentialEncrypted=` against a `--user --uid=1000`-scoped blob), and this module has
  # no way to guarantee a consumer's credential lands in one of `ImportCredential=`'s well-known
  # directories rather than wherever their own provisioning chose to put it. A consumer who DOES
  # keep the file at oo7's own default search location gets identical behaviour either way, since
  # oo7-daemon's packaged unit's `ImportCredential=` line fires independently of anything this
  # module renders -- the two are complementary belt-and-braces, not competing.
  #
  # `&& cfg.keyring.oo7.renderDaemon` on the oo7 branch, NOT a separate guard bolted on afterward:
  # `renderDaemon`'s own option doc (below, under `keyring.oo7`) has the full account of the live
  # bug this closes, but the reason it has to live HERE specifically, in the branch condition
  # itself rather than in a wrapper around this value, is a Nix laziness fact -- `cfg.keyring.oo7.
  # command` is MANDATORY with no default (see that option's own doc), so a host that sets
  # `renderDaemon = false` and therefore never states `command` at all (there is no daemon left
  # for this module to invoke) must never let evaluation TOUCH `cfg.keyring.oo7.command`, or it
  # throws "used but not defined" regardless of whether the resulting value would ever have been
  # read. Putting the guard in the `if` condition means the `then` branch, and `command` inside
  # it, is never forced when `renderDaemon` is false -- the same short-circuit discipline
  # `effectiveKeyringCommand`'s own guards elsewhere in this file already rely on.
  keyringProviderCommand =
    if cfg.keyring.oo7.enable && cfg.keyring.oo7.renderDaemon then cfg.keyring.oo7.command
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

  # ── oo7 keyring BOOTSTRAP command, assembled HERE ─────────────────────────────────────────────
  # See `keyring.oo7.credential.bootstrap`'s own header comment (below, by its `enable`) for the
  # full account of WHY this exists: oo7-daemon 0.6.0 will not conjure a brand-new encrypted
  # keyring from a readable credential alone -- it creates an in-memory LOCKED placeholder and then
  # blocks forever on a D-Bus Unlock prompt nothing on a headless/autologin host ever answers
  # (measured live, see that comment). `oo7-cli -k <path> -s <password> repair` is the fix, proved
  # live: it talks directly to the keyring FILE and never touches D-Bus or a Prompt at all.
  #
  # A plain shell one-liner (`command` + `runShell = true`, the existing mechanism above), NOT a
  # `pkgs.writeShellScript` -- unlike this module's own private per-host NixOS-plane sibling's
  # version of this identical mechanism, which can and does reach for `pkgs.writeShellScript`
  # because that file is not this repo. This module does not wrap the consumer-supplied oo7
  # package or invent a second command path for it -- the same reasoning
  # `execStartFor`'s own `runShell` branch already exists to serve for `idle`/`lock-at-start`
  # above, reused here rather than inventing a second code path.
  #
  # `install -d`, bare, PATH-resolved -- deliberately NOT `${pkgs.coreutils}/bin/install`, for the
  # identical reason `keyring.oo7.command` itself has no default and the component commands it
  # composes with (`swayidle`, `pkill`, `gnome-keyring-daemon`) are consumer-owned bare names: this
  # is a home-manager module, evaluated once and consumed on BOTH the NixOS-with-home-manager and
  # Arch/system-manager-with-home-manager planes this repo serves, and `install`/`cat`/`dirname`
  # are on every such host's own PATH by construction (base coreutils, not a package this repo
  # would ever need to name platform-specific paths for).
  oo7BootstrapCommand =
    let
      b = cfg.keyring.oo7.credential.bootstrap;
      credentialName = cfg.keyring.oo7.credential.name;
    in
    "install -d -m 0700 \"$(dirname ${b.keyringPath})\""
    + " && ${b.oo7CliCommand} -k ${b.keyringPath}"
    # `$CREDENTIALS_DIRECTORY` is systemd's own env var for a unit using `LoadCredentialEncrypted=`
    # (this unit's own `loadCredentialEncrypted` below reuses the SAME credential the daemon
    # itself loads -- one credential, two readers, see that option's own header). Nested double
    # quotes inside `$( )` are ordinary POSIX shell (the inner pair opens its own quoting context),
    # not an escaping bug -- proved live on three hosts already using this exact idiom, each in
    # its own private per-host config in the infra checkout this ports from.
    + " -s \"$(cat \"$CREDENTIALS_DIRECTORY/${credentialName}\")\""
    + " repair";

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
  # `/bin/sh`, ABSOLUTE, NOT bare `sh` -- verified live, the server (NixOS), 2026-08-03. A
  # persistent `--user` unit's own `ExecStart=` binary-name lookup for a NON-absolute command is
  # systemd's OWN internal search over a small compiled-in default list (`systemd.exec(5)`), and
  # that search NEVER consults the unit's own $PATH -- neither its `Environment=` nor the
  # manager's dynamic environment block (`systemctl --user set-environment`/`import-environment`).
  # Proved live, both directions: pointing the manager's own PATH at a nonexistent directory via
  # `set-environment` changed nothing (a bare `waybar` ExecStart still failed to resolve exactly
  # as before), and restoring the correct PATH afterward ALSO changed nothing (still failed) --
  # PATH is simply not part of this lookup at all. On NixOS this compiled-in list resolves
  # nothing real for a home-manager profile binary (waybar, mako, swaylock, ... all live under
  # `/etc/profiles/per-user/<user>/bin`, never `/usr/bin`) -- but even bare `sh` ITSELF failed
  # this exact lookup (`idle.service: Unable to locate executable 'sh'`), despite `/bin/sh`
  # genuinely existing on disk (NixOS's own POSIX-compat symlink, confirmed present and a valid
  # ELF-backed binary) -- so whatever this systemd build's compiled-in list nominally contains, it
  # does not functionally include `/bin` either. An ABSOLUTE path sidesteps the lookup entirely
  # (systemd never searches for an already-absolute ExecStart), and `/bin/sh` is the one absolute
  # interpreter path safe to assume on BOTH planes this module serves: NixOS maintains it as a
  # long-standing compatibility symlink specifically because so much software assumes it, and
  # Arch (where this module's other consumers run) has always had a real `/bin/sh`. Once systemd
  # can exec this one absolute program, everything `command` invokes AFTER it (a bare `swayidle`,
  # `swaylock`, `pkill`) resolves through the SHELL's own ordinary libc PATH search instead of
  # systemd's -- and that search DOES use the process's real, correct $PATH (same proof above,
  # the other direction: a shell run this same way successfully found every home-manager-profile
  # binary on that identical environment) -- so nothing downstream of this one hop needs to
  # change, and the plain-argv (non-shell) path below is untouched for the same reason: it is a
  # values problem there (see `polkitAgent.command`'s own doc), not a mechanism one.
  execStartFor = svc:
    if svc.runShell
    then ":/bin/sh -c ${escapeExecArg svc.command}"
    else svc.command;

  toSystemdUnit = _name: svc: {
    Unit = {
      Description = svc.description;
      PartOf = svc.partOf;
      After = svc.after;
      Requires = svc.requires;
      Before = svc.before;
      # Empty list renders no directive, same convention as every other list field here --
      # `bindsTo`'s own option doc has the one consumer (`readinessBridge`, below) and the full
      # reasoning for why `After=`/`Before=` ordering alone cannot express what this adds.
      BindsTo = svc.bindsTo;
    }
    # `ConditionPathExists` is omitted entirely, not rendered as `null`, when the option is left
    # at its own default -- home-manager's systemd module writes whatever key is present verbatim
    # into the unit file, so a present-but-null value would render a syntactically bogus
    # `ConditionPathExists=` line (no value after `=`) for every one of the many components that
    # never asked for this at all, rather than the same "absent means no directive" treatment
    # `loadCredentialEncrypted`'s own empty-attrset case already gets below.
    // lib.optionalAttrs (svc.conditionPathExists != null) {
      ConditionPathExists = svc.conditionPathExists;
    }
    # THE UNIT SECTION, NOT [Service], for both of these -- `man 5 systemd.unit` is where
    # `StartLimitIntervalSec=`/`StartLimitBurst=` are documented, and systemd still parsing them
    # under `[Service]` for backwards compatibility is exactly how they end up in the wrong section
    # by accident. Same "absent means no directive" treatment as `ConditionPathExists` immediately
    # above: a `null` renders nothing at all and leaves systemd's own defaults (5 starts per 10 s)
    # in place -- see this file's header for why those defaults kill this entire class of unit
    # permanently on a compositor with no readiness gate, and each option's own doc for the values.
    // lib.optionalAttrs (svc.startLimitIntervalSec != null) {
      StartLimitIntervalSec = svc.startLimitIntervalSec;
    }
    // lib.optionalAttrs (svc.startLimitBurst != null) {
      StartLimitBurst = svc.startLimitBurst;
    }
    // lib.optionalAttrs (svc.restartIfChanged != null) {
      X-RestartIfChanged = svc.restartIfChanged;
    };
    Service = {
      Type = svc.serviceType;
      ExecStart = execStartFor svc;
      Restart = svc.restart;
      RemainAfterExit = svc.remainAfterExit;
      Environment = lib.mapAttrsToList (k: v: "${k}=${v}") svc.environment;
      # One name per line; empty list renders no directive, same as `Environment=` above. See the
      # option's own doc for why an empty-string `Environment=` entry is not a substitute.
      UnsetEnvironment = svc.unsetEnvironment;
      # One `LoadCredentialEncrypted=ID:PATH` line per attr, same "always present, empty list
      # renders no directive" treatment as `Environment=` immediately above -- see
      # `loadCredentialEncrypted`'s own option doc for the mechanism this populates, and the
      # keyring assembly's header comment for the one convenience that fills it in today.
      LoadCredentialEncrypted =
        lib.mapAttrsToList (id: path: "${id}:${path}") svc.loadCredentialEncrypted;
    }
    # Same "absent means no directive" treatment as `ConditionPathExists` above, for the
    # identical reason: `NotifyAccess=` (unlike a list field) has no natural "empty" rendering,
    # so a present-but-null value would render a bogus bare `NotifyAccess=` line for every
    # component that never touched this option -- see `notifyAccess`'s own doc for its one
    # consumer.
    // lib.optionalAttrs (svc.notifyAccess != null) {
      NotifyAccess = svc.notifyAccess;
    }
    # The spacing half of the restart backoff (`StartLimitIntervalSec=`/`StartLimitBurst=`, its
    # budget half, are `[Unit]` directives and render above). Same absent-means-no-directive rule:
    # `null` leaves systemd's own 100ms in place. Inert for a component with `Restart=no`, which is
    # why it is rendered unconditionally rather than gated on `restart` -- systemd ignores it there,
    # and a gate would only make the rendered unit differ for no behavioural reason.
    // lib.optionalAttrs (svc.restartSec != null) {
      RestartSec = svc.restartSec;
    };
    Install = {
      WantedBy = svc.wantedBy;
    };
  };

  # The convenience blocks below only ever set the fields they have an actual opinion about;
  # everything else falls through to the generic submodule's own defaults. Each is wrapped in
  # `defaults` so that a consumer who also reaches into `nixdesktop.session.services.bar.*`
  # directly (the same generic mechanism these compile down to) overrides cleanly instead of
  # hitting a "conflicting definition" error.
  #
  # PER FIELD, NOT PER BLOCK, AND THAT DISTINCTION IS THE WHOLE POINT. These blocks used to be
  # written `bar = lib.mkDefault { command = ...; description = ...; }`, which does NOT do what it
  # reads like. `services` is `attrsOf (submodule ...)`, so `services.bar` is one option and
  # `mkDefault` there prices the WHOLE definition at priority 1000. A consumer definition of
  # `services.bar.environment` arrives at the default priority of 100, wins the option outright,
  # and the priced-out definition is DISCARDED rather than merged — taking `command` with it. The
  # failure is `The option 'nixdesktop.session.services.bar.command' was accessed but has no value
  # defined`, from a consumer who set something else entirely and never touched `command`.
  #
  # Pricing each FIELD instead leaves one definition per leaf option, so the submodule merges the
  # two definitions field-wise the way the comment above always claimed it did.
  defaults = lib.mapAttrs (_: lib.mkDefault);

  wellKnownServices =
    (lib.optionalAttrs cfg.bar.enable {
      bar = defaults {
        inherit (cfg.bar) command;
        description = "Status bar";
      };
    })
    // (lib.optionalAttrs cfg.notifications.enable {
      notifications = defaults {
        inherit (cfg.notifications) command;
        description = "Notification daemon";
      };
    })
    // (lib.optionalAttrs cfg.osd.enable {
      osd = defaults {
        inherit (cfg.osd) command;
        description = "On-screen-display server";
      };
    })
    // (lib.optionalAttrs cfg.patchbay.enable {
      patchbay = defaults {
        inherit (cfg.patchbay) command;
        description = "PipeWire patchbay, minimized to the tray (one click away, never fully gone -- see the option group's own header comment)";
        # OPPOSITE of `keyring`/`lock-at-start`'s `restart = "no"`, deliberately -- see the
        # `patchbay` option group's own header comment ("PROCESS SHAPE, MEASURED") for the full
        # reasoning. Short version: this is the one component in this file with an easily-reached,
        # ordinary "Quit" action (a menu item, a tray-context-menu entry) whose clean exit
        # `Restart=on-failure` -- the class default, correct for `bar`/`notifications`/`osd` above,
        # none of which expose a comparable quit -- would NOT bring back (exit 0 is not a
        # "failure" by systemd's own definition), permanently killing the tray icon the whole
        # "one click away" design depends on staying reachable for the rest of the session.
        restart = "always";
      };
    })
    // (lib.optionalAttrs cfg.readinessBridge.enable {
      "${cfg.readinessBridge.serviceName}" = defaults {
        command = ''systemd-notify --ready && while [ -S "${readinessSocketVariable}" ]; do sleep 2; done'';
        runShell = true;
        description = "Seated-session readiness bridge for ${cfg.readinessBridge.serviceName}.service";
        serviceType = "notify";
        notifyAccess = "all";
        restart = "no";
        partOf = [ ];
        after = [ ];
        wantedBy = [ ];
        before = [ "graphical-session.target" ];
        bindsTo = [ "graphical-session.target" ];
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
      "cliphist-text" = defaults {
        command = cfg.clipboardHistory.textCommand;
        description = "Clipboard history watcher (text)";
      };
      "cliphist-image" = defaults {
        command = cfg.clipboardHistory.imageCommand;
        description = "Clipboard history watcher (image)";
      };
    })
    # `effectiveIdleCommand` is null when there is no idle daemon to run at all (either
    # `lockAfterSeconds = null`, or an explicit `command = null` with no timeouts). Guarding on it
    # here rather than asserting keeps "enable the session layer, but this host never idle-locks" a
    # valid configuration instead of a build failure.
    // (lib.optionalAttrs (cfg.idleAndLock.enable && effectiveIdleCommand != null) {
      idle = defaults {
        command = effectiveIdleCommand;
        runShell = true;
        description = "Idle/lock daemon";
      };
    })
    # Gated on `lockAtStart` ALONE, never on `lockAfterSeconds` -- "gate the start, never lock on
    # idle" is a legitimate configuration (see the option's own doc), and tying this to the idle
    # daemon's existence would silently drop the only gate such a session has.
    #
    # Type=oneshot + RemainAfterExit is the session-lifetime latch. The wrapper applies the
    # configured command contract, returns only after that contract reports readiness, and then
    # remains active even after the human unlocks. PartOf=graphical-session.target clears the
    # latch at session teardown (and kills a still-running locker child through the unit's cgroup).
    // (lib.optionalAttrs (cfg.idleAndLock.enable && cfg.idleAndLock.lockAtStart) {
      "lock-at-start" = defaults {
        command = toString lockAtStartScript;
        description = "Lock the session at start (the one password this desk asks for)";
        serviceType = "oneshot";
        remainAfterExit = true;
        restart = "no";
        # sd-switch's KeepOld path applies to active units. The oneshot latch above deliberately
        # stays active after unlock, so activation changes cannot turn this into a mid-session lock.
        restartIfChanged = false;
        # `command` is an absolute store-path script, so systemd needs no shell parsing and the
        # script's own final `exec` resolves the consumer-supplied bare locker through its PATH.
        runShell = false;
      };
    })
    // (lib.optionalAttrs cfg.polkitAgent.enable {
      "polkit-agent" = defaults {
        inherit (cfg.polkitAgent) command environment;
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
    })
    # ── oo7 keyring bootstrap: THE MISSING MECHANISM, now supplied ──────────────────────────────
    #
    # Gated on the full chain (`keyring.enable` -> `oo7.enable` -> `credential.enable` ->
    # `credential.bootstrap.enable`), the same "guard before the generic submodule's own
    # non-nullable types ever see a misconfigured value" reasoning the `keyring` entry immediately
    # above already documents -- `config.assertions` below turns every INCOMPLETE combination
    # (bootstrap wanted but the credential or the provider it bootstraps is not) into a named
    # build failure rather than a silent no-op or a raw "not of type string" error.
    //
    (lib.optionalAttrs
      (cfg.keyring.enable && cfg.keyring.oo7.enable && cfg.keyring.oo7.credential.enable
      && cfg.keyring.oo7.credential.bootstrap.enable)
      {
        "oo7-keyring-bootstrap" = defaults {
          command = oo7BootstrapCommand;
          runShell = true;
          description = "Create the oo7 login keyring FILE, once, so oo7-daemon's credential-based unlock has something to unlock (idempotent, non-destructive)";
          serviceType = "oneshot";
          remainAfterExit = true;
          # "no", the same reasoning `keyring`'s own gnome-keyring branch and `lock-at-start`
          # already give: this wins once (the file now exists) or the daemon it prepares state for
          # was never going to work regardless -- there is nothing to gain by restart-looping a
          # bootstrap step, and `conditionPathExists` below already makes every run AFTER the first
          # a guaranteed, harmless no-op rather than something `restart` would ever need to rescue.
          restart = "no";
          # See this option's own header comment (by its declaration, above `partOf`) for the `!`
          # negation syntax and why a systemd Condition is what this needs rather than a shell-level
          # `[ -e ... ]` guard.
          conditionPathExists = "!${cfg.keyring.oo7.credential.bootstrap.keyringPath}";
          # The one direction `after`/`wantedBy` alone cannot express: the DAEMON must wait for
          # THIS, never the reverse. See `daemonServiceName`'s own option doc for the "!" negation
          # syntax's sibling story here -- the bare name is no longer hardcoded to this module's
          # own `keyring` entry, because it is not always the unit that needs waiting for (see
          # `oo7.renderDaemon`'s own doc for the live bug that forced this).
          before = [ "${cfg.keyring.oo7.credential.bootstrap.daemonServiceName}.service" ];
          # `wantedBy`/`partOf` pinned to `daemonServiceName`'s own sibling, `daemonTarget`, rather
          # than left at the generic per-component default (graphical-session.target) every OTHER
          # entry in this file safely relies on -- see `daemonTarget`'s own option doc for exactly
          # why leaving them at the generic default stops being correct the moment
          # `daemonServiceName` points outside this module's own rendering
          # (`oo7.renderDaemon = false`): `before` above only orders two units that land in the
          # SAME systemd transaction, and pinning these to the target the REAL daemon unit is
          # actually `WantedBy=` is what guarantees that.
          #
          # `after` IS EMPTY, AND THAT IS THE WHOLE POINT -- it used to name `daemonTarget` too,
          # alongside the `wantedBy` on the same target and the `before` on a daemon that is itself
          # `WantedBy=` it. Those three together are a CYCLE, because systemd gives every unit an
          # implicit `Before=` on the target that pulls it in: target -> daemon -> this -> target.
          # systemd breaks such a loop by silently DELETING one start job, and either outcome here
          # is a quiet disaster -- lose this unit's job and the daemon starts against a keyring
          # file that was never repaired (precisely what this bootstrap exists to prevent, failing
          # invisibly); lose the daemon's and the session has no Secret Service at all. See the
          # generic assertion in `config.assertions` below, which now names this shape for any
          # consumer who reconstructs it through `services.<name>` directly.
          #
          # Nothing is lost by dropping it. This unit's only real ordering requirement is "before
          # the daemon", which `before` states outright, and `wantedBy` still decides WHETHER it
          # runs at all. `basic.target` remains implicit via systemd's own default dependencies.
          after = [ ];
          wantedBy = [ cfg.keyring.oo7.credential.bootstrap.daemonTarget ];
          partOf = [ cfg.keyring.oo7.credential.bootstrap.daemonTarget ];
          # The identical credential the daemon itself loads (`keyringLoadCredentialEncrypted`,
          # already computed above) -- one credential, two readers, never a second copy asked for
          # here: `oo7-cli repair`'s `-s <password>` and oo7-daemon's own unlock must see the exact
          # same bytes, or the file this unit creates would not be the file the daemon can open.
          loadCredentialEncrypted = keyringLoadCredentialEncrypted;
        };
      });
  # ── ORDERING CYCLES THROUGH A PULL-IN TARGET ──────────────────────────────────────────────────
  #
  # THE SHAPE, which systemd punishes silently. Every unit a target pulls in gets an IMPLICIT
  # `Before=` on that target -- `systemctl show` reports it even though no unit file says it. So a
  # component that is `wantedBy` T and also `after` T sits on both sides of T at once. That is
  # harmless while nothing waits for the component. The moment a SIBLING that T also pulls in is
  # ordered after it, the loop closes:
  #
  #   T  ->  sibling (implicitly before T, waits for the component)
  #      ->  component (after T)
  #      ->  T
  #
  # WHAT SYSTEMD DOES WITH IT. Not an error, and not a failed unit: it picks one job in the loop
  # and DELETES it, logging one line against a unit that is not necessarily either of the two a
  # reader would go looking at.
  #
  #   Found ordering cycle: graphical-session.target/verify-active after bar.service/start
  #     after scroll-ipc-compat.service/start - after graphical-session.target
  #   Job bar.service/start deleted to break ordering cycle
  #
  # The victim then reports `inactive (dead)` with nothing failed and no error of its own -- it
  # simply is not there after a reboot, which is exactly how this arrived: a status bar that
  # stopped appearing, with a clean `systemctl --failed`.
  #
  # WHY AN ASSERTION AND NOT JUST A DOC NOTE. `after` and `wantedBy` both DEFAULT to
  # graphical-session.target here, so the dangerous half is what a consumer gets by writing
  # nothing at all; only the `before` (or a sibling's `after`) is ever typed deliberately, and it
  # reads entirely reasonable on its own. Nothing about the resulting config looks wrong, and the
  # failure surfaces one boot later as an absence. This is the check that turns it into a build
  # error naming both units.
  #
  # SCOPE. Only this module's own components, and only ordering they declare about each other --
  # `after`/`before` naming units from outside (`dbus.socket`, a foreign daemon) cannot be
  # resolved here and is left alone.
  cycleServices = lib.filterAttrs (_: svc: svc.enable) cfg.services;

  # `after`/`before` name UNITS ("foo.service"); `services` is keyed by the bare name.
  cycleUnitOf = name: "${name}.service";

  # Siblings ordered AFTER `name`, however that was expressed: this one's `before`, or theirs
  # `after`. Both directions describe the same edge and either is enough to close the loop.
  cycleWaitersOn = name:
    let svc = cycleServices.${name};
    in lib.unique (
      (lib.filter (o: o != name && lib.elem (cycleUnitOf o) svc.before) (lib.attrNames cycleServices))
      ++ (lib.attrNames (lib.filterAttrs
        (o: other: o != name && lib.elem (cycleUnitOf name) other.after)
        cycleServices))
    );

  # One entry per (target, component, sibling) loop that would actually be built.
  cycleFindings = lib.flatten (lib.mapAttrsToList
    (name: svc: lib.flatten (map
      (target: map
        (waiter: { inherit name target waiter; })
        (lib.filter (w: lib.elem target cycleServices.${w}.wantedBy) (cycleWaitersOn name)))
      # A target is only dangerous when this component is BOTH pulled in by it and ordered after
      # it -- either alone is the ordinary, correct pattern the whole file is built on.
      (lib.filter (t: lib.elem t svc.wantedBy) svc.after))
    )
    cycleServices);

  cycleMessage = f: ''
    nixdesktop.session.services.${f.name}: ordering cycle through ${f.target}.

      ${f.target}  ->  ${f.waiter} (pulled in by it, and waits for ${f.name})
                    ->  ${f.name} (after = [ "${f.target}" ], and pulled in by it too)
                    ->  ${f.target}

    Every unit a target pulls in is implicitly ordered BEFORE that target, so `${f.name}` being
    both `wantedBy` and `after` ${f.target} closes the loop as soon as a sibling waits for it.
    systemd does not fail this -- it deletes one start job to break the cycle and logs a single
    "Found ordering cycle" line, after which one of these two units is simply absent from the
    session with nothing marked failed.

    Fix it on `${f.name}`, which is the unit with the contradictory pair: drop `${f.target}` from
    its `after` (its `wantedBy` still decides whether it runs, and the sibling's own ordering
    still decides when), or order it after a target OUTSIDE the loop, such as
    graphical-session-pre.target.
  '';
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
              "on-failure" and the backoff configured by `restartSec`/`startLimitBurst`/
              `startLimitIntervalSec` below, a missing binary fails loudly ten times over roughly
              eighteen seconds and then parks in a `systemctl --user --failed`-visible failed state
              -- instead of spawn-at-startup's own behaviour, which is nothing, forever, with no
              diagnostic anywhere. Those three are what make that sentence true: under systemd's own
              UNCONFIGURED start-limiting (five attempts in ten seconds, 100ms apart) the identical
              wording would also be true of a component that merely started a second before its
              compositor did, which is how a whole desktop's worth of healthy components once ended
              the session dead -- see this file's header, "⚠ THE READINESS GUARANTEE IS
              CONDITIONAL".
            '';
          };

          restartIfChanged = lib.mkOption {
            type = lib.types.nullOr lib.types.bool;
            default = null;
            description = ''
              Home Manager sd-switch's `X-RestartIfChanged=` policy. `null` omits it and keeps
              sd-switch's default stop/start behavior; `false` preserves an active process when
              the rendered unit changes.
            '';
          };

          restartSec = lib.mkOption {
            type = lib.types.nullOr lib.types.ints.unsigned;
            default = 2;
            example = 5;
            description = ''
              systemd's `RestartSec=`, in seconds (a bare number is seconds, systemd's own default
              unit for this directive). THE SPACING half of this class's restart backoff; the
              BUDGET half is `startLimitBurst`/`startLimitIntervalSec` below. See this file's
              header ("⚠ THE READINESS GUARANTEE IS CONDITIONAL") for the measured session this
              exists to survive.

              systemd's unconfigured default is 100ms, and that value is the whole mechanism behind
              that failure rather than a detail of it: at 100ms a component exhausts five attempts
              inside half a second, so a compositor arriving even ONE second late outlives the
              component's entire restart budget and the component never runs again. Two seconds
              spreads `startLimitBurst` attempts across roughly eighteen seconds instead, which is
              what turns "the Wayland socket was not there yet" from permanent death into a few
              journal lines followed by a working bar.

              Not raised further, because this is also how long a human waits staring at a gap in
              the desktop when a component really did crash mid-session -- widening the retry BUDGET
              is `startLimitBurst`'s job, not this option's. Two seconds is also exactly what
              nixdesktop.launcher already uses for the compositor's own `RestartSec=`, so the whole
              session retries on one rhythm rather than two. `null` omits the directive entirely and
              restores systemd's own 100ms -- correct only for a component that genuinely should
              hot-loop, which nothing in this file is.
            '';
          };

          startLimitBurst = lib.mkOption {
            type = lib.types.nullOr lib.types.ints.unsigned;
            default = 10;
            example = 5;
            description = ''
              systemd's `StartLimitBurst=` (a `[Unit]` directive -- see `startLimitIntervalSec`
              below): how many starts are permitted inside one `startLimitIntervalSec` window
              before systemd refuses to start the unit again and parks it `failed` with
              `start-limit-hit`.

              Ten, against systemd's own default of five, and the number that matters is not this
              one but its product with `restartSec`: ten starts two seconds apart span roughly
              eighteen seconds of wall clock, and that span is the ENTIRE tolerance a component has
              for a compositor that is not accepting connections yet. Systemd's own defaults give
              that same tolerance a value of half a second, which is less than the one-second gap
              actually measured on a seated scroll session (see this file's header).

              Deliberately finite, not `0`/unlimited: this is what still lets a genuinely broken
              component (a missing binary, an unparseable config) reach a visible resting state in
              `systemctl --user --failed` rather than exec-failing every two seconds for the rest of
              the session -- the full argument is in the header, under "WHY NOT
              `StartLimitIntervalSec=0`". `null` omits the directive and restores systemd's own
              five.
            '';
          };

          startLimitIntervalSec = lib.mkOption {
            type = lib.types.nullOr lib.types.ints.unsigned;
            default = 60;
            example = 0;
            description = ''
              systemd's `StartLimitIntervalSec=`, in seconds -- the rolling window `startLimitBurst`
              counts starts within. Rendered into the unit's `[Unit]` section, where `man 5
              systemd.unit` documents both directives; systemd also still accepts them under
              `[Service]` for backwards compatibility, which is exactly how they end up in the wrong
              section by accident.

              Sixty seconds, against systemd's own ten. Wide enough that `startLimitBurst`
              attempts spaced `restartSec` apart (about eighteen seconds at the defaults) finish
              well inside one window -- which is what makes the BURST the thing that ends a
              hopeless unit, deterministically, rather than a window that happens to expire first
              and silently hands the unit an unlimited number of further attempts. It also catches a
              thrash class systemd's own default misses entirely: a unit failing every three seconds
              never fits five failures into a rolling ten-second window, so stock systemd
              restart-loops it for the whole session with no failed state and no end, while ten
              failures inside sixty seconds is a real thrash signature this parks.

              `0` disables start rate limiting altogether (systemd's own spelling for "retry
              forever") -- available deliberately, and deliberately not the default: see the
              header's "WHY NOT `StartLimitIntervalSec=0`" for why an unreachable failed state costs
              this module more than the extra retries buy it. `null` omits the directive and
              restores systemd's own ten seconds.
            '';
          };

          notifyAccess = lib.mkOption {
            type = lib.types.nullOr (lib.types.enum [ "main" "exec" "all" "none" ]);
            default = null;
            example = "all";
            description = ''
              systemd's `NotifyAccess=`. `null`, the default, omits the directive -- for
              `serviceType = "notify"`/`"notify-reload"` that leaves systemd's own default of
              `"main"` in effect, correct whenever the process that calls `sd_notify`/
              `systemd-notify` IS this unit's own main PID (a plain binary `command`, `runShell =
              false`).

              Set to `"all"` when `command` is shell-wrapped (`runShell = true`) and the shell
              itself calls `systemd-notify`: that call runs as a CHILD of the shell (the shell is
              MAINPID, not the notifier), so its READY=1 message arrives from a PID the default
              `"main"` access silently ignores -- proved live (`systemd-run --user` scratch-unit
              experiment, 2026-08-02): an otherwise identical unit, only `NotifyAccess=` changed,
              and the `"main"`-access version timed out waiting for a notification that had, in
              fact, already arrived a second earlier. `readinessBridge`, below, is the one
              consumer today.
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

          conditionPathExists = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "!/home/alice/.local/share/keyrings/login.keyring";
            description = ''
              systemd's `ConditionPathExists=` (`Unit.ConditionPathExists` in the rendered unit).
              `null`, the default, omits the directive entirely -- most components here have
              nothing conditional about them and render exactly as before this option existed.

              Added for a real, generic need this repo already had no way to express: a one-shot
              bootstrap step that must run AT MOST ONCE, ever, gated on some FILE it itself
              creates not existing yet (the `keyring.oo7.credential.bootstrap` convenience below is
              the first consumer). A leading `!` negates the condition, systemd's own documented
              syntax (`man 5 systemd.unit`) -- so `"!<path>"` reads as "run only when `<path>` is
              ABSENT", and a later start with the path present is marked "skipped" (not failed),
              not merely "guarded by a shell-level `[ -e ... ]` check that still counts as a
              successful run every time". This is the identical mechanism this module's own private
              per-host NixOS-plane sibling (plain NixOS, no home-manager) already uses via its own
              `unitConfig.ConditionPathExists` -- this option is the home-manager-module
              equivalent, not a different idea.
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
              replaces a `sleep 1` guess with a real dependency edge -- but WHAT that edge
              guarantees is a property of whichever unit pulls the target in, not of the target.
              On niri it is a genuine readiness gate (niri.service binds and precedes the target
              and is `Type=notify`, so the target is not reached until the compositor says it is
              ready -- see the header comment). On a compositor whose unit is `Type=simple`, such
              as a seated scroll session, it guarantees only that the compositor process has been
              FORKED: the Wayland socket may not exist for another second or more, and components
              ordered here will start and fail against it. The restart backoff
              (`restartSec`/`startLimitBurst`/`startLimitIntervalSec`, above) is what covers that
              gap -- ordering alone cannot, since there is no unit left to order against.
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

          before = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            example = [ "keyring.service" ];
            description = ''
              systemd's `Before=`. Empty by default -- ordinary session components have no unit
              that needs to wait FOR them (everything here is ordered AFTER
              graphical-session.target, never before a sibling). The one component that does is a
              one-shot bootstrap step that must complete before the real daemon it prepares state
              for ever starts (`keyring.oo7.credential.bootstrap`, below, orders itself
              `Before = [ "keyring.service" ]` this way) -- `After=`/`Wants=` alone cannot express
              that direction, since those only ever say what THIS unit waits for, never what waits
              for it. `readinessBridge`, below, is a second consumer, for a different reason --
              see `bindsTo`'s own doc.
            '';
          };

          bindsTo = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            example = [ "graphical-session.target" ];
            description = ''
              systemd's `BindsTo=`. Empty by default -- see `partOf`'s own doc for why an
              ordinary session component only ever STOPS with the target (`PartOf=`), never the
              reverse. `BindsTo=` is what expresses "pull the named unit in as a dependency when
              THIS one starts" (`man 5 systemd.unit`: BindsTo is Requires= plus stop
              propagation) -- the one thing `After=`/`Before=` ordering alone cannot do. Almost no
              consumer of this file needs it: `graphical-session.target` already has
              `RefuseManualStart=yes` (a real, systemd-shipped unit, `man 7 systemd.special` --
              not this repo's own invention) precisely so it is only ever reached as a
              dependency, never started directly. `readinessBridge`, below, is the one component
              here that FILLS that dependency role instead of depending on an already-running
              target -- see its own header for the full mechanism this field exists to support.
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

          unsetEnvironment = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            example = [ "SCROLLSOCK" "I3SOCK" ];
            description = ''
              systemd's `UnsetEnvironment=`: variables REMOVED from the environment this unit
              inherits, applied after everything else. Empty list renders no directive, same
              convention as the other list fields here.

              Not the same thing as `environment` with an empty value, and the difference is what
              this option is for. A variable set to "" is still SET, so any consumer that tests for
              presence rather than contents still finds it — which is exactly how a client library
              that probes several socket variables in priority order behaves. Only unsetting it
              makes the probe fall through to the next candidate.

              THE CASE THIS EXISTS FOR, so it is not rediscovered: pointing a sway-IPC client at a
              compatibility shim by setting `SWAYSOCK` alone does nothing if the compositor also
              exports its own variable (scroll exports `SCROLLSOCK`), because the client prefers
              the compositor-specific one and connects straight past the shim. Nothing fails, no
              error appears anywhere — the client simply talks to the compositor directly and
              behaves as though the shim were not installed.
            '';
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
              on the server, via SSH from a second host: a `systemd-run --user` unit given exactly
              this option's own directive, fed a host-key-encrypted blob
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
          (a compositor integration's OSD settings, for instance), which bind the
          volume/brightness/mic-mute keys
          to swayosd-client -- the client has nothing to talk to until this server is running.
        '';
      };
    };

    # ── patchbay: A LONG-RUNNING GUI PROCESS THAT LIVES IN THE TRAY, NOT A TRAY IMPLEMENTATION ────
    #
    # THE ASK, VERBATIM (operator, across several messages): "A patchbay like helvum is what I
    # need... I want to move away from waybar. But I want it to live in the tray and then when I
    # retool I want to be able to do so... different pipewire profiles or something would be
    # nice... unobtrusive daily, but just one click away in case you need to reprogram or do
    # recording." Three requirements follow directly: (1) invisible on an ordinary day, (2) one
    # click from a full graph editor when rewiring or recording, (3) the tray dependency must
    # survive a future compositor/shell swap (waybar today, whatever replaces it tomorrow) without
    # this component caring which -- so it must not be built around waybar's own tray module.
    #
    # ── ONE UNIT, NOT TWO -- UNLIKE `cliphist-text`/`cliphist-image` ABOVE ─────────────────────
    # cliphist split into two units because there are genuinely TWO independent OS processes with
    # two independent failure domains (two separate `wl-paste --watch` invocations -- see that
    # block's own comment). A patchbay minimized to the tray is the opposite shape: ONE process
    # with two VISUAL states (a hidden window plus a live StatusNotifierItem registration, or a
    # raised window) -- never two processes. Every tool in this category (a Qt/GTK graph editor
    # with an optional start-hidden flag) registers its own tray icon from inside the same process
    # that owns the window; there is no second binary to supervise. So this is ONE
    # `services.<name>` entry, the same shape as `bar`/`notifications`/`osd` above, not a pair.
    #
    # ── PROCESS SHAPE, MEASURED ────────────────────────────────────────────────────────────────
    # Type=simple -- the submodule's own default, left unset in `wellKnownServices` below rather
    # than restated, same as `bar`/`notifications`/`osd`. Every tool in this category is an
    # ordinary foreground GTK/Qt event-loop process: it never forks and exits the way
    # gnome-keyring-daemon does (see this file's `keyring` assembly, above, for the one component
    # here that genuinely needs `forking`). There is no double-fork to track, so the default is
    # already correct and restating it would only be noise.
    #
    # Restart=always -- NOT the submodule's own `on-failure` default, and the OPPOSITE of
    # `keyring`/`lock-at-start`'s `restart = "no"` above, deliberately. Those two are one-shot
    # units whose CLEAN exit (code 0) is the intended, successful, terminal state -- a keyring
    # daemon that finished bootstrapping, or a locker that exited because the human unlocked it,
    # has WON, and restarting either would be actively wrong (see their own comments). A patchbay
    # minimized to the tray has no equivalent "done" state: its entire value is being reachable
    # with one click for the ENTIRE session, exactly like `bar`/`notifications`/`osd` above -- but
    # unlike those three, a graph editor is a full application window with a completely ordinary,
    # easily-reached Quit action (a menu item, a tray-context-menu entry) that a bar or notifier
    # simply does not expose. That quit exits cleanly (code 0) -- exactly the exit code
    # `Restart=on-failure` (the class default that already suffices for `bar`/`notifications`/
    # `osd`, none of which offer a comparable one-click quit) does NOT restart on, by systemd's own
    # documented definition of "failure". Left at the default here, one accidental "Quit" click
    # would permanently kill both the process AND the tray icon the operator would otherwise click
    # to bring it back -- the exact silent, unrecoverable gap the "one click away" design this
    # component exists to satisfy cannot tolerate. `Restart=always` restarts regardless of exit
    # code, so a clean voluntary quit comes back exactly like a crash does: the tray icon is never
    # permanently gone for the rest of a session. The cost -- it can never be TRULY stopped except
    # via `systemctl --user stop`, or disabling this option and re-switching -- is the correct
    # trade for a component whose whole reason to exist is "always there to click".
    #
    # ── THE SNI-HOST DEPENDENCY, NAMED HONESTLY, NOT PRETENDED AWAY ────────────────────────────
    # A tray icon is not free-floating pixels: the process above only ever REGISTERS itself as a
    # StatusNotifierItem over D-Bus (the freedesktop/KDE StatusNotifierItem specification, the
    # mechanism every "system tray" on Wayland actually uses -- there is no compositor-native tray
    # protocol). Registering has nowhere to draw unless something else on the session implements
    # the other half, a StatusNotifierHost -- on this estate that is waybar's own `tray` module
    # today (see profiles/desktop.nix's `bar` option: "waybar ... has a real SNI tray"). With NO
    # host running, the unit below is in every respect a perfectly healthy, running, non-crashing
    # systemd service -- `systemctl --user status` shows it green -- and the operator has no way to
    # reach it at all: no icon, no error, nothing. That is precisely the silent-failure class this
    # whole repo exists to eliminate (see the file header above), and it cannot be solved by
    # asserting "waybar is enabled": the operator's own stated intent is to move OFF waybar and
    # onto some other shell later, and hard-coupling this component to one specific bar
    # implementation would make it break the moment that migration happens -- the opposite of what
    # was asked.
    #
    # So this module cannot know the answer (home-manager's `nixdesktop.session` and the NixOS/
    # system-manager-plane `nixdesktop.desktop.bar` role that actually resolves an SNI host today,
    # profiles/desktop.nix, are different module TREES, not reliably composed together in every
    # consumer -- home-manager here is explicitly usable standalone too, per this repo's own
    # README), and it does not pretend to. `trayHostAvailable`, below, is a fact the consumer
    # states instead -- the same shape `nixdesktop.sessions.<name>.vt` (modules/session.nix)
    # already uses for "a fact only the consumer's own host config can know". Left false, the
    # difference shows up as a `config.warnings` entry, loud on every `home-manager switch` and
    # never silent -- not a hard assertion, because running with no visible tray icon is a
    # legitimate transitional state (the exact state the operator described moving through) rather
    # than a misconfiguration this module should refuse to build.
    #
    # ── THE TOOL CHOICE, RESEARCHED, NOT ASSUMED (verified 2026-08-01) ────────────────────────
    # This repo names no package (see the file header: "package names ... are platform-specific"),
    # but it does record the one capability fact that should drive whichever tool a consumer picks,
    # because getting this wrong produces a tool that LOOKS right and then cannot do what was
    # asked. A mixer-shaped control (`pavucontrol`, a native volume mixer, `pactl`/`wpctl` used
    # directly) shares one structural limit regardless of how polished its UI is: moving a stream
    # to a sink is a METADATA assignment (`target.node`, one value -- the same operation `wpctl
    # set-default` performs), which can only ever name ONE destination. It cannot express "this
    # microphone feeds BOTH the recording software and the monitoring/voice-chat output at once" --
    # exactly the "recording microphones and something" fan-out the operator asked for. A
    # PATCHBAY-shaped tool (arbitrary port-to-port LINK creation -- dragging a cable between two
    # dots) is structurally different: creating a second link out of one output port ADDS a
    # connection rather than replacing the existing one, because link creation, unlike a metadata
    # assignment, carries no "exactly one" constraint anywhere in PipeWire's own object model.
    # Splitting one source to two sinks is therefore not a matter of which patchbay looks nicer --
    # it is the one thing only a patchbay-shaped tool, never a mixer-shaped one, can do at all.
    #
    # Two well-known implementations of that shape were compared for this repo (checked live
    # against both projects' own upstream repositories on 2026-08-01, not assumed from memory): one
    # is written in Rust/GTK4 and was DROPPED from nixpkgs in March 2026 as upstream-unmaintained (a
    # maintainer ping went unanswered; a dependency audit found an open RUSTSEC advisory in a
    # transitive crate), then briefly reinstated in May 2026 alongside a single 0.6.2 release, with
    # no further upstream commits since. The other, Qt/Widgets-based, remains in active day-to-day
    # upstream development (a commit landed the day before this was verified) and additionally
    # offers something neither the mixer class nor the less-active patchbay does: saving a
    # connection arrangement to a file and reapplying it later, matched by stable port name. That
    # second capability is the direct answer to "so different pipewire profiles or something would
    # be nice" (see the disambiguation immediately below) -- a saved, reloadable ROUTING
    # ARRANGEMENT is not a feature either the mixer class or PipeWire itself provides at all; it
    # exists only inside whichever patchbay implementation bothers to persist one. This repo states
    # the capability, not a name, so this comparison is worth re-running before picking -- current
    # maintenance status is exactly the kind of fact that goes stale.
    #
    # ── "PIPEWIRE PROFILES", DISAMBIGUATED -- THIS ESTATE HAS ALREADY BEEN BITTEN BY THE OVERLAP ──
    # The operator's own word, "profiles", names TWO things that share no code path, and only one
    # of them is anything this component (or PipeWire/WirePlumber themselves) can address at all:
    #
    #   (1) A per-card ALSA profile -- what `wpctl set-profile` / `pactl set-card-profile` actually
    #       changes (PipeWire's `EnumProfile`/`Profile` SPA params on a Device object): which of a
    #       sound card's physical modes is active (a plain stereo output vs. a multi-port
    #       "Pro Audio" mode, say). This is a REAL, native PipeWire/WirePlumber concept, but this
    #       component has nothing to do with it -- it is a property of a card, set through a
    #       completely different mechanism, and nothing here reads or writes it.
    #
    #   (2) A saved ROUTING ARRANGEMENT -- "my recording setup": the studio microphone feeding both
    #       the interface's own monitor path AND the recording software at once. THIS DOES NOT
    #       EXIST as a native object anywhere in PipeWire or WirePlumber -- there is no "scene", no
    #       link-set, nothing a `wpctl`/`pactl` command could name. It exists ONLY as whatever a
    #       patchbay implementation with save/restore support persists on disk, matched by port
    #       name at reload time. THIS is the sense the operator meant, and it is real -- but it is
    #       USER STATE the chosen tool owns, not something this module renders or could ever
    #       render: a Nix option cannot declare "which cable is plugged into which dot today" any
    #       more sensibly than it could declare today's clipboard contents. `command` below starts
    #       the tool; what gets wired inside it, and any file it saves to remember that wiring, is
    #       that tool's own business -- the same boundary `keyring`'s own `oo7`/`gnomeKeyring` split
    #       draws between "which daemon runs" (this module's job) and "what secrets it holds"
    #       (never this module's job, or any Nix module's).
    patchbay = {
      enable = lib.mkEnableOption ''
        a PipeWire patchbay/graph-editor GUI, run as a systemd user service and left running for
        the whole session so a tray click can always raise it -- see the header comment above this
        option group for the full account of why this is ONE unit (not a pair, unlike
        `clipboardHistory`), why its `restart` is deliberately the opposite of `keyring`/
        `lock-at-start`'s "no", the real StatusNotifierItem-host dependency a tray icon has and why
        this module cannot resolve it for you (`trayHostAvailable`, below), the researched
        capability that should drive which tool you pick (`command`, below), and why "PipeWire
        profile" means two unrelated things, only one of which this component can ever touch.
      '';

      command = lib.mkOption {
        type = lib.types.str;
        example = "your-chosen-patchbay --start-hidden";
        description = ''
          The patchbay invocation. NO DEFAULT, deliberately, unlike `bar`/`osd` above: this repo
          measured a real, dated gap between the current maintenance state of the well-known
          implementations of this capability (see the header comment's "THE TOOL CHOICE" section)
          and declines to bake in today's winner as a silent default that would go stale the
          moment that measurement changes -- pick one against the CAPABILITY checklist below, not
          this option's own (deliberately non-specific) example.

          The tool must be able to do TWO things a mixer-shaped app (pavucontrol, a native volume
          mixer, `pactl`/`wpctl` used directly) structurally cannot: (1) create an arbitrary
          port-to-port LINK rather than merely reassigning a stream's one destination, which is the
          only way to express one source feeding two sinks at once (see the header comment for why
          this is a structural difference, not a UI preference); and, for the "different pipewire
          profiles" ask specifically, (2) save a connection arrangement and reapply it later,
          matched by stable port name -- since no such saved arrangement exists anywhere in
          PipeWire/WirePlumber itself (see the header comment's disambiguation of "profile").

          Include whatever start-hidden/start-minimized flag your chosen tool offers, if it has
          one, so the window does not flash visibly at every session start -- there is no universal
          flag name across implementations for this module to supply on your behalf. Without one,
          the tool still works (and the unit below is exactly as correct), it just draws a window
          for a moment before you would have to minimize it by hand the first time.
        '';
      };

      trayHostAvailable = lib.mkOption {
        type = lib.types.bool;
        example = true;
        description = ''
          Whether SOMETHING on this session already implements a StatusNotifierHost -- the D-Bus
          role that actually draws a tray icon a StatusNotifierItem client (this component)
          registers with. See the header comment's "THE SNI-HOST DEPENDENCY" section for the full
          account of why this module cannot answer that question itself (this repo's own
          `nixdesktop.desktop.bar` role, profiles/desktop.nix, resolves an SNI host today via
          waybar's `tray` module -- but that is a different module TREE, not reliably composed
          alongside this home-manager one, and coupling this component to waybar specifically is
          exactly what the operator's own move-off-waybar intent rules out).

          REQUIRED, WITH NO DEFAULT -- the same "guessing either way is wrong" reasoning
          `nixdesktop.sessions.<name>.vt` (modules/session.nix) already uses for an equally
          unknowable-from-here host fact. `true` when a host is running (waybar's tray module,
          today, or whatever replaces it once the operator retools): the unit below renders exactly
          as it would otherwise, no warning. `false` renders the identical unit -- the process
          still runs, and still does real work over D-Bus/PipeWire regardless of whether anything
          can currently draw its icon -- but adds a `config.warnings` entry, because a healthy,
          running, `systemctl --user status`-green unit with a tray icon nobody can see is
          precisely the silent-failure class this repo exists to eliminate, and staying quiet about
          a state this module can see coming would be exactly that failure, just moved one file
          over.
        '';
      };
    };

    # ── readinessBridge: a notify-capable seated compositor's user-session bridge ─────────────
    # A seated compositor runs as a system unit, so its packaged user unit cannot pull in
    # `graphical-session.target`. The launcher starts this thin user service only after a
    # notify-capable compositor reports readiness. It immediately mirrors that readiness and
    # remains alive while the integration-supplied IPC socket exists. `BindsTo=` and `Before=`
    # give it the target-owning shape without launching a second compositor. The compositor
    # integration owns both names because neither the service name nor socket variable is neutral.
    readinessBridge = {
      enable = lib.mkEnableOption ''
        a thin compositor readiness service that bridges a seated system unit into
        graphical-session.target
      '';

      serviceName = lib.mkOption {
        type = lib.types.str;
        example = "ciri";
        description = ''
          User-service name the seated launcher starts after the compositor reports readiness.
          The compositor integration supplies this value.
        '';
      };

      socketEnvironment = lib.mkOption {
        type = lib.types.str;
        example = "CIRI_SOCKET";
        description = ''
          Environment variable naming the compositor's IPC socket. The bridge remains alive
          while that socket exists and exits when the seated compositor disappears.
        '';
      };
    };

    clipboardHistory = {
      enable = lib.mkEnableOption "cliphist watcher services (two -- see the header comment for why)";

      # `textCommand`/`imageCommand`, ADDED -- until this pass these two invocations were
      # hardcoded bare strings inside `wellKnownServices` itself, the ONLY pair in this whole
      # module with no override hook at all (every sibling -- `bar`, `notifications`, `osd`,
      # `polkitAgent` -- already exposes `command`). That gap was invisible as long as `wl-paste`/
      # `cliphist` only ever needed to resolve on a platform where systemd's own bare-ExecStart
      # search actually finds them (Arch's real `/usr/bin`); it became a real build-time need on
      # NixOS, where they don't (see `execStartFor`'s own header for the mechanism) and a
      # consumer has no way to hand this module an absolute path the way `polkitAgent.command`'s
      # own doc already documents for the identical situation. Bare defaults, unchanged from
      # before this pass, so no existing consumer's rendered unit changes.
      textCommand = lib.mkOption {
        type = lib.types.str;
        default = "wl-paste --type text --watch cliphist store";
        description = ''
          The text-watcher invocation, plain argv (no shell) by default -- same "cheaper path"
          shape as `bar.command`/`notifications.command`/`osd.command`. A platform whose systemd
          cannot resolve a bare ExecStart via $PATH needs this overridden to an absolute path,
          the same way `polkitAgent.command`'s own doc already documents for that case.
        '';
      };

      imageCommand = lib.mkOption {
        type = lib.types.str;
        default = "wl-paste --type image --watch cliphist store";
        description = "The image-watcher invocation -- see `textCommand`'s own doc, identical shape.";
      };
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

      lockAtStartCommandMode = lib.mkOption {
        type = lib.types.enum [ "foreground" "daemonizing" ];
        default = "daemonizing";
        description = ''
          The process contract implemented by `lockCommand -f` when `lockAtStart` starts it.

          `daemonizing` means the launched parent exits zero only after a surviving child has
          acquired the compositor's session lock, and exits nonzero on failure. The wrapper waits
          for that parent instead of treating its mere presence as readiness, then verifies the
          child. This is the default because it is the `-f`/`--daemonize` contract of both swaylock
          1.8.6 (`-F`/`--show-failed-attempts` is a different flag) and nixlock >= 0.1.3. Setting
          this mode for a command that merely forks without a post-lock readiness handshake would
          make the gate dishonest.

          `foreground` is an explicit compatibility mode for a custom or legacy command whose
          `-f` genuinely remains as the lock-owning process. The wrapper backgrounds it and accepts
          only a stable exact executable on this Wayland display; process stability cannot prove
          compositor lock acquisition, so do not select it for a daemonizing command.
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
        example = "/usr/lib/soteria-polkit/soteria";
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

      environment = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { GSK_RENDERER = "cairo"; };
        example = { GSK_RENDERER = "cairo"; };
        description = ''
          Environment scoped to the authentication-agent process. The default keeps GTK4 agents
          such as Soteria on GTK's CPU-side Cairo renderer; non-GTK agents simply ignore it.
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

        # ── renderDaemon: WHETHER THIS MODULE OWNS THE DAEMON UNIT AT ALL ─────────────────────────
        #
        # THE BUG THIS OPTION EXISTS TO NAME, MEASURED LIVE (the workstation, 2026-08-03). The
        # pacman `oo7` package installs its OWN `--user` unit at the identical bare name this
        # module's own `keyring` entry uses for a DIFFERENT unit
        # (`/usr/lib/systemd/user/oo7-daemon.service`, `[Install] WantedBy=default.target`,
        # `ImportCredential=oo7.keyring-encryption-password` -- the exact shipped text is quoted in
        # full in the keyring assembly's own header comment, above). On a host that never masks
        # that vendor unit (unlike this module's own private per-host predecessor's deliberate
        # `mkOutOfStoreSymlink "/dev/null"` mask -- see that file's header for why THAT host's
        # shape is different, and correct, on its own terms), the vendor unit wins
        # `org.freedesktop.secrets` every single time: `default.target` is the base target a
        # `--user` manager reaches at STARTUP, strictly before `graphical-session.target` is ever
        # pulled in by a compositor (this file's own header, "THE ORDERING TARGET") -- so by the
        # time this module's own `keyring` entry (`WantedBy=graphical-session.target`, the same
        # default every other component here uses) even starts, the vendor daemon has already
        # claimed the bus name. Confirmed live: `busctl --user list` on that host shows the VENDOR
        # unit owning `org.freedesktop.secrets`, healthy; this module's own `keyring.service` loses
        # the `RequestName` race every time and sits permanently `failed`. Secrets keep working
        # throughout (the vendor unit provides them) -- the bug is a duplicate, doomed-to-fail unit
        # left behind by every `home-manager switch`, not a secrets outage.
        #
        # `renderDaemon = false` is the fix: this module still renders EVERYTHING ELSE the oo7
        # provider needs -- `credential`/`credential.bootstrap` below are real `--user`-manager
        # units this module is the ONLY thing that can render on a system-manager host at all (see
        # `modules/oo7-keyring-bootstrap.nix`'s own header, "WHY THIS IS THE ONE GENUINELY
        # IRREDUCIBLE SPLIT") -- it just stops ALSO rendering a second copy of the daemon itself.
        # `credential.bootstrap.daemonServiceName`/`.daemonTarget` (below, that option group's own
        # fields) are what then let the bootstrap step order itself correctly against whichever
        # unit actually IS the daemon on such a host, instead of a name (`keyring.service`) that no
        # longer exists to order against at all -- see those two options' own docs.
        #
        # `true`, the default, is unchanged behaviour for every host that does not opt out: this
        # module renders its own `keyring.service` exactly as it always has, which remains the
        # RIGHT shape both for a platform with no working vendor unit of its own (this module's
        # own private per-host NixOS-plane sibling, `modules/oo7-keyring-bootstrap.nix`, draws the
        # identical "this module never declares the daemon" line for the identical reason, but
        # NixOS's `services.oo7.enable` -- a SEPARATE module this repo does not own -- is what
        # supplies primary's actual daemon, always; there is no "renderDaemon" toggle needed on
        # that plane because the daemon was never this module's to render in the first place) and
        # for a host that, like this module's own private per-host predecessor, has deliberately
        # masked the vendor unit and wants THIS module's own daemon to be the one and only
        # implementation.
        #
        # WHY NOT nixarch's `modules/foreign-service.nix` ("pacman owns the binary and the unit,
        # Nix owns only the config, never render a second unit" -- the identical DOCTRINE this
        # option applies). Considered and rejected as the implementation, not merely unconsidered:
        # that module is SYSTEM-scoped throughout (`environment.etc`, `systemd.services`, a
        # system-manager-only `config` block) and solves a differently-shaped problem -- it takes
        # over a foreign daemon's ON-DISK CONFIG FILE and re-triggers it (`restartUnits`/`reapply`)
        # whenever that file's content changes; it has no notion of `systemd.user.services` at all
        # (oo7-daemon is a `--user` unit -- see this file's own header, "THE ORDERING TARGET" --
        # and there is no `nixarch.foreignServices`-shaped config file to take over here in the
        # first place, only two units that need correct RELATIVE ORDERING). Forcing this gap
        # through that module would mean inventing a fake `configFiles` entry and a `reapply`
        # script for a problem that was never about a config file, the exact "worse legibility for
        # no real gain" nixarch's own README warns against elsewhere in this repo. The two modules
        # share a doctrine, not a shape -- this stays a home-manager-plane option instead.
        renderDaemon = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Whether this module renders its own `keyring` unit (the `oo7-daemon` invocation
            configured via `command` above) at all. See the header comment on this option, above,
            for the live bug this exists to name and fix -- rendering a second daemon alongside a
            platform vendor unit that already owns `org.freedesktop.secrets` produces a
            permanently-failed duplicate, not a second working provider (a systemd D-Bus
            `RequestName` race has exactly one winner, always).

            Set `false` on a host whose platform package already ships and starts a healthy
            `org.freedesktop.secrets` daemon of its own (a pacman `oo7` package's packaged unit,
            confirmed live via `busctl --user list` showing IT as the name's owner) -- this module
            then renders only the credential + first-keyring bootstrap machinery (`credential.*`,
            below), ordered against that EXTERNAL unit via `credential.bootstrap.
            daemonServiceName`/`.daemonTarget` instead of against a `keyring.service` this module
            no longer creates. `config.assertions` below refuses the one combination this cannot
            express safely: `renderDaemon = false` with `daemonServiceName` left at its own
            self-referential default.
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

          # ── bootstrap: THE FIRST-KEYRING GAP, MEASURED, NOT ASSUMED CLOSED BY THE CREDENTIAL ──
          #
          # THE GAP. A daemon that can read its unlock credential still cannot conjure a keyring to
          # unlock out of nothing. Measured live (this module's own private per-host predecessor in
          # the infra checkout this ports from, before nixdesktop carried any answer of its own):
          # on a data directory with no keyring file present, oo7-daemon 0.6.0 logs `Unlocking session keyring with
          # user's systemd credentials` (it DID read the credential), immediately followed by `No
          # default collection found, creating 'Login' keyring` / `Keyring file not found, creating
          # a new one` / `Created default 'Login' collection (locked)` -- i.e. the credential is
          # read and then simply has nothing to unlock, so the daemon falls back to an in-memory
          # LOCKED placeholder collection (`oo7::file::locked_keyring`, a distinct type from a real
          # file-backed `Keyring` a password can unlock) that stays `Locked = true` regardless.
          # `oo7-cli unlock -s ""` against it fails outright (`Keyring file doesn't support
          # unlocking`), and a `store` call opens a D-Bus Prompt and blocks forever waiting for a
          # `Completed` signal nothing on a headless/autologin host ever sends -- no portal, no GUI,
          # and the systemd credential is never consulted by that code path at all.
          #
          # THE FIX, proved live end-to-end. `oo7-cli` has a second, entirely separate mode that
          # talks directly to a keyring FILE (`-k <path> -s <secret> repair`) and never touches
          # D-Bus or a Prompt at all: it creates a real, empty, password-encrypted keyring file with
          # zero D-Bus round-trip (proved: a fresh path with no items needed came back "0 broken
          # items were deleted", genuinely AES-encrypted -- the plaintext password appears nowhere
          # in the resulting bytes, and a wrong password on lookup fails with "Item is not valid and
          # cannot be decrypted" rather than silently succeeding). Land that file at the exact
          # well-known path oo7-daemon's own startup scan looks for, BEFORE oo7-daemon ever starts,
          # and its normal startup path changes completely: `Scanning for v0 keyrings in .../
          # keyrings` / `Found v0 keyring: <name>` / `Unlocked keyring '<name>' from "..."` /
          # `Locked = false`, zero prompts.
          #
          # WHY THIS NEVER TOUCHES `oo7.command`'s OWN `keyring.service` UNIT DIRECTLY. This is a
          # SEPARATE one-shot unit (`oo7-keyring-bootstrap`, wired into `wellKnownServices` above),
          # not a `serviceType = "oneshot"` override smuggled onto the daemon's own entry -- the
          # daemon unit must stay a real, restartable `Type = "simple"` long-running process (see
          # the keyring assembly's own header, "oo7-daemon -- DOES NOT MATCH gnome-keyring's
          # shape"), and a one-shot gate that runs once and a long-running daemon that runs forever
          # are two different systemd unit shapes with no way to be the same unit. `before = [
          # "<daemonServiceName>.service" ]` on the bootstrap entry (not `after` on the daemon's
          # own) is what orders them, since `keyring`'s own assembly (above) has no reason to know
          # a bootstrap step exists at all when this is disabled -- see `before`'s own generic
          # option doc. `daemonServiceName` (below), NOT a hardcoded `"keyring.service"`: the unit
          # that actually needs waiting for is not always this module's own `keyring` entry -- see
          # `oo7.renderDaemon`'s own doc for the live bug that forced the name to become a value
          # the consumer states, the same way `daemonTarget` (also below) forced `after`/
          # `wantedBy`/`partOf` to stop being an unstated assumption too.
          bootstrap = {
            enable = lib.mkEnableOption ''
              close the first-keyring gap above by running `oo7-cli -k <keyringPath> -s <password>
              repair` once, gated on `keyringPath` not already existing, strictly before
              `daemonServiceName` (oo7-daemon itself, by default this module's own `keyring.
              service`) ever starts. Requires `credential.enable` (this reuses the identical
              credential the daemon loads -- see this option's own header) -- meaningless, and
              asserted against, otherwise.

              LEAVE THIS OFF for a host whose keyring file already holds real secrets under some
              OTHER name than `keyringPath` names (a migrated Default_keyring.keyring, say): this
              mechanism only ever CREATES an empty keyring at a path that does not yet exist, it
              never touches, renames, or shadows one that is already there under a different name.
              Point `keyringPath` at the file that is actually meant to be the login keyring, or
              leave `bootstrap.enable = false` and provision that first keyring some other way.
            '';

            keyringPath = lib.mkOption {
              type = lib.types.str;
              example = "/home/alice/.local/share/keyrings/login.keyring";
              description = ''
                The keyring FILE to create if (and only if) it does not exist yet -- the exact
                well-known path oo7-daemon's own startup scan looks for. NO DEFAULT: the FILENAME
                is not fixed across hosts -- gnome-keyring's own convention names the default
                collection `login.keyring`, and oo7 stays compatible with that layout (confirmed
                live via oo7-daemon's own DEBUG log: `Found v0 keyring: login`), but a host that
                migrated from a differently-named collection (`Default_keyring.keyring`, observed
                on at least one host in this estate) must point here instead -- see this option
                group's own `enable` doc for why this mechanism must never invent a second, empty,
                competing keyring under a name nothing already uses. Resolves relative to nothing:
                give the full path (`$HOME` does not expand inside a Nix string -- interpolate
                `config.home.homeDirectory` yourself, the same way this repo's own checks do).
              '';
            };

            oo7CliCommand = lib.mkOption {
              type = lib.types.str;
              example = lib.literalExpression ''"''${pkgs.oo7}/bin/oo7-cli"'';
              description = ''
                `oo7-cli` invocation -- NO DEFAULT, deliberately, the same reasoning as `oo7.
                command` above: `oo7-cli`'s installed location differs per platform (confirmed live
                against BOTH: nixpkgs' `oo7` package installs it to `$out/bin/oo7-cli`, ON PATH,
                unlike `oo7-daemon`'s own `$out/libexec/oo7-daemon`; the real Arch `oo7` 0.6.0-3
                package installs it to `/usr/bin/oo7-cli`, also on PATH, again unlike
                `oo7-daemon`'s own `/usr/lib/oo7-daemon`) -- so unlike the daemon binary, a bare
                `"oo7-cli"` WOULD resolve correctly on either platform via PATH alone. Left
                mandatory with no default anyway, matching `oo7.command`'s own convention rather
                than special-casing this one binary as the exception: this repo names no package,
                full stop, and a silent default here would be exactly the kind of package-name
                knowledge the file header says this module never carries.
              '';
            };

            daemonServiceName = lib.mkOption {
              type = lib.types.str;
              default = "keyring";
              example = "oo7-daemon";
              description = ''
                The BARE name (no `.service` suffix) of the `nixdesktop.session.services` entry
                this bootstrap step must complete before -- mirrors `modules/oo7-keyring-
                bootstrap.nix`'s own `daemonServiceName` option on the NixOS-only sibling module
                (same name, same purpose: that module's own header names THIS option group as the
                system-manager plane's equivalent mechanism, so the option is ported here rather
                than reinvented under a different name).

                Defaults to `"keyring"` -- this module's OWN rendered daemon entry (see `oo7.
                renderDaemon`'s own doc, above), correct exactly as long as that default
                (`renderDaemon = true`) is also in effect: the two are a matched pair, never
                independently free to disagree. Set this to the REAL vendor unit's bare name (e.g.
                `"oo7-daemon"`, the pacman `oo7` package's own packaged unit -- see the keyring
                assembly's header comment for its exact shipped unit text) whenever `oo7.
                renderDaemon = false` names an externally-owned daemon instead. Getting this wrong
                does not fail loudly: systemd treats `Before=` ordering against a unit that is
                never created as a silent no-op, so a stale `"keyring"` left behind after flipping
                `renderDaemon` to `false` does not break the build, it just silently stops closing
                the gap this whole mechanism exists for -- `config.assertions` below catches
                exactly that one combination, and `checks/oo7-convergence.nix` (the infra checkout)
                proves it against each host's own real rendered config, not merely against this
                option's own default.
              '';
            };

            daemonTarget = lib.mkOption {
              type = lib.types.str;
              default = "graphical-session.target";
              example = "default.target";
              description = ''
                The systemd user target this bootstrap step shares with the daemon named by
                `daemonServiceName` -- pinned onto `after`/`wantedBy`/`partOf` all three at once,
                instead of leaving those three at the generic per-component default every OTHER
                entry in this file safely relies on (see each of those options' own docs: an
                ordinary component's daemon-of-interest genuinely IS `graphical-session.target`
                itself, so the generic default already puts both in the one relevant transaction).

                `before = [ "<daemonServiceName>.service" ]` (this option group's own sibling
                field, above) only orders two units that land in the SAME systemd transaction --
                systemd does not retroactively re-order a unit that already finished starting as
                part of an earlier, separate transaction. Leaving `after`/`wantedBy`/`partOf` at
                `graphical-session.target` (this module's usual assumption) is exactly correct when
                `daemonServiceName` names THIS module's own `keyring` entry (`oo7.renderDaemon =
                true`, the default -- both units are `WantedBy` that same target, so they are
                already in the same transaction), but silently WRONG the moment `daemonServiceName`
                names an externally-owned unit that starts on a DIFFERENT target: a pacman `oo7`
                package's own packaged unit ships `[Install] WantedBy=default.target` (see the
                keyring assembly's header comment for the exact shipped text), and
                `default.target` is the base target a `--user` manager reaches at startup, strictly
                BEFORE `graphical-session.target` is ever pulled in (this file's own header, "THE
                ORDERING TARGET"). A bootstrap step left on `graphical-session.target` in that case
                queues into a transaction that starts strictly LATER than the one that already
                started the real daemon, so `before` never gets a chance to fire at all -- the
                ordering is not merely absent, it is INVERTED (the thing `before` was meant to
                precede has already finished starting by the time this unit is even considered).
                Set this to `"default.target"` (or whatever real target `daemonServiceName`'s own
                unit is actually `WantedBy=`) whenever `daemonServiceName` points outside this
                module's own rendering.
              '';
            };
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

    # ── ordering cycles ──────────────────────────────────────────────────────────────────────
    # One assertion per loop found rather than a single aggregate one, so a config with two of
    # them names both instead of reporting the first and hiding the rest -- see `cycleFindings`'
    # own header in the `let` block above for the mechanism and for the live failure that
    # introduced this.
    assertions = (map (f: { assertion = false; message = cycleMessage f; }) cycleFindings) ++ [
      {
        assertion = !cfg.readinessBridge.enable
          || builtins.match "[a-z0-9][a-z0-9_-]*" cfg.readinessBridge.serviceName != null;
        message = "nixdesktop.session.readinessBridge.serviceName must be a lowercase service slug";
      }
      {
        assertion = !cfg.readinessBridge.enable
          || builtins.match "[A-Z_][A-Z0-9_]*" cfg.readinessBridge.socketEnvironment != null;
        message = "nixdesktop.session.readinessBridge.socketEnvironment must be an environment-variable name";
      }
      # ── keyring provider assertions ────────────────────────────────────────────────────────
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
        # `oo7.enable && !oo7.renderDaemon` is excluded on purpose, NOT an oversight: that
        # combination means "oo7 IS the active provider, it just deliberately renders no
        # `keyring` unit of its own" (see `renderDaemon`'s own header comment for the live bug
        # this state exists to fix) -- `effectiveKeyringCommand == null` is the CORRECT, intended
        # outcome there, not the "nobody chose a provider" misconfiguration this assertion exists
        # to catch. Without this exclusion, the very state `renderDaemon = false` was built to
        # express would itself become a build failure, which would defeat the option entirely.
        assertion = !(cfg.keyring.enable && effectiveKeyringCommand == null
          && !(cfg.keyring.oo7.enable && !cfg.keyring.oo7.renderDaemon));
        message = ''
          nixdesktop.session.keyring.enable is true but nothing tells it what to run: neither
          `oo7.enable` nor `gnomeKeyring.enable` is set, and `command` is null. Enable a provider,
          or set `command` directly as the escape hatch. (If you intended oo7 with no daemon of
          its own, set `oo7.enable = true` and `oo7.renderDaemon = false` explicitly -- that
          combination is exempted from this assertion, not silently accepted by accident.)
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
      # ── oo7 keyring bootstrap assertions ──────────────────────────────────────────────────────
      # Two independent booleans again (`credential.bootstrap.enable` nested two levels under
      # `oo7.enable`/`credential.enable`, neither of which it implies just by being set), the exact
      # same reasoning as `oo7.enable`/`gnomeKeyring.enable` above: a consumer can set
      # `bootstrap.enable = true` while never having turned on the credential (or the provider)
      # that bootstrap step exists to serve, and that must be a named build failure rather than a
      # silently-inert option or a bootstrap unit that renders with a `LoadCredentialEncrypted=`
      # pointing at nothing (`keyringLoadCredentialEncrypted` would be `{ }` in that case, which the
      # wellKnownServices guard's OWN gate already prevents by not being reached at all when
      # `credential.enable` is false -- but a consumer relying on that silent non-render instead of
      # a clear error is exactly the class of failure this file's assertions exist to name).
      {
        assertion = !(cfg.keyring.oo7.credential.bootstrap.enable && !cfg.keyring.oo7.credential.enable);
        message = ''
          nixdesktop.session.keyring.oo7.credential.bootstrap.enable is true but
          `credential.enable` is false. The bootstrap step reuses the daemon's own unlock
          credential (one credential, two readers -- see `credential.bootstrap`'s own doc) and has
          nothing to load without it. Enable `credential.enable` too (with a real `credential.path`
          -- see that option's own assertion above), or turn bootstrap back off.
        '';
      }
      {
        assertion = !(cfg.keyring.oo7.credential.bootstrap.enable && !cfg.keyring.oo7.enable);
        message = ''
          nixdesktop.session.keyring.oo7.credential.bootstrap.enable is true but `oo7.enable` is
          false. This bootstrap step exists solely to prepare a keyring FILE for oo7-daemon's own
          credential-based unlock (see `credential.bootstrap`'s own header) -- it has no purpose,
          and nothing to order `before = [ "<daemonServiceName>.service" ]` against, when oo7
          itself is not the active provider. Enable `oo7.enable`, or turn bootstrap back off.
        '';
      }
      # The one combination `renderDaemon`/`daemonServiceName` cannot be left to disagree
      # silently: see `renderDaemon`'s own header comment for the live bug that introduced both
      # options, and `daemonServiceName`'s own doc for exactly why getting this wrong does NOT
      # fail loudly on its own (a `Before=` edge onto a unit that is never created is a silent
      # systemd no-op, not an error) -- this assertion is what turns it into a named build failure
      # instead. `checks/oo7-convergence.nix` (the infra checkout) re-proves the same invariant
      # against each host's own real rendered config, not merely against this option's own default.
      {
        assertion = !(cfg.keyring.oo7.credential.bootstrap.enable && !cfg.keyring.oo7.renderDaemon
          && cfg.keyring.oo7.credential.bootstrap.daemonServiceName == "keyring");
        message = ''
          nixdesktop.session.keyring.oo7.renderDaemon is false (this module renders no daemon of
          its own) but credential.bootstrap.daemonServiceName is still "keyring" -- that name only
          ever refers to THIS module's own daemon entry, which renderDaemon = false means is never
          created. `before = [ "keyring.service" ]` would then order this bootstrap step against a
          unit that does not exist, which systemd treats as a silent no-op rather than a build or
          runtime failure -- see that option's own doc. State the REAL daemon unit's bare name
          explicitly (e.g. "oo7-daemon" for a pacman `oo7` package's own packaged unit, and set
          `daemonTarget` to match its real `[Install] WantedBy=` target too), or turn
          `renderDaemon` back on.
        '';
      }
    ];

    # ── patchbay SNI-host warning ─────────────────────────────────────────────────────────────
    # See the `patchbay` option group's own header comment, "THE SNI-HOST DEPENDENCY", for why
    # this is a WARNING and not an assertion: a patchbay with no confirmed tray host is a
    # legitimate transitional state (exactly the state the operator described moving through while
    # retooling off waybar), not a misconfiguration to refuse to build -- but it is exactly the
    # silent-failure class this repo exists to eliminate if nothing says so out loud. `lib.optional`
    # rather than an unconditional entry: `trayHostAvailable` is a required option with no default
    # (see its own doc), so forcing it while `patchbay.enable` is false would throw "used but not
    # defined" for a consumer who never touched this component at all -- `&&` short-circuits before
    # that happens, the same laziness `effectiveKeyringCommand`'s own guards above rely on.
    warnings = lib.optional (cfg.patchbay.enable && !cfg.patchbay.trayHostAvailable) ''
      nixdesktop.session.patchbay is enabled with trayHostAvailable = false: nothing on this
      session currently implements a StatusNotifierHost, so this unit's own StatusNotifierItem
      registration has nowhere to draw -- it will run, healthy and reachable over D-Bus/PipeWire,
      with no visible tray icon anywhere. See the `patchbay` option group's own header comment
      ("THE SNI-HOST DEPENDENCY") for why this module cannot detect that fact for you. Enable a
      host (this repo's own `nixdesktop.desktop.bar` role, profiles/desktop.nix -- waybar's own
      `tray` module is one today) and set `trayHostAvailable = true`, or accept that this instance
      is reachable only some other way (a compositor keybind that raises it by window class, for
      instance) until one exists.
    '';
  };
}
