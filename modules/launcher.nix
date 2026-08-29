# modules/launcher.nix — the piece that actually STARTS a desktop session: turns a
# `nixdesktop.sessions.<name>` instance (modules/session.nix — an INSTANCE, not yet a running
# thing) into a real systemd unit, seated or headless.
#
# WHY THIS FILE HAS TO EXIST SEPARATELY, AND WHY IT TOOK THIS LONG TO WRITE. Every other module in
# this repo produces DATA — an identity string, a resolved rectangle, a permitted/denied device
# NAME list. None of that runs anything. This estate currently has THREE desktops with three
# different private answers to "how do I actually launch a compositor" (the workstation's
# hand-written `niri-seat.service`, the laptop's stock `--user niri.service`, primary not built
# yet) because nobody had written the one mechanism down. See the consuming private config for
# the laptop's live, silent consequence of skipping this: a stock `--user niri.service` never
# registers its polkit agent, because `niri-session -l` re-forks niri under `user@1000.service`,
# and no privileged GUI prompt on that machine has ever worked as a result.
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
# the workstation's own hand-rolled `niri-seat.service` (read-only precedent for this file — see
# its own header) proved live on this estate for one host, by hand, before this module generalised it.
#
# ── DESIGN A: AUTOLOGIN EVERYWHERE, NO GREETER, EVER — ONE PASSWORD ON EVERY PATH, NEVER TWO ─────
#
# An intermediate revision of this file swapped the unit below for a `share/wayland-sessions/
# <name>.desktop` SESSION ENTRY for a GREETER to exec, on the reasoning that `PAMName=` is an
# AUTOLOGIN — PAM opens the session but nothing in that conversation ever prompts for or collects
# a password — so `pam_gnome_keyring`'s own `auth` line, the one that captures a TYPED password and
# hands it to the keyring daemon so it can auto-unlock WITH it, never runs, leaving the login
# keyring locked forever on an autologin unit. That reasoning about the MECHANISM was correct; the
# FIX was wrong. A greeter's own PAM conversation does collect a password — that is the entire
# point of a greeter — which means every boot now costs a SECOND password, seconds after the
# operator already typed the LUKS passphrase to get the disk decrypted at all: cold boot becomes
# LUKS, then a greeter, two prompts in a row, guarding a disk that is already encrypted, for the
# one user who holds the key. This estate's own decision (Design A, operator-mandated) is exactly
# ONE password on every path to a usable desktop — the LUKS passphrase at cold boot, the lock
# screen when returning to an idle desk, and nothing else, ever — so a greeter is not a smaller
# version of that design, it is a second, forbidden class of prompt. Seated is back to being the
# unit this file rendered before that detour: `PAMName=`/`User=` on a SYSTEM unit, true autologin,
# no greeter anywhere on this estate. Not "no greeter YET" — greetd, ly, cage, gtkgreet are all
# equally out of scope, not because any one of them is a bad greeter, but because a greeter of any
# kind is the wrong shape for this design.
#
# THE PRICE OF AUTOLOGIN, PAID ONCE, BY HAND, AND NEVER BY THIS MODULE. Since PAM's auth phase
# never runs on this unit, the login keyring can never auto-unlock by MATCHING a captured password
# — the only shape left is a keyring with NO password protecting it at all (gnome-keyring's own
# "blank password" keyring, a real, distinct mode from a login-password match), which unlocks the
# instant the daemon touches it, autologin or not. That is USER DATA — a passphrase choice on a
# real secret store, set once by hand (seahorse, or the keyring's own first-run prompt) — never
# something this module declares, resets, or could even see. Nothing HERE fights it either: this
# unit never touches PAM's auth phase, never runs a keyring-locking step, and never itself asks for
# a password anywhere on the seated path — see home/session.nix's own `keyring` option for where
# the daemon actually starts, an ordinary `--user` service alongside this unit's own session.
#
# LOCKING IS home/session.nix's swayidle ASSEMBLY, ON IDLE/SUSPEND/LID — NEVER AT SESSION START.
# This unit starts a session with nothing locked; swayidle only ever locks later, on its own
# triggers, once the operator has actually stepped away. Locking at start would spend a second
# password the instant this unit's autologin finished — precisely the two-in-a-row case Design A
# exists to forbid — so nothing on this file's own path ever calls a locker.
#
# WHAT THIS FILE DELIBERATELY DOES NOT DO. It does not choose a compositor, a monitor layout, or a
# device claim — those are `nixdesktop.sessions.<name>.{compositor,layout,environment}`, already
# resolved by modules/session.nix into `permittedDevices`/`deniedDevices` (device NAMES) before
# this file ever sees them. This module's only job is turning that already-resolved DATA into a
# running unit. It does not pick, install, or configure a greeter either — there is none to pick,
# by design (see above). `nixdesktop.launcher.compositors` is the one new, small, deliberately
# extensible surface it adds: the argv and device-env-var names a compositor needs, because THAT
# part (unlike device claims, which live on `nixhost`) has nowhere else in this family to live.
#
# ── THE ENFORCEMENT MECHANISM, REBUILT ONCE ON THE BACK OF nixgpu's STABLE PATHS ────────────────
#
# An earlier revision of this file resolved device NAMES to `/dev/dri/*` paths at SHELL time,
# inside an `ExecStartPre=+` step that mutated the unit's own `DeviceAllow=` via `systemctl
# set-property` — because at the time a name could only ever become a real device path against
# live sysfs, and eval time had nothing stable to build one from. Adversarial review (measured live
# on the server) found that shape genuinely broken in three independent ways: `DevicePolicy=
# strict` applies to the cgroup BEFORE any ExecStartPre runs, so an empty starting `DeviceAllow=`
# deadlocks the unit before the mutating step ever execs (`status=208/STDIN`); `strict` itself
# admits none of `/dev/null`/`/dev/ptmx`/`/dev/tty*`, which a terminal emulator needs regardless of
# GPU policy; and the compositor's own `ExecStart` was a bare name, which `systemd.exec(5)`
# resolves against a small fixed compile-time path list that does not include the Nix profile --
# never against `$PATH`, contrary to what this file used to claim.
#
# nixgpu's `stableDevicePaths.devices.<name>.{cardPath,renderPath,cardNamePath,renderNamePath}`
# removes the reason any of that existed: every one of those is a string built from a
# PCI/platform-bus ADDRESS — a physical slot, fixed at build/install time, never a probe-order
# artifact — so they are real Nix VALUES, known at the same EVAL TIME this unit itself is rendered
# at. `DeviceAllow=` can therefore be an ordinary STATIC list, exactly like every other
# `serviceConfig` field on this unit: nothing needs to mutate the cgroup after the fact, so the
# bootstrap deadlock has no way to occur. See `nixhost.resources.gpu` below for how those fields
# reach this module (through the SAME `lib.probeFact` mirror modules/session.nix already reads for
# the device NAMES, never a new flake input on nixgpu — this repo still takes no compositor, and no
# GPU domain, as an input).
#
# ── WLR_DRM_DEVICES: `cardNamePath`, NEVER `cardPath` ──────────────────────────────────────────
#
# wlroots parses this colon-separated variable with a bare `strtok_r(gpus, ":", &save)`
# (`backend/session/session.c`, `explicit_find_gpus()`, no escaping, verified against wlroots
# `master`) — so nixgpu's `cardPath` (`/dev/dri/by-path/pci-0000:0a:00.0-card`) splits on ITS OWN
# colons into three nonexistent paths, and wlroots logs "Found 0 GPUs, cannot create backend"
# instead of starting. `cardNamePath` (`/dev/dri/by-name/<name>-card`) is keyed on the device's own
# attrset key — asserted colon-free by nixgpu itself — so it is immune by construction. See
# nixgpu's own `modules/stable-device-paths/options.nix`, "A FOURTH SYMLINK FAMILY", for the full
# argument. `deviceAllowFor` below still uses `cardPath` for `DeviceAllow=`: that line is never
# parsed by wlroots, and `cardPath` is the one spelling systemd-udev's own built-in rules reproduce
# unconditionally, with no `nixgpu.stableDevicePaths.enable` required at all — `cardNamePath`
# exists only once that option is actually set.
#
# ── THE VT FACT: THE ONLY REAL DIFFERENCE BETWEEN ONE SEATED UNIT AND ANOTHER, AND IT CUTS BOTH
# WAYS ─────────────────────────────────────────────────────────────────────────────────────────
#
# A seat that HAS a VT requires `XDG_VTNR` set to it: omitting it makes `pam_systemd` reject
# `CreateSession` outright with `org.varlink.service.InvalidParameter` — measured, this exact
# failure happened live on primary. A seat with NO VT must NOT be given `XDG_VTNR` at all — there
# is no VT for it to claim, and stating one it does not own is simply false. Verified live: the
# workstation has no `/dev/tty0` at all, yet `loginctl` there DOES report a real `seat0` with a
# genuine user session sitting on it — the seat is real, just not VT-backed.
# `nixdesktop.sessions.<name>.vt` (modules/session.nix — a number, or `null`) is the one fact this
# unit reads to get both directions right: see the `Environment` block in `mkSeatedUnit` below for
# where it becomes `XDG_VTNR=`, and `seatdVtBound`/`requiredGroups` (also modules/session.nix) for
# the two further consequences a VT-less seat carries downstream — `SEATD_VTBOUND=0` on the same
# unit, and the group-membership assertion further down in this file.
#
# ── TWO PLANES, ONE FILE: WHAT system-manager ACTUALLY SUPPORTS (READ FROM SOURCE, NOT ASSUMED) ─
#
# An earlier revision of this repo's flake.nix claimed a session "will grow a system unit with
# `PAMName=`/`User=` ... none of which system-manager can implement" and kept both `session` and
# `launcher` NixOS-only on that basis. That claim was FALSE, and there is a live counter-example on
# this estate: the workstation's own hand-rolled config, composed into a system-manager target,
# not NixOS — declares `systemd.services.niri-seat` with `PAMName = "login"`,
# `User = "alice"`, a real `Environment` list and `Restart`, and has been running for months.
# system-manager manages real systemd units; a unit property like `PAMName=` is just text in a unit
# file, and system-manager's `systemd.services` renders through the IDENTICAL nixpkgs
# `systemdUtils.lib.serviceToUnit` code NixOS itself calls (confirmed by reading
# `nix/modules/systemd.nix` at the pinned rev, numtide/system-manager@48d47346 — it takes `utils`
# from `${nixos}/lib/utils.nix`, the real nixpkgs systemd-unit renderer, not a reimplementation).
# `users.users`/`users.groups` are ALSO real there (vendored verbatim from nixpkgs'
# `nixos/modules/config/users-groups.nix`, activated through `userborn` instead of NixOS's own
# activation scripts — see `nix/modules/upstream/nixpkgs/{users-groups,userborn}.nix`), so `homeOf`
# below reads `config.users.users` identically on both planes — and so does the group-membership
# assertion (`missingRequiredGroups`, further down): `config.users.users` resolves the same way
# whichever plane composed this module.
#
# What genuinely does NOT exist anywhere in that module tree (`nix/modules/{default,systemd,
# environment,tmpfiles,etc}.nix` plus everything `upstream/nixpkgs/default.nix` imports): a
# `systemd.user.services` option, or any per-user-manager (`user@<uid>.service`) unit surface at
# all. system-manager activates exactly one systemd instance — the SYSTEM one — and never touches
# a user manager's own units. That is the one real, structural gap between the two planes, and it
# lands exactly on the `delivery = "headless"` case (a `--user` unit, scoped by
# `unitConfig.ConditionUser`) — never on `delivery = "seated"`, which was always a SYSTEM unit to
# begin with. See `headlessUnsupportedAssertions` near the bottom of this file for how that gap is
# degraded explicitly rather than silently dropped, and this module's own `config` block for why
# the omission has to be structural (plain Nix, decided by `plane` before the module system ever
# sees a `config` attrset) rather than an `lib.mkIf false` guarding a still-written definition.
{ probeFact, collectProbes }:
# `plane`: "nixos" or "system-manager", closed over BEFORE the module system ever sees the
# result — same discipline as `probeFact`/`collectProbes` above, and the reason flake.nix builds
# two module values from this one file (`launcherModuleFor "nixos"` / `launcherModuleFor
# "system-manager"`) instead of branching on some `config`-derived condition. Which plane a host
# is on is a fact about which flake output was imported, decided long before evaluation reaches
# this module's own options — never something a session or a host config could toggle at
# runtime, so a plain Nix argument is the honest shape, not a `nixdesktop.launcher.plane` option.
plane:
{ lib, config, ... }:
if !(lib.elem plane [ "nixos" "system-manager" ]) then
  throw "modules/launcher.nix: plane must be \"nixos\" or \"system-manager\", got ${builtins.toJSON plane}"
