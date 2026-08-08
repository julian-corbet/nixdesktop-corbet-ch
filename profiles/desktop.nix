# profiles/desktop.nix — the POLICY layer of a desktop session: which roles the session wants
# filled, and by which implementation. Compositor-neutral: the compositor itself is just another
# role (`compositor`, a free-form string), resolved by a platform backend exactly like every
# other role here. This module installs nothing and names no package.
#
# WHY NO PACKAGES HERE. Package names are platform-specific (`pcmanfm-gtk3` on Arch,
# `pkgs.pcmanfm` in nixpkgs) and so are binary paths (mate-polkit's agent lives somewhere
# different on every distro). Worse, on NixOS some roles are not a package at all: gvfs and Thunar
# only work through real NixOS options, so what a role RESOLVES TO differs in kind, not just in
# spelling. A profile that emits package names is a profile that only works on one distro. So this
# module emits ROLES — a read-only `nixdesktop.want` attrset — and a platform backend resolves
# them. nixarch ships the Arch/CachyOS backend; this repo's own `modules/nixos-backend.nix` is
# the NixOS one.
#
# THE DEFAULTS ARE NOT TASTE. Every default below is the CPU-rendered option in its category,
# because that is this project's one hard constraint (see studies/rendering-cost.md): a Wayland
# desktop component that opens a DRM fd and drives a GPU scene graph (GTK4/GSK, Qt Quick/QML)
# costs real, permanent VRAM for work a CPU-side toolkit does for free. Measured, not assumed —
# an effects-capable compositor plus a QML shell cost ~860-930MB VRAM mastering a display, versus
# ~83-131MB for niri plus a GTK3 bar doing the identical job. On a machine whose GPU memory is
# shared with real work (an iGPU carving out of system RAM, or a discrete card also serving
# compute), that difference is the whole budget. This constraint does not pick a compositor for
# you (see `compositor` below) — it only shapes the defaults for the roles *around* whichever one
# you choose.
#
# Consequences worth naming, since they cut against the obvious pick in two cases:
#   - fileManager defaults to thunar, not nautilus. Nautilus is GTK4; Thunar is GTK3+Cairo.
#   - polkitAgent defaults to mate-polkit, not polkit-kde-agent. niri's own wiki suggests the
#     latter, but it is Qt6+QML and drags a KDE Frameworks stack onto an otherwise-GTK box.
#     mate-polkit is GTK3 and confirmed to work standalone outside its parent DE.
# Both are plain options. A consumer who wants the heavier component sets it and moves on.
{ lib, config, ... }:
let
  cfg = config.nixdesktop.desktop;
