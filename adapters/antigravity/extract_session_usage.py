import os
import sys
import argparse
import json
from pathlib import Path

USAGE_OUTPUT_VERSION = 1


def shared_dir():
    # <data>/adapters/<name> links to .managed/<name>/generations/<id>, whose
    # resolved parent is not the adapters dir: try the logical path first.
    for adapter in (Path(os.path.abspath(__file__)).parent, Path(__file__).resolve().parent):
        parts = adapter.parts
        managed = len(parts) > 4 and parts[-4] == '.managed' and parts[-2] == 'generations'
        shared = (Path(*parts[:-4]) if managed else adapter.parent) / 'shared'
        if shared.is_dir():
            return str(shared)
    sys.exit(f'extract_session: no shared/ runtime found from {__file__}')


sys.path.insert(0, shared_dir())
from extract_session_usage import extract, discover, count
from sqlite_usage import _extract as extract_database, file_entry, emit
from usage_db import AntigravityDatabase


def session_id(path):
    return Path(path).parent.parent.parent.name


class AntigravityUsage:
    def __init__(self, path, supplied_id):
        self.session = supplied_id or session_id(path)

    def event(self, row):
        if row.get('type') != 'PLANNER_RESPONSE' or 'input_tokens' not in row:
            return None
        if not row.get('model') or not isinstance(row.get('step_index'), int):
            raise ValueError('native usage lacks model or step index')
        return dict(type='usage', at=row['created_at'], session_id=self.session,
                    model=row['model'], dedupe=f"antigravity:{self.session}:step:{row['step_index']}",
                    tokens=dict(input=count(row['input_tokens']), output=count(row.get('output_tokens')),
                                cache_read=count(row.get('cache_read_tokens')), cache_write_5m=0,
                                cache_write_1h=0, reasoning=0))


def defaults():
    homes = [Path.home() / '.gemini' / name / 'brain'
             for name in ('antigravity-cli', 'antigravity-acp')]
    if os.environ.get('ANTIGRAVITY_HOME'):
        homes.append(Path(os.environ['ANTIGRAVITY_HOME']).expanduser())
    return [str(home) for home in homes]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--usage', action='store_true', required=True)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--list', action='store_true')
    mode.add_argument('--batch', action='store_true')
    parser.add_argument('--since', type=float, default=0)
    parser.add_argument('--max-files', type=int, default=500)
    options = parser.parse_args()
    database = AntigravityDatabase()
    if options.list:
        discover(defaults(), options.since, session_id,
                 lambda name: name == 'transcript.jsonl')
        for path in database.discover(options.since):
            item = file_entry(path, path.stem, options.since)
            if item:
                emit(item)
    else:
        for index, line in enumerate(sys.stdin):
            if index >= options.max_files:
                raise ValueError('batch exceeds --max-files')
            request = json.loads(line)
            if Path(request['path']).suffix == '.db':
                extract_database(request, request, database, 128)
            else:
                extract(request, AntigravityUsage)
    return 0


if __name__ == '__main__':
    sys.exit(main())
