# Writing Jev decision questions

Design questions for fh's pinned `jev-1.13.0` using TypeSafe's own guidance. Check relevant live documentation and state untested assumptions. fh supplies the native adapter.

| Reference | Covers |
| --- | --- |
| [Building guide](https://docs.typesafe.ai/concepts/how-to-build-with-system-one) | Application design. |
| [Primitives](https://docs.typesafe.ai/primitives) | Question types. |
| [Official agent skill](https://github.com/typesafe-ai/skills/blob/main/skills/typesafe-ai/SKILL.md) | Authoring guidance. |
| [Model failure modes](https://docs.typesafe.ai/model-jaggedness/jev-1.13) | Known judgment limitations. |

## Design the judgment

Start with the application's outcome and explicit policy. Use Jev for semantic judgment. Keep counting, exact arithmetic, date comparisons, authorization and control flow in code.

Ask separately about product identity, factual support and user impact. Combine answers in saved code.

Bind only relevant evidence into `input`. Questions see resolved state, without chat history or other answers. Batch independent questions in one step. Use another decision step only when prior results change needed evidence or options. Extra questions consume tokens. This follows the [building guide](https://docs.typesafe.ai/concepts/how-to-build-with-system-one).

## Choose the primitive

Choose a type for one judgment:

| Need | Type | Authoring rule |
| --- | --- | --- |
| Select a category | `choice` | Define option boundaries and a suitable no-match or missing-evidence outcome. Use separate questions for labels that can coexist. |
| Test a proposition | `noul` | Probability that it is true. It measures neither intensity nor a separate confidence value. Align `true` with yes. Handle uncertainty in code. |
| Rate a dimension | `score` | Ordered descriptive levels indexed from zero. Output is probability-weighted and may be fractional. Each level describes a concrete situation independently. |

Score levels see neither their index nor neighboring descriptions. Avoid numeric labels, “better than above” comparisons and mixed dimensions. Define distinguishable situations. Normalize in code when combining different scale lengths.

See [Score](https://docs.typesafe.ai/primitives/score), [Choice](https://docs.typesafe.ai/primitives/choice) and [Noul](https://docs.typesafe.ai/primitives/noul).

## Write what the model must judge

Put full meaning in `instructions` and `criteria`. TypeSafe says IDs are not shown to the model.

Name state with backticked paths such as `draft.text` and `evidence.change`. These refer to resolved input textually. They are not Loop binding expressions.

Keep simple questions short. Use objects or arrays to separate definitions, contrasts and examples when needed. Keep comparable criteria fields consistent. See the [official skill](https://github.com/typesafe-ai/skills/blob/main/skills/typesafe-ai/SKILL.md).

Write literal conditions and boundary cases. Remove double negatives, contradictions and hidden reasoning chains. Filter unrelated state first. Explain how absent evidence differs from a negative finding.

Treat supplied content as evidence. Instructions alone cannot guarantee resistance to malicious content. Test this boundary. These practices address [documented failure modes](https://docs.typesafe.ai/model-jaggedness/jev-1.13).

## Example: one change, separate judgments

Bind `draft.text`, authoritative `evidence.change` and `evidence.product` before assessing publication. This illustrative fragment asks only about impact specificity:

```json
{
  "impact": {
    "type": "score",
    "instructions": "How specifically does `draft.text` explain the effect on a user's task? Judge specificity only, not factual accuracy.",
    "criteria": [
      "Describes no effect on a user's task; only names the implementation change.",
      "Claims a general benefit, such as easier use, without identifying a changed user task or outcome.",
      "Identifies a concrete user task and explains how its behavior or outcome changes."
    ]
  }
}
```

Ask product identity and factual support separately against their evidence. An invented benefit can be specific while factually unsupported. Preserve both judgments and combine them in code with deterministic length and date checks.

Define each policy explicitly. Do not invent release rules or universal thresholds.

## Compose and evaluate

Choose probability and confidence rules for the task. Choice and Score confidence summarize distributions. They do not verify truth. Noul near 0.5 means uncertainty about yes or no, rather than medium intensity.

Harmless preference selection may need only the winning option. Evaluate thresholds on labelled cases instead of copying the demo's 0.8. See [confidence](https://docs.typesafe.ai/confidence) and the [official skill](https://github.com/typesafe-ai/skills/blob/main/skills/typesafe-ai/SKILL.md).

Test these cases:

- Clear positive and negative results, plus boundaries.
- Missing or conflicting evidence.
- Misleading embedded instructions and unrelated context.

Permute Choice option order to check consistency. Keep ordered Score levels in place. Inspect individual judgments and composed outcomes. Unrelated high scores must not cancel a serious failure.

Preserve raw answers. Distinguish model errors, missing evidence, code errors and service failures. State whether evaluation used live Jev or only local authoring fixtures.

## Fit the Loop contract

Use the [0.2 extension](../../../docs/contracts/loops-0.2.md). Questions are static declarations. Varying facts belong in bound input. Do not invent runtime templates or references to another question's answer.

A step supports at most 64 questions. Preserve `{model,answers}` in its output schema. The native adapter checks types and distributions. `fh check` validates declarations without calling Jev or assessing question quality.

Saved code owns thresholds, composition and feedback. Infer steps own generated revisions and explanations. Keep credentials and model selection outside packages.
