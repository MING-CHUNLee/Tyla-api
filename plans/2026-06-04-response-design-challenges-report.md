# Designing Reliable Tutor Responses: Challenges and Solutions

**Date:** 2026-06-04
**Status:** Shipped
**Scope:** `POST /api/v1/tutor_chats` response design — the `content` (prose) and `actions` (structured file operations) fields.

---

## 1. Background

The Tyla tutoring API returns a two-part response for every student turn:

- **`content`** — the natural-language explanation the tutor writes back to the student.
- **`actions`** — a structured array of concrete operations the tutor wants to perform on the student's workspace. Three action types are supported:
  - `edit_file` — apply a search-and-replace patch to a file the student is working on,
  - `execute_script` — provide a runnable R demonstration script, and
  - `load_file` — request a workspace file that was not included in the current context.

The `actions` field is what makes the tutor *agentic* rather than purely conversational: it is the channel through which the model turns "here is what is wrong" into "here is the fix, applied." The reliability of this field is therefore central to the product. This report documents the challenges we encountered in making the `actions` channel fire reliably, and the engineering changes we made to resolve them.

---

## 2. The Core Problem

In testing on 2026-06-04 we observed that the `actions` field was **almost always an empty array (`[]`)**, even when the model clearly understood that an action was warranted and said so in prose. Two representative cases:

**Case 1 — an `edit_file` that never materialized.**
A student wrote: *"My hw2.R computes quartiles but I used the wrong probs vector: `quantile(d123, probs = c(0.25, 0.75))`. I need the 10th, 50th, and 90th percentiles instead. Can you fix it?"* The buggy line was present verbatim in the workspace, so the search string was unambiguous. The model correctly explained that the vector should become `c(0.1, 0.5, 0.9)`, and closed with *"Let me apply this update in your file."* — yet `actions` came back empty. The structured block was simply never produced.

**Case 2 — an `execute_script` deferred forever.**
A student asked for a worked example with made-up numbers. The model produced an ~900-token derivation and ended with *"Would you like me to write an R script to demonstrate this as well?"* Again `actions` was empty: the model treated the demonstration as something to do *after* the student confirmed, and the confirmation turn never produced the action either.

In both cases the tutor *knew* what to do and *announced* it, but the structured output never appeared.

---

## 3. Root-Cause Analysis

### 3.1 The original mechanism was inherently fragile

The original design asked the model to emit, **after** its natural-language prose, an additional structured block — an XML-like `<actions>[...]</actions>` envelope containing JSON. In other words, the model had to *remember*, every single time, to append a second machine-readable section once it had finished writing to the human.

This fights the grain of the model in three ways:

1. **RLHF biases models toward clean conversational endings.** A model trained on human-preference data tends to stop after a natural closing sentence. Appending a structured payload afterward is exactly the kind of "unnatural" continuation that such training discourages.
2. **Transitional phrases read as completion signals.** Sentences like *"Let me apply this..."* or *"Would you like me to...?"* are, to the model, the end of the response. Having committed to that ending, it stops generating — before the `<actions>` block is ever reached.
3. **Prompt pressure cannot win this fight.** No matter how forcefully the instruction was phrased, it was competing against the model's stop-generation tendency rather than working with it.

### 3.2 Prompt engineering did not fix it

We exhausted the prompt-only options first. None worked:

| Attempted prompt change | Result |
|---|---|
| Add "When the buggy code appears in the workspace, prefer `edit_file`" | No effect |
| Strengthen "when ..." → "you MUST end your response with ..." | No effect; more tokens, same behavior |
| Add few-shot examples using the same `hw2.R` code | No effect; risked the model treating the example as the answer |
| Rewrite few-shot examples as a fictional scenario (`analysis.R`) | No effect |
| Add "Do NOT write transitional phrases like 'Let me apply...'" | No effect |

The conclusion was that the problem was **architectural, not a matter of wording.** As long as the contract required the model to self-serialize a structured block after prose, it would remain unreliable.

---

## 4. The Solution: API-Native Function Calling

The fix was to stop asking the model to *write* a structured block and instead let it *call a function*. Function calling (tool use) is a first-class API mechanism: the model emits tool calls as structured output that the provider returns in a dedicated field, entirely separate from prose. There is nothing to "remember to append," so the stop-generation problem disappears at its root.

### 4.1 Dual-provider coverage with one shared schema

We define the three actions once, as a single shared tool schema in the Anthropic `input_schema` shape, and let each client adapt it to its provider's wire format. Both supported providers go through function calling — there is no provider-specific branch in the application layer.

| Provider | Tool format | Where actions come from |
|---|---|---|
| GitHub Models / OpenAI | OpenAI `tools` (`{ type: "function", function: { parameters } }`) | `choices[0].message.tool_calls` |
| Anthropic | Anthropic `tool_use` blocks | `content[].type == "tool_use"` |
| Other (no tool support) | — | Fallback: XML `<actions>` parsing |

### 4.2 Implementation

- **`LlmResponse`** gained a `tool_calls` field (default `[]`), so both clients return actions through one uniform value object alongside `content` and `usage`.
- **`AnthropicClient`** accepts a `tools:` argument (added to the request body only when non-empty) and, on parse, separates `text` blocks (→ `content`) from `tool_use` blocks (→ `tool_calls`).
- **`OpenAiClient`** accepts the same `tools:` argument, converts the shared `input_schema` format into OpenAI's `function`/`parameters` wrapper, and parses `tool_calls`, JSON-decoding each `function.arguments` string. Malformed arguments are dropped rather than raising.
- **`RunTutorChat`** owns the shared `TOOLS` constant, always passes `tools: TOOLS`, and routes through a small `extract_reply`: if `tool_calls` are present they become the actions, otherwise it falls back to the XML parser.

