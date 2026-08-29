# Evaluates home/session.nix for real and asserts the RESTART BACKOFF every session component
# renders -- `RestartSec=` plus the `StartLimitIntervalSec=`/`StartLimitBurst=` pair. See that
# file's own header ("⚠ THE READINESS GUARANTEE IS CONDITIONAL") for the measured session this
# machinery exists to survive: on a compositor whose unit is `Type=simple`,
# `After=graphical-session.target` guarantees only that the compositor was forked, so every
# component here can and does start against a Wayland socket that is not accepting yet.
#
# WHAT IS ACTUALLY WORTH PROVING HERE, since a directive that merely EXISTS proves nothing:
#
#   1. The directives land in the right SECTIONS. `StartLimitIntervalSec=`/`StartLimitBurst=` are
#      `[Unit]` directives (`man 5 systemd.unit`) that systemd also still accepts under `[Service]`
#      for backwards compatibility -- so putting them in the wrong section is invisible in review,
#      invisible at eval, and (on a systemd that ever drops the compat path) silently restores the
#      lethal defaults. Only reading the RENDERED unit can catch that; the intermediate
#      `nixdesktop.session.services` attrset every sibling check in this directory reads cannot.
#   2. EVERY component gets them, with no call site opting in -- the failure was a property of the
#      whole class, so a backoff each convenience block had to remember to set would be the same
#      bug with an extra step.
#   3. The three defaults are COHERENT as a set, not merely present individually. Two independent
#      arithmetic facts make or break the fix, and neither is visible from any one option:
#      `restartSec * startLimitBurst` must exceed the compositor lateness actually measured (1 s),
#      or the fix does not fix anything; and that same product must fit INSIDE
#      `startLimitIntervalSec`, or the window expires mid-burst and a hopeless unit is handed
#      unlimited further attempts instead of parking in `systemctl --user --failed`.
#   4. Both escape hatches still work: `null` omits a directive (restoring systemd's own default),
#      and `startLimitIntervalSec = 0` renders a real `0` rather than being swallowed as "empty".
{ pkgs, lib ? pkgs.lib }:
let
  support = import ./support.nix { inherit pkgs lib; };
  inherit (support) report;

  # Same stub as checks/patchbay.nix's own, plus a `systemd.user` that is written AND read back:
  # this is the one check in the directory whose subject is the rendered unit text itself, so
  # `types.anything` (which merges the attrset home/session.nix assigns) is exactly the surface
  # needed -- home-manager's own `systemd.user.services` option is a faithful superset.
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
      systemd.user = lib.mkOption { type = lib.types.anything; default = { }; };
    };
  };

  evalWith = settings: (lib.evalModules {
    modules = [
      stubs
      ../home/session.nix
      { nixdesktop.session = { enable = true; } // settings; }
    ];
    specialArgs = { inherit pkgs; };
  }).config;

  unitsFor = settings: (evalWith settings).systemd.user.services;

  # ── FIXTURES ─────────────────────────────────────────────────────────────────────────────────
  #
  # Every convenience block this module has, all at once, plus one raw `services.<name>` entry --
  # the generic mechanism the blocks compile down to. The point of the breadth is claim 2 above:
  # this is the whole desktop that came up dead on the measured session (bar, notifications, osd,
  # idle, polkit agent, both cliphist watchers), and the assertion below sweeps the rendered set
  # rather than naming any one of them, so a future component added without the backoff fails here.
  wholeDesktop = unitsFor {
    bar.enable = true;
    notifications.enable = true;
    osd.enable = true;
    clipboardHistory.enable = true;
    polkitAgent = { enable = true; command = "/fake/polkit-agent"; };
    idleAndLock = { enable = true; lockAfterSeconds = 300; };
    keyring = { enable = true; gnomeKeyring.enable = true; };
    readinessBridge = {
      enable = true;
      serviceName = "ciri";
      socketEnvironment = "CIRI_SOCKET";
    };
    services.custom = { command = "fake-component"; };
  };

  # `restart = "no"` on this one: the backoff must render for it too. RestartSec is inert under
  # `Restart=no` (systemd ignores it) but the start limit is NOT -- it rate-limits manual and
  # dependency-driven starts just the same -- so gating either one on `restart` would produce a
  # unit whose rendered text differs for no behavioural reason. See toSystemdUnit's own comment.
  neverRestarts = (unitsFor { services.gate = { command = "fake-gate"; restart = "no"; }; }).gate;

  # Both escape hatches, on the generic mechanism.
  omitted = (unitsFor {
    services.plain = {
      command = "fake";
      restartSec = null;
      startLimitBurst = null;
      startLimitIntervalSec = null;
    };
  }).plain;

  retryForever = (unitsFor {
    services.forever = { command = "fake"; startLimitIntervalSec = 0; };
  }).forever;

  bar = wholeDesktop.bar;
  readinessBridge = wholeDesktop.ciri;

  # The defaults, read back off a rendered unit rather than restated as literals here -- the
  # arithmetic assertions below are about what a host ACTUALLY gets, so re-typing the numbers would
  # let the invariants stay green against values no consumer receives.
  restartSec = bar.Service.RestartSec;
  burst = bar.Unit.StartLimitBurst;
  interval = bar.Unit.StartLimitIntervalSec;

  hasBackoff = u:
    u.Service ? RestartSec && u.Unit ? StartLimitBurst && u.Unit ? StartLimitIntervalSec;

  results = {
    # ── THE DIRECTIVES RENDER, IN THE SECTIONS SYSTEMD DOCUMENTS THEM IN ──────────────────────
    "bar renders RestartSec in [Service]" =
      bar.Service.RestartSec == 2;
    "bar renders StartLimitBurst in [Unit], where man 5 systemd.unit documents it" =
      bar.Unit.StartLimitBurst == 10;
    "bar renders StartLimitIntervalSec in [Unit], not the [Service] compat spelling" =
      bar.Unit.StartLimitIntervalSec == 60;
    "neither start-limit directive leaks into [Service], where a future systemd may stop reading it" =
      !(bar.Service ? StartLimitBurst) && !(bar.Service ? StartLimitIntervalSec);
    "RestartSec does not leak into [Unit], which would not parse there at all" =
      !(bar.Unit ? RestartSec);

    # ── EVERY COMPONENT GETS IT, WITH NO CALL SITE OPTING IN ──────────────────────────────────
    "every rendered component of a whole desktop carries the full backoff" =
      lib.all hasBackoff (lib.attrValues wholeDesktop);
    "...including the components that were dead on the measured session" =
      lib.all (n: wholeDesktop ? ${n})
        [ "bar" "notifications" "osd" "idle" "polkit-agent" "cliphist-text" "cliphist-image" ];
    "the generic readiness bridge uses the integration-supplied service and socket names" =
      lib.hasInfix "$CIRI_SOCKET" readinessBridge.Service.ExecStart
      && readinessBridge.Service.Type == "notify"
      && readinessBridge.Service.NotifyAccess == "all"
      && readinessBridge.Unit.BindsTo == [ "graphical-session.target" ]
      && readinessBridge.Unit.Before == [ "graphical-session.target" ];
    "the readiness bridge is only a socket-watching shell, never a second compositor" =
      !(lib.hasInfix "ExecStart=ciri" readinessBridge.Service.ExecStart)
      && readinessBridge.Service.Restart == "no";
    "the polkit agent alone receives GTK4's CPU-side Cairo renderer" =
      lib.elem "GSK_RENDERER=cairo" wholeDesktop."polkit-agent".Service.Environment
      && !(lib.elem "GSK_RENDERER=cairo" wholeDesktop.bar.Service.Environment);
    "...and a raw services.<name> entry, the generic mechanism the blocks compile down to" =
      hasBackoff wholeDesktop.custom;
    "a restart = \"no\" component still renders the start limit, which applies to manual starts too" =
      hasBackoff neverRestarts && neverRestarts.Service.Restart == "no";

    # ── THE DEFAULTS ARE COHERENT AS A SET, NOT MERELY PRESENT ────────────────────────────────
    # The measured gap was 1 s (see home/session.nix's header). systemd's own unconfigured defaults
    # buy 5 * 0.1 = 0.5 s of it, which is why the desktop stayed dead; anything at or below that
    # number here would ship the identical bug under new option names.
    "the retry budget outlasts the compositor lateness actually measured, with real margin" =
      restartSec * burst >= 10;
    # If the window expired mid-burst, systemd would keep granting starts forever and a hopeless
    # unit would never reach `systemctl --user --failed` -- the end-stop the header argues for is
    # exactly this inequality, not the presence of a StartLimitBurst= line.
    "the whole burst fits inside one window, so the BURST is what parks a hopeless unit" =
      restartSec * burst < interval;
    "the window is wider than systemd's own 10 s, so slow thrash is caught rather than looped forever" =
      interval > 10;

    # ── THE ESCAPE HATCHES ────────────────────────────────────────────────────────────────────
    "null omits each directive entirely, restoring systemd's own defaults" =
      !(omitted.Service ? RestartSec)
      && !(omitted.Unit ? StartLimitBurst)
      && !(omitted.Unit ? StartLimitIntervalSec);
    "startLimitIntervalSec = 0 renders a real 0 (systemd's \"no rate limiting\"), never an omission" =
      retryForever.Unit.StartLimitIntervalSec == 0;
  };
in
report "session-restart-backoff" results
