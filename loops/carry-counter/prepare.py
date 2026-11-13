import json, sys
value = json.load(sys.stdin)
print(json.dumps({"number": value["start"]}))
