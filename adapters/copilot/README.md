# GitHub Copilot

Requires the standalone `copilot` CLI (tested with 1.0.86), Python 3, and an account with Copilot CLI access enabled. Authenticate with `copilot login`.

The adapter supports terminal sessions and native chat over ACP, session resume, command discovery, permission requests, context usage, and prompt images. Copilot currently exposes model selection through `/model` rather than an ACP model catalog. Use `/model` in chat or add `--model` and `--reasoning-effort` to a launch profile's CLI arguments. The adapter deliberately has no static model catalog because availability depends on the account.

Terminal hooks live in `~/.copilot/hooks/atrium.json` (or `$COPILOT_HOME/hooks/atrium.json`). They are inactive outside an atrium pane and in native chat, where the chat runtime owns activity and context injection. `sessionStart` carries the initial context; `userPromptTransformed` carries prompt-time context and skill sigils. Copilot ignores command-hook output from `userPromptSubmitted`, so the adapter does not use it for injection.

History is read from `$COPILOT_HOME/session-state/<id>/events.jsonl`. Only top-level sessions in the requested working directory appear in the resume picker. Extraction excludes system messages, transformed prompts, and hidden reasoning.

Copilot's ACP mode and feature surface can change independently of its terminal UI. The adapter does not advertise live model switching, plan-mode controls, checkpoints, steering, or background-task support. Copilot's own advertised slash commands remain available.

Validation:

```sh
./validate-adapter.sh adapters/copilot
python3 -m unittest discover -s adapters/copilot/tests -p '*_test.py'
ATRIUM_DATA_DIR=/path/to/dev-data ./test-adapter.sh adapters/copilot
```

The icon is from [GitHub Octicons](https://github.com/primer/octicons), under the MIT license in `ICON-LICENSE`.
