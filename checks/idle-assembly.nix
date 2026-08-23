# Evaluates home/session.nix for real and asserts the swayidle assembly it owns.
#
# WHY THIS FILE EXISTS AT ALL: `nix flake check` does not evaluate `homeManagerModules`. It lists
# them as unchecked and moves on, so a green check here covers the nixosModules and the formatter
# while proving nothing about home/session.nix -- including the assembly below, which is real
# computed logic with several branches.
#
# Owning the assembly here (rather than per-compositor) is deliberate: swayidle's invocation is
# byte-identical under any wlroots compositor and idle timeouts are host policy, not compositor
# config syntax -- owning it per-compositor would produce one copy per compositor repo. Having
# taken that responsibility on, this repo owes it a test.
{ pkgs, home-manager, lib ? pkgs.lib }:
let
  stubs = { lib, ... }: {
    options = {
      xdg.configFile = lib.mkOption {
        type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
        default = { };
      };
      home.packages = lib.mkOption { type = lib.types.listOf lib.types.anything; default = [ ]; };
      home.file = lib.mkOption { type = lib.types.attrsOf lib.types.anything; default = { }; };
      assertions = lib.mkOption { type = lib.types.listOf lib.types.anything; default = [ ]; };
      warnings = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
      # session.nix renders real systemd user units; this check only reads the intermediate
      # `nixdesktop.session.services` attrset, so the unit output just needs somewhere to land.
      systemd.user = lib.mkOption { type = lib.types.anything; default = { }; };
    };
  };

  # Returns the `idle` unit's ExecStart-ish command, or null when no idle unit exists at all.
  idleUnit = settings:
    let
      evaluated = (lib.evalModules {
        modules = [
          stubs
          ../home/session.nix
          { nixdesktop.session = { enable = true; } // settings; }
        ];
        specialArgs = { inherit pkgs; };
      }).config;
      services = evaluated.nixdesktop.session.services;
    in
    if services ? idle then services.idle.command else null;

  sessionConfig = settings:
    (
      (lib.evalModules {
        modules = [
          stubs
          ../home/session.nix
          { nixdesktop.session = { enable = true; } // settings; }
        ];
        specialArgs = { inherit pkgs; };
      }).config
    );

  # The whole `services` attrset, for assertions about units OTHER than `idle` -- `lock-at-start`
  # is a separate unit, so `idleUnit` above cannot see it at all.
  sessionServices = settings: (sessionConfig settings).nixdesktop.session.services;

  base = { idleAndLock.enable = true; };
  merge = extra: { idleAndLock = base.idleAndLock // extra; };

  full = idleUnit (merge { });
  noSuspend = idleUnit (merge { suspendAfterSeconds = null; });
  noIdle = idleUnit (merge { lockAfterSeconds = null; });
  overridden = idleUnit (merge { command = "hypridle --config /dev/null"; });
  otherLocker = idleUnit (merge { lockCommand = "waylock"; });
  disabled = idleUnit { idleAndLock.enable = false; };

  atStart = sessionServices (merge { lockAtStart = true; });
  atStartNoIdle = sessionServices (merge { lockAtStart = true; lockAfterSeconds = null; });
  noAtStart = sessionServices (merge { });
  atStartOtherLocker = sessionServices (merge { lockAtStart = true; lockCommand = "waylock"; });
  longLockerName = "swaylock[.*]-effects";
  nearRegexMatchName = "swaylock.-effects";
  atStartLongLocker = sessionServices (merge {
    lockAtStart = true;
    lockCommand = longLockerName;
  });
  atStartDaemonizingLongLocker = sessionServices (merge {
    lockAtStart = true;
    lockCommand = longLockerName;
    lockAtStartCommandMode = "daemonizing";
  });
  defaultLockAtStartCommandMode =
    (sessionConfig (merge { lockAtStart = true; })).nixdesktop.session.idleAndLock.lockAtStartCommandMode;
  renderedAtStart = (sessionConfig (merge { lockAtStart = true; })).systemd.user.services."lock-at-start";
  realHome = home-manager.lib.homeManagerConfiguration {
    inherit pkgs;
    modules = [
      ../home/session.nix
      {
        home.username = "nixdesktop-test";
        home.homeDirectory = "/home/nixdesktop-test";
        home.stateVersion = "25.05";
        nixdesktop.session = {
          enable = true;
          idleAndLock = {
            enable = true;
            lockAtStart = true;
          };
        };
      }
    ];
  };
  realRenderedAtStart =
    realHome.config.xdg.configFile."systemd/user/lock-at-start.service".source;

  # systemd keeps a successful oneshot with RemainAfterExit active after its process returns.
  # Exact sd-switch semantics then map an active changed unit with X-RestartIfChanged=false to
  # KeepOld. Model the post-unlock activation explicitly so these three load-bearing fields cannot
  # drift independently while the check still calls the result idempotent.
  latchRemainsActiveAfterUnlock =
    renderedAtStart.Service.Type == "oneshot"
    && renderedAtStart.Service.RemainAfterExit;
  activationAfterUnlock =
    if latchRemainsActiveAfterUnlock && renderedAtStart.Unit.X-RestartIfChanged == false
    then "keep-old"
    else "start";

  has = haystack: needle: haystack != null && lib.hasInfix needle haystack;

  results = {
    # The default assembly: lock timeout, suspend timeout, and the three lifecycle hooks.
    "assembles the lock timeout" = has full "timeout 300 'swaylock -f'";
    "assembles the suspend timeout" = has full "timeout 600 'systemctl suspend'";
    "assembles before-sleep, lock and unlock hooks" =
      has full "before-sleep 'swaylock -f'"
      && has full "lock 'swaylock -f'"
      && has full "unlock 'pkill -USR1 swaylock'";
    "passes -w so swayidle waits for its commands" = has full "swayidle -w";

    # suspendAfterSeconds = null must drop ONLY the suspend action. This is the setting a container
    # desktop needs (it shares a kernel, and therefore a power state, with its host), so getting it
    # wrong either suspends the host or stops locking entirely.
    "null suspendAfterSeconds drops the suspend action" =
      !(has noSuspend "systemctl suspend");
    "null suspendAfterSeconds keeps locking" =
      has noSuspend "timeout 300 'swaylock -f'";

    # null lockAfterSeconds means no idle daemon at all -- and must be a valid configuration, not
    # an evaluation failure, for a host that simply never idle-locks.
    "null lockAfterSeconds creates no idle unit" = noIdle == null;

    # enable = false must also create nothing, independently of the timeouts.
    "disabled creates no idle unit" = disabled == null;

    # The escape hatch is used verbatim and does NOT get swayidle grammar wrapped around it.
    "an explicit command overrides the assembly verbatim" =
      overridden == "hypridle --config /dev/null";

    # lockCommand must reach every position, including the pkill target -- a locker named in three
    # places and missed in the fourth would leave `unlock` silently signalling the wrong process.
    "lockCommand reaches every position including pkill" =
      has otherLocker "timeout 300 'waylock -f'"
      && has otherLocker "before-sleep 'waylock -f'"
      && has otherLocker "lock 'waylock -f'"
      && has otherLocker "unlock 'pkill -USR1 waylock'"
      && !(has otherLocker "swaylock");

    # ── lockAtStart ─────────────────────────────────────────────────────────────────────────
    # OFF BY DEFAULT is the load-bearing assertion here, not a formality: this option costs a
    # SECOND password immediately after the disk passphrase on any host that boots normally, and
    # the estate's whole rule is exactly one password per path to a usable desktop. A default that
    # drifted to `true` would silently impose that second prompt everywhere.
    "lockAtStart is off by default" = !(noAtStart ? "lock-at-start");

    "lockAtStart creates its own unit" = atStart ? "lock-at-start";

    "lockAtStart uses a session-lifetime oneshot latch" =
      atStart."lock-at-start".serviceType == "oneshot"
      && atStart."lock-at-start".remainAfterExit;
    "lockAtStart renders the session-lifetime latch" =
      renderedAtStart.Service.Type == "oneshot"
      && renderedAtStart.Service.RemainAfterExit;
    "lockAtStart keeps the latch scoped and ordered with the graphical session" =
      renderedAtStart.Unit.PartOf == [ "graphical-session.target" ]
      && renderedAtStart.Unit.After == [ "graphical-session.target" ]
      && renderedAtStart.Install.WantedBy == [ "graphical-session.target" ];
    "lockAtStart uses a plain absolute store-path wrapper" =
      !atStart."lock-at-start".runShell
      && lib.hasPrefix builtins.storeDir atStart."lock-at-start".command;
    "post-unlock Home Manager activation keeps the active latch" =
      activationAfterUnlock == "keep-old";

    # A locker that exits because the human unlocked it has SUCCEEDED. Restart=always here would
    # re-lock the screen the instant they got in -- an unusable desk, and a plausible default to
    # inherit by accident.
    "lockAtStart never restarts" = atStart."lock-at-start".restart == "no";

    # "gate the start, never lock on idle" must be expressible: the two settings are independent,
    # and tying the start gate to the idle daemon's existence would silently drop the only gate a
    # container desktop has.
    "lockAtStart works with no idle daemon at all" =
      (atStartNoIdle ? "lock-at-start") && !(atStartNoIdle ? idle);

    "lockAtStart honours lockCommand" =
      atStartOtherLocker."lock-at-start".command != atStart."lock-at-start".command;
    "lockAtStart gives long regex-like locker names their own wrapper" =
      atStartLongLocker."lock-at-start".command != atStart."lock-at-start".command;
    "lockAtStart command contract defaults to foreground" =
      defaultLockAtStartCommandMode == "foreground";
    "lockAtStart command contract changes the wrapper" =
      atStartDaemonizingLongLocker."lock-at-start".command
      != atStartLongLocker."lock-at-start".command;
  };

  failed = lib.attrNames (lib.filterAttrs (_: passed: !passed) results);
in
# The x86_64 check also executes the process-detection condition. Other declared systems keep the
  # fixed-output marker so `--all-systems` remains evaluable on an x86_64 CI builder.
if failed == [ ]
then
  if pkgs.stdenv.hostPlatform.system != "x86_64-linux"
  then pkgs.emptyFile
  else
    pkgs.runCommand "nixdesktop-lock-at-start-idempotence"
    {
      nativeBuildInputs = [ pkgs.stdenv.cc pkgs.coreutils ];
      foregroundLockCommand = atStartLongLocker."lock-at-start".command;
      daemonizingLockCommand = atStartDaemonizingLongLocker."lock-at-start".command;
      renderedUnit = realRenderedAtStart;
      inherit longLockerName nearRegexMatchName;
    } ''
      set -eu

      # Validate the real Home Manager serialization, not only this check's intermediate module
      # attrset. A store-path ExecStart must remain one physical line and parse as a user unit.
      grep -Fx 'Type=oneshot' "$renderedUnit"
      grep -Fx 'RemainAfterExit=true' "$renderedUnit"
      grep -Fx 'Restart=no' "$renderedUnit"
      grep -Fx 'PartOf=graphical-session.target' "$renderedUnit"
      grep -Fx 'After=graphical-session.target' "$renderedUnit"
      grep -Fx 'WantedBy=graphical-session.target' "$renderedUnit"
      grep -Fx 'X-RestartIfChanged=false' "$renderedUnit"
      grep -E '^ExecStart=/nix/store/[^[:space:]]+-nixdesktop-lock-at-start$' "$renderedUnit"
      test "$(grep -c '^ExecStart=' "$renderedUnit")" -eq 1
      mkdir "$TMPDIR/systemd-home" "$TMPDIR/systemd-runtime"
      chmod 0700 "$TMPDIR/systemd-runtime"
      env -i HOME="$TMPDIR/systemd-home" XDG_RUNTIME_DIR="$TMPDIR/systemd-runtime" \
        SYSTEMD_UNIT_PATH="${pkgs.systemd}/example/systemd/user" \
        ${lib.getExe' pkgs.systemd "systemd-analyze"} --user verify "$renderedUnit"

      # Both private wrappers carry every detector dependency as an absolute store path and compare
      # the full executable basename/display literally. Their launch contracts must remain visibly
      # different: foreground samples a stable process, daemonizing waits for launcher completion.
      for command in "$foregroundLockCommand" "$daemonizingLockCommand"; do
        grep -F '${lib.getExe' pkgs.procps "pgrep"}' "$command"
        grep -F '${lib.getExe' pkgs.coreutils "readlink"}' "$command"
        grep -F '${lib.getExe' pkgs.coreutils "sleep"}' "$command"
        grep -F '${lib.getExe' pkgs.coreutils "tr"}' "$command"
        grep -F '${lib.getExe pkgs.gnugrep}' "$command"
        grep -F 'candidate_exe##*/' "$command"
        grep -F 'WAYLAND_DISPLAY=$WAYLAND_DISPLAY' "$command"
      done
      grep -F "'swaylock[.*]-effects' -f &" "$foregroundLockCommand"
      grep -F 'while [ "$attempt" -lt 100 ]' "$foregroundLockCommand"
      grep -F 'while kill -0 "$launcher_pid"' "$daemonizingLockCommand"
      grep -F 'wait "$launcher_pid" || launcher_status=$?' "$daemonizingLockCommand"
      grep -F 'reported readiness without a surviving child' "$daemonizingLockCommand"

      # One real ELF covers both declared command contracts and their failures. Markers contain the
      # launched/surviving PID so every spawned process is proved alive and cleaned up explicitly.
      $CC -x c -o "$TMPDIR/locker-elf" - <<'EOF'
      #include <fcntl.h>
      #include <stdio.h>
      #include <stdlib.h>
      #include <string.h>
      #include <unistd.h>
      static int write_marker(const char *path) {
        int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
        if (fd < 0) return 21;
        if (dprintf(fd, "%ld\n", (long)getpid()) < 0) return 23;
        close(fd);
        return 0;
      }
      int main(int argc, char **argv) {
        if (argc == 2 && strcmp(argv[1], "--hold") == 0) {
          for (;;) pause();
        }
        if (argc == 2 && strcmp(argv[1], "-f") == 0) {
          const char *marker = getenv("SPAWN_MARKER");
          const char *ready_marker = getenv("READY_MARKER");
          const char *mode = getenv("LOCKER_MODE");
          if (marker == NULL) return 20;
          if (mode != NULL && strcmp(mode, "daemonize") == 0) {
            pid_t pid = fork();
            if (pid < 0) return 24;
            if (pid > 0) {
              usleep(300000);
              if (ready_marker == NULL || write_marker(ready_marker) != 0) return 25;
              return 0;
            }
          }
          if (write_marker(marker) != 0) return 21;
          if (mode != NULL && strcmp(mode, "success") == 0) return 0;
          if (mode != NULL && strcmp(mode, "fail") == 0) return 42;
          for (;;) pause();
        }
        return 22;
      }
      EOF
      cp "$TMPDIR/locker-elf" "$TMPDIR/$longLockerName"
      cp "$TMPDIR/locker-elf" "$TMPDIR/$nearRegexMatchName"

      holder_pid=""
      spawned_pids=""
      cleanup_processes() {
        for cleanup_pid in $holder_pid $spawned_pids; do
          test -z "$cleanup_pid" || kill "$cleanup_pid" 2>/dev/null || true
        done
      }
      trap cleanup_processes EXIT

      wait_for_marker() {
        marker_path=$1
        for _attempt in $(seq 1 100); do
          test -s "$marker_path" && return 0
          sleep 0.02
        done
        return 1
      }

      # A foreground locker is the live regression: the wrapper must return while its child stays
      # alive, rather than keeping the oneshot's start job open until the human unlocks.
      foreground_marker="$TMPDIR/foreground-spawned"
      PATH="$TMPDIR:$PATH" WAYLAND_DISPLAY=wayland-foreground SPAWN_MARKER="$foreground_marker" \
        LOCKER_MODE=foreground \
        /bin/sh -c "$foregroundLockCommand"
      wait_for_marker "$foreground_marker"
      foreground_pid=$(cat "$foreground_marker")
      kill -0 "$foreground_pid"
      spawned_pids="$spawned_pids $foreground_pid"

      # A daemonizing command may create its same-executable child immediately, but the child is
      # not ready until its parent completes the post-lock handshake. The delayed READY_MARKER is
      # written by that parent immediately before exit; accepting process presence would return
      # about 250ms too early and fail this assertion.
      daemon_marker="$TMPDIR/daemon-spawned"
      daemon_ready_marker="$TMPDIR/daemon-ready"
      PATH="$TMPDIR:$PATH" WAYLAND_DISPLAY=wayland-daemon SPAWN_MARKER="$daemon_marker" \
        READY_MARKER="$daemon_ready_marker" LOCKER_MODE=daemonize \
        /bin/sh -c "$daemonizingLockCommand"
      test -s "$daemon_ready_marker"
      wait_for_marker "$daemon_marker"
      daemon_pid=$(cat "$daemon_marker")
      kill -0 "$daemon_pid"
      spawned_pids="$spawned_pids $daemon_pid"

      # Successful launcher exit without a surviving same-display child is not readiness.
      immediate_marker="$TMPDIR/immediate-success"
      if PATH="$TMPDIR:$PATH" WAYLAND_DISPLAY=wayland-exit SPAWN_MARKER="$immediate_marker" \
        LOCKER_MODE=success /bin/sh -c "$daemonizingLockCommand"; then
        echo "a successful daemonizing launcher without a child incorrectly satisfied readiness" >&2
        exit 1
      fi
      test -e "$immediate_marker"

      # A nonzero readiness parent must propagate failure even if its executable was observable
      # during launch.
      failure_marker="$TMPDIR/nonzero-failure"
      if PATH="$TMPDIR:$PATH" WAYLAND_DISPLAY=wayland-fail SPAWN_MARKER="$failure_marker" \
        LOCKER_MODE=fail /bin/sh -c "$daemonizingLockCommand"; then
        echo "a nonzero daemonizing launcher incorrectly satisfied readiness" >&2
        exit 1
      fi
      test -e "$failure_marker"

      # A daemonizing contract that never completes is bounded and its launcher is killed. This
      # deliberately costs the wrapper's five-second readiness ceiling once in CI.
      timeout_marker="$TMPDIR/readiness-timeout"
      if PATH="$TMPDIR:$PATH" WAYLAND_DISPLAY=wayland-timeout SPAWN_MARKER="$timeout_marker" \
        LOCKER_MODE=foreground /bin/sh -c "$daemonizingLockCommand"; then
        echo "a hung daemonizing launcher incorrectly satisfied readiness" >&2
        exit 1
      fi
      wait_for_marker "$timeout_marker"
      timeout_pid=$(cat "$timeout_marker")
      if kill -0 "$timeout_pid" 2>/dev/null; then
        echo "the timed-out daemonizing launcher survived wrapper cleanup" >&2
        exit 1
      fi

      # A real same-UID, same-display ELF whose basename is longer than comm's 15 bytes must be
      # detected without starting a duplicate. This is the concrete old-pgrep-x regression.
      same_display_marker="$TMPDIR/same-display-spawned"
      WAYLAND_DISPLAY=wayland-a "$TMPDIR/$longLockerName" --hold &
      holder_pid=$!
      holder_ready=false
      for _attempt in $(seq 1 50); do
        holder_exe="$(${lib.getExe' pkgs.coreutils "readlink"} "/proc/$holder_pid/exe" 2>/dev/null || true)"
        if [ "''${holder_exe##*/}" = "$longLockerName" ] \
          && ${lib.getExe' pkgs.coreutils "tr"} '\0' '\n' < "/proc/$holder_pid/environ" 2>/dev/null \
          | ${lib.getExe pkgs.gnugrep} -Fqx -- 'WAYLAND_DISPLAY=wayland-a'; then
          holder_ready=true
          break
        fi
        sleep 0.02
      done
      test "$holder_ready" = true
      if ${lib.getExe' pkgs.procps "pgrep"} -u "$(${lib.getExe' pkgs.coreutils "id"} -u)" \
        -x "$longLockerName" >/dev/null 2>&1; then
        echo "the regression locker unexpectedly fits pgrep -x" >&2
        exit 1
      fi
      PATH="$TMPDIR:$PATH" WAYLAND_DISPLAY=wayland-a SPAWN_MARKER="$same_display_marker" \
        /bin/sh -c "$foregroundLockCommand"
      test ! -e "$same_display_marker"
      kill -0 "$holder_pid"

      # The same executable under the same UID but on another display is not this session's lock.
      other_display_marker="$TMPDIR/other-display-spawned"
      PATH="$TMPDIR:$PATH" WAYLAND_DISPLAY=wayland-b SPAWN_MARKER="$other_display_marker" \
        LOCKER_MODE=foreground \
        /bin/sh -c "$foregroundLockCommand"
      wait_for_marker "$other_display_marker"
      other_display_pid=$(cat "$other_display_marker")
      kill -0 "$other_display_pid"
      spawned_pids="$spawned_pids $other_display_pid"

      kill "$holder_pid"
      wait "$holder_pid" 2>/dev/null || true
      holder_pid=""

      # A near name that the configured `[.*]` would match as a regex is not an exact basename
      # match. The target must therefore execute instead of being suppressed by the near process.
      exact_name_marker="$TMPDIR/exact-name-spawned"
      WAYLAND_DISPLAY=wayland-c "$TMPDIR/$nearRegexMatchName" --hold &
      holder_pid=$!
      holder_ready=false
      for _attempt in $(seq 1 50); do
        holder_exe="$(${lib.getExe' pkgs.coreutils "readlink"} "/proc/$holder_pid/exe" 2>/dev/null || true)"
        if [ "''${holder_exe##*/}" = "$nearRegexMatchName" ] \
          && ${lib.getExe' pkgs.coreutils "tr"} '\0' '\n' < "/proc/$holder_pid/environ" 2>/dev/null \
          | ${lib.getExe pkgs.gnugrep} -Fqx -- 'WAYLAND_DISPLAY=wayland-c'; then
          holder_ready=true
          break
        fi
        sleep 0.02
      done
      test "$holder_ready" = true
      PATH="$TMPDIR:$PATH" WAYLAND_DISPLAY=wayland-c SPAWN_MARKER="$exact_name_marker" \
        LOCKER_MODE=foreground \
        /bin/sh -c "$foregroundLockCommand"
      wait_for_marker "$exact_name_marker"
      exact_name_pid=$(cat "$exact_name_marker")
      kill -0 "$exact_name_pid"
      spawned_pids="$spawned_pids $exact_name_pid"
      kill -0 "$holder_pid"

      touch "$out"
    ''
else
  throw ''
    nixdesktop: the idle/lock assembly is wrong. Failing assertions:
    ${lib.concatMapStringsSep "\n" (f: "  - ${f}") failed}
  ''
