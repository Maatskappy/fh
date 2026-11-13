"""Read only explicit snapshot JSON; discovered workspace code stays inert."""
import json
import sys


def clean(value, limit=256):
    return "".join(c if c.isprintable() else " " for c in str(value))[:limit]


def unique_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate key")
        result[key] = value
    return result


def reject_constant(value):
    raise ValueError("non-JSON constant")


def finite_float(value):
    result = float(value)
    if result in (float("inf"), -float("inf")):
        raise ValueError("nonfinite number")
    return result


def essential(manifest):
    if not isinstance(manifest, dict) or manifest.get("format") != "loops/0.1":
        return False
    if any(not isinstance(manifest.get(key), str) or not manifest[key].strip()
           for key in ("name", "version")):
        return False
    if not isinstance(manifest.get("inputs"), dict) or "schema" not in manifest["inputs"]:
        return False
    steps = manifest.get("steps")
    if not isinstance(steps, list) or not steps or "output" not in manifest:
        return False
    for step in steps:
        if not isinstance(step, dict) or not isinstance(step.get("id"), str) or not step["id"].strip():
            return False
        if "input" not in step or not isinstance(step.get("output"), dict) or "schema" not in step["output"]:
            return False
        if step.get("kind") == "code":
            if any(not isinstance(step.get(key), str) or not step[key].strip() for key in ("file", "runtime")):
                return False
        elif step.get("kind") == "infer":
            if not isinstance(step.get("instructions"), str) or not step["instructions"].strip():
                return False
        else:
            return False
    return True


def suggest(snapshot):
    nearby, issues = [], []
    gaps = [clean(value) for value in snapshot["gaps"]]
    complete = snapshot["complete"]

    def issue(path, code, message):
        nonlocal complete
        if len(issues) < 8:
            issues.append({"path": clean(path), "code": code, "message": clean(message)})
        else:
            complete = False
            if "Additional issues omitted." not in gaps:
                gaps.append("Additional issues omitted.")

    for package in snapshot["packages"]:
        path = clean(package["path"])
        if package["state"] != "captured" or package["manifest"] is None:
            complete = False
            continue
        try:
            manifest = json.loads(package["manifest"], object_pairs_hook=unique_pairs,
                                  parse_constant=reject_constant, parse_float=finite_float)
        except (ValueError, RecursionError):
            issue(path, "malformed_json", "loop.json is not strict JSON; use /check for the exact diagnostic.")
            continue
        if not essential(manifest):
            issue(path, "essential_shape", "loop.json is missing an essential Loop declaration; use /check.")
            continue
        if len(nearby) < 8:
            nearby.append({"path": path, "name": clean(manifest["name"], 128)})
        else:
            complete = False
            if "Additional nearby packages omitted." not in gaps:
                gaps.append("Additional nearby packages omitted.")
        if not package["inventoryComplete"]:
            complete = False
        for entry in package["files"]:
            if entry["state"] == "missing":
                issue(path, "missing_file", "Referenced package file is missing: " + clean(entry["path"], 128))
            elif entry["state"] != "present":
                complete = False

    if issues:
        suggestion = "A nearby Loop has an obvious issue. Use /check to inspect it."
    elif nearby:
        suggestion = "Found nearby Loops. Use /check on a package, then /run when ready."
    elif complete:
        suggestion = "Describe a repeatable task and I can help you create a Loop here."
    else:
        suggestion = "Workspace context is partial. Describe a task or use /check on a known package."
    return {"suggestion": suggestion, "nearbyLoops": nearby, "issues": issues,
            "complete": complete, "gaps": gaps[:32]}


if __name__ == "__main__":
    print(json.dumps(suggest(json.load(sys.stdin)), ensure_ascii=True, allow_nan=False))
