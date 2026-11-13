import json, sys
value = json.load(sys.stdin)
number = value["state"]["number"] + 1
print(json.dumps({"number": number, "ready": number >= value["target"]}))
