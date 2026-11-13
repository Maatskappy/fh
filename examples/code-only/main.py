import json
import sys
value = json.load(sys.stdin)
print(json.dumps({"answer": value["number"] + 1, "verdict": "fail"}))
