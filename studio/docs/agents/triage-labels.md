# Triage Labels

The skills speak in terms of five canonical triage roles. This file maps those
roles to the actual label strings used in this repo's GitHub tracker
(`geeeze/chopshop-studio`). Here each label string **is** its role name — no
translation is needed, and a skill naming a role can apply it verbatim.

| Canonical role    | Label in this tracker | Meaning                                  |
| ----------------- | --------------------- | ---------------------------------------- |
| `needs-triage`    | `needs-triage`        | Maintainer needs to evaluate this issue  |
| `needs-info`      | `needs-info`          | Waiting on reporter for more information |
| `ready-for-agent` | `ready-for-agent`     | Fully specified, ready for an AFK agent  |
| `ready-for-human` | `ready-for-human`     | Requires human implementation            |
| `wontfix`         | `wontfix`             | Will not be actioned                     |

When a skill mentions a role (e.g. "apply the AFK-ready triage label"), use the
corresponding label string from this table.

## Kind labels (secondary)

An issue carries its triage state **plus** one or more kind labels saying what
it is about. The kinds in use:

`bug` · `documentation` · `question` · `suggestion` · `expectation` ·
`reference` · `enhancement` · `accessibility` · `invalid` · `duplicate`

`invalid` and `duplicate` are terminal kinds and normally travel with `wontfix`
(or with a close comment explaining the finding).
