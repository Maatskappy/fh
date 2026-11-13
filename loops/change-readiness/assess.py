"""Assess explicit receipts only; this program does not run or verify checks."""
import json
import sys


def assess(value):
    receipts = value["receipts"]
    counts = {}
    for receipt in receipts:
        name = receipt["name"]
        counts[name] = counts.get(name, 0) + 1
    missing = [name for name in value["required_checks"] if name not in counts]
    duplicates = sorted(name for name, count in counts.items() if count > 1)
    failed = sorted({receipt["name"] for receipt in receipts if receipt["exit_code"] != 0})
    ready = not (missing or duplicates or failed)
    if duplicates:
        action = "Supply one unambiguous receipt per check name."
    elif missing:
        action = "Run the missing checks and supply their receipts."
    elif failed:
        action = "Correct the failed checks and supply fresh receipts."
    else:
        action = "All supplied check receipts pass; review the identified change before proceeding."
    evidence = {
        "source": "caller_supplied",
        "required_count": len(value["required_checks"]),
        "receipt_count": len(receipts),
        "summed_duration_ms": sum(receipt["duration_ms"] for receipt in receipts),
        "receipts": receipts,
    }
    for key in ("revision", "diff_identity"):
        if key in value:
            evidence[key] = value[key]
    return {"ready": ready, "failed_checks": failed, "missing_checks": missing,
            "duplicate_checks": duplicates, "next_action": action, "evidence": evidence}


if __name__ == "__main__":
    print(json.dumps(assess(json.load(sys.stdin)), ensure_ascii=True, allow_nan=False))
