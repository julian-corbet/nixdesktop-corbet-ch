# Evaluates modules/nixos-backend.nix + profiles/desktop.nix as a REAL NixOS system and proves the
# one thing about the file-manager role that a package list can never prove: that the role is wired
# through the actual NixOS options and not merely dropped into `environment.systemPackages`.
#
# WHY THIS CHECK EXISTS. On Arch, "the package is installed" and "the thing works" are the same
# statement, so a table of package names is a complete answer and nixarch's backend needs nothing
# else. On NixOS they come apart, and for this role they come apart almost completely:
# `pkgs.gvfs` in a package list leaves `GIO_EXTRA_MODULES` unset, so not one uri scheme resolves —
# no smb://, no mtp://, no sftp://, not even trash:// — and leaves `programs.fuse.enable` and
# `services.udisks2.enable` off, so nothing mounts at all, down to a plain USB stick.
# `pkgs.thunar` in a package list is the UNWRAPPED binary, whose `THUNARX_DIRS` is unset, so every
# thunarx plugin installed beside it is a `.so` nothing ever loads — and whose D-Bus activation
# files still name that plugin-less copy, so "open containing folder" from another application
# reaches it even when a wrapped one is also installed. Every one of those failures is silent. A
# config that looks configured and isn't is precisely what an eval check is for, and `nix flake
# check` on its own would only confirm that `nixosModules.backend` IS a module.
#
# WHY A REAL `nixpkgs.lib.nixosSystem` AND NOT `lib.evalModules` + A STUB, unlike most of this
# directory. Everything asserted below is produced by nixpkgs' OWN modules, downstream of the two
# booleans this backend sets: `programs.xfconf.enable` and the wrapped `pkgs.thunar.override` come
# from `programs/thunar.nix`, and `GIO_EXTRA_MODULES`/`programs.fuse.enable`/
# `services.udisks2.enable` from `services/desktops/gvfs.nix`. A stub declaring
# `programs.thunar`/`services.gvfs` as `attrsOf anything` would accept this backend's writes and
# prove nothing about what they cause — which is the entire claim. Same reasoning, and the same
# remedy, as checks/launcher.nix's own third and fourth layers.
#
# `support.hostStub` is deliberately NOT composed here: real NixOS declares `options.assertions`
# and `options.warnings` itself, and redeclaring either is an "option declared twice" error rather
# than a harmless no-op. `system.stateVersion` and `boot.isContainer` are set for hygiene (a
# fixture that would also survive a real `nixos-rebuild`), not because anything read below needs
# them — nothing here forces `config.system.build.toplevel`, so an unrelated upstream assertion
# can never turn this check red by surprise.
{ pkgs, nixpkgs, system, lib ? pkgs.lib }:
let
  support = import ./support.nix { inherit pkgs lib; };
  inherit (support) report;

  roles = import ../lib/nixos-roles.nix { inherit lib pkgs; };

  configFor = settings: (nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      ../profiles/desktop.nix
      ../modules/nixos-backend.nix
      {
        nixdesktop.nixosBackend.enable = true;
        system.stateVersion = "24.11";
        boot.isContainer = true;
      }
      settings
    ];
  }).config;

  # `compositor` has no default (see profiles/desktop.nix) and is mandatory the moment the profile
  # is enabled, so every enabled fixture carries it. Which compositor is irrelevant to this check.
  desktop = extra: { nixdesktop.desktop = { enable = true; compositor = "niri"; } // extra; };

  # ── FIXTURES ─────────────────────────────────────────────────────────────────────────────────
  full = configFor (desktop { fileManager = "thunar"; fileManagerExtras = true; theming = true; });
  plain = configFor (desktop { fileManager = "thunar"; });
  backends = configFor (desktop { fileManager = "thunar"; gvfsBackends = true; });
  nautilus = configFor (desktop { fileManager = "nautilus"; });
  noFileManager = configFor (desktop { fileManager = null; });

  # The profile off entirely: `nixdesktop.want` is `{}`, and the backend must emit NOTHING — the
  # contract modules/nixos-backend.nix has promised since it only had `environment.systemPackages`
  # to emit, now that it also writes four real options that would otherwise fire unconditionally.
  # `compositor` is still defined, since a consumer's config would still be carrying it.
  disabled = configFor { nixdesktop.desktop = { enable = false; compositor = "niri"; }; };

  packageNames = cfg: map (p: p.name or "") cfg.environment.systemPackages;
  countNamed = prefix: cfg:
    lib.length (lib.filter (n: lib.hasPrefix prefix n) (packageNames cfg));
  hasNamed = prefix: cfg: countNamed prefix cfg > 0;

  outPaths = drvs: map (d: d.outPath) drvs;

  results = {
    # ── THE REAL OPTIONS, NOT A PACKAGE LIST ──────────────────────────────────────────────────
    "thunar sets programs.thunar.enable, the only thing that builds the plugin wrapper" =
      full.programs.thunar.enable;

    "...which brings programs.xfconf.enable with it, without which Thunar persists no settings" =
      full.programs.xfconf.enable;

    "a selected file manager sets services.gvfs.enable" =
      full.services.gvfs.enable;

    # Membership in the colon-split search path, not equality against the whole of it: NixOS' own
    # `environment.sessionVariables` merges its `listOf str` definitions down to a single joined
    # string, and a second contributor to that variable is a legitimate config rather than a
    # regression. What must hold is that the gvfs actually enabled is one of the entries.
    #
    # Split-and-compare rather than `lib.hasInfix`, deliberately: `hasInfix` compiles its argument
    # into a regex, and a regex is not allowed to carry a store-path reference — passing an
    # interpolated `${package}` there fails evaluation outright with "not allowed to refer to a
    # store path", which looks like a failing assertion and is not one. `or ""` for the same
    # reason in the other direction: when the variable is not set at all — the exact regression
    # this line exists to catch — reading it would throw "attribute missing" and report nothing,
    # instead of this assertion failing under its own name.
    "...which is the only thing that sets GIO_EXTRA_MODULES, and it names the enabled gvfs itself" =
      lib.elem "${full.services.gvfs.package}/lib/gio/modules"
        (lib.splitString ":"
          (toString (full.environment.sessionVariables.GIO_EXTRA_MODULES or "")));

    "...and the mount floor rides along: without fuse + udisks2 not even a USB stick appears" =
      full.programs.fuse.enable && full.services.udisks2.enable;

    "thunar sets services.tumbler.enable, so files get thumbnails rather than generic icons" =
      full.services.tumbler.enable;

    # ── THE INSTALLED THUNAR IS THE WRAPPED ONE ───────────────────────────────────────────────
    "fileManagerExtras installs the plugin WRAPPER (thunar-with-plugins), never the bare binary" =
      countNamed "thunar-with-plugins" full == 1;

    "programs.thunar.plugins is exactly lib/nixos-roles.nix's exported thunarPlugins" =
      outPaths full.programs.thunar.plugins == outPaths roles.thunarPlugins;

    "...and no plugin leaks into environment.systemPackages, where nothing would ever load it" =
      !(hasNamed "thunar-archive-plugin" full)
      && !(hasNamed "thunar-media-tags-plugin" full)
      && !(hasNamed "thunar-vcs-plugin" full);

    "without fileManagerExtras there are no plugins at all" =
      plain.programs.thunar.plugins == [ ];

    "...so nixpkgs hands back the unwrapped thunar, and no wrapper is built for nothing" =
      countNamed "thunar-with-plugins" plain == 0;

    # ── NO DUPLICATE BUILDS OF THE THINGS THE REAL OPTIONS ALREADY INSTALL ────────────────────
    #
    # The gvfs one is the dangerous half: `services.gvfs.package` defaults to
    # `gvfs.override { gnomeSupport = true; }`, a different store path with the IDENTICAL
    # `gvfs-<version>` name, so a stray `pkgs.gvfs` in the package list puts two same-named builds
    # in the profile — one wins arbitrarily while GIO_EXTRA_MODULES keeps pointing at the other.
    "exactly one gvfs build in the system profile" =
      countNamed "gvfs-" full == 1;

    "no second, unwrapped thunar alongside the wrapper" =
      lib.length (lib.filter (n: n == pkgs.thunar-unwrapped.name) (packageNames full)) == 0;

    "no separate tumbler package on top of the one services.tumbler.enable installs" =
      countNamed "tumbler-" full == 1;

    # thunar-volman is the one thing that stays a package: it ships no `lib/thunarx-3/*.so`, so it
    # is not a thunarx plugin at all, and thunar spawns it by bare name through PATH.
    "thunar-volman stays a package on PATH, and is not passed off as a plugin" =
      hasNamed "thunar-volman" full
      && !(lib.any (p: lib.hasPrefix "thunar-volman" p.name) full.programs.thunar.plugins);

    # ── GATING BY WHICH FILE MANAGER, AND BY WHETHER THERE IS ONE ─────────────────────────────
    "another file manager still gets gvfs -- every one of them browses through it" =
      nautilus.services.gvfs.enable;

    "...but never thunar's own options" =
      !nautilus.programs.thunar.enable && !nautilus.services.tumbler.enable;

    "fileManager = null asks for no gvfs and no thumbnailer" =
      !noFileManager.services.gvfs.enable && !noFileManager.services.tumbler.enable;

    # ── gvfsBackends IS A DOCUMENTED NO-OP HERE, AND STAYS ONE ────────────────────────────────
    #
    # nixpkgs builds ONE gvfs with smb/nfs/mtp/gphoto2 compiled in, so the role is already
    # satisfied by services.gvfs.enable. Arch splits them into separate packages, which is why the
    # boolean exists at all. Asserted rather than merely commented, because "adds nothing" is a
    # claim a future edit could quietly break in either direction.
    "gvfsBackends changes not one package on NixOS -- the backends are already in the one gvfs" =
      packageNames backends == packageNames plain;

    "...and does not accidentally gate gvfs itself" =
      backends.services.gvfs.enable;

    # ── theming ───────────────────────────────────────────────────────────────────────────────
    "theming installs the GTK settings writer and the GTK3 theme" =
      hasNamed "nwg-look" full && hasNamed "adw-gtk3" full;

    # Identity, not merely presence: `pkgs.qt6ct` still EXISTS as a top-level attribute but is a
    # throwing alias, so this proves the table names the real `qt6Packages.qt6ct`.
    "...and the Qt platform theme is the real qt6Packages.qt6ct, not the throwing top-level alias" =
      lib.any (p: p.outPath == pkgs.qt6Packages.qt6ct.outPath) full.environment.systemPackages;

    "theming off installs none of it" =
      !(hasNamed "nwg-look" plain) && !(hasNamed "adw-gtk3" plain);

    # A package a nothing points at configures nothing -- see modules/nixos-backend.nix's own
    # comment on this line. Qt only loads the platform theme QT_QPA_PLATFORMTHEME names.
    "theming sets QT_QPA_PLATFORMTHEME to the role it just installed, not merely the package" =
      full.environment.sessionVariables.QT_QPA_PLATFORMTHEME or null == "qt6ct";

    "theming off sets no platform theme -- nothing installed for it to name" =
      !(plain.environment.sessionVariables ? QT_QPA_PLATFORMTHEME);

    # ── fileManagerExtras' archiver ───────────────────────────────────────────────────────────
    #
    # The archive plugin dispatches to an archive manager through a `.tap` wrapper script it looks
    # up under its OWN store path, and filters out every candidate for which no such script exists
    # — so the archiver has to be one the plugin itself ships a tap for, or the context-menu
    # entries end in "No suitable archive manager found". See lib/nixos-roles.nix's own comment.
    "fileManagerExtras installs an archive manager for the archive plugin to dispatch to" =
      hasNamed "engrampa" full;

    "...and not when the role is off, where the plugin that needs it is absent too" =
      !(hasNamed "engrampa" plain);

    # ── THE WHOLE THING IS A NO-OP WITH THE PROFILE DISABLED ──────────────────────────────────
    "a disabled profile publishes an empty want" =
      disabled.nixdesktop.want == { };

    "...so none of the five real options this backend writes are turned on" =
      !disabled.programs.thunar.enable
      && !disabled.services.gvfs.enable
      && !disabled.services.tumbler.enable
      && !disabled.xdg.portal.enable
      && !(disabled.environment.sessionVariables ? QT_QPA_PLATFORMTHEME);

    "...and not one file-manager package is installed either" =
      !(hasNamed "thunar" disabled)
      && !(hasNamed "gvfs" disabled)
      && !(hasNamed "engrampa" disabled)
      && !(hasNamed "nwg-look" disabled);
  };
in
report "file-manager" results
