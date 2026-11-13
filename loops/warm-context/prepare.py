import json
import sys

context = json.load(sys.stdin)
context["failed_checks"] = [item["check"] for item in context["evidence"] if item["status"] == "failed"]
print(json.dumps(context))
