# Examples

This directory contains working examples of the self-improvement loop.

## minimal

A bare-bones example showing the loop in action on a tiny repo.

```bash
cd minimal
./setup.sh          # Create a demo repo + signals
../../self-improve.sh  # Run the loop
```

## with-notifications

The same loop, but configured with Slack/webhook notifications at each stage.

```bash
cd with-notifications
export NOTIFY_CMD="./notify.sh"  # set up your webhook
../../self-improve.sh
```

## signal-sources.jsonl

Example signal file showing the expected JSON format:

```jsonl
{"source":"error_log","sha":"abc123","message":"Timeout in request handler","repo":"(agent)"}
{"source":"upstream_commit","sha":"def456","message":"Fix memory leak in cache eviction","repo":"org/dependency"}
{"source":"anomaly","sha":"ghi789","message":"Handler panic on nil pointer","repo":"(agent)"}
```

Each signal object must have:
- `source`: "error_log", "upstream_commit", or "anomaly"
- `sha`: unique identifier (hash or commit SHA)
- `message`: human-readable description
- `repo`: source repo or "(agent)" for agent's own errors

## running-a-full-loop.md

Walkthrough: how to set up and run a complete self-improvement loop on a real repo.