else
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
  #
  # IDENTICAL ON BOTH PLANES: `users.users` is a real, vendored-from-nixpkgs option under
  # system-manager too (see this file's header) -- this read never needs to know which plane it
  # is on, because it is not the module that renders `users.users` in the first place.
  homeOf = user: if config.users.users ? ${user} then config.users.users.${user}.home else "/home/${user}";

  # ── THE SAME nixhost MIRROR modules/session.nix ALREADY READS, read a second time here ────────
  #
  # session.nix stops at device NAMES (`permittedDevices`/`deniedDevices`) -- "what a device IS
  # belongs to nixgpu and is none of this module's business", per its own header. This module is
  # the first consumer that DOES need to know what a name IS, because it is the one place a name
  # has to become something this unit's own `DeviceAllow=` or a compositor's env var can use. So it
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

  # `.cardPath`/`.cardNamePath` are plain (non-nullable) `str` on nixgpu's own submodule;
  # `.renderPath`/`.renderNamePath` are `nullOr str`, null exactly when the device has no render
  # node (evdi, by driver fact, always; a BMC/IPMI framebuffer, sometimes). A permitted name absent
  # from `inventory` altogether -- legitimate, if nixhost.environments claims a device nixgpu never
  # declared; session.nix already warns about that mismatch -- resolves to no paths at all here,
  # silently: this module has nothing further to add about a mismatch it did not create.
  deviceOf = name: inventory.${name} or null;

  # STATIC, because every field read here is an eval-time Nix value -- see this file's header. One
  # "PATH rw" entry per card node, plus its render node when the device has one; ORDER FOLLOWS
  # `permittedDevices`, which modules/session.nix already orders primary-first (exclusive claims
  # before shared, alphabetical within each) -- this function only ever maps over that order, it
  # never reorders it. Feeds `deviceFenceFor` below -- which lands both on the seated unit's own
  # `DeviceAllow=` AND on the read-only `nixdesktop.launcher.deviceFence` mirror -- never a
  # compositor's own env var; see this file's header for why `cardPath` is the right spelling here
  # and the wrong one for `WLR_DRM_DEVICES`.
  deviceAllowFor = names: lib.concatMap
    (name:
      let dev = deviceOf name; in
      if dev == null then [ ] else
        [ "${dev.cardPath} rw" ] ++ lib.optional (dev.renderPath != null) "${dev.renderPath} rw")
    names;

  # The compositor's OWN device-restriction env var (`WLR_DRM_DEVICES` for a wlroots compositor)
  # wants CARD nodes ONLY, and the COLON-FREE `by-name` spelling -- see this file's header, "WLR_
  # DRM_DEVICES: cardNamePath, NEVER cardPath". A render node is not a candidate wlroots itself
  # ever enumerates there -- it derives the render node from whichever card it opens -- so handing
  # it one is not merely redundant, `open_render_node()` treats every entry as a card candidate and
  # a `renderD*` path fails to open as one; `deviceAllowFor` above is the only place a render path
  # (name- or path-based) is ever read.
  cardNamePathsFor = names: lib.concatMap
    (name: let dev = deviceOf name; in if dev == null then [ ] else [ dev.cardNamePath ])
    names;

  # ── THE STATIC/CLOSED DEVICE FLOOR EVERY SEATED SESSION NEEDS, REGARDLESS OF WHICH CARD ───────
  #
  # `DevicePolicy=closed` (not `strict`) already admits `/dev/null`, `/dev/zero`, `/dev/full`,
  # `/dev/random`, `/dev/urandom` for free (systemd.resource-control(5)) -- what it does NOT admit,
  # and what a graphical session concretely needs on top, is a way for whatever terminal emulator
  # this session's user launches to allocate a pty, and a way for libinput to read the raw
  # peripherals. Verified live against `/proc/devices` on the server (2026-07-31), so this list
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
  # not master. SHARED VERBATIM ACROSS BOTH PLANES: `DevicePolicy=`/`DeviceAllow=` are the same
  # `serviceConfig` fields either way (see this file's header), so this floor is exactly as correct
  # on a system-manager seated unit as a NixOS one.
  staticGraphicalDeviceAllow = [
    "/dev/ptmx rw"
    "/dev/tty rw"
    "char-tty rw"
    "char-pts rw"
    "char-input rw"
  ];

  # ── THE DEVICE FENCE, COMPUTED ONCE, USED TWICE ─────────────────────────────────────────────
  #
  # Single-sourced: `mkSeatedUnit` below writes this record's two fields straight onto the unit's
  # own `serviceConfig.DevicePolicy`/`.DeviceAllow` -- the REAL enforcement, a kernel-checked cgroup
  # ACL -- and `config.nixdesktop.launcher.deviceFence` (near the bottom of this file) exposes the
  # IDENTICAL record a second time as plain, read-only DATA, so a host or `checks/launcher.nix` can
  # read the policy without inspecting a rendered unit. Never two independent computations of the
  # same policy: whichever changes, both read it from here.
  # `permittedDevicePaths` comes LAST, and it is the only part of this list a host writes by hand.
  # Everything before it is derived -- the tty/input floor, then the GPU inventory's own resolved
  # paths -- so keeping the hand-written half at the end makes a rendered unit readable: everything
  # after the DRM lines is something a host asked for explicitly, for a device class no inventory
  # owns yet (today: sound). See that option's own doc for why it takes paths where
  # `permittedDevices` deliberately takes names.
  deviceFenceFor = session: {
    devicePolicy = "closed";
    deviceAllow =
      staticGraphicalDeviceAllow
      ++ deviceAllowFor session.permittedDevices
      ++ map (p: "${p} rw") session.permittedDevicePaths;
  };

  # No compositor is built in. Integration products register their complete
  # launch descriptor, so nixdesktop contains neither runtime-specific defaults
  # nor a hidden compatibility path that survives removal of an integration.
  declaredCompositorNames = lib.attrNames launcherCfg.compositors;

  compositorEntry = name:
    let
      user = launcherCfg.compositors.${name} or null;
      pick = field: fallback:
        if user != null && user.${field} != null then user.${field}
        else fallback;
    in
    {
      command = pick "command" "";
      deviceEnvironment = pick "deviceEnvironment" [ ];
      rendererEnvironment = pick "rendererEnvironment" { };
      headlessEnvironment = pick "headlessEnvironment" { };
      package = pick "package" null;
      supportsHeadless = pick "supportsHeadless" false;
      supportsVirtualOutputs = pick "supportsVirtualOutputs" false;
      supportsNotify = pick "supportsNotify" false;
      currentDesktop = pick "currentDesktop" name;
    };

  rendererEnvironmentFor = entry: renderer:
    entry.rendererEnvironment.${renderer} or { };

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
  # compositor derivation (nixscroll's, nixciri's, or an Arch-side one) wires it straight through this
  # option instead of re-deriving a store path by hand. nixdesktop itself takes no compositor as a
  # flake input, so every integration supplies a package or an already-absolute command.
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

      # One path works on both supported planes. Missing directories are harmless: on NixOS the
      # two profile entries expose system and home-manager packages, while on a foreign/FHS host
      # the conventional directories expose distro packages. This must be one Environment=PATH
      # value because systemd applies duplicate environment keys last-value-wins.
      sessionPath = lib.concatStringsSep ":" [
        "/run/current-system/sw/bin"
        "/etc/profiles/per-user/${session.user}/bin"
        "/usr/local/sbin"
        "/usr/local/bin"
        "/usr/sbin"
        "/usr/bin"
        "/sbin"
        "/bin"
      ];

      # `pam_systemd` adds the newly-created logind session id to the compositor process, but not
      # to the already-running user manager. Some authentication agents (Soteria in particular)
      # require that id as `XDG_SESSION_ID` even though they correctly run as user units outside
      # the compositor's own session scope. Ask logind for this user's display session after PAM
      # has opened it, then publish the dynamic id to the user manager before the graphical
      # session target can start its components. Never guess or persist the boot-local number.
      # system-manager's `config.systemd.package` is systemd-minimal, whose bin output does not
      # contain loginctl. On that foreign/FHS plane the host's own systemd is the running authority
      # and its clients live in /usr/bin.
      systemdClientBin =
        if plane == "system-manager" then "/usr/bin" else "${config.systemd.package}/bin";
      importSessionId =
        "+/bin/sh -c 'session_id=\"$(${systemdClientBin}/loginctl show-user \"${session.user}\" --property=Display --value)\"; "
        + "if test -z \"$session_id\"; then echo \"nixdesktop: logind reports no display session for ${session.user}; XDG_SESSION_ID was not imported\" >&2; exit 0; fi; "
        + "exec ${systemdClientBin}/systemctl --machine=\"${session.user}@.host\" --user set-environment \"XDG_SESSION_ID=$session_id\"'";

      cardNames = cardNamePathsFor session.permittedDevices;
      envDeviceVars = lib.concatMap (var: [ "${var}=${lib.concatStringsSep ":" cardNames}" ]) entry.deviceEnvironment;
      rendererEnvironment = rendererEnvironmentFor entry session.renderer;

      fence = deviceFenceFor session;
    in
    {
      description = "nixdesktop seated session \"${name}\" (${session.compositor}, user ${session.user}, seat ${session.seat})";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-user-sessions.service" ];

      # A wedged or crash-looping compositor must not hot-loop forever against a real GPU --
      # matches the workstation precedent's own reasoning rather than inventing new numbers.
      startLimitIntervalSec = 60;
      startLimitBurst = 5;

      # A RECONFIGURATION MUST NOT RESTART A LIVE SEATED SESSION. This unit IS the graphical session:
      # restarting it kills every terminal, editor, agent CLI and waypipe client running under the
      # compositor (see knowledge/hosts/shared/seated-session-restart.md -- "scroll crashed and took
      # all the Claude Codes with it"). system-manager (and NixOS switch-to-configuration) restart a
      # unit whose rendered store path moved, so an unrelated activation would otherwise tear the
      # session down as a pure side effect. `restartIfChanged = false` is a SERVICE-level option that
      # renders `X-RestartIfChanged=false` into `[Service]`, which system-manager's engine reads
      # (activate/services.rs -> "Skipping restart of <unit>: X-RestartIfChanged=false") and NixOS's
      # switch honours identically -- the live session is left running across every activation. A
      # deliberate session change is applied by logging the seat out / rebooting, never mid-use. Do
      # NOT move this into `unitConfig`/`serviceConfig`: the engine only reads the `[Service]` key,
      # and the option already renders there.
      restartIfChanged = false;

      serviceConfig = {
        # THE ENTIRE SEATING MECHANISM: PAMName + User on a SYSTEM unit (this is `systemd.services`,
        # never `systemd.user.services`) is the only shape `sd_pid_get_session()` can ever resolve
        # to a seat -- see this file's header. `PAMName = "login"` is what makes systemd open a
        # real PAM login session and migrate this unit's main process into its own
        # `session-<N>.scope`. This is AUTOLOGIN, deliberately -- no greeter runs first, no password
        # is ever collected here -- see this file's header, "DESIGN A", for why that is the whole
        # point rather than an oversight, and what it costs (an empty-password keyring, set once by
        # hand, never by this module). IDENTICAL on both planes -- see this file's header for the
        # confirmed system-manager module surface.
        User = session.user;
        PAMName = "login";
        WorkingDirectory = home;

        Environment = [
          "HOME=${home}"
          "XDG_SEAT=${session.seat}"
          "XDG_SESSION_TYPE=wayland"
          "XDG_SESSION_CLASS=user"
          # `entry.currentDesktop` -- see that option's own doc for what it resolves to per
          # compositor and why. NEVER omitted: an EMPTY `XDG_CURRENT_DESKTOP` is not a smaller
          # version of a correct one, it is exactly the state that let Electron's `safeStorage`
          # sniff nothing and persist a secret-store backend choice this session never made on
          # purpose (see that option's own doc for the full account) -- so this line is
          # unconditional, matching every other seat-identity var immediately above it, never
          # gated behind an `lib.optional`.
          "XDG_CURRENT_DESKTOP=${entry.currentDesktop}"
          # `PATH`, WITHOUT WHICH `spawn "fuzzel"`-SHAPED BARE NAMES SILENTLY GO NOWHERE -- MEASURED
          # LIVE, NOT ASSUMED (2026-08-02). This unit's Environment= is rendered AFTER whichever
          # base PATH the plane's own systemd machinery injects by default (confirmed by reading the
          # rendered unit: a `PATH=` line naming only nix-store coreutils/findutils/gnugrep/gnused/
          # systemd-minimal -- correct for THIS unit's own `ExecStart`, which this file's header
          # already establishes must be absolute and therefore never consults PATH at all -- but
          # wrong for anything the COMPOSITOR itself spawns as a bare name (config.kdl's `spawn
          # "fuzzel"`/`spawn "foot"`, or an integration's own startup lines), because THAT resolution
          # happens inside niri's own process, against ITS OWN inherited PATH, at IPC-action time --
          # not something this file's `resolvedExecFor`/`ExecStart` discipline touches at all.
          # systemd's own Environment= is last-value-wins per key, and this line renders after the
          # auto-injected one, so it overrides rather than merely supplementing it.
          #
          # Proved live: `niri msg action spawn -- fuzzel` (a bare name, exactly what a keybind's
          # own `spawn "fuzzel"` sends) returned success but produced no process at all; the
          # IDENTICAL action with an absolute path (`spawn -- /usr/bin/fuzzel`) worked immediately --
          # `execvp()` failing to resolve a bare name against a PATH that never contained `/usr/bin`,
          # not a keybind, config, or device-access problem (all three were checked and ruled out
          # first: the IPC action itself accepted the command, niri held real input+DRM device fds,
          # and `niri msg outputs` reported the real panels correctly).
          #
          # The FHS half remains what foreign-distro sessions need. The NixOS half is equally
          # load-bearing: `/run/current-system/sw/bin` exposes system packages and
          # `/etc/profiles/per-user/<user>/bin` exposes home-manager packages when
          # `useUserPackages` is enabled. Omitting those paths left a healthy NixOS scroll session
          # unable to execute its own inherited bare `swaybg` command even though the package was
          # declaratively installed. See `sessionPath` above for why the two planes are combined
          # rather than selected with a distro branch.
          "PATH=${sessionPath}"
        ]
        # THE VT FACT, both directions -- see this file's header. `session.vt` (modules/session.nix)
        # is `null` on every seat this estate has ever measured with no VT (the workstation); a
        # number on every seat it has measured WITH one (primary, VT 1). Neither branch is a guess:
        # omitting `XDG_VTNR` on a VT-backed seat is what measured live as `pam_systemd` refusing
        # `CreateSession` with `org.varlink.service.InvalidParameter` on primary; SETTING it on a
        # VT-less seat would claim a VT that plainly does not exist there.
        ++ lib.optional (session.vt != null) "XDG_VTNR=${toString session.vt}"
        ++ lib.mapAttrsToList (k: v: "${k}=${v}") rendererEnvironment
        # See modules/session.nix's own `seatdVtBound` doc: `false` means this seat has no VT for a
        # VT-bound seatd to follow -- measured live on the workstation, whose `/dev/tty0` does not
        # exist at all (only `/dev/console`, a pty). Device access there rests entirely on
        # `requiredGroups` instead -- see the assertion below that actually checks the host grants
        # them.
        ++ lib.optional (!session.seatdVtBound) "SEATD_VTBOUND=0"
        ++ envDeviceVars
        ++ lib.mapAttrsToList (k: v: "${k}=${v}") session.extraEnvironment;

        # ── STATIC, because everything it is built from is an eval-time Nix value now — see this
        # file's header for what used to sit here instead (an `ExecStartPre=+` mutating the same
        # property at shell time) and why it deadlocked. `closed`, not `strict`: see
        # `staticGraphicalDeviceAllow`'s own comment for exactly what that difference buys and why
        # each extra entry is there. SINGLE-SOURCED from `deviceFenceFor` -- the identical record
        # `nixdesktop.launcher.deviceFence` exposes read-only, below, never a second, independent
        # computation of the same policy.
        DevicePolicy = fence.devicePolicy;
        DeviceAllow = fence.deviceAllow;

        # See `resolvedExecFor`'s own comment: never a bare compositor name, which systemd cannot
        # resolve against a Nix profile no matter what `$PATH` says.
        ExecStart = resolvedExecFor entry;

        # `Type=notify` ONLY when `entry.supportsNotify` is a MEASURED fact, not a guess (see
        # that option's own doc for exactly what was checked, per compositor). Direct invocation,
        # no wrapper script stands between systemd and the compositor either way -- Restart
        # always tracks the compositor's own PID, `Type=` only changes what "started" MEANS to
        # systemd (immediately, for `simple`; only once sd_notify(READY=1) actually arrives, for
        # `notify`) -- so this line alone is what makes the `ExecStartPost=` below fire at the
        # real moment the compositor is ready, rather than the moment it merely forked.
        Type = if entry.supportsNotify then "notify" else "simple";
        Restart = "always";
        RestartSec = 2;
      }
      # ── THE BRIDGE INTO THE USER MANAGER'S graphical-session.target ───────────────────────────
      #
      # THE GAP. A seated session is, by construction (this file's header, "THE ONE FORCED
      # FACT"), a SYSTEM unit -- the compositor's own PACKAGED `--user` unit (niri's own
      # `niri.service`: `BindsTo=graphical-session.target` + `Before=graphical-session.target` +
      # `Type=notify` + `ExecStart=niri --session`, confirmed by reading the real shipped file)
      # never runs here at all. On every OTHER niri setup, THAT unit is what pulls
      # `graphical-session.target` in and holds it open until the compositor's own readiness
      # notification arrives. Skip it, and nothing else was ever going to start the target: it
      # sits `inactive (dead)` for the entire session (`RefuseManualStart=yes` on the target
      # itself forbids fixing this by hand, too -- a REAL shipped systemd unit,
      # `/usr/lib/systemd/user/graphical-session.target`, not this repo's own invention). Measured
      # live, on the laptop and the workstation, 2026-08-02: an empty screen, a perfectly
      # healthy compositor underneath it, and every home/session.nix component ordered
      # `After=graphical-session.target` -- the bar, notifications, the idle daemon, clipboard
      # history, the polkit agent, the keyring -- dead for the whole session, with nothing
      # anywhere naming why.
      #
      # THE FIX. For `Type=notify` (`entry.supportsNotify`, above), `ExecStartPost=` runs only
      # once THIS unit's own readiness notification has genuinely arrived (`systemd.service(5)`)
      # -- so firing `systemctl --user start "<compositor>.service"` from here starts a THIN
      # bridge unit (home/session.nix's `readinessBridge` renders exactly this shape) at the
      # identical moment the real compositor reports
      # ready, never earlier. That bridge unit reproduces the packaged unit's own
      # `BindsTo=graphical-session.target` + `Before=graphical-session.target` + `Type=notify`
      # shape, immediately confirms what this ExecStartPost already knows, and supervises the
      # session from there -- it does NOT launch a second real compositor, which would be the
      # exact double-DRM-master crash this estate lived through once already
      # (`drm_setmaster_ioctl` returns -EBUSY the instant a second master opens the same device,
      # this file's header, "SEATING IS CGROUP-STRUCTURAL") rather than a harmless duplicate.
      #
      # THE `+` PREFIX IS REQUIRED, NOT OPTIONAL -- MEASURED LIVE, NOT ASSUMED (2026-08-02), AND
      # THE OPPOSITE OF THIS FILE'S FIRST ATTEMPT. Without it, `ExecStartPost=` inherits this
      # unit's own `User=`/`PAMName=login`/`XDG_VTNR=1` -- and, empirically, EVERY exec command on
      # a `PAMName=` unit opens its OWN independent PAM session, not one shared session for the
      # whole unit (confirmed: the journal shows a SEPARATE `pam_unix(login:session): session
      # opened` line for the `ExecStartPost` process, distinct from the one for `ExecStart`'s own
      # niri). A second `PAMName=login` session claiming the SAME `XDG_VTNR` while the first
      # (niri's) is still open fails outright --
      # `pam_systemd(login:session): Varlink call io.systemd.Login.CreateSession failed:
      # io.systemd.Login.VirtualTerminalAlreadyTaken` -- which fails the ExecStartPost control
      # process, which fails the WHOLE unit (`Control process exited, code=exited,
      # status=1/FAILURE`), which restarts it, which repeats the identical collision: a crash
      # loop that hits `start-limit-hit` in under 15 seconds, taking the previously-healthy real
      # compositor down with it. `+` runs this ONE command with the manager's own (root)
      # privileges, skipping `User=`/`Group=`/`PAMName=` (and therefore the second PAM session)
      # entirely for it (`systemd.service(5)`, COMMAND LINES) -- niri's own `ExecStart=` above is
      # deliberately NOT prefixed, so it alone still opens the one real seated PAM session this
      # unit exists to open.
      #
      # `--machine="${session.user}@.host" --user`, not a bare `--user`, for the identical reason
      # `+` is required: this command now runs as root with NO `XDG_RUNTIME_DIR`/
      # `DBUS_SESSION_BUS_ADDRESS` of its own to fall back on (root's, not alice's) -- confirmed
      # live: a bare `systemctl --user` here fails immediately with "Failed to connect to user
      # scope bus via local transport: $DBUS_SESSION_BUS_ADDRESS and $XDG_RUNTIME_DIR not
      # defined", and that very error message names the fix used here. `--machine=<user>@.host`
      # is systemd's own documented mechanism for a privileged caller to reach a SPECIFIC user's
      # `--user` manager by NAME, with no numeric uid and no pre-set environment required --
      # exactly the shape this module already prefers (`session.user` is a name throughout, see
      # modules/session.nix's own `user` option doc: "never a uid, and never a uid anywhere
      # downstream either").
      #
      # `${config.systemd.package}/bin/systemctl`, never a bare name or a hardcoded `/usr/bin/
      # systemctl` -- see this file's header, "ExecStart MUST BE ABSOLUTE": ExecStartPost is
      # parsed by the identical grammar, and `systemd.package` (confirmed present on both planes
      # -- this file's header, "TWO PLANES, ONE FILE", already establishes system-manager renders
      # through the same real nixpkgs systemd module tree NixOS does) is the one spelling that
      # resolves correctly regardless of which plane composed this module, rather than assuming
      # `/usr/bin/systemctl` exists (true on the Arch/system-manager plane, unverified on NixOS).
      // {
        # The session-id import runs for EVERY seated compositor. The second command is the
        # integration-owned readiness bridge and exists only where the compositor really supports
        # sd_notify. Order is load-bearing: user components must inherit XDG_SESSION_ID before the
        # bridge pulls graphical-session.target in.
        ExecStartPost = [ importSessionId ] ++ lib.optional entry.supportsNotify
          "+${config.systemd.package}/bin/systemctl --machine=\"${session.user}@.host\" --user start ${session.compositor}.service";
      };
    };

  # `--user` unit: correct and sufficient for headless, and NOT a lesser version of the seated
  # case -- see modules/session.nix's own header. Nothing in wlroots' headless BACKEND touches
  # libseat at all (`attempt_headless_backend()` never calls `session_create_and_wait()`), so there
  # is no seat to acquire and PAMName would be solving a problem this delivery class does not have.
  #
  # NIXOS PLANE ONLY -- see `headlessUnsupportedAssertions` and this file's own header. This
  # function itself is still shared code, kept here rather than duplicated into a separate file:
  # it is only ever REFERENCED from `config` below when `plane == "nixos"`, so on the
  # system-manager plane it exists as dead, unforced Nix code (defining a function costs nothing
  # unless called) -- the actual capability boundary is enforced in `config`, not by hiding this
  # definition.
  mkHeadlessUnit = name: session:
    let
      entry = compositorEntry session.compositor;
      rendererEnvironment = rendererEnvironmentFor entry session.renderer;
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
          # `%U`: a systemd unit-file specifier expanded by systemd itself when it parses this
          # Environment= line (never by a shell), to the UID of the user this manager instance
          # belongs to -- correct for every user this shared unit definition ever loads under,
          # without this module ever needing to know a uid.
          "XDG_RUNTIME_DIR=/run/user/%U"
          # Same var, same reasoning, same `entry.currentDesktop` as `mkSeatedUnit` -- see that
          # option's own doc. A headless session is exactly as capable of running an Electron app
          # or a portal-mediated one (an agent driving a browser has no seat, not no desktop
          # identity), so the gap this closes is not seated-only.
          "XDG_CURRENT_DESKTOP=${entry.currentDesktop}"
        ]
        ++ lib.mapAttrsToList (k: v: "${k}=${v}") entry.headlessEnvironment
        ++ lib.mapAttrsToList (k: v: "${k}=${v}") rendererEnvironment
        ++ lib.mapAttrsToList (k: v: "${k}=${v}") session.extraEnvironment;

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
  # compositors for the same person). PLANE-AGNOSTIC: on system-manager this list is only ever
  # non-empty when `headlessUnsupportedAssertions` has already failed the build (see below), so
  # computing it unconditionally here is harmless -- it never reaches a real tmpfiles rule.
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

  # ── GROUP MEMBERSHIP FOR A NON-VT-BACKED SEAT, ACTUALLY VERIFIED ────────────────────────────
  #
  # modules/session.nix derives `requiredGroups` (see its own doc) but reads no `users.users` at
  # all -- it is host-and-platform-neutral by design (flake.nix's own comment: "none of it touches
  # pkgs, systemd, or users"). This module already reads `config.users.users`, which is real and
  # identical on both planes (see this file's header) -- for the SAME reason a defensive read beats
  # an import elsewhere in this family: an externally-managed identity (lldap, per the design doc
  # §6) has no entry here at all, and that is legitimate, not a defect -- only a NixOS/system-
  # manager-MANAGED user whose `extraGroups` provably lacks a required group is a real, catchable
  # misconfiguration, and it is exactly the one failure mode modules/session.nix's own
  # `requiredGroups` doc warns has no error message pointing at it otherwise.
  missingRequiredGroups = session:
    if !(config.users.users ? ${session.user}) then [ ]
    else lib.filter
      (g: !(lib.elem g (config.users.users.${session.user}.extraGroups or [ ])))
      session.requiredGroups;

  # ── HEADLESS ON system-manager: THE ONE GENUINE GAP, DEGRADED EXPLICITLY, NEVER SILENT ─────────
  #
  # See this file's header for the full source-reading behind this: system-manager activates only
  # the SYSTEM systemd instance and has no `systemd.user.services` (or any `systemd.user`
  # namespace) anywhere in its module tree. A headless session is therefore UNREPRESENTABLE on
  # that plane, not merely inconvenient -- there is no option path this module could write it to.
  # This assertion is what turns naming one anyway into a build failure that says exactly why,
  # rather than a session that is silently never started (and, worse, never even mentioned).
  #
  # Only ever consulted when `plane == "system-manager"` (see `config` below) -- computing the
  # list itself is harmless on the NixOS plane too, but folding it into `assertions` there would
  # be actively wrong (a NixOS host legitimately runs headless sessions).
  headlessUnsupportedAssertions = lib.mapAttrsToList
    (name: _: {
      assertion = false;
      message = ''
        nixdesktop.sessions.${name} has delivery = "headless", which the system-manager plane of
        nixdesktop.launcher cannot start. system-manager (confirmed by reading its own module
        tree at the pinned rev, not assumed -- see this file's header) manages only the SYSTEM
        systemd instance: there is no `systemd.user.services`, no `systemd.user` namespace, and
        no per-user-manager unit surface anywhere in it. A headless session needs exactly that
        surface (a `--user` unit, scoped by `unitConfig.ConditionUser`); a seated session does
        not -- it is a SYSTEM unit with `PAMName=`/`User=`, which system-manager renders
        identically to the NixOS plane (see the workstation's own hand-rolled
        `niri-seat.service` for the live proof, months of uptime on this exact mechanism).
        Run this session on a NixOS host via `nixosModules.launcher` instead, or remove it from a
        system-manager host's `nixdesktop.sessions`.
      '';
    })
    headlessSessions;

  # ── THE VT's OTHER CLAIMANTS ────────────────────────────────────────────────────────────────
  # A seated `PAMName=` unit does not own its VT merely by asking for it. `getty@tty<vt>` is
  # statically enabled by the distro's own presets, and `autovt@tty<vt>` is what logind spawns
  # on demand if that VT is ever reactivated -- either one will happily open a login session on
  # the same VT this module just claimed, and then BOTH mechanisms are racing for one seat.
  # Whichever arrives first wins the boot; the loser fails, retries, and dies on its start limit.
  #
  # Measured live on a laptop running exactly this module: the getty-spawned login won every boot,
  # the seated unit burned its five restarts and sat in `start-limit-hit`, and that host's own
  # config asserted in a comment that both units were "masked outright" -- while nothing in this
  # module, or anywhere else, had ever implemented that masking. The comment described a design;
  # the design was never built. This is it.
  #
  # Both instances, never just `getty@`: masking the boot-time unit alone leaves `autovt@` free to
  # re-enter one `loginctl activate` later, which is the identical race merely deferred.
  vtGettyMaskUnits = lib.concatMap
    (session: lib.optionals (session.vt != null && session.maskVtGetty) [
      "getty@tty${toString session.vt}.service"
      "autovt@tty${toString session.vt}.service"
    ])
    (lib.attrValues seatedSessions);
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
              `lib.getExe'`). nixdesktop has no compositor input or package default; the
              integration product that declares this descriptor supplies the exact derivation.
              If this is null, `command` must begin with an absolute path.
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

              `null` means the integration did not provide a command. An enabled session naming
              that descriptor then fails evaluation.
            '';
          };

          deviceEnvironment = mkOption {
            type = types.nullOr (types.listOf types.str);
            default = null;
            description = ''
              Environment-variable names that receive the colon-joined, primary-first list of
              permitted DRM card paths. An empty list means device selection is translated into
              the compositor's config by its integration product.
            '';
          };

          rendererEnvironment = mkOption {
            type = types.nullOr (types.attrsOf (types.attrsOf types.str));
            default = null;
            example = {
              auto = { };
              hardware = { };
              software.WLR_RENDERER = "pixman";
            };
            description = ''
              Mapping from nixdesktop's neutral renderer intents (`auto`, `hardware`, and
              `software`) to this compositor's own environment variables. nixdesktop never
              emits a wlroots, Smithay, EGL, Vulkan, or Pixman knob itself.
            '';
          };

          headlessEnvironment = mkOption {
            type = types.nullOr (types.attrsOf types.str);
            default = null;
            example.WLR_BACKENDS = "headless";
            description = ''
              Compositor-specific environment for a headless launch. Used only when
              `supportsHeadless` is true; nixdesktop does not assume a wlroots backend.
            '';
          };

          supportsHeadless = mkOption {
            type = types.nullOr types.bool;
            default = null;
            example = true;
            description = ''
              Whether this compositor can run a session with no physical seat or output.
              A headless session on an integration that does not declare this capability is a
              build failure.
            '';
          };

          supportsVirtualOutputs = mkOption {
            type = types.nullOr types.bool;
            default = null;
            example = true;
            description = ''
              Whether this compositor can create an output that no physical panel backs, at
              runtime, for a session that declares `nixdesktop.sessions.<name>.virtualOutputs`.
              The integration product owns this measured capability. Null resolves to false, and
              a session that asks for virtual outputs then fails evaluation.
            '';
          };

          supportsNotify = mkOption {
            type = types.nullOr types.bool;
            default = null;
            example = true;
            description = ''
              Whether this compositor's OWN binary calls sd_notify(READY=1) once it is genuinely
              ready (backend up, outputs configured) -- never whether some WRAPPER around it
              could be made to. Drives `mkSeatedUnit`'s own `Type=`/`ExecStartPost=` below: a
              seated session is a SYSTEM unit that bypasses the compositor's PACKAGED `--user`
              unit entirely (this file's header, "THE ONE FORCED FACT"), so nothing else was
              ever going to fire that packaged unit's own `BindsTo=graphical-session.target` --
              this field is what tells `mkSeatedUnit` it can safely reproduce that exact
              mechanism itself, on the SYSTEM unit, instead of silently leaving every
              `graphical-session.target`-ordered component (home/session.nix's bar,
              notifications, idle daemon, ...) dead for the whole session.

              The integration product owns this measured fact. Null resolves to false and keeps
              the system unit on `Type=simple` without a readiness bridge.
            '';
          };

          currentDesktop = mkOption {
            type = types.nullOr types.str;
            default = null;
            example = "scroll";
            description = ''
              What this compositor's session is HONESTLY called, for the one purpose that has
              nothing to do with launching it: `XDG_CURRENT_DESKTOP` on the rendered unit's own
              `Environment=` (see `mkSeatedUnit`/`mkHeadlessUnit`, both of which append an
              `XDG_CURRENT_DESKTOP=<value>` line unconditionally -- there is no session this repo
              renders for which the variable is legitimately absent).

              Electron secret storage, desktop-entry filtering, and portal selection all consume
              this value, so the integration product must declare its measured desktop identity.

              `null` falls back to the descriptor name. Integration products should normally set
              the value explicitly whenever the runtime's desktop identity differs or has been
              verified against a portal route.

              A SINGLE STRING, NEVER A LIST, even though `XDG_CURRENT_DESKTOP` is itself
              colon-separated and may carry several entries (the XDG Desktop Entry Specification's
              own `OnlyShowIn`/`NotShowIn` wording: "a list of strings identifying the desktop
              environments that will [not] display a given desktop entry"). No consumer of this
              table has a MEASURED need for a second entry -- the whole finding above is that ONE
              correct entry beats the plausible-sounding one it replaced, not that more entries
              beat fewer. Nothing here enforces single-token-ness either: this is a plain `str`, so
              a consumer who does one day measure a genuine second-entry need writes the
              colon-joined value directly (`currentDesktop = "scroll:sway";`) rather than this
              option growing a second, list-shaped surface for a case nobody has hit yet.
            '';
          };
        };
      });
      default = { };
      example = lib.literalExpression ''
        {
          scroll = {
            command = "scroll";
            package = nixscroll.packages.''${pkgs.system}.scroll;
            deviceEnvironment = [ "WLR_DRM_DEVICES" ];
            rendererEnvironment.software.WLR_RENDERER = "pixman";
            headlessEnvironment.WLR_BACKENDS = "headless";
            supportsHeadless = true;
          };
        }
      '';
      description = ''
        Complete compositor launch descriptors supplied by integration products. nixdesktop has
        no built-in rows: a session is usable only when its compositor integration declares the
        exact package/command, device and renderer translations, headless and virtual-output
        capabilities, readiness behavior, and desktop identity. The same table is consumed on the
        NixOS and system-manager planes.
      '';
    };

    deviceFence = mkOption {
      # Opaque, deliberately -- the same choice nixhost's own `resources.gpu` makes for the
      # identical reason (see that option's own comment): the two fields below (`devicePolicy`,
      # `deviceAllow`) are cheap enough that a submodule would buy nothing but merge-semantics
      # complexity a plain attrset does not have to worry about, and this module is the only
      # writer either way.
      type = types.attrsOf types.attrs;
      readOnly = true;
      description = ''
        READ-ONLY, derived: one `{ devicePolicy; deviceAllow; }` record per SEATED session -- the
        IDENTICAL `DevicePolicy=`/`DeviceAllow=` pair this module writes onto that session's own
        systemd unit's `serviceConfig` (see `mkSeatedUnit`, and `deviceFenceFor`, this file's own
        single source for both), exposed a SECOND time here as plain, read-only DATA -- so a host,
        or `checks/launcher.nix`, can read the exact enforced policy without inspecting a rendered
        unit. `readOnly` because the unit is what actually enforces this: writing here would change
        nothing a real cgroup sees, so this option must never be mistaken for a second way to set
        the policy, only a cheap way to read it back.
      '';
    };
  };

  config = {
    assertions =
      # ── AN UNKNOWN COMPOSITOR FAILS LOUDLY ──────────────────────────────────────────────────
      # Checked here rather than left to the generated wrapper failing at runtime: the whole
      # session table is available at eval time, so a typo is a build failure naming every
      # offending session at once, not a unit that fails to start on whichever host happens to hit
      # it first. `declaredCompositorNames` comes only from integration-provided descriptors.
      lib.mapAttrsToList
        (name: s: {
          assertion = lib.elem s.compositor declaredCompositorNames;
          message = ''
            nixdesktop.sessions.${name} names compositor "${s.compositor}", which is neither one of
            declared in nixdesktop.launcher.compositors. Declared:
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

      # ── RENDERER INTENT MUST HAVE A COMPOSITOR TRANSLATION ────────────────────────────────
      ++ lib.mapAttrsToList
        (name: s: {
          assertion = builtins.hasAttr s.renderer
            (compositorEntry s.compositor).rendererEnvironment;
          message = ''
            nixdesktop.sessions.${name} selects renderer intent "${s.renderer}", but compositor
            "${s.compositor}" does not declare a translation for it in
            nixdesktop.launcher.compositors.${s.compositor}.rendererEnvironment. Renderer
            implementation belongs to the compositor integration; nixdesktop will not guess a
            wlroots, Smithay, EGL, Vulkan, or Pixman environment variable.
          '';
        })
        (lib.filterAttrs (_: s: lib.elem s.compositor declaredCompositorNames) enabledSessions)

      # ── HEADLESS IS A DECLARED COMPOSITOR CAPABILITY ───────────────────────────────────────
      ++ lib.mapAttrsToList
        (name: s: {
          assertion = (compositorEntry s.compositor).supportsHeadless;
          message = ''
            nixdesktop.sessions.${name} is headless, but compositor "${s.compositor}" does not
            declare supportsHeadless = true. The required launch mechanism is compositor-specific
            and must come from its integration product.
          '';
        })
        (lib.filterAttrs
          (_: s: s.delivery == "headless" && lib.elem s.compositor declaredCompositorNames)
          enabledSessions)

      # ── VIRTUAL OUTPUTS DECLARED ON A COMPOSITOR THAT CANNOT CREATE ONE ─────────────────────
      # Only for sessions naming a compositor the table above DOES declare -- same scoping as the
      # unresolvable-command check just above, for the same reason: an unknown compositor already
      # fails, once, higher up, and checking a capability of a compositor that does not resolve at
      # all would just be a second, confusing error about the identical typo.
      #
      # WHY THIS HAS TO BE A HARD FAILURE, NOT A WARNING. `nixdesktop.sessions.<name>.
      # virtualOutputs` exists because an agent identity with no seat still needs somewhere to
      # render a browser into (see modules/session.nix's own doc on that option, and the
      # workstation-story design doc's invariant 1b) -- so a session that declares one and gets no
      # error is not a cosmetic gap, it is an identity with no display, discovered only when
      # whatever was meant to draw into it silently never appears anywhere. That is exactly the
      # failure class `permittedDevices == [ ]` already refuses to let a seated session reach
      # silently, a few assertions up -- this is the same shape, for a different capability.
      ++ lib.mapAttrsToList
        (name: s: {
          assertion = false;
          message = ''
            nixdesktop.sessions.${name} declares ${toString (lib.length s.virtualOutputs)}
            virtualOutputs, but compositor "${s.compositor}" cannot create one
            (nixdesktop.launcher.compositors."${s.compositor}".supportsVirtualOutputs is not
            `true`). A virtual output is a structural requirement for a session with no physical
            panel behind it -- see nixdesktop.sessions.<name>.virtualOutputs's own doc -- and a
            compositor that cannot provide one must fail loudly, naming itself, rather than
            leaving the session with no display and no error saying why. Either run this session
            on a compositor that supports virtual outputs (scroll does, out of the box), or set
            nixdesktop.launcher.compositors."${s.compositor}".supportsVirtualOutputs = true
            yourself, if a version of "${s.compositor}" newer than this repo knows about has
            gained the capability.
          '';
        })
        (lib.filterAttrs
          (_: s: s.virtualOutputs != [ ] && !(compositorEntry s.compositor).supportsVirtualOutputs)
          (lib.filterAttrs (_: s: lib.elem s.compositor declaredCompositorNames) enabledSessions))

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
        rawDeviceNameOffenders

      # ── A SEATED, NON-VT-BACKED SESSION'S USER IS ACTUALLY IN ITS REQUIRED GROUPS ────────────
      # See modules/session.nix's own `requiredGroups` doc: on a seat with no VT, group membership
      # is the ONLY mechanism granting device access at all, and a group silently missing from
      # `extraGroups` fails this session to draw anything, with an error naming neither the group
      # nor this config. Only for a NixOS/system-manager-MANAGED user (`missingRequiredGroups`
      # returns `[ ]`, and this fires never, for an externally-managed one) -- see that helper's
      # own comment for why asserting into existence a fact this host genuinely cannot see would be
      # exactly the wrong failure mode.
      ++ lib.mapAttrsToList
        (name: s: {
          assertion = false;
          message = ''
            nixdesktop.sessions.${name} needs group(s) ${lib.concatStringsSep ", " (missingRequiredGroups s)}
            on user "${s.user}" (managed in users.users here), but
            users.users.${s.user}.extraGroups does not list them. This session's seat has no VT
            (nixdesktop.sessions.${name}.vt is null -- see modules/session.nix's own
            `requiredGroups` doc): there is no active-VT ACL to fall back on, so these groups are
            the ONLY thing that will grant it /dev/dri/* and input access at all. A group silently
            missing here does not fail this session to start -- it fails it to draw anything, and
            both libinput and the DRM backend report nothing more specific than "couldn't create
            backend". Add:
              users.users.${s.user}.extraGroups = [ ${lib.concatMapStringsSep " " (g: "\"${g}\"") s.requiredGroups} ];
          '';
        })
        (lib.filterAttrs
          (_: s: s.requiredGroups != [ ] && config.users.users ? ${s.user} && missingRequiredGroups s != [ ])
          seatedSessions)

      # ── HEADLESS NAMED ON A PLANE THAT CANNOT START IT ──────────────────────────────────────
      # See `headlessUnsupportedAssertions`'s own comment. Only folded in on the system-manager
      # plane -- a NixOS host naming a headless session is exercising exactly the feature that
      # plane exists to support, so this list is empty there by construction (`plane` is a plain
      # Nix value fixed before evaluation reaches here, never a `config`-derived condition).
      ++ lib.optionals (plane == "system-manager") headlessUnsupportedAssertions;

    # This module's own read of `nixhost.resources.gpu` (see `inventoryProbe`'s own comment) folds
    # into the SAME warnings list session.nix's identical-path probe already contributes to --
    # `collectProbes` is idempotent-in-effect here (an unresolved leaf reported once per probe
    # call site, not once per module), never a duplicate of session.nix's own wording.
    warnings = (collectProbes [ inventoryProbe ]).warnings;

    # ── ONE `systemd` VALUE, ASSEMBLED IN PLAIN NIX BEFORE `config` EVER SEES IT ─────────────
    #
    # `services`/`tmpfiles.rules` (always present) and `user.services` (nixos-plane only) all
    # nest under the SAME top-level `systemd` key -- and a module's own `config` attribute is
    # plain Nix, merged shallowly wherever plain Nix `//` is used directly (the module SYSTEM's
    # recursive merge only ever applies ACROSS separate modules, never inside one module's own
    # returned value). An earlier revision of this split built `systemd.services`/`.tmpfiles.rules`
    # as top-level `config` keys and then appended `// lib.optionalAttrs (plane == "nixos")
    # { systemd.user.services = ...; }` AFTER the closing brace of the main `config` attrset --
    # which shallow-merges at the OUTER level, so the second attrset's `systemd = { user.services
    # = ...; }` silently REPLACED the first's `systemd = { services = ...; }` wholesale, deleting
    # `services`/`tmpfiles.rules` outright on the nixos plane (caught immediately: `nix flake
    # check` on the very fixture this file's own header describes reported `attribute
    # 'nixdesktop-desk' missing`). Building the full `systemd` attrset here, ONE level higher,
    # means the plane-conditional `//` only ever merges DISTINCT keys (`services`/`tmpfiles` vs
    # `user`) within that one attrset -- never two different values claiming the same key.
    systemd = {
      services = lib.mapAttrs' (name: session: lib.nameValuePair "nixdesktop-${name}" (mkSeatedUnit name session)) seatedSessions;

      # ── LINGERING, WITHOUT TOUCHING `users.users` AT ALL ───────────────────────────────────
      #
      # `users.users.<name>.linger = true` -- what this file used to write, unconditionally, for
      # every headless session's user -- makes NixOS treat `<name>` as a NixOS-MANAGED account the
      # moment it appears as a key in `users.users`, definition or not: `users-groups.nix`'s own
      # activation logic then wants to create/verify a real local account for it. That is exactly
      # backwards for the identity path this module's own comments (see `homeOf`) say it
      # accommodates -- a user that exists only through an external source (lldap) must never be
      # asserted into existence here, and there is no way to make that write conditional on "is
      # this user ALREADY declared elsewhere" without reading the very option this module is
      # contributing to (a genuine self-reference, not a subtlety worth routing around). This
      # concern is IDENTICAL on system-manager (`userborn` reads `config.users.users` exactly as
      # eagerly, see this file's header), so the fix below applies unchanged on both planes.
      #
      # So this reaches for the mechanism ONE LAYER BELOW `users.users.<name>.linger` instead of
      # trying to gate it: `loginctl enable-linger USER` does exactly one thing on disk -- create
      # an empty marker file at `/var/lib/systemd/linger/<username>` (verified live on
      # the server: `ls -la /var/lib/systemd/linger/` shows a zero-byte `alice`).
      # `systemd-logind` reads that directory to decide which users' `user@<uid>.service` survives
      # across reboots; it has never cared whether `<username>` is declared in `users.users` at
      # all. `systemd.tmpfiles.rules` writing that same file declaratively (`f`, create-if-absent)
      # reproduces the imperative command's ONLY on-disk effect, for ANY username -- NixOS-declared
      # or externally-managed alike -- without this module ever touching `users.users` or
      # `users.manageLingering`. Same idiom session.nix's own header already uses for seat
      # assignment (`loginctl attach` is itself just a udev rule NixOS can render directly) -- a
      # real logind mechanism has a declarative rendering, and reaching for it beats asking
      # NixOS's own `users.*` option surface to accommodate a case it was not built for.
      # `systemd.tmpfiles.rules` is a real, identical option on both planes (see this file's
      # header), so this needs no plane branching either.
      tmpfiles.rules = map (u: "f /var/lib/systemd/linger/${u} 0644 root root -") lingerUsers;
    }
    # ── STRUCTURAL, NOT `mkIf`: `user.services` (i.e. the full `systemd.user.services` path)
    # must never appear in the `systemd` attrset AT ALL on the system-manager plane. `plane` is a
    # plain Nix value, fixed long before the module system builds a `config`, so
    # `lib.optionalAttrs` decides at THAT level whether the key exists in the attrset in the first
    # place -- there is no risk of the module system ever seeing a definition for an option
    # system-manager never declares, unlike `lib.mkIf (plane == "nixos") { systemd.user.services =
    # ...; }` would be (that guards the VALUE, not whether the KEY is written at all, and NixOS's
    # own module system requires every written config path to match a declared option regardless
    # of whether the guard ever evaluates true). See this file's header for the full reasoning,
    # and checks/launcher.nix for the fixture that proves it: a system-manager-plane host stub
    # that does not declare `systemd.user.services` still evaluates cleanly through this module
    # with a seated-only session table.
    // lib.optionalAttrs (plane == "nixos") {
      user.services = lib.mapAttrs' (name: session: lib.nameValuePair "nixdesktop-${name}" (mkHeadlessUnit name session)) headlessSessions;

      # See `vtGettyMaskUnits`. NixOS's own masking mechanism is `systemd.units.<name>.enable =
      # false`, which renders the unit as a symlink to /dev/null -- `systemd.services.<name>` is
      # the wrong surface for a TEMPLATE INSTANCE like `getty@tty1`, which NixOS does not
      # generate content for and would therefore not emit at all.
      units = lib.listToAttrs (map (u: lib.nameValuePair u { enable = false; }) vtGettyMaskUnits);
    }
    // lib.optionalAttrs (plane == "system-manager") {
      # See `vtGettyMaskUnits`. `systemd.maskedUnits` (numtide/system-manager's own
      # `nix/modules/systemd.nix`) is the mechanism here, NOT `systemd.services.<name>.enable =
      # false`: that only does anything for units system-manager itself generates content for,
      # per its own documentation -- pointed at a distro-owned unit like `getty@tty1` it is a
      # SILENT no-op, which is indistinguishable from a working mask right up until the boot
      # where the getty wins the race.
      maskedUnits = vtGettyMaskUnits;
    };

    # ── deviceFence: THE SAME RECORD THE UNIT ABOVE CARRIES, EXPOSED READ-ONLY TOO ────────────
    # See `deviceFenceFor`'s own comment and the `deviceFence` option's own doc -- cheap (two small
    # lists per seated session), single-sourced from the identical helper `mkSeatedUnit` reads, and
    # `readOnly` so nothing can mistake writing here for a second way to set the policy.
    nixdesktop.launcher.deviceFence = lib.mapAttrs (_: deviceFenceFor) seatedSessions;
  };
}
