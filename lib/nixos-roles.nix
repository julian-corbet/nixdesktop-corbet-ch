# lib/nixos-roles.nix — the NixOS resolution tables for nixdesktop's roles. Pure data (a function
# of `pkgs`, plus an optional consumer-supplied compositor table — see `compositors` below), no
# module system: imported by modules/nixos-backend.nix (the only consumer today) and
# available to a future paired home-manager module the same way nixarch's home/desktop.nix reads
# lib/desktop-roles.nix — for the same reason: the polkit agent's package and the polkit agent's
# spawn command are the same fact, and keeping them in one attrset means a system-layer module and
# a user-layer module can never disagree about it even though they are separate evaluations.
#
# THIS FILE IS THE ONLY PLACE IN THE PROJECT THAT KNOWS NIXPKGS ATTRIBUTE PATHS for the desktop.
# nixdesktop declares roles ("thunar", "mate-polkit") and never names a package; that split is the
# whole point, and this file is the NixOS half of it (nixarch/lib/desktop-roles.nix is the Arch
# half, same shape, pacman names instead of nixpkgs attrs).
#
# WHY THIS BACKEND LIVES IN nixdesktop ITSELF, UNLIKE THE ARCH ONE. nixarch's backend could not
# live here because naming pacman packages requires knowing Arch's package repos — foreign
# knowledge nixdesktop has no other reason to carry. Resolving roles to nixpkgs attributes needs no
# such foreign knowledge: nixpkgs is already nixdesktop's only flake input (see flake.nix), so this
# file adds a data table, not a dependency. The asymmetry is deliberate, not an inconsistency.
#
# NIXPKGS ATTR PATHS ARE NOT PACMAN NAMES. This is the entire reason the role indirection exists,
# and it bites immediately: `thunar` is `pkgs.thunar` (top-level in current nixpkgs; older releases
# nested it under `pkgs.xfce`), but `mate-polkit` is `pkgs.mate-polkit` while
# `polkit-kde-agent` is `pkgs.kdePackages.polkit-kde-agent-1` — no top-level alias, and the trailing
# `-1` is part of the real attribute name, not a version pin. Verified against a live nixpkgs
# evaluation while writing this file (`nix eval`/`nix build` against nixos-unstable), not guessed.
#
# POLKIT AGENT BINARY PATHS ARE STORE PATHS, NOT `/usr/lib/...`. nixarch's table hardcodes
# absolute paths like `/usr/lib/mate-polkit/polkit-mate-authentication-agent-1` because that is
# where Arch's packaging puts it, always, for every user. Nix has no equivalent fixed location —
# the agent binary lives under the package's own store path, which is only known once the package
# is. So every `command` below is built as a string interpolation of the package itself
# (`"${pkg}/libexec/..."`), never a literal path. The subpath itself was confirmed by building each
# package and listing its output (`nix build` + `find $out`) rather than assumed from the Arch
# layout — mate-polkit in particular installs straight to `$out/libexec/`, with none of the
# `mate-polkit/`-named subdirectory Arch's own packaging adds, so copying the Arch path across
# platforms would have silently pointed at a directory that doesn't exist.
{ lib, pkgs, extraCompositors ? { } }:
rec {
  # ── Roles whose implementation is a named choice ────────────────────────────────────────────

  # A file manager alone is not a working file manager: thumbnails need a thumbnailer service, and
  # mounting or browsing anything — a USB stick, an SMB share, an MTP phone — needs gvfs. nixarch's
  # equivalent table ships that whole floor as pacman names right in the entry, because on Arch
  # installing the package IS enabling it. NixOS is the case the `capabilities` header below
  # describes for portals, and it bites harder here than anywhere else:
  #
  #   - `pkgs.gvfs` in `environment.systemPackages` leaves `GIO_EXTRA_MODULES` unset, so NOT ONE uri
  #     scheme resolves — no smb://, no mtp://, no sftp://, not even trash:// or network://. And
  #     nothing MOUNTS at all, not even a USB stick, because that takes `programs.fuse.enable` and
  #     `services.udisks2.enable`, neither of which follows from a package; nor do the libmtp udev
  #     rules a phone or camera needs. All four come from `services.gvfs.enable` and nowhere else
  #     (nixpkgs' `nixos/modules/services/desktops/gvfs.nix`).
  #   - `pkgs.thunar` is the UNWRAPPED binary. thunarx plugins load only from `THUNARX_DIRS`, which
  #     is set exclusively by the wrapper `pkgs.thunar.override { thunarPlugins = ...; }` builds,
  #     pointing at its own symlinkJoin output — so with plugins installed any other way they NEVER
  #     load. `programs.thunar.enable` is also what rewrites thunar's systemd user unit and its
  #     three `org.xfce.*` D-Bus activation files to name the WRAPPED binary; without it, "open
  #     containing folder" from another app D-Bus-activates the plugin-less copy instead. And it
  #     sets `programs.xfconf.enable`, without which Thunar persists NO settings whatsoever.
  #
  # So the floor is wired through the real options by modules/nixos-backend.nix, exactly as
  # `portalPackages` is, and this table carries only what those options do NOT already install.
  #
  # AND LISTING THEM ANYWAY WOULD BE WORSE THAN REDUNDANT, not merely untidy — which is why no
  # entry below names gvfs, and the thunar entry names neither thunar nor tumbler.
  # `services.gvfs.enable` installs `services.gvfs.package`, whose default is `pkgs.gnome.gvfs` —
  # that is `gvfs.override { gnomeSupport = true; }`, a DIFFERENT store path carrying the IDENTICAL
  # `gvfs-<version>` name. Adding `pkgs.gvfs` beside it puts two same-named gvfs builds in the
  # system profile, one of which wins arbitrarily while `GIO_EXTRA_MODULES` keeps pointing at the
  # other: a half-working gvfs with nothing to blame. Same shape for thunar, except the two names
  # DIFFER (`thunar-<version>` vs `thunar-with-plugins-<version>`) so not even a collision warning
  # fires, and both ship `bin/thunar`.
  #
  # thunar-volman is the one thing left in the `thunar` entry, and it belongs there rather than in
  # `thunarPlugins` below because it is not a thunarx plugin at all: `nix build` + `find $out` shows
  # `bin/thunar-volman` and `bin/thunar-volman-settings` and NO `lib/thunarx-3/*.so` (nixpkgs' own
  # `programs.thunar.plugins` example lists it anyway — misleading; it would work from there only
  # because the wrapper's symlinkJoin merges `bin/` too, not because anything loads it as a plugin).
  # Thunar spawns it by bare name — `argv[0] = g_strdup ("thunar-volman")` in `thunar-application.c`,
  # a PATH lookup whose only failure mode is a g_warning nobody sees — so PATH is exactly right.
  fileManagers = {
    thunar = [ pkgs.thunar-volman ];
    nautilus = [ pkgs.nautilus ];
    dolphin = [ pkgs.kdePackages.dolphin pkgs.kdePackages.kio-extras ];
    nemo = [ pkgs.nemo ];
    pcmanfm = [ pkgs.pcmanfm ];
  };

  # thunarx plugins, for `programs.thunar.plugins` — NEVER `environment.systemPackages`. A plugin
  # dropped in the package list installs a `.so` into a store path no thunar ever reads: only the
  # wrapper's `THUNARX_DIRS` is consulted, and it names the wrapper's own output. Wired by
  # modules/nixos-backend.nix, gated on `want.fileManagerExtras`, for the same reason
  # `portalPackages` is wired rather than resolved — see the `capabilities` header below.
  #
  # Top-level attributes, all three: the `pkgs.xfce.thunar-*-plugin` paths still evaluate but emit a
  # "was moved to top-level" warning on every rebuild.
  #
  # thunar-vcs-plugin is the Git half only as packaged (`withSubversion ? false`); it shells out to
  # a bare `"git"` (`tvp-git-helper/*.c`), so its menu entries need git on PATH — which, since they
  # only appear inside a working copy, is a condition that answers itself. An SVN-capable build is
  # an `.override`, not a second entry here.
  thunarPlugins = [
    pkgs.thunar-archive-plugin
    pkgs.thunar-media-tags-plugin
    pkgs.thunar-vcs-plugin
  ];

  polkitAgents = {
    mate-polkit = {
      packages = [ pkgs.mate-polkit ];
      command = "${pkgs.mate-polkit}/libexec/polkit-mate-authentication-agent-1";
    };
    polkit-kde-agent = {
      # qt6ct rides along for the same reason nixarch's table carries it: this agent is the only
      # Qt component on an otherwise-GTK desktop, and without a Qt platform theme it renders
      # unstyled against everything else.
      packages = [ pkgs.kdePackages.polkit-kde-agent-1 pkgs.qt6Packages.qt6ct ];
      command = "${pkgs.kdePackages.polkit-kde-agent-1}/libexec/polkit-kde-authentication-agent-1";
    };
    lxqt-policykit = {
      packages = [ pkgs.lxqt.lxqt-policykit ];
      command = "${pkgs.lxqt.lxqt-policykit}/bin/lxqt-policykit-agent";
    };
  };

  # gnome-keyring and kwallet both install their binary straight to $out/bin (confirmed by build +
  # `find`, same as every other role), so — unlike the polkit agents above — a bare command resolved
  # via PATH is correct and there is no store path to interpolate. Kept as `command` strings anyway,
  # mirroring the Arch table's shape and for the same reason a future home-layer module would want
  # it: the package and the spawn command are one fact. oo7, added below, BREAKS that pattern — see
  # its own comment for why it needs the polkit agents' string-interpolation treatment instead.
  keyrings = {
    gnome-keyring = {
      packages = [ pkgs.gnome-keyring ];
      # --components=secrets only: this is the secret-service role, not the ssh-agent or pkcs11
      # ones. A consumer wanting those should say so rather than get them by accident.
      command = "gnome-keyring-daemon --start --components=secrets";
    };
    kwallet = {
      packages = [ pkgs.kdePackages.kwallet ];
      command = "kwalletd6";
    };

    # oo7 -- THE DECISION (operator-mandated): the modern Secret Service provider, replacing
    # gnome-keyring on any host that autologins with no PAM auth phase. See home/session.nix's own
    # `nixdesktop.session.keyring` option group — specifically its "keyring provider, assembled
    # HERE" header comment — for the full account of the credential-based autologin unlock this
    # entry exists to support, and for every fact below, all confirmed live against the exact
    # `nixpkgs#oo7-server` version (0.6.0) the operator's mandate itself names, not assumed from
    # gnome-keyring's precedent two lines above.
    oo7 = {
      packages = [ pkgs.oo7-server ];
      # UNLIKE gnome-keyring/kwallet above: `nix build nixpkgs#oo7-server` + `find $out -type f`
      # shows the real binary at `$out/libexec/oo7-daemon`, NOT `$out/bin` — a bare "oo7-daemon"
      # would NOT resolve via PATH. Interpolated like the `polkitAgents` table above, for the
      # identical reason (see that table's own header comment).
      #
      # NOT `${pkgs.oo7-server}/run/wrappers/bin/oo7-daemon` — that is the path nixpkgs' OWN
      # packaged unit (`share/systemd/user/oo7-daemon.service`, `useWrappedDaemon = true` by
      # default — see `pkgs/by-name/oo/oo7-server/package.nix`) points its `ExecStart=` at, and it
      # only resolves to a real binary on a host whose SYSTEM config also sets
      # `security.wrappers.oo7-daemon` (CAP_IPC_LOCK, mlock so secrets can't be swapped to disk —
      # see nixpkgs' own `nixos/modules/services/desktops/oo7.nix`, `services.oo7.enable`, read at
      # the pinned 0.6.0-era checkout). home/session.nix's own keyring rendering has no `pkgs`, no
      # root, and no route to `security.wrappers` — it cannot reproduce that wrapper regardless of
      # what path this entry names, so pointing here at a wrapper that may not exist would be
      # strictly worse than the true, working (if CAP_IPC_LOCK-less) libexec path below. The gap is
      # flagged, not silently worked around — see `nixdesktop.session.keyring.oo7.command`'s own
      # doc for the consumer-facing half of this same note.
      command = "${pkgs.oo7-server}/libexec/oo7-daemon";
    };
  };

  bars = {
    waybar = [ pkgs.waybar ];
    eww = [ pkgs.eww ];
    # noctalia is installed from its own flake through home-manager, not from nixpkgs — nixpkgs
    # carries no package for it at all. Empty on purpose, not an oversight; see flake.nix's own
    # comment on why noctalia is deliberately not a flake input here.
    noctalia = [ ];
  };

  notificationDaemons.mako = [ pkgs.mako ];

  osds.swayosd = [ pkgs.swayosd ];

  # ── Capability roles: booleans in `want`, package sets here ─────────────────────────────────
  #
  # `portals` is deliberately NOT a key here, unlike nixarch's table. On Arch, "install the portal
  # backend" and "the portal works" are the same action — pacman drops the package and the
  # `.portal`/desktop files it ships are all xdg-desktop-portal reads. On NixOS the package alone
  # is not enough: `xdg-desktop-portal` itself needs `xdg.portal.enable` (its systemd user service,
  # its D-Bus activation) and a backend needs to be listed in `xdg.portal.extraPortals` so it is
  # registered in `portals.conf` at all — dropping the package into `environment.systemPackages`
  # with nothing else produces an installed-but-unregistered binary that is invisible to portal
  # requests, which is a worse failure than doing nothing (it looks configured and isn't). Rather
  # than pretend that gap away by wiring it through `packagesFor` like everything else,
  # `portalPackages` below is exported separately and modules/nixos-backend.nix wires it through
  # the real option.
  #
  # `fileManagerExtras` below is the same story told half-way: the boolean IS a key here, because
  # the archiver it installs is an ordinary package, but the thunarx plugins the role is actually
  # about are `thunarPlugins` above and reach `programs.thunar.plugins` through the backend. A
  # capability whose package set is a partial answer says so in its own comment; none of them
  # silently pretends `environment.systemPackages` was enough.
  capabilities = {
    # niri probes for xwayland-satellite by name at startup and, if absent, WARNS and continues
    # with X11 integration silently disabled — which surfaces much later as "X11 apps don't
    # start" with nothing obvious to blame.
    xwayland = [ pkgs.xwayland-satellite ];
    screenshots = [ pkgs.grim pkgs.slurp ];
    clipboardHistory = [ pkgs.cliphist pkgs.wl-clipboard ];
    idleAndLock = [ pkgs.swayidle pkgs.swaylock ];

    # The plugins this boolean really exists for are NOT here — they are `thunarPlugins` above,
    # wired through `programs.thunar.plugins`. What IS here is the archive manager the archive
    # plugin dispatches to: with no archiver installed, "Create Archive"/"Extract Here" appear in
    # the context menu and do nothing useful, which is the exact failure this whole file exists to
    # stop shipping.
    #
    # engrampa, NOT xarchiver, and that is a NixOS fact rather than a taste call.
    # thunar-archive-plugin never runs an archiver directly: it looks up a `<desktop-id>.tap`
    # wrapper script under the LIBEXECDIR baked into the plugin at compile time
    # (`tap_backend_mime_wrapper`, `tap-backend.c`) and FILTERS OUT of its candidate list every
    # application for which no such script exists. On Arch that directory is the shared
    # `/usr/lib/thunar-archive-plugin`, so the `xarchiver.tap` that xarchiver itself installs lands
    # next to the plugin's bundled ones and resolves. On NixOS LIBEXECDIR is the PLUGIN'S OWN store
    # path, so the only wrappers reachable are the ones the plugin ships — ark, engrampa,
    # file-roller, plus desktop-id symlinks — and xarchiver's tap sits unreachable in xarchiver's
    # store path. Installing xarchiver here would turn "Extract Here" into "No suitable archive
    # manager found". Read out of the plugin's C source and both packages' built outputs, not
    # inferred from the Arch layout.
    #
    # Of the three that DO resolve, engrampa is the one this project's own constraint permits: ark
    # drags KDE Frameworks onto a GTK desktop, file-roller is GTK4 + libadwaita at the pinned
    # version, engrampa is GTK3 — the same reasoning that makes mate-polkit the default polkit
    # agent (see profiles/desktop.nix's header).
    #
    # THE BACKENDS ARE NOT OPTIONAL EXTRAS, they are what makes the front-end able to do anything.
    # engrampa is a dispatcher: `src/fr-command-*.c` is one module per format, each exec'ing a
    # command by bare name. The binary is NOT wrapped (raw ELF, no PATH injection), so on NixOS
    # every one of those commands has to be somewhere on the session's own PATH or the format is
    # simply missing from "Create Archive" and an archive of that type will not open. On a distro
    # with an ambient /usr/bin this never comes up; here it is the entire difference between a
    # working archive manager and a window that lists three formats.
    #
    # 7z and RAR are NOT listed below, even though engrampa dispatches to them the same way as
    # everything else here: `p7zip` (7z, and engrampa's ARJ path) and `unar` (engrampa's free
    # `unarchiver` backend for RAR, in preference to the unfree `unrar`) now come from nixsh
    # instead of from this role. nixsh is the universal shell layer — every host gets it, GUI or
    # headless, because every host has a shell — so a host that also carries this GUI archive
    # manager can rely on those two CLI backends already being on its PATH rather than this role
    # declaring a second copy of them. That is the correct layering: a GUI depends on CLI backends
    # existing, it does not own them. See nixsh for the packages themselves and the unar-vs-unrar /
    # p7zip-vs-_7zz reasoning that used to live here.
    #
    # No `unace`: not in nixpkgs at all. ACE is a dead format with one proprietary implementation;
    # the Arch table carries it because Arch still packages it, and this asymmetry is a fact about
    # the two package sets rather than a decision.
    fileManagerExtras = [
      pkgs.engrampa

      # Formats worth having, one package per fr-command backend that needs an external tool.
      # (The 7z and RAR backends, p7zip and unar, come from nixsh now — see the comment above.)
      pkgs.lhasa # lha/lzh
      pkgs.lrzip # lrzip
      pkgs.lzop # lzo
      pkgs.cpio # cpio, and half of rpm
      pkgs.rpm # rpm2cpio
      pkgs.dpkg # deb
      pkgs.brotli # brotli

      # tar/gzip/bzip2/xz/zstd/zip/unzip are NOT listed: they are in the default NixOS system
      # path already, and a second copy here would shadow the one the rest of the system uses.
    ];

    # DELIBERATELY EMPTY, and the emptiness is the content. nixpkgs builds ONE gvfs derivation with
    # samba, libnfs, libmtp and libgphoto2 all as ordinary buildInputs (`pkgs/by-name/gv/gvfs`:
    # libgphoto2 and libnfs unconditional, samba and libmtp under the `udevSupport` branch that
    # defaults true on Linux), so smb://, nfs://, mtp:// and gphoto2:// all arrive the moment
    # `services.gvfs.enable` is on and there is nothing left for this role to install. Arch splits
    # the same backends into separate `gvfs-smb`/`gvfs-nfs`/`gvfs-mtp`/`gvfs-gphoto2` packages that
    # each have to be asked for, which is the only reason the role exists. The key stays here,
    # rather than being left out to resolve to nothing by accident, so the asymmetry is visible to
    # the next reader instead of looking like an omission.
    gvfsBackends = [ ];

    # A wlroots session has no control centre, so the GTK/Qt appearance settings every toolkit
    # still reads have nothing writing them: nwg-look writes the GTK ones, qt6ct gives Qt a platform
    # theme, and adw-gtk3 is what makes GTK3 apps match the GTK4/libadwaita ones next to them
    # instead of looking a decade older.
    #
    # `pkgs.qt6Packages.qt6ct`, NOT `pkgs.qt6ct`: the top-level attribute still EXISTS but is a
    # throwing alias, so naming it fails evaluation outright with a rename message. Likewise the
    # theme attribute is `adw-gtk3` — there is no `adw-gtk-theme` in nixpkgs at all. Both confirmed
    # by evaluation. qt6ct is the same package the `polkit-kde-agent` entry above already carries
    # for its own reason; `lib.unique` in `packagesFor` makes choosing both free.
    theming = [ pkgs.nwg-look pkgs.adw-gtk3 pkgs.qt6Packages.qt6ct ];
  };

  # Not a capability (no `want.portals`-shaped boolean loop reaches this) — see the comment on
  # `capabilities` above for why. Same package choice as nixarch's table: niri hard-requires SOME
  # portal backend, gtk is the general-purpose fallback, gnome supplies the screencast portal gtk's
  # does not (what screen sharing actually needs on wlroots-adjacent stacks).
  portalPackages = [ pkgs.xdg-desktop-portal-gnome pkgs.xdg-desktop-portal-gtk ];

  # The compositor plus what its own default keybinds shell out to. niri's stock media and
  # brightness binds call these by name, so a compositor installed without them has keys that
  # silently do nothing.
  #
  # EXTENSIBLE, NOT CLOSED. niri is the only compositor with a nixpkgs package today; scroll (a
  # niri fork) has none, and future compositor-module repos won't necessarily either. Hardcoding
  # scroll's derivation here would mean this file — and a new release of this repo — has to be
  # edited every time a sibling compositor-module repo shows up, exactly the coupling the rest of
  # this project avoids for every other role. `extraCompositors` (this file's own function
  # argument, threaded in from `modules/nixos-backend.nix`'s identically-named option) is merged
  # in on top instead, so a consumer pairs this backend with, say, nixscroll by supplying
  # `{ scroll = [ nixscroll-flake.packages.${system}.scroll ]; }` — no edit to this file, no new
  # release of this repo needed. niri needs no such entry; it already resolves out of the box.
  compositors = { niri = [ pkgs.niri pkgs.brightnessctl pkgs.playerctl ]; } // extraCompositors;

  # ── Resolution ──────────────────────────────────────────────────────────────────────────────

  # Look a role value up in a table; fall through to `pkgs.${value}` as a top-level nixpkgs
  # attribute. The fallthrough exists for the same reason as nixarch's: nixdesktop's `fileManager`,
  # `launcher` and `terminal` are free-form strings precisely so a consumer is not gated on this
  # table being exhaustive (`launcher = "fuzzel"` and `terminal = "foot"`, this profile's own
  # defaults, both resolve this way — neither has a dedicated table above). Unlike the Arch
  # version, the fallthrough cannot just return the string: `environment.systemPackages` needs real
  # derivations, not names, so an unresolvable value is a hard eval error (`pkgs.${value}` throws
  # "attribute missing") rather than a silent no-op — a consumer who reaches for a role name that
  # isn't also a top-level nixpkgs attribute finds out at evaluation time, not at runtime with a
  # missing binary.
  resolve = table: value:
    if value == null then [ ]
    else if table ? ${value} then
      (if lib.isList table.${value} then table.${value} else table.${value}.packages)
    else [ pkgs.${value} ];

  # Packages for a resolved `nixdesktop.want`. An empty want (profile disabled) yields nothing.
  packagesFor = want:
    if want == { } then [ ] else
    lib.unique (
      resolve compositors (want.compositor or null)
      ++ resolve bars (want.bar or null)
      ++ resolve notificationDaemons (want.notifications or null)
      ++ resolve fileManagers (want.fileManager or null)
      ++ resolve polkitAgents (want.polkitAgent or null)
      ++ resolve keyrings (want.keyring or null)
      ++ resolve osds (want.osd or null)
      ++ lib.optionals (want.launcher or null != null) [ pkgs.${want.launcher} ]
      ++ lib.optionals (want.terminal or null != null) [ pkgs.${want.terminal} ]
      ++ lib.concatLists (lib.mapAttrsToList
        (name: pkgs': lib.optionals (want.${name} or false) pkgs')
        capabilities)
      ++ map (name: pkgs.${name}) (want.extraComponents or [ ])
    );
}
