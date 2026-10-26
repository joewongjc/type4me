# Intelli Sense Semantic Evaluation

This package manually evaluates production `Type4MeIntelliSenseCore` prompts and validation behavior against live OpenAI-compatible models. It is intentionally separate from the app package, normal `swift test`, product builds, and CI.

## Configure

Copy `eval-config.example.json` to `eval-config.json` and set the endpoint/model. Keep the API key in the environment named by `apiKeyEnvironment`:

```bash
export INTELLISENSE_EVAL_API_KEY='...'
```

Alternatively set `INTELLISENSE_EVAL_MODEL`, `INTELLISENSE_EVAL_BASE_URL`, and `INTELLISENSE_EVAL_API_KEY` without a config file.

## Run

Run these commands from this package directory (`tools/IntelliSenseEval`):

```bash
swift run intellisense-eval validate
swift run intellisense-eval run --suite smoke --model product
swift run intellisense-eval run --suite context --model product
swift run intellisense-eval run --suite all --model product
swift run intellisense-eval run --suite all --case cp01 --model product
swift run intellisense-eval run --suite all --tag correction --model product
swift run intellisense-eval report --run <run-id>
swift run intellisense-eval compare --baseline approved
```

Results are written under `Runs/<run-id>/`. `run.jsonl` is machine-readable; each `review-packet-*.md` is designed for human review or submission to a stronger AI reviewer. Model responses are cached by model and production prompt hash, so an interrupted run can reuse completed requests. Use `--no-cache` to force new requests, `--concurrency N` to limit parallelism, and `--repeat 3` to repeat only the 16 critical cases. Transient failures are retried twice and the retry count is recorded.

The 126 cases are split into `core-polish`, `boundary-fidelity`, `application`, `context`, `expression`, and `privacy-fallback`; `smoke` selects 28 of those cases without duplicating requests. The package never invokes a judge model. Fill in `pass`, `acceptable`, `fail`, or `needs-review` in the generated packet, then version an approved machine-readable result as `Baselines/<name>.jsonl` when needed. Runs, caches, local config, and API keys are Git-ignored.
