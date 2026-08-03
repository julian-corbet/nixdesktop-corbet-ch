# home/thunar.nix — declarative Thunar custom actions (~/.config/Thunar/uca.xml), sibling to the
# other home/*.nix modules in this repo. Installs nothing: Thunar itself comes from the
# `fileManager` role, through whichever platform backend a consumer paired with this repo.
#
# ONE THUNAR SURFACE IS DECLARABLE, AND IT IS THIS ONE. Thunar keeps its state in two places, and
# only one of them is a file anything but Thunar may write:
#
#   ~/.config/xfce4/xfconf/xfce-perchannel-xml/thunar.xml — NOT declarable, do not try. It is an
#   xfconf channel, and xfconfd holds the whole channel in memory: it reads the file once, on
#   first access, and thereafter REWRITES it in full from its cache a few seconds after any
#   property changes. There is no inotify watch and no reload path. Verified end to end on a
#   private session bus: write a property, wait for the flush, edit the resulting file externally,
#   and xfconfd still reports the value it cached — then the next property change writes the whole
#   file back out and the external edit is gone. A Nix-rendered thunar.xml is therefore reverted
#   silently, and because home-manager materialises it as a symlink into the store, the daemon's
#   atomic rename replaces that symlink with a regular file on the way — so the config is not only
#   ignored, it is detached, and stays detached until the next switch trips over it.
#
#   ~/.config/Thunar/uca.xml — declarable, and the subject of this module. It is a plain XML file
#   the thunar-uca plugin reads directly, not an xfconf channel (`xfconf-query -l` lists `thunar`,
#   never `uca`). Verified by strace against a real Thunar: one `openat(... "Thunar/uca.xml",
#   O_RDONLY)` when the first window is built, through a symlink, to a read-only file, with no
#   write of any kind and the symlink still intact afterwards.
#
# EVERY ACTION MUST CARRY A `<unique-id>`, WHICH IS WHY `id` HAS A DEFAULT AND NO WAY TO BE EMPTY.
# This is the one detail that decides whether a declarative uca.xml survives at all. If any action
# in the file lacks a unique-id, Thunar generates ids for the whole file and immediately saves it:
# it writes `uca.xml.XXXXXX` beside the target and `rename()`s over the path. Verified by strace —
# the rename lands on the path, not on the symlink's target, so home-manager's symlink is replaced
# by a regular file the moment the first Thunar window opens, and the declarative config is
# detached from the store on a fresh login with nothing logged anywhere. With ids present, the
# same trace shows the read and nothing else. Ids are derived from the attribute name so they are
# stable across evaluations: an id that changed per build would rewrite the file's identity on
# every switch, which is what Thunar's toolbar item ordering keys on.
#
# THIS FILE IS DECLARATIVELY OWNED, WHICH MEANS THUNAR'S OWN EDITOR IS NOT. Edit ▸ Configure custom
# actions… writes uca.xml by exactly the mechanism above, so changes made there are lost at the
# next `home-manager switch` (and until then they have replaced the symlink). Custom actions are
# now a value in a config repo; the dialog is a viewer.
#
# ACTIONS ARE READ ONCE PER THUNAR PROCESS. The plugin loads the model when the first window is
# built and keeps it; there is no file monitor. A `home-manager switch` therefore does not reach a
# Thunar that is already running — quit it (`thunar -q`) to pick the new actions up.
#
# AN ACTION WITH NO FILE TYPES CAN NEVER APPEAR. Thunar matches an action against a selection by
# intersecting bitflags, so an action whose type set is empty matches nothing at all — it is not a
# broken menu entry, it is an invisible one, which is far harder to notice. Hence the assertion:
# `fileTypes` may be narrowed to any subset, but never emptied.
{ lib, config, ... }:
let
  cfg = config.nixdesktop.thunar;

  # The six type-flag elements Thunar's parser accepts inside <action>, spelled exactly as they
  # appear in the XML so there is no translation table between this option and the file it writes.
  allFileTypes = [
    "directories"
    "audio-files"
    "image-files"
    "other-files"
    "text-files"
    "video-files"
  ];

  actionType = lib.types.submodule ({ name, ... }: {
    options = {
      name = lib.mkOption {
        type = lib.types.str;
        example = "Open Terminal Here";
        description = ''
          The label shown in the context menu. Mandatory, and deliberately not defaulted to the
          attribute name: an attribute name is a slug, and a slug in a context menu is a bug
          nobody would think to look for in a config file.
        '';
      };

      command = lib.mkOption {
        type = lib.types.str;
        example = "exo-open --working-directory %f --launch TerminalEmulator";
        description = ''
          The command to run. Split with shell-style argv parsing and executed directly — there is
          no shell, so pipes, redirections and `$VAR` expansion do not work; wrap those in
          `sh -c '...'` explicitly.

          Substituted before the split: `%f`/`%F` (path of the first selected file / all of them),
          `%u`/`%U` (the same as URIs), and Thunar's own `%d`/`%D` (directory containing the first
          file / all of them) and `%n`/`%N` (basename of the first file / all of them). Each
          expansion is quoted for you. A literal percent is `%%`.
        '';
      };

      id = lib.mkOption {
        type = lib.types.str;
        default = "nixdesktop-${name}";
        defaultText = lib.literalMD "`nixdesktop-` followed by the attribute name";
        description = ''
          The action's `<unique-id>`. Opaque to Thunar — any stable string will do — but it must
          exist and it must not change between switches; see this file's header for what Thunar
          does to a file whose actions have no ids, and why that costs the consumer their symlink.
          Override it only to adopt an id Thunar itself generated earlier.
        '';
      };

      description = lib.mkOption {
        type = lib.types.str;
        default = "";
        example = "Open a terminal in this directory";
        description = "Tooltip shown for the action in the context menu.";
      };

      icon = lib.mkOption {
        type = lib.types.str;
        default = "";
        example = "utilities-terminal";
        description = ''
          Icon name (an icon-theme name, or an absolute path). Empty for no icon.
        '';
      };

      patterns = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "*" ];
        example = [ "*.tar.gz" "*.tar.bz2" "*.zip" ];
        description = ''
          Glob patterns the selected file names must match for the action to appear. Joined with
          `;` — the separator Thunar splits on — so no pattern may contain one.
        '';
      };

      fileTypes = lib.mkOption {
        type = lib.types.listOf (lib.types.enum allFileTypes);
        default = allFileTypes;
        example = [ "directories" ];
        description = ''
          Which kinds of selection the action appears for. Defaults to all of them, i.e. any
          selection whose names also match `patterns`. Narrow it freely; emptying it is an
          assertion failure, because Thunar can then never show the action at all.
        '';
      };

      startupNotify = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Emit `<startup-notify/>`, so the desktop shows launch feedback (a busy cursor) while the
          command starts. Correct for anything that opens a window, wrong for a command that exits
          without opening one — the feedback then hangs until it times out.
        '';
      };

      range = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "2-";
        description = ''
          How many files may be selected for the action to appear, as Thunar's `<range>`:
          `"1"` for exactly one, `"2-"` for two or more, `"1-3"` for a bounded range. Null for no
          restriction.
        '';
      };

      submenu = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "Archive";
        description = ''
          Name of a submenu to file the action under, or null to place it in the context menu
          directly. Actions sharing a submenu name are grouped together.
        '';
      };
    };
  });

  flagElement = type: "\t<${type}/>";

  renderAction = action:
    let
      # Thunar's own element order when IT writes this file, kept deliberately: a diff between a
      # generated uca.xml and one Thunar has rewritten is then about content, never about layout.
      lines =
        lib.optional (action.icon != "") "\t<icon>${lib.escapeXML action.icon}</icon>"
        ++ [ "\t<name>${lib.escapeXML action.name}</name>" ]
        ++ lib.optional (action.submenu != null) "\t<submenu>${lib.escapeXML action.submenu}</submenu>"
        ++ [
          "\t<unique-id>${lib.escapeXML action.id}</unique-id>"
          "\t<command>${lib.escapeXML action.command}</command>"
        ]
        ++ lib.optional (action.description != "") "\t<description>${lib.escapeXML action.description}</description>"
        ++ lib.optional (action.range != null) "\t<range>${lib.escapeXML action.range}</range>"
        ++ [ "\t<patterns>${lib.escapeXML (lib.concatStringsSep ";" action.patterns)}</patterns>" ]
        ++ lib.optional action.startupNotify "\t<startup-notify/>"
        # Emitted in the module's own canonical order rather than the consumer's list order, so
        # that reordering a list never rewrites the file.
        ++ map flagElement (lib.filter (t: lib.elem t action.fileTypes) allFileTypes);
    in
    lib.concatStringsSep "\n" ([ "<action>" ] ++ lines ++ [ "</action>" ]);

  # Sorted by attribute name, not by definition order: `attrValues` is already sorted, and a stable
  # order is what keeps the rendered file (and therefore the store path, and therefore the switch)
  # from changing when a consumer merely rearranges their own attribute set.
  actions = lib.attrValues cfg.customActions;

  emptyTypeActions = lib.attrNames (lib.filterAttrs (_: a: a.fileTypes == [ ]) cfg.customActions);

  ids = map (a: a.id) actions;
  duplicateIds = lib.unique (lib.filter (id: lib.count (i: i == id) ids > 1) ids);

  ucaXml = lib.concatStringsSep "\n"
    (
      [
        ''<?xml version="1.0" encoding="UTF-8"?>''
        "<!-- Generated by nixdesktop (home/thunar.nix). Thunar's own custom-action editor writes"
        "     this file too; anything it writes here is replaced on the next switch. -->"
        "<actions>"
      ]
      ++ map renderAction actions
      ++ [ "</actions>" ]
    ) + "\n";
