#!/usr/bin/env python3
"""Compare the Kubernetes resource identities produced by two renderers."""

from pathlib import Path
import sys

import yaml


IGNORED_KINDS = {"Namespace"}


def resource_identities(path: Path) -> set[tuple[str, str, str, str]]:
    identities: set[tuple[str, str, str, str]] = set()

    with path.open(encoding="utf-8") as stream:
        for document in yaml.safe_load_all(stream):
            if not document or document.get("kind") in IGNORED_KINDS:
                continue

            metadata = document.get("metadata", {})
            identity = (
                document.get("apiVersion", ""),
                document.get("kind", ""),
                metadata.get("namespace", ""),
                metadata.get("name", ""),
            )
            if identity in identities:
                raise ValueError(f"duplicate resource in {path}: {identity}")
            identities.add(identity)

    return identities


def format_identity(identity: tuple[str, str, str, str]) -> str:
    api_version, kind, namespace, name = identity
    scope = f"{namespace}/" if namespace else ""
    return f"{api_version} {kind} {scope}{name}"


def main() -> int:
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} KUSTOMIZE_RENDER HELM_RENDER", file=sys.stderr)
        return 2

    kustomize = resource_identities(Path(sys.argv[1]))
    helm = resource_identities(Path(sys.argv[2]))

    only_kustomize = sorted(kustomize - helm)
    only_helm = sorted(helm - kustomize)
    if only_kustomize or only_helm:
        for identity in only_kustomize:
            print(f"only in Kustomize: {format_identity(identity)}", file=sys.stderr)
        for identity in only_helm:
            print(f"only in Helm: {format_identity(identity)}", file=sys.stderr)
        return 1

    print(f"Helm and Kustomize render the same {len(helm)} workload resources.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
