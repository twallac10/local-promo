#!/usr/bin/env python3
"""Convert CustomResourceDefinitions to JSON schemas for kubeconform.

Usage: crd2schema.py OUT_DIR crds.yaml [more.yaml ...]
Writes OUT_DIR/<kind>-<group>-<version>.json (kind lowercased, full group),
strict: unknown fields are rejected unless the CRD says
x-kubernetes-preserve-unknown-fields.

Standard library only: YAML is converted to JSON with yq (mikefarah v4),
which the other scripts need anyway.
"""
import json
import os
import subprocess
import sys


def strict(node):
    if isinstance(node, dict):
        if "properties" in node and not node.get("x-kubernetes-preserve-unknown-fields"):
            node.setdefault("additionalProperties", False)
        for v in node.values():
            strict(v)
    elif isinstance(node, list):
        for v in node:
            strict(v)
    return node


def load_docs(path):
    # All documents of the file as one JSON array.
    out = subprocess.run(["yq", "ea", "-o=json", "-I=0", "[.]", path],
                         check=True, capture_output=True, text=True).stdout
    return json.loads(out) if out.strip() else []


def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    for path in sys.argv[2:]:
        for doc in load_docs(path):
            if not isinstance(doc, dict) or doc.get("kind") != "CustomResourceDefinition":
                continue
            spec = doc["spec"]
            kind = spec["names"]["kind"].lower()
            group = spec["group"]
            for v in spec["versions"]:
                schema = (v.get("schema") or {}).get("openAPIV3Schema")
                if not schema:
                    continue
                name = f"{kind}-{group}-{v['name']}.json"
                with open(os.path.join(out, name), "w") as o:
                    json.dump(strict(schema), o)


if __name__ == "__main__":
    main()
