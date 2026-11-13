# Loops 0.2 decision extension

Use a decision step for typed questions about bound state. Saved code can turn
the answers into a domain verdict or a repeat condition.

loops/0.2 retains the bindings, carry, code/infer steps, schemas, ordered execution and bounded repeat behavior of loops/0.1. It adds one step kind: decision. loops/0.1 continues to reject this kind, so packages explicitly opt into 0.2.

A decision has id, kind:"decision", input, output:{schema:…}, questions, and optional requires:[]. Input resolves to the complete provider state; questions are static package-owned declarations. Model, endpoint, credentials and budgets belong to the installation.

Questions is a nonempty map of at most 64 named questions. Every question has type and instructions. Instructions is a string, object or array. choice has criteria: a map of 1..255 labelled options to descriptions (string/object/array/null). score has criteria: an ordered array of 2..10 level descriptions. noul may declare criteria:{"true":…,"false":…}. Unknown question fields and capabilities are rejected.

Output is {model,answers}. answers contains exactly the declared IDs and matching types. choice returns choice, probabilities and confidence; score returns score, legend, probabilities and confidence; noul returns noul in [0,1]. Probabilities and confidence are retained without implicit rounding or thresholding. A saved code step owns thresholds or transforms probabilities into a repeat-until boolean. Decisions cannot create permission grants.

Decision invocation counts toward the same operation and token budgets as infer, shares the run deadline and cancellation, and records effects before dispatch. Usage is persisted before rejecting malformed or late answers. Unknown usage/delivery stops the procedure; there is no automatic retry or replay. Ordinary declared output schema validation still runs after adapter semantic validation.

## Native adapter

The native binding uses TypeSafe Jev at its official systemone endpoint. One POST sends all questions with already bound state. Other runners must supply a compatible decision adapter; 0.2 itself does not imply TypeSafe access or portability proof.
