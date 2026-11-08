#!/usr/bin/env python3
"""Convert CustomResourceDefinitions to JSON schemas for kubeconform.

Usage: crd2schema.py OUT_DIR crds.yaml [more.yaml ...]
Writes OUT_DIR/<kind>-<group>-<version>.json (kind lowercased, full group), strict: unknown
fields are rejected unless the CRD says x-kubernetes-preserve-unknown-fields.
"""
import json
import os
import sys

import yaml

# Some CRDs contain a bare "=" scalar, which PyYAML reads as a !!value tag.
yaml.SafeLoader.add_constructor("tag:yaml.org,2002:value", yaml.SafeLoader.construct_yaml_str)


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


def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    for path in sys.argv[2:]:
        with open(path) as f:
            for doc in yaml.safe_load_all(f):
                if not doc or doc.get("kind") != "CustomResourceDefinition":
                    continue
                spec = doc["spec"]
                kind = spec["names"]["kind"].lower()
                group = spec["group"]
                for v in spec["versions"]:
                    schema = v.get("schema", {}).get("openAPIV3Schema")
                    if not schema:
                        continue
                    name = f"{kind}-{group}-{v['name']}.json"
                    with open(os.path.join(out, name), "w") as o:
                        json.dump(strict(schema), o)


if __name__ == "__main__":
    main()