in
{
  options.nixdesktop.desktop = {
    enable = lib.mkEnableOption
      "desktop policy (declare the roles a session needs, for whichever compositor `compositor` names; a platform backend installs them)";

    compositor = lib.mkOption {
      type = lib.types.str;
      example = "niri";
      description = ''
        Which compositor this session runs — `"niri"`, `"scroll"`, or any future name a sibling
        compositor-module repo (nixniri, nixscroll, ...) introduces. Free-form rather than a
        closed enum, deliberately: a new compositor must become usable by naming it here and
        supplying it a package (`lib/nixos-roles.nix`'s `compositors` table on the NixOS side,
        extensible via `modules/nixos-backend.nix`'s `extraCompositors` option for anything not
        already in nixpkgs), never by editing this repo. No default — nixdesktop draws no
        distinction between compositors and has no reason to prefer one, so the consumer must
        say which one they mean.
      '';
    };

    bar = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [ "waybar" "eww" "noctalia" ]);
      default = "waybar";
      description = ''
        Status bar, or null for none. `waybar` is GTK3/Cairo (CPU-only, has a real SNI tray).
        `eww` is GTK3 too but ships no bar — you build one from primitives. `noctalia` is a full
        QML shell: far more capable, and measurably more expensive in VRAM.
      '';
    };

    notifications = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [ "mako" ]);
      default = "mako";
      description = ''
        Notification daemon, or null when something else owns
        `org.freedesktop.Notifications` (a full shell like noctalia does). Deliberately
        independent of `bar`: the two are unrelated jobs, and a daemon left installed can still
        win the D-Bus race via its own service-activation file even if it is never spawned — so
        to hand notifications to another component this must actually be null, not merely
        unspawned.
      '';
    };

    fileManager = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "thunar";
      description = ''
        File manager role, or null for none. Free-form rather than an enum: the backend maps the
        name, and there is no reason to gatekeep which one a consumer wants. See the header for
        why the default is Thunar (GTK3) rather than Nautilus (GTK4).
      '';
    };

    polkitAgent = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [ "mate-polkit" "polkit-kde-agent" "lxqt-policykit" ]);
      default = "mate-polkit";
      description = ''
        Polkit authentication agent, or null for none. Without one, any privileged GUI prompt
        (udisks, NetworkManager, a GUI sudo) fails **silently** — there is no error, the dialog
        simply never appears, which is a genuinely hard failure to diagnose. Many Wayland
        compositors (niri among them) do not process XDG autostart, so the agent needs an
        explicit spawn — that is the job of whichever compositor module you pair this profile
        with (nixniri's own polkit wiring, for instance), not this profile's; the backend
        supplies the platform's binary path for the role declared here.

        Known trap, not a bug in any agent: polkit refuses to register an agent from a session
        with no logind seat. A compositor started as a bare systemd `--user` unit has none, and
        every agent then fails identically ("Failed to register client" / "Cannot determine user
        of subject"). Fix the session's seat, not the agent.
      '';
    };

    keyring = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [ "gnome-keyring" "kwallet" "oo7" ]);
      default = "gnome-keyring";
      description = ''
        Secret-service provider (`org.freedesktop.secrets`), or null for none. Only one may run:
        two providers racing for the same D-Bus name is a real and confusing failure mode.
        `kwallet` works without a Plasma session but needs its own explicit spawn wiring.

        `oo7` is the modern path (this repo's own `home/session.nix`'s `nixdesktop.session.
        keyring.oo7` option group has the full account, including the credential-based unlock
        that makes it viable under autologin) — NOT the default here, deliberately: this option
        only decides which package(s) `nixdesktop.nixosBackend` installs, a decision this generic
        library repo has no fleet-specific opinion about, unlike a specific host's own config.
        Picking `oo7` here does not by itself run anything — pair it with `nixdesktop.session.
        keyring.oo7.enable = true;` in your own home-manager configuration, the same manual
        wiring every other role here already asks for (see `keyring`'s sibling roles above).
      '';
    };

    launcher = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "fuzzel";
      description = "Application launcher role, or null for none. fuzzel is pixman/cairo (CPU-only).";
    };

    terminal = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "foot";
      description = ''
        Terminal role, or null for none. Must be set to something the backend can install: a
        compositor module typically binds a terminal by name regardless of whether this role is
        filled, so leaving this null while that keybind stays produces a bind that spawns a
        binary that isn't there.
      '';
    };

    osd = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [ "swayosd" ]);
      default = null;
      description = ''
        On-screen display for volume/brightness/caps-lock, or null. Null is not a broken desktop:
        the media and brightness keys still act via the compositor's own binds, they just do so
        without visual feedback.
      '';
    };

    input = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [ "keyd" ]);
      default = null;
      description = ''
        Keyboard remapping daemon, or null for none — the INPUT SUBSTRATE, which sits BELOW the
        compositor rather than inside it. That placement is the whole reason this is a role of its
        own instead of a compositor keybind: a daemon of this class rewrites events at the
        evdev/uinput layer, so its mappings are in force in a TTY, in the display manager, in
        every compositor and in an X11 session alike, and they survive a compositor restart. A
        compositor's own keybinds can do none of that — they exist only while that compositor is
        running and only for the windows it owns.

        `keyd` is the one implementation this table knows. It reads `/etc/keyd/*.conf` and runs as
        a system daemon.

        THIS ROLE INSTALLS AND ENABLES; IT DOES NOT CONFIGURE. nixdesktop has no opinion about
        which key should become which — that is exactly the kind of personal decision a shared
        policy layer should stay out of, the same stance `theming` takes for appearance. A
        remapping daemon with no config file remaps nothing and costs nothing; writing
        `/etc/keyd/default.conf` is the consumer's own job.

        NOT SYMMETRIC ACROSS PLATFORMS, and both backends say so in their own tables. On Arch the
        package ships the daemon, its systemd unit and its udev rules into the one shared prefix,
        so installing it is most of the work. On NixOS the package alone gives you only the client
        binaries (`keyd monitor`, `keyd reload`) — the daemon, the `keyd` group and `/etc/keyd`
        all come from `services.keyd.enable`, which the NixOS backend wires for you when this role
        is filled, exactly as it already does for `services.gvfs.enable` behind `fileManager`.
      '';
    };

    screenshots = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Install a region-capture toolchain (grim/slurp class). Some compositors (niri among them) have a built-in screenshot bind that does not strictly need these, but most region workflows do.";
    };

    xwayland = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        X11 application support (xwayland-satellite class). Some compositors (niri among them)
        probe for it at startup and silently disable X11 integration if absent — they warn
        rather than failing, so a missing binary shows up much later as "X11 apps don't start"
        with no obvious cause.
      '';
    };

    clipboardHistory = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Clipboard history tooling (cliphist/wl-clipboard class), paired with a compositor module's own clipboard binds (e.g. nixniri's `niri.clipboardHistory`).";
    };

    idleAndLock = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Idle daemon + screen locker (swayidle/swaylock class). This role installs them; `nixdesktop.session.idleAndLock` sets the timeouts and assembles the invocation, and a compositor module reads `lockCommand` from there for its own lock keybind.";
    };

    portals = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Install desktop portal backends. Most Wayland compositors (niri among them) declare a
        hard dependency on *some* portal implementation, so this is close to mandatory: screen
        sharing, file choosers and "open with" all route through it.
      '';
    };

    fileManagerExtras = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Taste-level file-manager add-ons on top of whatever `fileManager` names: archive
        integration ("Create Archive" / "Extract Here" in the context menu, plus an archive
        manager for it to hand the work to), media-tag editing, and VCS status decorations.
        Default false — none of it is needed for a file manager to work, which is the line
        `fileManager` itself covers.

        NOT SYMMETRIC ACROSS PLATFORMS, and worth knowing before you read a backend. On Arch a
        file-manager plugin is an ordinary package: it drops a `.so` into a shared directory the
        installed file manager already reads. On NixOS there is no shared directory — a Thunar
        plugin is only ever loaded through a wrapper built around the plugin set, so the NixOS
        backend feeds these to `programs.thunar.plugins` and a plugin placed in
        `environment.systemPackages` instead would install a file nothing reads. Which archiver
        satisfies the archive plugin also differs by platform for the same reason; the backend
        picks one that actually resolves rather than the most obvious name.
      '';
    };

    gvfsBackends = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Network and device backends for the virtual filesystem layer `fileManager` browses
        through: SMB/CIFS shares, NFS, MTP phones, PTP cameras. Without them the local disk still
        works and every remote or device uri simply fails to resolve.

        NOT SYMMETRIC ACROSS PLATFORMS. Arch splits these into separate packages
        (`gvfs-smb`, `gvfs-nfs`, `gvfs-mtp`, `gvfs-gphoto2`) that each have to be asked for, which
        is the reason this role exists at all. nixpkgs builds one gvfs with all of them compiled
        in, so on NixOS they arrive with the file manager itself and setting this changes nothing
        — it is a no-op there, deliberately, not an unimplemented option. Set it if you want the
        capability stated in your config regardless of which platform it lands on.
      '';
    };

    theming = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        GTK/Qt appearance tooling: something to write the GTK settings with, a GTK3 theme that
        matches the GTK4/libadwaita look, and a Qt platform-theme configurator. A bare Wayland
        session has no control centre, so nothing writes those settings otherwise and mixed-toolkit
        applications end up visibly mismatched — a Qt dialog rendering unstyled next to GTK ones is
        the usual first symptom.

        Off by default because appearance is the one thing a consumer most likely wants to own
        outright (a home-manager `gtk`/`qt` block, a dotfiles repo), and a role that installs a
        theme is a role that fights with that.

        Available on both platforms, unlike the two roles above — the asymmetry here is only in the
        package names, which is exactly what a backend is for.

        It installs the TOOLS, not the assets they choose between: an icon set is `iconThemes`
        below, and this profile names none of either.
      '';
    };

    iconThemes = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "papirus-icon-theme" ];
      description = ''
        Icon theme packages to install, as backend-resolved names.

        INSTALLING IS NOT SELECTING, and this option deliberately does only the first. Which theme
        a session actually uses is `gtk-icon-theme-name` (and its Qt and cursor counterparts) —
        written by `theming`'s configurator, by a home-manager `gtk` block, or by a dotfiles repo,
        all of which are consumer-owned. What none of them can do is conjure a theme that is not
        on disk: `theming` above installs the picker and exactly one asset (a GTK3 widget theme,
        for a reason of its own), so a desktop that turns it on gets a chooser with nothing
        distinctive to choose. This is the option that puts something in it.

        A LIST, NOT A NAMED CHOICE, unlike `fileManager`/`polkitAgent`/`keyring`. Those roles are
        genuinely exclusive — one file manager runs. Icon themes are not: they coexist on disk,
        applications fall through a theme's `Inherits` chain to others, and a host reasonably keeps
        several installed and selects between them at will. Modelling this as a single value would
        be claiming a selection this option does not make.

        FREE-FORM NAMES, resolved by the platform backend exactly like `extraComponents`,
        `launcher` and `terminal` — so portability is the consumer's problem for these, and
        deliberately so. This profile names no theme itself: an icon set is taste, and it is also
        the kind of asset a distribution ships under a name nobody else uses.

        Empty by default. A desktop that inherits whatever its distribution installed, or that
        owns its appearance entirely from home-manager, sets nothing here.
      '';
    };

    syntheticTyping = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Install a tool that types into the focused window as if from a keyboard — the Wayland
        equivalent of `xdotool type`.

        WHAT IT IS FOR: everything that has to put text somewhere it cannot paste. A password
        manager filling a native login form, an expander turning an abbreviation into a
        boilerplate block, a script driving an application that has no scripting interface of its
        own. Pasting is not a substitute — many such targets refuse clipboard input outright, and
        anything that goes through the clipboard leaves a secret sitting in it afterwards, which
        is precisely what a password manager is trying not to do.

        NOT THE SAME THING AS `input` ABOVE, and the two are worth keeping straight because both
        are about keys. That role is a REMAPPING DAEMON below the compositor: it rewrites events
        at the evdev/uinput layer, before any Wayland client sees them, which is what makes its
        mappings hold in a TTY and across a compositor restart. This is a compositor CLIENT that
        synthesizes new events through `virtual-keyboard-v1`, so it exists only inside a running
        Wayland session and only where the compositor implements that protocol. They are also not
        alternatives to one another — a host can want both, or either, which is why this is a
        boolean capability rather than another entry in that role's enum.

        A COMPOSITOR PERMISSION QUESTION, WHICH THIS ROLE DOES NOT ANSWER. `virtual-keyboard-v1`
        lets any client that can reach it inject keystrokes into any other; some compositors gate
        that, some do not. Installing the tool is the whole of what this option does — whether the
        session's compositor exposes the protocol, and to whom, belongs to that compositor's own
        configuration.

        Off by default: nothing else in this profile needs it, and a desktop that never automates
        input should not carry a keystroke injector.
      '';
    };

    browsers = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Web browsers: Firefox and Chromium, both together — not a single named choice the way
        `fileManager`/`polkitAgent`/`keyring` above are. A browser role with one implementation
        would force a pick nixdesktop has no basis for; a working desktop routinely wants both at
        once (Chromium for its devtools/PWA-install path, Firefox as the daily driver), and
        neither substitutes for the other the way any two file managers do. So this is a flat
        boolean over a fixed pair, matching `fileManagerExtras`/`gvfsBackends`/`theming` above
        rather than the single-choice roles.

        Off by default, for the same reason those three are: nothing else in this profile needs a
        browser to function, and a large, opinionated pair of packages should be asked for rather
        than inherited by every consumer of this profile.

        Available on both platforms under the same two names — Arch's official repos and nixpkgs
        both carry `firefox` and `chromium` outright, so unlike `gvfsBackends` there is no
        per-platform asymmetry here for a consumer to know about.
      '';
    };

    appIndicators = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        The tray-icon substrate: BOTH application-indicator libraries, the legacy one and its
        maintained fork, together.

        WHY BOTH, WHICH LOOKS LIKE AN OVERSIGHT AND IS NOT. They are not two builds of one thing
        and they are not interchangeable — they ship DIFFERENT SONAMES
        (`libappindicator3.so.1` versus `libayatana-appindicator3.so.1`). A program built or
        `dlopen`ing against one simply does not find the other; there is no compatibility symlink
        and no fallback in the loader. The ecosystem never finished migrating, so a desktop that
        installs only the fork silently has no tray for whichever half of its applications still
        reach for the original name. Installing one and calling the other legacy is the mistake
        this role exists to prevent.

        A SUBSTRATE, NOT AN APPLICATION, which is why it is a role at all. Nothing here is
        something a user runs. These are libraries that a bar's status-notifier host and the
        applications feeding it both need to be present for a tray icon to appear — the same
        shape as the `input` role above, one layer over: infrastructure below the visible
        components, whose absence shows up as a feature quietly missing rather than an error.

        WHY ITS CONSUMERS ARE INVISIBLE TO A PACKAGE MANAGER, worth stating because it changes how
        you check. These libraries are `dlopen`ed at runtime, not linked, so a distribution's
        reverse-dependency query reports no dependents at all and reads exactly like "nothing uses
        this". Inspecting a process map is no better unless a tray application happens to be
        running at that moment. Scanning installed binaries for the soname is what actually
        settles it — and on a real host it finds real consumers: a major cross-platform game/media
        library references the legacy name for its tray support, and so does a widely used desktop
        application framework's build tool. Both, in fact, reference BOTH names, which is the
        clearest possible statement that the split is live.

        Off by default, and a boolean over a fixed pair rather than a named choice, matching
        `browsers` above: "pick one" is precisely the wrong interface here.
      '';
    };

    duplicateFinder = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        A graphical duplicate/waste finder — the tool you point at a directory when a disk is
        full and you want to know what is redundant rather than merely large. czkawka is the
        implementation both backends resolve.

        A DESKTOP APPLICATION, DELIBERATELY, AND THE SHAPE IS THE POINT. Everything this class of
        tool does is destructive on confirmation, and the only thing that makes that safe is a
        human choosing the scope each time it runs. Run as a locally-launched GUI it can only see
        what the person at the keyboard hands it. Run as a always-on service with standing access
        to a whole data set — mounted writable, wakeable by anything that can reach it — the same
        program becomes a remote deletion capability over files nobody was looking at. Same
        binary, opposite blast radius. This role exists to declare the first shape.

        Boolean over a single implementation rather than a named choice, matching `browsers`
        above rather than `fileManager`/`polkitAgent`: there is no second implementation worth
        offering here, so a `nullOr (enum [...])` would be a choice with one option pretending to
        be a policy. Off by default, for `browsers`' reason too — nothing else in this profile
        needs it, and a large application should be asked for rather than inherited.

        THE CLI IS NOT PART OF THIS ROLE. The project also ships a headless variant; a
        terminal-first tool fails this repo's own subject test and belongs to whichever repo owns
        the terminal, not here. Both backends resolve the GUI only.

        NOT SYMMETRIC IN PACKAGING, though it is in behaviour. On NixOS one attribute provides
        the GUI. On Arch the GUI has its own package name, which upstream ships only through the
        AUR while at least one derivative carries a prebuilt one in its own repository — so the
        Arch backend routes it through its AUR/repo split rather than naming it flatly. A
        consumer sees none of that, which is what the backend indirection is for.
      '';
    };

    extraComponents = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Escape hatch: additional role names passed through to the backend verbatim. Use for
        things this profile has no opinion about (a bluetooth applet, an audio mixer). Names are
        resolved by the backend, so portability is the consumer's problem for these.
      '';
    };
  };

  # NO `default` here, and the definition below is unconditional. `readOnly` permits exactly one
  # definition, and a default combined with a `mkIf`-guarded definition counts as two — the
  # profile fails to evaluate the moment it is enabled. So the empty-when-disabled case is
  # expressed in the value, not by withholding the definition.
  options.nixdesktop.want = lib.mkOption {
    type = lib.types.attrs;
    readOnly = true;
    description = ''
      READ-ONLY, computed. The resolved role set a platform backend consumes to produce real
      packages, including `compositor` itself (see that option above) — a backend never
      hardcodes which compositor it's installing for. This is the entire contract between
      nixdesktop and a backend — a backend that reads only this attrset needs no other knowledge
      of this profile, and this profile needs none of the backend's package naming.
    '';
  };

  config.nixdesktop.want = lib.optionalAttrs cfg.enable {
    inherit (cfg)
      compositor
      bar
      notifications
      fileManager
      polkitAgent
      keyring
      launcher
      terminal
      osd
      input
      screenshots
      xwayland
      clipboardHistory
      idleAndLock
      portals
      fileManagerExtras
      gvfsBackends
      theming
      iconThemes
      syntheticTyping
      browsers
      appIndicators
      duplicateFinder
      extraComponents
      ;
  };
}
