# home/startup.nix — the one thing nixdesktop owns across every compositor: a place to say
# "run this at session start" without naming a compositor.
#
# THE PROBLEM THIS AVOIDS. A niri-specific startup option, owned by a niri-specific module, is a
# hard compile-time dependency for anything that wants to append a startup command: a consumer
# who imports home/noctalia.nix without also importing that niri module would hit "the option
# does not exist", a hard eval error, not a graceful no-op -- and there is no path at all for a
# scroll consumer, since a scroll module has (and should have) no reason to expose a niri-shaped
# option.
#
# THE FIX. `nixdesktop.startup` is a plain list of raw shell-command strings, owned by nixdesktop
# itself rather than by any one compositor module. Any nixdesktop module that wants a command to
# run at session start (home/noctalia.nix today) appends to this list instead of reaching into a
# compositor's own options. A compositor module (nixniri, nixscroll, ...) is expected to read
# `config.nixdesktop.startup` and wrap each entry in its own native startup syntax (niri's
# `spawn-sh-at-startup "<command>"` form, scroll's equivalent, ...) -- nixdesktop deliberately
# stores plain commands, not pre-wrapped compositor syntax, so the same list works unmodified
# regardless of which compositor module ends up reading it.
#
# THIS FILE DECLARES THE OPTION ONLY. It produces no config, spawns nothing itself, and has no
# `enable` flag -- there is nothing to enable, just a contract both sides read and write. Kept in
# its own file (rather than folded into, say, home/session.nix) so a compositor module can depend
# on the contract alone, without also pulling in session.nix's systemd-service machinery. Modules
# in this repo that write to `nixdesktop.startup` (home/noctalia.nix) `imports` this file
# directly, so the option is always declared wherever they are; it is also exported in its own
# right, as `homeManagerModules.startup`, for a sibling compositor module to import without
# depending on any other nixdesktop module.
{ lib, ... }:
{
  options.nixdesktop.startup = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = ''
      Raw startup-command strings, owned by nixdesktop and written by whichever of its modules
      wants something running at session start (`home/noctalia.nix` today). Each entry is a
      plain POSIX shell command line -- no compositor-specific wrapping. A compositor module is
      expected to read this list and splice its entries into its own native startup mechanism,
      wrapping each one in that mechanism's own syntax itself (e.g. a niri module would emit
      each entry as its own `spawn-sh-at-startup "<command>"` line). nixdesktop makes no
      assumption beyond "these are shell commands, read in order" -- the wrapping is the
      consuming compositor module's job, not something this option does.

      Entries merge across every module that defines this list (the standard behaviour for a
      `listOf` option), so nixdesktop modules that need a startup command can each append their
      own entry independently without needing to know about each other.
    '';
  };
}
