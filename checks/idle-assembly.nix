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

  base = { idleAndLock.enable = true; };
  merge = extra: { idleAndLock = base.idleAndLock // extra; };

  full = idleUnit (merge { });
  noSuspend = idleUnit (merge { suspendAfterSeconds = null; });
  noIdle = idleUnit (merge { lockAfterSeconds = null; });
  overridden = idleUnit (merge { command = "hypridle --config /dev/null"; });
  otherLocker = idleUnit (merge { lockCommand = "waylock"; });
  disabled = idleUnit { idleAndLock.enable = false; };

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
  };

  failed = lib.attrNames (lib.filterAttrs (_: passed: !passed) results);
in
if failed == [ ]
then pkgs.runCommand "nixdesktop-idle-assembly-ok" { } "touch $out"
else throw ''
  nixdesktop: the idle/lock assembly is wrong. Failing assertions:
  ${lib.concatMapStringsSep "\n" (f: "  - ${f}") failed}
''
