#!/usr/bin/env python3
"""Convert a chopshop ComfyUI API-format prompt into a SwarmUI example workflow.

SwarmUI example workflows (the files under
``CustomWorkflows/Examples/``, e.g. ``Basic SDXL.json``) are a wrapper:

    {
      "workflow":  { "nodes": [...], "links": [...], ... },  # UI editor graph
      "prompt":    { "<id>": {"class_type": ..., "inputs": {...}}, ... },  # API graph
      "custom_params": {}, "param_values": {},
      "description": "...", "enable_in_simple": bool, "image": null
    }

Execution correctness comes only from ``prompt`` (input names). The ``workflow``
UI graph is what the editor canvas draws; slot indices there are positional and
must match the node schema. We derive them from the backend's ``object_info``
so the canvas wires correctly.

Usage:
    .venv/bin/python scripts/comfy_to_swarmui.py \
        swarm_workflows/trace_generate_trace_flux2_klein.json \
        --object-info /tmp/object_info2.json \
        --out "CustomWorkflows/Examples/ChopShop Trace Generate Trace (Flux.2 Klein 4B).json"
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def load_object_info(path: Path) -> dict:
    info = json.loads(path.read_text())
    # Normalize node-type -> ordered input names (required then optional).
    ordered: dict[str, list[str]] = {}
    for name, meta in info.items():
        req = meta.get("input", {}).get("required", {})
        opt = meta.get("input", {}).get("optional", {})
        ordered[name] = list(req.keys()) + list(opt.keys())
    return ordered


def build_workflow_graph(prompt: dict, ordered: dict) -> dict:
    """Build the SwarmUI UI-editor graph from an API-format prompt."""
    # Link records: origin node/slot -> target node/slot, by type.
    links = []
    link_id = 1
    nodes = []

    # First pass: nodes and their widget/input structure.
    for node_id in sorted(prompt, key=int):
        entry = prompt[node_id]
        class_type = entry["class_type"]
        inputs = entry.get("inputs", {})
        schema_order = ordered.get(class_type, list(inputs.keys()))

        node_inputs = []
        widget_values = []
        for name in schema_order:
            if name not in inputs:
                # Schema input not provided in prompt (optional): emit a widget
                # placeholder so the editor still shows the slot.
                node_inputs.append({
                    "name": name,
                    "type": "WIDGET",
                    "widget": {"name": name},
                    "link": None,
                })
                widget_values.append(None)
                continue
            value = inputs[name]
            if isinstance(value, list) and len(value) == 2 and isinstance(value[0], (int, str)) and isinstance(value[1], int):
                node_inputs.append({
                    "name": name,
                    "type": "LINK",
                    "link": None,  # filled in link pass
                })
                widget_values.append(None)
            else:
                node_inputs.append({
                    "name": name,
                    "type": "WIDGET",
                    "widget": {"name": name},
                    "link": None,
                })
                widget_values.append(value)

        # Outputs: placeholders; filled in link pass.
        node = {
            "id": int(node_id),
            "type": class_type,
            "pos": [0, 0],
            "size": {"0": 300, "1": 120},
            "flags": {},
            "order": int(node_id),
            "mode": 0,
            "inputs": node_inputs,
            "outputs": [],
            "properties": {"Node name for S&R": class_type},
            "widgets_values": widget_values,
        }
        nodes.append(node)

    node_by_id = {n["id"]: n for n in nodes}
    # Map (node_id, input_name) -> index in that node's inputs list.
    input_index = {
        (n["id"], inp["name"]): i for n in nodes for i, inp in enumerate(n["inputs"])
    }

    # Second pass: wire links.
    for node_id in sorted(prompt, key=int):
        entry = prompt[node_id]
        class_type = entry["class_type"]
        inputs = entry.get("inputs", {})
        schema_order = ordered.get(class_type, list(inputs.keys()))
        target_node = node_by_id[int(node_id)]
        for name in schema_order:
            if name not in inputs:
                continue
            value = inputs[name]
            if isinstance(value, list) and len(value) == 2 and isinstance(value[0], (int, str)):
                origin_id = int(value[0])
                origin_slot = int(value[1])
                target_slot = input_index[(int(node_id), name)]
                # Assign link id on both sides.
                target_node["inputs"][target_slot]["link"] = link_id
                origin_node = node_by_id[origin_id]
                # Ensure the origin node has an output slot for origin_slot.
                while len(origin_node["outputs"]) <= origin_slot:
                    origin_node["outputs"].append({
                        "name": "OUTPUT",
                        "type": "*",
                        "links": [],
                        "slot_index": len(origin_node["outputs"]),
                    })
                origin_node["outputs"][origin_slot]["links"].append(link_id)
                links.append({
                    "id": link_id,
                    "origin_id": origin_id,
                    "origin_slot": origin_slot,
                    "target_id": int(node_id),
                    "target_slot": target_slot,
                    "type": "*",
                })
                link_id += 1

    return {
        "last_node_id": max(node_by_id),
        "last_link_id": link_id - 1,
        "nodes": nodes,
        "links": links,
        "groups": [],
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("prompt_json", type=Path)
    ap.add_argument("--object-info", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--description", default="")
    args = ap.parse_args()

    prompt = json.loads(args.prompt_json.read_text())
    prompt.pop("_meta", None)

    ordered = load_object_info(args.object_info)
    workflow = build_workflow_graph(prompt, ordered)

    wrapper = {
        "workflow": workflow,
        "prompt": prompt,
        "custom_params": {},
        "param_values": {},
        "description": args.description,
        "enable_in_simple": False,
        "image": None,
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(wrapper, indent=2) + "\n")
    print(f"wrote {args.out} ({len(workflow['nodes'])} nodes, "
          f"{len(workflow['links'])} links)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
