# Experiments

Throwaway trials: spikes, one-off scripts, measurements not yet worth writing up properly.
Nothing here is guaranteed to work, be maintained, or survive the next cleanup pass. If something
here turns out to matter, distill the finding into [`../studies/`](../studies/README.md) and let
the experiment stay disposable (or delete it).

| File | What |
|---|---|
| `eval-smoke-test.nix` | Confirms the policy profile evaluates and `nixdesktop.want` contains only platform-resolved roles; the selected compositor remains a host fact outside that attrset. |
| `eval-nixos-backend.nix` | Confirms `modules/nixos-backend.nix` resolves the default `nixdesktop.want` to real nixpkgs packages, handles portals through `xdg.portal`, and never materializes the compositor owned by an integration product. |

## Open questions

Judgment calls that are reasoned but not measured. Each closes into a default in
`profiles/desktop.nix`.

- **Role vocabulary granularity.** `want` currently mixes named implementations
  (`fileManager = "thunar"`) with capability booleans (`clipboardHistory = true`). That reads
  well, but a backend has to know which is which. A second backend now exists
  (`modules/nixos-backend.nix`) and it did not need a different vocabulary to consume `want` —
  both backends' `resolve`/`packagesFor` handle the mix identically. Downgraded from "unproven" to
  "proven adequate, not proven optimal"; still not worth churning without a concrete complaint.
- **The two-evaluation seam is now a two-*repo* seam too.** Policy is evaluated by
  system-manager/NixOS; compositor config generation now lives in a sibling repo entirely
  (nixciri, nixscroll, ...) rather than just a separate home-manager evaluation. Nothing about
  idle/lock has to be wired across that seam any more: this repo owns the timeouts, the locker
  name and the swayidle assembly (`nixdesktop.session.idleAndLock`), and a compositor module reads
  `lockCommand` from it defensively for its own lock keybind. That replaced an arrangement where
  each compositor module assembled the invocation from its own timeout options and the consumer
  hand-wired the result in — which was one copy of the assembly per compositor repo, and none at
  all for a compositor whose repo had not written one. The polkit-agent and keyring commands never
  had a compositor-side assembly to begin with (they are a binary invocation, not a timeout
  calculation), so those still come from a platform backend's role table
  (`lib/nixos-roles.nix`'s `polkitAgents`/`keyrings`).
- **`bar = "eww"` is under-served.** eww ships no bar, only primitives, so selecting it declares
  an intent the profile cannot fulfil alone. Possibly it should not be an enum value at all.
- **The startup contract (`home/startup.nix`) is consumed by both compositor integrations.**
  `homeManagerModules.noctalia` writes to `nixdesktop.startup`; nixscroll and nixciri translate
  those commands into their native startup syntax.
