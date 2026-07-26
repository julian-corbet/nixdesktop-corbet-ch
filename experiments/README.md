# Experiments

Throwaway trials: spikes, one-off scripts, measurements not yet worth writing up properly.
Nothing here is guaranteed to work, be maintained, or survive the next cleanup pass. If something
here turns out to matter, distill the finding into [`../studies/`](../studies/README.md) and let
the experiment stay disposable (or delete it).

| File | What |
|---|---|
| `eval-smoke-test.nix` | Confirms the policy profile evaluates and `nixdesktop.want` resolves as a backend expects. |

## Open questions

Judgment calls that are reasoned but not measured. Each closes into a default in
`profiles/niri-desktop.nix`.

- **Role vocabulary granularity.** `want` currently mixes named implementations
  (`fileManager = "thunar"`) with capability booleans (`clipboardHistory = true`). That reads
  well, but a backend has to know which is which. A uniform vocabulary might be better; not worth
  churning until a second backend exists to prove it.
- **The two-evaluation seam.** Policy is evaluated by system-manager/NixOS; config generation by
  home-manager. They are separate evaluations, so a consumer today states the polkit choice twice
  — once as a role, once as `polkitAgentCommand`. A backend shipping a paired home-manager module
  that derives the command from the role would close this. Deliberately left open in the first
  iteration rather than guessed at.
- **`bar = "eww"` is under-served.** eww ships no bar, only primitives, so selecting it declares
  an intent the profile cannot fulfil alone. Possibly it should not be an enum value at all.
