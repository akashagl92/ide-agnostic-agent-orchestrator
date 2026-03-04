#!/usr/bin/env python3
import argparse
import json
import sys
from pathlib import Path
from typing import List, Optional


def load_json(path: Path):
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def detect_mutation(command: str, mutating_tokens: List[str]) -> bool:
    c = f" {command} "
    for token in mutating_tokens:
      if token in c:
          return True
    return False


def detect_forbidden_target(command: str, forbidden_targets: List[str]) -> Optional[str]:
    for target in forbidden_targets:
        if target in command:
            return target
    return None


def detect_stage(root: Path) -> str:
    stage_script = root / "scripts" / "pai_stage_detect.sh"
    if not stage_script.exists():
        return "dev"
    try:
        out = (
            __import__("subprocess")
            .check_output([str(stage_script)], text=True, cwd=str(root))
            .splitlines()
        )
        for line in out:
            if line.startswith("STAGE="):
                return line.split("=", 1)[1].strip() or "dev"
    except Exception:
        return "dev"
    return "dev"


def main():
    parser = argparse.ArgumentParser(description="Evaluate structured PAI policy")
    parser.add_argument("--policy", required=True)
    parser.add_argument("--mode", required=True)
    parser.add_argument("--actor", required=True, choices=["parent", "child"])
    parser.add_argument("--command", required=True)
    parser.add_argument("--root", required=True)
    args = parser.parse_args()

    policy = load_json(Path(args.policy))
    mode_rules = policy.get("mode_rules", {})
    global_rules = policy.get("global", {})
    stage_overrides = policy.get("stage_overrides", {})

    if args.mode not in mode_rules:
        print("DENY unknown_mode")
        return 4

    rule = mode_rules[args.mode]
    stage = detect_stage(Path(args.root))

    if args.actor == "child" and not rule.get("allow_spawn", True):
        print("DENY spawn_disallowed_in_mode")
        return 5

    forbidden = detect_forbidden_target(args.command, global_rules.get("forbidden_targets", []))
    if forbidden:
        print(f"DENY forbidden_target={forbidden}")
        return 6

    mutating = detect_mutation(args.command, global_rules.get("mutating_tokens", []))
    if mutating and not rule.get("allow_mutation", False):
        print("DENY mutation_disallowed_in_mode")
        return 7

    stage_rule = stage_overrides.get(stage, {})
    if args.mode == "scoped_write" and stage_rule.get("allow_scoped_write") is False:
        print("DENY scoped_write_disallowed_in_stage")
        return 8

    print(f"ALLOW stage={stage} mutating={str(mutating).lower()} mode={args.mode}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
