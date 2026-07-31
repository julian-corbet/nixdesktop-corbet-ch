# modules/launcher.nix — the piece that actually STARTS a desktop session: turns a
# `nixdesktop.sessions.<name>` instance (modules/session.nix — an INSTANCE, not yet a running
# thing) into a real systemd unit, seated or headless.
#
# WHY THIS FILE HAS TO EXIST SEPARATELY, AND WHY IT TOOK THIS LONG TO WRITE. Every other module in
# this repo produces DATA — an identity string, a resolved rectangle, a permitted/denied device
# NAME list. None of that runs anything. This estate currently has THREE desktops with three
# different private answers to "how do I actually launch a compositor" (archlxc's hand-written
# `niri-seat.service`, the elitebook's stock `--user niri.service`, devhome not built yet) because
# nobody had written the one mechanism down. See
# `knowledge/hosts/shared/desktop-session-model.md` §7.2 for the elitebook's live, silent
# consequence of skipping this: its polkit agent runs but never registers, because
# `niri-session -l` re-forks niri under `user@1000.service`, and no privileged GUI prompt on that
# machine has ever worked as a result.
#
# THE ONE FORCED FACT THIS FILE IS BUILT AROUND: SEATING IS CGROUP-STRUCTURAL, NOT ENVIRONMENTAL.
# `sd_pid_get_session()` → `cg_path_get_session()` requires the process's OWN cgroup path to
# literally contain `session-<N>.scope` (systemd's `cgroup-util.c`). No exported `XDG_SESSION_ID`,
# no environment variable of any kind, can fake that. A `--user` unit lives under
# `user@<uid>.service`, whose logind session class is literally `"manager"` — it can NEVER be
# seated, full stop, regardless of what it exports. The only sanctioned way into a real seat is
# `PAMName=` + `User=` on a SYSTEM unit, which `systemd.exec(5)` documents as migrating the unit's
# main process into its own session scope during PAM session opening — this is exactly what
# gdm/sddm/greetd do internally, and it is exactly what
# `infra/hosts/archlxc/niri-session.nix` (read-only precedent for this file — see its own header)
# proved live on this estate for one host, by hand, before this module generalised it.
#
# WHAT THIS FILE DELIBERATELY DOES NOT DO. It does not choose a compositor, a monitor layout, or a
# device claim — those are `nixdesktop.sessions.<name>.{compositor,layout,environment}`, already
# resolved by modules/session.nix into `permittedDevices`/`deniedDevices` (device NAMES) before
# this file ever sees them. This module's only job is turning that already-resolved DATA into a
# running unit. `nixdesktop.launcher.compositors` is the one new, small, deliberately extensible
# surface it adds: the argv and device-env-var names a compositor needs, because THAT part (unlike
# device claims, which live on `nixhost`) has nowhere else in this family to live.
#
# ── THE ENFORCEMENT MECHANISM, REBUILT ONCE ON THE BACK OF nixgpu's STABLE PATHS ────────────────
#
# An earlier revision of this file resolved device NAMES to `/dev/dri/*` paths at SHELL time,
# inside an `ExecStartPre=+` step that mutated the unit's own `DeviceAllow=` via `systemctl
# set-property` — because at the time a name could only ever become a real device path against
# live sysfs, and eval time had nothing stable to build one from. Adversarial review (measured live
# on corbet-server) found that shape genuinely broken in three independent ways: `DevicePolicy=
# strict` applies to the cgroup BEFORE any ExecStartPre runs, so an empty starting `DeviceAllow=`
# deadlocks the unit before the mutating step ever execs (`status=208/STDIN`); `strict` itself
# admits none of `/dev/null`/`/dev/ptmx`/`/dev/tty*`, which a terminal emulator needs regardless of
# GPU policy; and the compositor's own `ExecStart` was a bare name, which `systemd.exec(5)`
# resolves against a small fixed compile-time path list that does not include the Nix profile --
# never against `$PATH`, contrary to what this file used to claim.
#
# nixgpu's `stableDevicePaths.devices.<name>.{cardPath,renderPath}` removes the reason any of that
# existed: both are `/dev/dri/by-path/*` strings built from a PCI/platform-bus ADDRESS — a physical
# slot, fixed at build/install time, never a probe-order artifact — so they are real Nix VALUES,
# known at the same EVAL TIME this unit itself is rendered at. `DeviceAllow=` can therefore be an
# ordinary STATIC list, exactly like every other `serviceConfig` field on this unit: nothing needs
# to mutate the cgroup after the fact, so the bootstrap deadlock has no way to occur. See
# `nixhost.resources.gpu` below for how those two fields reach this module (through the SAME
# `lib.probeFact` mirror modules/session.nix already reads for the device NAMES, never a new flake
# input on nixgpu — this repo still takes no compositor, and no GPU domain, as an input).
{ probeFact, collectProbes }:
{ lib, config, ... }:
let
  inherit (lib) types mkOption;

  sessionsCfg = config.nixdesktop.sessions;
  launcherCfg = config.nixdesktop.launcher;

  enabledSessions = lib.filterAttrs (_: s: s.enable) sessionsCfg;
  seatedSessions = lib.filterAttrs (_: s: s.delivery == "seated") enabledSessions;
  headlessSessions = lib.filterAttrs (_: s: s.delivery == "headless") enabledSessions;

  # A user declared via NixOS's own `users.users` carries its real `home`; a user that exists only
  # through an external identity source (lldap, per the design doc §6) does not appear there at
  # all, and `/home/<name>` is the only fact available about it in that case. Never a hard failure
  # either way -- both are legitimate, and asserting NixOS-managed-ness here would make this module
  # unusable on exactly the identity path the design doc says this estate is moving toward.
  homeOf = user: if config.users.users ? ${user} then config.users.users.${user}.home else "/home/${user}";

  # ── THE SAME nixhost MIRROR modules/session.nix ALREADY READS, read a second time here ────────
  #
  # session.nix stops at device NAMES (`permittedDevices`/`deniedDevices`) -- "what a device IS
  # belongs to nixgpu and is none of this module's business", per its own header. This module is
  # the first consumer that DOES need to know what a name IS, because it is the one place a name
  # has to become something systemd can put in `DeviceAllow=` or a compositor's env var. So it
  # reads the identical mirror (`nixhost.resources.gpu`, itself a `lib.probeFact` read of
  # `nixgpu.stableDevicePaths.devices` -- see nixhost's own `modules/nixhost.nix`) through its own
  # `lib.probeFact` call, never a new flake input on nixgpu or nixhost's data shape: the house rule
  # this whole family follows is "cross-repo reads go through nixhost.lib.probeFact", and that is
  # exactly as true for a path as it was for a name.
  #
  # No separate `config.warnings` entry duplicated by hand here: `collectProbes` below folds this
  # probe in alongside session.nix's own (identical-path) probe, so an unresolved leaf is still
  # reported exactly once per module that actually depends on it -- not merged away, just not
  # hand-duplicated text.
  inventoryProbe = probeFact {
    inherit config;
    namespace = "nixhost";
    path = [ "resources" "gpu" ];
    fallback = { };
  };
  inventory = inventoryProbe.value;

  # `.cardPath` is a plain (non-nullable) `str` on nixgpu's own submodule; `.renderPath` is
  # `nullOr str`, null exactly when the device has no render node (evdi, by driver fact, always;
  # a BMC/IPMI framebuffer, sometimes). A permitted name absent from `inventory` altogether --
  # legitimate, if nixhost.environments claims a device nixgpu never declared; session.nix already
  # warns about that mismatch -- resolves to no paths at all here, silently: this module has
  # nothing further to add about a mismatch it did not create.
  deviceOf = name: inventory.${name} or null;

  # STATIC, because both fields are eval-time Nix values now -- see this file's header. One "PATH
  # rw" entry per card node, plus its render node when the device has one; ORDER FOLLOWS
  # `permittedDevices`, which modules/session.nix already orders primary-first (exclusive claims
  # before shared, alphabetical within each) -- this function only ever maps over that order, it
  # never reorders it.
  deviceAllowFor = names: lib.concatMap
    (name:
      let dev = deviceOf name; in
      if dev == null then [ ] else
        [ "${dev.cardPath} rw" ] ++ lib.optional (dev.renderPath != null) "${dev.renderPath} rw")
    names;

  # The compositor's OWN device-restriction env var (`WLR_DRM_DEVICES` for a wlroots compositor)
  # wants CARD nodes ONLY. A render node is not a candidate wlroots itself ever enumerates there --
  # it derives the render node itself from whichever card it opens -- so handing it one is not
  # merely redundant, `open_render_node()` treats every entry as a card candidate and a `renderD*`
  # path fails to open as one. The previous revision fed the SAME resolved list (card and render
  # both) to `DeviceAllow` and to this env var from one shared collector, which is exactly how that
  # contamination happened; this function returns cardPath alone, and `deviceAllowFor` above is the
  # only place a renderPath is ever read.
  cardPathsFor = names: lib.concatMap
    (name: let dev = deviceOf name; in if dev == null then [ ] else [ dev.cardPath ])
    names;

  # ── THE STATIC/CLOSED DEVICE FLOOR EVERY SEATED SESSION NEEDS, REGARDLESS OF WHICH CARD ───────
  #
  # `DevicePolicy=closed` (not `strict`) already admits `/dev/null`, `/dev/zero`, `/dev/full`,
  # `/dev/random`, `/dev/urandom` for free (systemd.resource-control(5)) -- what it does NOT admit,
  # and what a graphical session concretely needs on top, is a way for whatever terminal emulator
  # this session's user launches to allocate a pty, and a way for libinput to read the raw
  # peripherals. Verified live against `/proc/devices` on corbet-server (2026-07-31), so this list
  # names exactly what is actually registered rather than a guess:
  #
  #   1 mem      -- covers null/zero/full/random/urandom; already granted by `closed` above, not
  #                 repeated here.
  #   4 tty      -- the VT/tty core; covers /dev/tty0.."/dev/ttyN" (and ttyS* alongside it, same
  #                 major -- harmless to include, not worth a second group to exclude it).
  # 136 pts      -- the ALLOCATED pty SLAVE side. Genuinely needs the wildcard group: which pts
  #                 number a given terminal gets is assigned dynamically, unknowable at eval time.
  #  13 input    -- libinput's entire device surface (/dev/input/event*, /dev/input/mice); same
  #                 reasoning as `pts` -- which peripherals are attached is a runtime fact.
  #
  # `/dev/ptmx` and `/dev/tty` are each their OWN single, well-known node (major 5, registered
  # under names that embed a literal `/` and are therefore not sensible `char-<name>` globs) --
  # named here by exact path instead of chasing an awkward group spelling for a two-node need.
  # Opening `/dev/ptmx` is what allocates a new pty pair, which is the concrete step a terminal
  # emulator takes to start a shell at all; `/dev/tty` is the "current controlling terminal" alias
  # some shells and readline stacks open by name directly.
  #
  # None of this touches a DRM node, so none of it widens what this session can do to a GPU -- it
  # is the tty/input floor every interactive session needs regardless of which card it may or may
  # not master. UNVERIFIED LIVE AS A RUNNING SEATED SESSION YET (this pass edits the tree only, per
  # its own instructions) -- confirm on the first real rollout with `systemctl show <unit> -p
  # DeviceAllow -p DevicePolicy` while the session is up.
  staticGraphicalDeviceAllow = [
    "/dev/ptmx rw"
    "/dev/tty rw"
    "char-tty rw"
    "char-pts rw"
    "char-input rw"
  ];

  # ── The compositor exec table, and WHY built-in rows live OUTSIDE the option's own `config` ────
  #
  # A session names its compositor as a free-form string (modules/session.nix, mirroring
  # profiles/desktop.nix's own `compositor` option) precisely so a new compositor never requires
  # editing nixdesktop. This is the one place THIS module needs to know how to actually start one:
  # its argv, which of ITS OWN env vars (if any) want the resolved device-path list, and the
  # package (if any) its binary should be resolved against.
  #
  # `builtinCompositors` is a PLAIN Nix value, never assigned to `config.nixdesktop.launcher.
  # compositors` at all (an earlier pass here tried exactly that, via `lib.mkOptionDefault`, on the
  # assumption that a low-priority definition merges field-by-field against a consumer's own
  # higher-priority one — checked live: it does NOT. NixOS's priority system picks the
  # HIGHEST-priority definition(s) of an OPTION AS A WHOLE before the type's own merge function
  # ever runs; for `attrsOf submodule` that means the instant a consumer defines EVEN ONE FIELD of
  # ONE entry — `compositors.scroll.package = ...;`, the exact escape hatch `package`'s own doc
  # recommends — the ENTIRE low-priority table is discarded, taking `niri`'s row and `scroll`'s
  # OTHER fields down with it. Measured directly: a two-entry `mkOptionDefault` table, overridden
  # on one field of one entry, comes back with the untouched entry GONE and the touched entry's
  # other field back at the SUBMODULE's own bare default.) So the built-in rows are resolved by
  # THIS FILE's OWN CODE instead, per field, in `compositorEntry` below — never through the module
  # system's priority machinery, which cannot express "fall through per field" for this shape.
  builtinCompositors = {
    scroll = { command = "scroll"; env = [ "WLR_DRM_DEVICES" ]; package = null; };
    niri = { command = "niri --session"; env = [ ]; package = null; };
  };

  # Every name either table declares -- what "known" means for the assertion below. A name in
  # NEITHER is unknown; a name in either (or both, a consumer legitimately restating a built-in
  # entry) is known and gets resolved field-by-field.
  declaredCompositorNames = lib.unique (lib.attrNames builtinCompositors ++ lib.attrNames launcherCfg.compositors);

  # `null` on `command`/`env`/`package` (the submodule's own per-field default -- see the options
  # below) UNAMBIGUOUSLY means "this definition did not set this field", which is exactly what
  # lets a consumer override JUST `package` for a built-in entry (`compositors.scroll.package =
  # pkgs.scroll;`) and still get `scroll`'s built-in `command`/`env` -- a consumer's own value for
  # a field always wins over the built-in one; the built-in wins over the final `fallback` only
  # when NEITHER side ever set that field. A name absent from both tables resolves to the same
  # inert, empty shape ("", [], null) the assertion below reports on -- never a `null`/`throw`
  # here, which would abort evaluation of `config.systemd.services` outright the moment anything
  # forces it, before that nicer message ever has a chance to run. Same discipline modules/
  # session.nix already uses for an unknown `environment`: degrade the derived value, assert on it
  # separately.
  compositorEntry = name:
    let
      builtin = builtinCompositors.${name} or null;
      user = launcherCfg.compositors.${name} or null;
      pick = field: fallback:
        if user != null && user.${field} != null then user.${field}
        else if builtin != null && builtin.${field} != null then builtin.${field}
        else fallback;
    in
    {
      command = pick "command" "";
      env = pick "env" [ ];
      package = pick "package" null;
    };

  # ── ExecStart MUST BE ABSOLUTE — systemd never consults $PATH for it ───────────────────────────
  #
  # `systemd.exec(5)`: when the executable name contains no slash, it is resolved against a small,
  # FIXED, compile-time search path (`/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:
  # /bin`) that does not include the Nix profile a package like this is actually installed to --
  # setting `Environment=PATH=...` on the unit changes nothing about that resolution, because it is
  # not `$PATH` that gets consulted at all. (This file used to claim the opposite; that claim was
  # wrong, and this comment replaces it.) So the first word of `command` needs to already be
  # absolute, or `package` needs to be set so this function can build one.
  firstWord = s: lib.head (lib.splitString " " s);
  restOfCommand = s:
    let parts = lib.tail (lib.splitString " " s); in
    lib.optionalString (parts != [ ]) " ${lib.concatStringsSep " " parts}";

  # `package` resolves the first word against `${package}/bin/<firstWord>` (`lib.getExe'`) — the
  # same shape nixscroll's own `programs.scroll.package` already uses, so a consumer who has a real
  # compositor derivation (nixscroll's, nixniri's, an Arch-side one) wires it straight through this
  # option instead of re-deriving a store path by hand. nixdesktop itself takes no compositor as a
  # flake input (see flake.nix's header), so neither built-in default entry below can supply one --
  # a consumer sets `package`, or spells `command` as an already-absolute path themselves.
  resolvedExecFor = entry:
    let fw = firstWord entry.command; in
    if lib.hasPrefix "/" fw then entry.command
    else if entry.package != null then "${lib.getExe' entry.package fw}${restOfCommand entry.command}"
    else entry.command; # unresolved: the assertion below is what turns this into a build failure
                         # naming every offending session, rather than a unit that fails at exec
                         # with "No such file or directory" and nothing pointing at why.

  isExecResolved = entry:
    lib.hasPrefix "/" (firstWord entry.command) || entry.package != null;

  mkSeatedUnit = name: session:
    let
      entry = compositorEntry session.compositor;
      home = homeOf session.user;

      cardPaths = cardPathsFor session.permittedDevices;
      envDeviceVars = lib.concatMap (var: [ "${var}=${lib.concatStringsSep ":" cardPaths}" ]) entry.env;
    in
    {
      description = "nixdesktop seated session \"${name}\" (${session.compositor}, user ${session.user}, seat ${session.seat})";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-user-sessions.service" ];

      # A wedged or crash-looping compositor must not hot-loop forever against a real GPU --
      # matches the precedent's own reasoning (infra/hosts/archlxc/niri-session.nix) rather than
      # inventing new numbers.
      startLimitIntervalSec = 60;
      startLimitBurst = 5;

      serviceConfig = {
        # THE ENTIRE SEATING MECHANISM: PAMName + User on a SYSTEM unit (this is `systemd.services`,
        # never `systemd.user.services`) is the only shape `sd_pid_get_session()` can ever resolve
        # to a seat -- see this file's header. `PAMName = "login"` is what makes systemd open a
        # real PAM login session and migrate this unit's main process into its own
        # `session-<N>.scope`, exactly as gdm/sddm/greetd do for their own children.
        User = session.user;
        PAMName = "login";
        WorkingDirectory = home;

        Environment = [
          "HOME=${home}"
          "XDG_SEAT=${session.seat}"
          "XDG_SESSION_TYPE=wayland"
          "XDG_SESSION_CLASS=user"
        ]
        ++ lib.optional (session.renderer != "auto") "WLR_RENDERER=${session.renderer}"
        ++ envDeviceVars
        ++ lib.mapAttrsToList (k: v: "${k}=${v}") session.extraEnvironment;

        # ── STATIC, because everything it is built from is an eval-time Nix value now — see this
        # file's header for what used to sit here instead (an `ExecStartPre=+` mutating the same
        # property at shell time) and why it deadlocked. `closed`, not `strict`: see
        # `staticGraphicalDeviceAllow`'s own comment for exactly what that difference buys and why
        # each extra entry is there. Per-device entries come from `deviceAllowFor`, ordered exactly
        # as `permittedDevices` already is.
        DevicePolicy = "closed";
        DeviceAllow = staticGraphicalDeviceAllow ++ deviceAllowFor session.permittedDevices;

        # See `resolvedExecFor`'s own comment: never a bare compositor name, which systemd cannot
        # resolve against a Nix profile no matter what `$PATH` says.
        ExecStart = resolvedExecFor entry;

        Type = "simple"; # niri/scroll never sd_notify; direct invocation (no wrapper script
                          # stands between systemd and the compositor any more) keeps the
                          # compositor as this unit's main PID, so Restart tracks IT directly.
        Restart = "always";
        RestartSec = 2;
      };
    };

  # `--user` unit: correct and sufficient for headless, and NOT a lesser version of the seated
  # case -- see modules/session.nix's own header. Nothing in wlroots' headless BACKEND touches
  # libseat at all (`attempt_headless_backend()` never calls `session_create_and_wait()`), so there
  # is no seat to acquire and PAMName would be solving a problem this delivery class does not have.
  mkHeadlessUnit = name: session:
    let
      entry = compositorEntry session.compositor;
    in
    {
      description = "nixdesktop headless session \"${name}\" (${session.compositor}, user ${session.user})";
      wantedBy = [ "default.target" ];

      # Scoped to exactly ONE user out of every user whose `--user` manager loads this shared unit
      # definition: NixOS's `systemd.user.services` is not per-user by itself (it is rendered into
      # every user's manager alike), so without this the SAME session would spawn again for any
      # other user who happens to have a running `--user` instance. `ConditionUser=` is evaluated
      # against the identity of the user OWNING the manager instance that is loading the unit --
      # precisely the documented use ("useful in --user service files") -- and is precedented
      # in-tree already: nixpkgs' own `virtualisation.docker-rootless` uses the identical mechanism
      # (`unitConfig.ConditionUser = "!root";`) to scope a shared `systemd.user.services.docker`
      # definition. A condition failing is a skip, never a unit failure -- exactly what "not this
      # user" should mean here.
      unitConfig.ConditionUser = session.user;

      startLimitIntervalSec = 60;
      startLimitBurst = 5;

      serviceConfig = {
        # NO User=, NO PAMName= -- see this file's header: those are precisely what a `--user` unit
        # cannot have and be seated by, and headless never wants a seat in the first place.
        Environment = [
          "WLR_BACKENDS=headless"
          # session.renderer, not a literal "pixman": modules/session.nix already ASSERTS every
          # enabled headless session has renderer == "pixman" (wlroots' auto-selected renderer
          # still opens a real render node even on the headless backend -- open_drm_render_node()
          # scans the whole system -- so "auto" would silently reach the one card this session is
          # forbidden). Reading it through rather than hardcoding keeps this one fact single-
          # sourced at the option that owns it.
          "WLR_RENDERER=${session.renderer}"
          # `%U`: a systemd unit-file specifier expanded by systemd itself when it parses this
          # Environment= line (never by a shell), to the UID of the user this manager instance
          # belongs to -- correct for every user this shared unit definition ever loads under,
          # without this module ever needing to know a uid.
          "XDG_RUNTIME_DIR=/run/user/%U"
        ] ++ lib.mapAttrsToList (k: v: "${k}=${v}") session.extraEnvironment;

        # No device resolution needed at all: modules/session.nix already asserts a headless
        # session's permittedDevices claim is irrelevant to it (delivery = headless never takes a
        # seat or a device), so there is nothing here to resolve into an env var or a DeviceAllow --
        # unlike the seated case. Same absolute-path requirement as the seated case, though: this
        # is exec'd directly by a `--user` unit, and systemd resolves it identically.
        ExecStart = resolvedExecFor entry;

        Type = "simple";
        Restart = "always";
        RestartSec = 2;
      };
    };

  # Every user named by a headless session needs the effect `loginctl enable-linger` produces --
  # otherwise `user@<uid>.service` (and therefore this unit) never starts until that user actually
  # logs in somewhere, which defeats the entire point of a session nobody is sitting at. `lib.
  # unique` because two headless sessions may legitimately share one user (e.g. two different
  # compositors for the same person).
  lingerUsers = lib.unique (lib.mapAttrsToList (_: s: s.user) headlessSessions);

  # Regex forms of the three shapes design doc §8 (assertion 10) singles out as structurally
  # unrepresentable: a bare card index, a bare render-node index, and a raw `major:minor` DRM
  # minor. modules/session.nix's own `permittedDevices`/`deniedDevices` are NAMES from nixhost's
  # mirror of nixgpu's inventory, never typed directly by a session -- but a name shaped like a raw
  # node is still wrong regardless of HOW it gets resolved (a card number is exactly the unstable
  # addressing this whole family exists to remove), so it is still worth catching here, at the
  # first module that ever treats a name as a real device selector.
  looksLikeRawDevicePath = n:
    builtins.match "card[0-9]+" n != null
    || builtins.match "renderD[0-9]+" n != null
    || builtins.match "[0-9]+:[0-9]+" n != null;

  rawDeviceNameOffenders = lib.concatLists (lib.mapAttrsToList
    (name: s: map (d: { inherit name d; }) (lib.filter looksLikeRawDevicePath (s.permittedDevices ++ s.deniedDevices)))
    enabledSessions);
