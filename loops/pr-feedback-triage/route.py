"""Exact admission facts and evidence-linked proposals; never executes an action."""
import json
import re
import sys

ACTIONS = {
    "code_issue": ("repair_code", "The feedback reports a concrete repository defect."),
    "clarification": ("answer_reviewer", "The reviewer primarily requests an explanation."),
    "infrastructure": ("investigate_infrastructure", "The evidence points to an external execution dependency."),
    "informational": ("no_action", "The feedback contains no substantive action request."),
    "insufficient": ("gather_context", "The supplied evidence cannot reliably identify the next action."),
}


def validate(value):
    if not isinstance(value, dict) or set(value) != {"head_sha", "feedback"}:
        raise ValueError("Expected head_sha and feedback only")
    def sha(v, nullable=False):
        return (nullable and v is None) or (isinstance(v, str) and re.fullmatch(r"[0-9a-f]{40}", v) is not None)
    if not sha(value["head_sha"]):
        raise ValueError("head_sha must be a full lowercase 40-character SHA")
    item = value["feedback"]
    names = {"id", "sha", "kind", "status", "text", "url", "check_name", "file", "line", "review_blocked"}
    if not isinstance(item, dict) or set(item) != names or not sha(item["sha"], True):
        raise ValueError("Invalid feedback fields or SHA")
    for name, cap, nullable, required in [("id", 128, False, True), ("url", 1024, False, True),
                                           ("text", 6000, False, False), ("file", 512, True, False),
                                           ("check_name", 256, True, False)]:
        v = item[name]
        if nullable and v is None:
            continue
        if not isinstance(v, str) or len(v) > cap or (required and not v):
            raise ValueError("Invalid feedback " + name)
    if item["kind"] not in ("review", "check") or item["status"] not in ("none", "pending", "pass", "fail"):
        raise ValueError("Invalid feedback kind/status")
    if type(item["review_blocked"]) is not bool:
        raise ValueError("review_blocked must be boolean")
    line = item["line"]
    if line is not None and (type(line) is not int or not 1 <= line <= 1000000):
        raise ValueError("Invalid feedback line")
    return value


def code_gate(value):
    validate(value)
    item = value["feedback"]
    if item["sha"] is None:
        return "gather_context", "Feedback is unbound to a commit; establish its applicability first."
    if item["sha"] != value["head_sha"]:
        return "ignore_stale", "Feedback is bound to a different commit than the supplied head."
    if item["review_blocked"]:
        return "restore_review", "The caller reports that this review did not run; a passing check is not review evidence."
    if item["kind"] == "check" and item["status"] == "pending":
        return "wait_for_ci", "The current-commit check is still running."
    if item["kind"] == "check" and item["status"] == "pass":
        return "no_action", "This supplied check passed; this says nothing about merge readiness."
    return None


def proposal(value, action, reason, decision=None):
    item = value["feedback"]
    location = item["file"]
    if location and item["line"] is not None:
        location += ":" + str(item["line"])
    where = " at " + location if location else " in the linked evidence"
    steps = {
        "repair_code": "Inspect the reported defect" + where + "; if confirmed, repair it and rerun the affected tests.",
        "answer_reviewer": "Read the linked review question and explain the relevant behavior or rationale to the reviewer.",
        "investigate_infrastructure": "Inspect the linked failure log and verify the named service or runner dependency before retrying the failed check.",
        "no_action": "No action proposed for this feedback item.",
        "gather_context": "Read the linked feedback and obtain the missing commit applicability, failure log or reproduction evidence before proposing a repair.",
        "ignore_stale": "Preserve this feedback as history; obtain current-head feedback before acting on the issue.",
        "wait_for_ci": "Wait for this current-commit check to finish, then assess its final result.",
        "restore_review": "Inspect the review quota or availability notice and arrange a substantive review of the current commit.",
    }
    return {"proposal_only": True, "action": action, "next_step": steps[action], "reason": reason,
            "head_sha": value["head_sha"], "gated_by": "jev" if decision else "code", "decision": decision,
            "evidence": {"id": item["id"], "url": item["url"], "sha": item["sha"], "kind": item["kind"],
                         "location": location, "excerpt": item["text"][:600]}}


def route(value, decision=None):
    gated = code_gate(value)
    if gated:
        return proposal(value, *gated)
    if decision is None:
        raise ValueError("Eligible feedback needs a decision")
    answer = decision["answers"]["feedback"]
    choice = answer["choice"]
    if choice not in ACTIONS:
        raise ValueError("Unsupported decision category")
    return proposal(value, *ACTIONS[choice], decision=decision)


if __name__ == "__main__":
    request = json.load(sys.stdin)
    print(json.dumps(route(request["context"], request["decision"]), separators=(",", ":")))