```ruby
def extract_reply(llm_reply)
  if llm_reply.tool_calls.any?
    [llm_reply.content, llm_reply.tool_calls]
  else
    Values::TutorReplyParser.call(llm_reply.content)
  end
end
```

- **The system prompt** dropped its `ACTIONS_PROTOCOL` section (which described the XML format) in favor of a shorter `TOOL_USE_GUIDE` that contains only *decision rules* — when to call each tool. Formatting is now the API's job, not the prompt's.

This change carried full test coverage: client-level specs for both tool-call parsing paths and for the presence/absence of the `tools` key, plus service-level specs for the `tool_calls` path. The suite landed green at 204 tests, 0 failures.

---

## 5. A Second, Subtler Challenge: the Model *Chose* Not to Call

Migrating to function calling fixed the `edit_file` case, but follow-up testing showed `actions` could still be empty for `execute_script`. Debug logs confirmed the tools were being sent correctly — the model was simply **deciding not to call them**, writing the whole derivation in prose and ending with *"If you'd like, I can illustrate this step-by-step process in R code for you. Let me know!"*

This is a different failure mode from the original one, and it is worth distinguishing clearly:

| Failure mode | XML era | After function calling |
|---|---|---|
| `edit_file` | Model said "Let me apply..." then stopped, forgetting the XML | Resolved — the API layer handles serialization |
| `execute_script` | Model said "Would you like me to..." then stopped | **Still occurred — addressed by the v2 patch** |

The root cause was in the wording of the decision rule. The original guide triggered `execute_script` *"when **showing** runnable demo code."* The model judged that it was *explaining a concept*, not *showing demo code*, so the condition read as false and no tool was called. The trigger was phrased in terms of the **model's own behavior**, which the model can always argue itself out of.

### 5.1 The fix: trigger on student intent, and forbid the confirmation reflex

We rewrote the guide so triggers are keyed to **what the student asked for** rather than to **what the model thinks it is doing**, and we explicitly banned the "ask first" pattern:

```
## Tool Use Guide
Call `edit_file` when the exact code to fix is visible in the student workspace — apply the fix directly without asking first.
Call `execute_script` when the student asks for a demo, example, or step-by-step illustration — provide the R code directly without asking for confirmation first.
Call `load_file` when you need to see a workspace file not provided in context.
Do NOT offer to run code as a follow-up question ("Would you like me to..."). If code would help, call the tool immediately.
If you have no concrete code to act on, or when refusing, do not call any tool.
```

The three key changes:

1. **Student-intent triggers.** "When the student asks for a demo, example, or illustration" replaces "when showing runnable demo code." Whether the student asked is an objective fact in the transcript; whether the model is "showing demo code" is a self-assessment it can rationalize away.
2. **Explicit "without asking first"** on `edit_file`.
3. **An explicit prohibition** on deferring with *"Would you like me to...?"* — if code would help, call the tool now.

---

## 6. A Related Tension on the Safety Side: False Positives

Making the tutor act readily on file requests created pressure at the other end of the pipeline. A safety guard scores each incoming prompt for jailbreak/attack probability before the tutor runs. Once we encouraged the tutor to honor natural-language requests like *"Can you check my hw2.R?"* or *"Can you show me an example?"*, the guard began **over-blocking** them: phrasing that asks the tutor to read or run code superficially resembles probing for system internals.

We addressed this by teaching the guard to distinguish **sanctioned actions on the student's own files** from genuine extraction attempts:

- We added an explicit "Legitimate Requests (score ≤ 0.10)" section enumerating the three sanctioned patterns (load own file, run a demo, fix own code), with the key distinction spelled out: reading *the student's own homework file* is safe; revealing the *reference solution, answer key, or system prompt* is not.
- We recalibrated the scoring instruction to treat a false positive (blocking a legitimate question) as just as harmful as a false negative, and to score above 0.5 only on clear attack signals.

This is an important design lesson in its own right: **response reliability and safety are coupled.** Encouraging the model to act decisively on one side of the pipeline requires the guard on the other side to recognize those same actions as legitimate, or the net effect is a tutor that is willing to act but is never allowed to.

---

## 7. The Retained Fallback

We kept the XML `<actions>` parser (`TutorReplyParser`) as a fallback for any provider that does not support function calling. The routing is automatic: when `llm_reply.tool_calls` is empty, the service parses the prose for an `<actions>` block instead. Parsing there is deliberately permissive — malformed or non-array JSON is dropped to `[]` while the prose is always preserved — so a provider without tool support degrades gracefully rather than failing the turn.

---

## 8. Summary and Lessons Learned

1. **Do not ask a model to self-serialize structured output after prose.** RLHF-trained models stop at natural conversational endings; a structured block appended afterward is exactly what they are biased to omit. No amount of prompt pressure reliably overcomes this.
2. **Use the API-native mechanism for structured output.** Function calling moves serialization from the model's discretion into the transport layer, eliminating the stop-generation failure entirely. A single shared schema, adapted per provider, kept the application layer free of provider branches.
3. **Phrase decision rules in terms of observable user intent, not model self-assessment.** "When the student asks for X" is a fact in the transcript; "when you are doing X" is something the model can argue itself out of. Pair such rules with an explicit ban on the confirmation reflex.
4. **Reliability and safety are two ends of one pipeline.** Making the tutor act decisively required teaching the upstream guard to recognize those same actions as legitimate; tuning one in isolation would have silently undone the other.

The combined result is a tutor whose `actions` field fires when — and only when — it should, across both supported providers, with a graceful fallback for the rest.
