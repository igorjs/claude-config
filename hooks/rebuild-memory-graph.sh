#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Igor Santos
# SPDX-License-Identifier: MIT
# PostToolUse hook: rebuild ~/.claude/memory/graph.json after any fact-file save.
# Exits immediately (no-op) if the written file is not inside ~/.claude/memory/.

set -u
HOOK_INPUT="${HOOK_INPUT:-}"
if [[ -z "$HOOK_INPUT" ]] && [[ ! -t 0 ]]; then
  HOOK_INPUT="$(cat 2>/dev/null || printf '')"
fi

MEMORY_DIR="${HOME}/.claude/memory"

# --- Early exit when not triggered by a memory file write ---
if [[ -n "$HOOK_INPUT" ]]; then
  file_path="$(printf '%s' "$HOOK_INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)"
  # Expand ~ so comparison works
  file_path="${file_path/#\~/$HOME}"
  if [[ -n "$file_path" ]] && [[ "$file_path" != "$MEMORY_DIR"* ]]; then
    exit 0
  fi
fi

# --- Rebuild graph ---
python3 - <<'PYTHON'
import os, json, re, tempfile

MEMORY_DIR = os.path.expanduser("~/.claude/memory")
GRAPH_FILE  = os.path.join(MEMORY_DIR, "graph.json")

def parse_frontmatter(content):
    """Parse YAML frontmatter between --- delimiters. Returns dict."""
    m = re.match(r'^---[ \t]*\n(.*?)\n---[ \t]*\n', content, re.DOTALL)
    if not m:
        return {}
    fm, result = m.group(1), {}
    current_key = current_kind = None
    buf_list, buf_dict = [], {}

    def flush():
        nonlocal current_key, current_kind, buf_list, buf_dict
        if current_key is None:
            return
        if current_kind == 'list':
            result[current_key] = buf_list[:]
        elif current_kind == 'dict':
            result[current_key] = dict(buf_dict)
        current_key = current_kind = None
        buf_list, buf_dict = [], {}

    for line in fm.splitlines():
        top = re.match(r'^([A-Za-z_]\w*):\s*(.*)', line)
        if top and not line[0].isspace():
            flush()
            current_key = top.group(1)
            val = top.group(2).strip()
            if val:
                result[current_key] = val
                current_key = None
        elif current_key and re.match(r'^\s{2,}- ', line):
            current_kind = 'list'
            buf_list.append(re.sub(r'^\s+-\s+', '', line).strip())
        elif current_key and re.match(r'^\s{2,}\w', line):
            kv = re.match(r'^\s+([A-Za-z_]\w*):\s*(.*)', line)
            if kv:
                current_kind = 'dict'
                buf_dict[kv.group(1)] = kv.group(2).strip()
    flush()
    return result

def scope_and_project(rel):
    parts = rel.replace('\\', '/').split('/')
    if len(parts) == 1:
        return 'global', None
    if len(parts) >= 3:
        return 'project', f'{parts[0]}/{parts[1]}'
    return 'global', None

def node_id(rel, scope, project):
    base = re.sub(r'\.md$', '', rel.replace('\\', '/'))
    if scope == 'global':
        return f'global/{base}'
    # strip owner/repo prefix
    tail = '/'.join(base.split('/')[2:])
    return f'{project}/{tail}'

nodes, edges, seen_code = [], [], set()

for dirpath, dirnames, filenames in os.walk(MEMORY_DIR):
    dirnames[:] = [d for d in dirnames if not d.startswith('.')]
    for fname in filenames:
        if not fname.endswith('.md') or fname == 'MEMORY.md':
            continue
        fpath = os.path.join(dirpath, fname)
        rel   = os.path.relpath(fpath, MEMORY_DIR)
        try:
            content = open(fpath, encoding='utf-8').read()
        except OSError:
            continue

        fm            = parse_frontmatter(content)
        scope, proj   = scope_and_project(rel)
        nid           = node_id(rel, scope, proj)

        n = {
            'id':          nid,
            'file':        rel,
            'scope':       scope,
            'type':        fm.get('type', 'reference'),
            'name':        fm.get('name', re.sub(r'\.md$', '', fname)),
            'description': fm.get('description', ''),
        }
        if proj:
            n['project'] = proj
        nodes.append(n)

        # links: → edges
        links = fm.get('links', {})
        if isinstance(links, dict):
            for relation, target in links.items():
                target_id = (f'global/{target}' if scope == 'global'
                             else f'{proj}/{target}')
                edges.append({'from': nid, 'to': target_id, 'relation': relation})

        # anchors: → code nodes + edges
        for anchor in (fm.get('anchors') or []):
            cid = f'code:{proj}/{anchor}' if proj else f'code:{anchor}'
            if cid not in seen_code:
                cn = {'id': cid, 'file': anchor, 'scope': 'code', 'type': 'code'}
                if proj:
                    cn['project'] = proj
                nodes.append(cn)
                seen_code.add(cid)
            edges.append({'from': nid, 'to': cid, 'relation': 'anchors'})

graph = {'nodes': nodes, 'edges': edges}
fd, tmp = tempfile.mkstemp(dir=MEMORY_DIR, suffix='.json')
try:
    with os.fdopen(fd, 'w') as f:
        json.dump(graph, f, indent=2)
    os.replace(tmp, GRAPH_FILE)
except Exception:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
PYTHON

exit 0
