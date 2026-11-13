The input `sentence` was written by the step before this one. Judge it; do not write about anything else.

Set `ok` to true only if the sentence is plain (everyday words, no jargon) and is under 25 words. Count the words.

If `ok` is true, return the sentence unchanged in `sentence`. If `ok` is false, return a tighter version in `sentence` that is plain, under 25 words, and keeps the same meaning.

Return JSON with `ok` and `sentence`.
