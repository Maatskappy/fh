import json, sys
value = json.load(sys.stdin)
title = value["title"]
print(json.dumps({"title": title, "words": len(title.split())}))
