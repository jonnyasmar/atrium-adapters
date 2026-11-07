import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'shared'))
from extract_session_usage import count, main


def session_id(path):
    return path.parent.parent.name if path.parent.name == 'subagents' else path.name.removesuffix('.zst').removesuffix('.jsonl')


class ClaudeUsage:
    def __init__(self, path, supplied_id):
        self.subagent = path.parent.name == 'subagents'
        self.session = session_id(path) if self.subagent else supplied_id or session_id(path)
        self.agent = path.name.removesuffix('.zst').removesuffix('.jsonl').removeprefix('agent-') if self.subagent else None

    def event(self, row):
        if row.get('type') != 'assistant':
            return None
        message = row.get('message') or {}
        usage = message.get('usage')
        if not usage or not message.get('id') or not row.get('requestId'):
            return None
        model, at = message.get('model'), row.get('timestamp')
        if not model or not at or model == '<synthetic>':
            return None
        creation = usage.get('cache_creation') or {}
        write_1h = count(creation.get('ephemeral_1h_input_tokens'))
        write_5m = count(creation.get('ephemeral_5m_input_tokens'))
        if not creation:
            write_5m = count(usage.get('cache_creation_input_tokens'))
        tier = usage.get('service_tier') or row.get('serviceTier')
        if usage.get('speed') == 'fast':
            tier = 'fast'
        return dict(type='usage', at=at, session_id=self.session, model=model,
                    dedupe=f"{message['id']}:{row['requestId']}",
                    tokens=dict(input=count(usage.get('input_tokens')), output=count(usage.get('output_tokens')),
                                cache_read=count(usage.get('cache_read_input_tokens')),
                                cache_write_5m=write_5m, cache_write_1h=write_1h, reasoning=0),
                    tier=tier if tier in ('standard', 'priority', 'batch', 'flex', 'fast') else None,
                    cost_usd=None, subagent=self.subagent, agent_id=self.agent, fork_of=None)


if __name__ == '__main__':
    defaults = [str(Path.home() / '.claude/projects')]
    if os.environ.get('CLAUDE_CONFIG_DIR'):
        defaults.append(str(Path(os.environ['CLAUDE_CONFIG_DIR']) / 'projects'))
    sys.exit(main(ClaudeUsage, defaults, session_id))
