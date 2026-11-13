import json, sys
value = json.load(sys.stdin)
words = len(value["draft"].split())
ready = words <= value["max_words"]
feedback = [] if ready else [f"Shorten from {words} words to at most {value['max_words']} words."]
print(json.dumps({"ready": ready, "words": words, "feedback": feedback}))