in
{
  options.nixdesktop.thunar = {
    enable = lib.mkEnableOption "declarative Thunar custom actions (~/.config/Thunar/uca.xml)";

    customActions = lib.mkOption {
      type = lib.types.attrsOf actionType;
      default = {
        # Byte-for-byte the action Thunar installs in its own system-wide uca.xml, description
        # included — the point of this default is parity with stock, so its wording is Thunar's
        # rather than something better that would make the claim untrue.
        open-terminal-here = {
          name = "Open Terminal Here";
          description = "Example for a custom action";
          icon = "utilities-terminal";
          command = "exo-open --working-directory %f --launch TerminalEmulator";
          fileTypes = [ "directories" ];
          startupNotify = true;
        };
      };
      defaultText = lib.literalMD "the single `Open Terminal Here` action Thunar itself ships";
      example = lib.literalExpression ''
        {
          open-terminal-here = {
            name = "Open Terminal Here";
            icon = "utilities-terminal";
            command = "foot --working-directory %f";
            fileTypes = [ "directories" ];
            startupNotify = true;
          };

          extract-here = {
            name = "Extract Here";
            icon = "package-x-generic";
            command = "xarchiver --extract-to %d %f";
            patterns = [ "*.tar" "*.tar.gz" "*.tar.xz" "*.zip" "*.7z" ];
            fileTypes = [ "other-files" ];
          };
        }
      '';
      description = ''
        The custom actions to write, keyed by a slug that also seeds each action's `<unique-id>`.

        This attribute set is the WHOLE file, in both directions. It replaces whatever uca.xml
        held, including anything added through Thunar's own editor — and it replaces the default
        below outright rather than merging with it, so an action stated here must be stated in
        full. Naming one action's `command` and expecting the rest of the default to survive is an
        evaluation error (the action's mandatory `name` is then simply undefined), which is the
        loud version of a failure that would otherwise be a menu quietly missing entries.

        That default is exactly the one action Thunar ships in its own system-wide uca.xml, so
        enabling this module and stating nothing else is not a regression from stock Thunar. It is
        also the only non-arbitrary default available here: a better command would have to name a
        terminal, and the terminal a consumer installed is declared on a different evaluation
        plane that a home-manager module cannot read. Consumers who know their terminal should say
        so — see the example.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = emptyTypeActions == [ ];
        message =
          "nixdesktop.thunar.customActions has ${toString (lib.length emptyTypeActions)} action(s) "
          + "with an empty fileTypes list: ${lib.concatStringsSep ", " emptyTypeActions}. Thunar "
          + "matches actions by intersecting file-type flags, so such an action never appears in "
          + "any context menu — it is invisible, not merely inert.";
      }
      {
        assertion = duplicateIds == [ ];
        message =
          "nixdesktop.thunar.customActions reuses unique-id(s): "
          + "${lib.concatStringsSep ", " duplicateIds}. Thunar treats <unique-id> as an identity "
          + "and has no conflict resolution for a repeat, so two actions sharing one are "
          + "indistinguishable to it.";
      }
    ];

    xdg.configFile."Thunar/uca.xml".text = ucaXml;
  };
}