in
{
  options.nixdesktop.launcher = {
    compositors = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          package = mkOption {
            type = types.nullOr types.package;
            default = null;
            example = lib.literalExpression "inputs.nixscroll.packages.\${pkgs.system}.scroll";
            description = ''
              The package providing this compositor's binary. When set, the first word of
              `command` is resolved against it (`''${package}/bin/<firstWord>`, via
              `lib.getExe'`) — the same shape nixscroll's own `programs.scroll.package` already
              uses, so a consumer wires their real compositor derivation straight through here,
              e.g. `nixdesktop.launcher.compositors.scroll.package = inputs.nixscroll.packages.
              ''${pkgs.system}.scroll;` — leaving `command`/`env` untouched and still getting
              `scroll`'s built-in values for both (see `compositorEntry`'s own comment for exactly
              how that per-field fallback works, and why it is NOT expressed through this option's
              own default at all).

              `null` by default. nixdesktop itself takes no compositor as a flake input (see
              flake.nix's header), so it has nothing to default this to for its own built-in
              `scroll`/`niri` rows either. `command`'s first word must then already be an absolute
              path — set it yourself, or set `package`. Leaving neither true for a compositor an
              enabled session actually names is a build failure (see the assertion below), not a
              unit that silently fails to exec.
            '';
          };

          command = mkOption {
            type = types.nullOr types.str;
            default = null;
            example = "niri --session";
            description = ''
              The argv used to launch this compositor. The FIRST WORD must resolve to an absolute
              path — either because it already IS one, or because `package` is set (see its own
              doc) — and the remainder of the string is appended verbatim as arguments.

              NEVER RESOLVED VIA `$PATH`, and this file used to claim otherwise: `systemd.exec(5)`
              resolves a non-absolute `ExecStart` against a small, fixed, compile-time search path
              (`/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`) that does not
              include the Nix profile a package like this is actually installed to. Setting
              `Environment=PATH=...` on the unit changes nothing, because that resolution never
              consults the environment at all.

              `null` by default — NOT `""` — so `compositorEntry` can tell "this definition never
              set `command`" (fall through to a built-in row's own `command`, for `scroll`/`niri`)
              apart from "this definition deliberately restated an empty string", which would
              otherwise be indistinguishable and silently clobber a perfectly good built-in value.
            '';
          };

          env = mkOption {
            type = types.nullOr (types.listOf types.str);
            default = null;
            description = ''
              Env var NAMES this compositor reads for device restriction (e.g.
              `[ "WLR_DRM_DEVICES" ]` for a wlroots compositor). Each is set, verbatim, to the
              SAME colon-joined, primary-first list of resolved permitted device paths — CARD
              nodes only, never a render node (see `cardPathsFor`'s own comment for why the two
              must never be mixed into one list).

              `null` by default, for the SAME reason `command`'s default is `null` and not `[ ]`:
              an explicit `env = [ ];` (a compositor that reads no device-restriction env var at
              all — niri's own built-in row is exactly this, since its device denylist comes from
              its generated CONFIG FILE instead, built from data this module never had access to:
              nixdesktop reads only nixhost's device NAMES, never nixgpu's PCI identities, so it
              cannot emit niri's own `debug { ignore-drm-device }` selectors itself — that
              translation is nixniri's job) must stay distinguishable from "this definition never
              touched `env` at all, fall through to the built-in row's own value".
            '';
          };
        };
      });
      default = { };
      example = lib.literalExpression ''
        { scroll = { command = "scroll"; env = [ "WLR_DRM_DEVICES" ]; package = nixscroll.packages.''${pkgs.system}.scroll; }; }
      '';
      description = ''
        Per-compositor launch data: the argv to exec (whose first word must resolve to an
        absolute path — see `command` and `package`), and which of the compositor's OWN env vars
        (if any) want the resolved permitted-device path list. `scroll` and `niri` already resolve
        out of the box (see `builtinCompositors`, above this option in the source — deliberately
        NOT this option's own `default`); a NEW compositor is added by naming it here (or by
        extending this option from a consumer's own config) and nothing else in this module --
        every session referencing it is handled generically. A session naming a compositor neither
        this table nor the built-in one declares, or one whose command cannot be resolved to an
        absolute path, is a build failure (see the assertions below), not a silently-broken unit.

        Overriding a SINGLE field of a built-in entry (`nixdesktop.launcher.compositors.scroll.
        package = pkgs.scroll;`, say, leaving `command`/`env` untouched) resolves correctly
        against that entry's built-in row — see `compositorEntry`'s own comment, in this module's
        source, for exactly how, and for why that is NOT expressed as this option's own `default`.
      '';
    };
  };

  config = {
    assertions =
      # ── AN UNKNOWN COMPOSITOR FAILS LOUDLY ──────────────────────────────────────────────────
      # Checked here rather than left to the generated wrapper failing at runtime: the whole
      # session table is available at eval time, so a typo is a build failure naming every
      # offending session at once, not a unit that fails to start on whichever host happens to hit
      # it first. Checked against `declaredCompositorNames` (built-in ∪ consumer-declared), never
      # bare `launcherCfg.compositors` alone -- the built-in rows are not IN that option's own
      # value at all (see `compositorEntry`'s own comment), so testing the option directly would
      # make every session naming `scroll`/`niri` untouched by a consumer fail this check.
      lib.mapAttrsToList
        (name: s: {
          assertion = lib.elem s.compositor declaredCompositorNames;
          message = ''
            nixdesktop.sessions.${name} names compositor "${s.compositor}", which is neither one of
            nixdesktop.launcher's built-in compositors nor declared in
            nixdesktop.launcher.compositors. Declared:
            ${lib.concatStringsSep ", " declaredCompositorNames}.
            Add an entry to nixdesktop.launcher.compositors.${s.compositor} (command + the env
            vars it reads for device restriction, if any) -- a new compositor becomes usable by
            naming it, never by editing this module's code.
          '';
        })
        enabledSessions

      # ── AN UNRESOLVABLE COMPOSITOR COMMAND FAILS LOUDLY, TOO ────────────────────────────────
      # Only for sessions naming a compositor the table above DOES declare -- an unknown
      # compositor already fails, once, above; checking resolution on top of that would fire a
      # second, redundant assertion for the exact same misconfiguration (compositorEntry's own
      # fallback has an empty, unresolvable `command`).
      ++ lib.mapAttrsToList
        (name: s:
          let entry = compositorEntry s.compositor; in
          {
            assertion = isExecResolved entry;
            message = ''
              nixdesktop.sessions.${name} names compositor "${s.compositor}", whose
              nixdesktop.launcher.compositors."${s.compositor}".command ("${entry.command}")
              does not start with an absolute path, and no `.package` is set to resolve it
              against. systemd never consults $PATH to resolve a non-absolute ExecStart (see
              `command`'s own doc) -- set nixdesktop.launcher.compositors."${s.compositor}".
              package to the compositor's real derivation, or spell "command" as an
              already-absolute path.
            '';
          })
        (lib.filterAttrs (_: s: lib.elem s.compositor declaredCompositorNames) enabledSessions)

      # ── A DEVICE NAME SHAPED LIKE THE THING THIS WHOLE DESIGN FORBIDS ───────────────────────
      # See design doc §8, assertion 10: cardN/renderDN/major:minor are all exactly as unstable as
      # each other and this module is where a name first gets treated as a real device selector.
      ++ map
        (o: {
          assertion = false;
          message = ''
            nixdesktop.sessions.${o.name} permits or denies "${o.d}", which is shaped like a raw
            device node or DRM minor rather than a stable name. cardN/renderDN numbers and
            major:minor pairs are assigned in kernel PROBE ORDER and genuinely renumber (an evdi
            module load reshuffled this estate's host on 2026-07-29) -- they are exactly the
            unstable addressing this design exists to remove. This name should come from
            nixgpu's own device inventory (mirrored read-only through nixhost), never written to
            look like a device node.
          '';
        })
        rawDeviceNameOffenders;

    # This module's own read of `nixhost.resources.gpu` (see `inventoryProbe`'s own comment) folds
    # into the SAME warnings list session.nix's identical-path probe already contributes to --
    # `collectProbes` is idempotent-in-effect here (an unresolved leaf reported once per probe
    # call site, not once per module), never a duplicate of session.nix's own wording.
    warnings = (collectProbes [ inventoryProbe ]).warnings;

    systemd.services = lib.mapAttrs' (name: session: lib.nameValuePair "nixdesktop-${name}" (mkSeatedUnit name session)) seatedSessions;

    systemd.user.services = lib.mapAttrs' (name: session: lib.nameValuePair "nixdesktop-${name}" (mkHeadlessUnit name session)) headlessSessions;

    # ── LINGERING, WITHOUT TOUCHING `users.users` AT ALL ─────────────────────────────────────
    #
    # `users.users.<name>.linger = true` -- what this file used to write, unconditionally, for
    # every headless session's user -- makes NixOS treat `<name>` as a NixOS-MANAGED account the
    # moment it appears as a key in `users.users`, definition or not: `users-groups.nix`'s own
    # activation logic then wants to create/verify a real local account for it. That is exactly
    # backwards for the identity path this module's own comments (see `homeOf`) say it
    # accommodates -- a user that exists only through an external source (lldap) must never be
    # asserted into existence here, and there is no way to make that write conditional on "is this
    # user ALREADY declared elsewhere" without reading the very option this module is contributing
    # to (a genuine self-reference, not a subtlety worth routing around).
    #
    # So this reaches for the mechanism ONE LAYER BELOW `users.users.<name>.linger` instead of
    # trying to gate it: `loginctl enable-linger USER` does exactly one thing on disk -- create an
    # empty marker file at `/var/lib/systemd/linger/<username>` (verified live on corbet-server:
    # `ls -la /var/lib/systemd/linger/` shows a zero-byte `richc`). `systemd-logind` reads that
    # directory to decide which users' `user@<uid>.service` survives across reboots; it has never
    # cared whether `<username>` is declared in `users.users` at all. `systemd.tmpfiles.rules`
    # writing that same file declaratively (`f`, create-if-absent) reproduces the imperative
    # command's ONLY on-disk effect, for ANY username -- NixOS-declared or externally-managed alike
    # -- without this module ever touching `users.users` or `users.manageLingering`. Same idiom
    # session.nix's own header already uses for seat assignment (`loginctl attach` is itself just a
    # udev rule NixOS can render directly) -- a real logind mechanism has a declarative rendering,
    # and reaching for it beats asking NixOS's own `users.*` option surface to accommodate a case
    # it was not built for.
    systemd.tmpfiles.rules = map (u: "f /var/lib/systemd/linger/${u} 0644 root root -") lingerUsers;
  };
}
