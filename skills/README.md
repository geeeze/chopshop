# Skills

Agent skills for this repo (Hermes/Claude-skill format: `SKILL.md` with YAML
frontmatter, plus any `references/` and `scripts/`).

| Skill | Covers |
|---|---|
| `chopshop-swarmui-integration` | The SwarmUI/ComfyUI layer: the bridge's verified API facts, the `ChopShopTrace` node and the binary-vs-color trace pitfall, the workflow files and how to regenerate them, the FLUX.2 Klein negative-prompt caveat, and the pipeline seam contract. |

Import into a Hermes install by copying the directory:

```bash
cp -r skills/chopshop-swarmui-integration ~/.hermes/skills/
```

## Why this skill lives here, not in chopshop-svg

`chopshop-svg` is the public repo, and its `skills/` carry only the two
pipeline skills that make sense to a reader with nothing installed. This one is
deliberately private-stack: it encodes a specific generation stack (SwarmUI's
flattened API shape, in-graph VTracer, a particular model family) and names
local install paths. Publishing it would tell a reader about a machine rather
than about the pipeline.

The same split applies to the repo's docs: `docs/workflow-candidates.md` is a
survey of public workflows and is safe anywhere, while `scripts/SWARMUI_PLAN.md`
describes this install and stays in the private stack.
