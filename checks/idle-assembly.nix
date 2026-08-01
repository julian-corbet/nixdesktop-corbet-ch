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
{ pkgs, lib ? pkgs.lib }:
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

  # The whole `services` attrset, for assertions about units OTHER than `idle` -- `lock-at-start`
  # is a separate unit, so `idleUnit` above cannot see it at all.
  sessionServices = settings:
    ((lib.evalModules {
      modules = [
        stubs
        ../home/session.nix
        { nixdesktop.session = { enable = true; } // settings; }
      ];
      specialArgs = { inherit pkgs; };
    }).config).nixdesktop.session.services;

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

    # -f, because swaylock only daemonizes with it -- and the unit is Type=forking, so without -f
    # systemd would wait forever for a fork that never comes and the session would never finish
    # starting.
    "lockAtStart locks with -f so it daemonizes" =
      atStart."lock-at-start".command == "swaylock -f";
    "lockAtStart unit is Type=forking" =
      atStart."lock-at-start".serviceType == "forking";

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
      atStartOtherLocker."lock-at-start".command == "waylock -f";
  };

  failed = lib.attrNames (lib.filterAttrs (_: passed: !passed) results);
in
# `pkgs.emptyFile`, not `pkgs.runCommand`: this check decides everything at EVALUATION time and the
# derivation is a formality, but `nix flake check --all-systems` (which this repo's CI runs, and
# must) asks for that formality on EVERY declared system. A `runCommand` marker has a
# system-dependent output path, so the aarch64 one is a real aarch64 build and dies with "platform
# mismatch" on any x86_64 machine -- a red check about nothing. `emptyFile` is fixed-output: its
# path comes from the content hash alone and is identical on every system, so Nix substitutes it
# instead of building it. See checks/support.nix, which does the same for the same reason.
if failed == [ ]
then pkgs.emptyFile
else throw ''
  nixdesktop: the idle/lock assembly is wrong. Failing assertions:
  ${lib.concatMapStringsSep "\n" (f: "  - ${f}") failed}
''
