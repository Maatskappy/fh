import json
import sys

value = json.load(sys.stdin)
answer = value["answers"]["gate"]
action = answer["choice"]
if answer["confidence"] < 0.8 or action == "insufficient":
    action = "review"
json.dump({"action": action, "choice": answer["choice"],
           "confidence": answer["confidence"], "model": value["model"]}, sys.stdout)
