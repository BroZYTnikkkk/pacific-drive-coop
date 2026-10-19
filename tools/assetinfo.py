"""Summarize UAssetAPI JSON dumps: components, meshes, visibility flags, sockets, transforms.
Usage: assetinfo.py <dump.json> [name-substring ...]"""
import json
import sys


def load(path):
    with open(path, encoding='utf-8') as f:
        return json.load(f)


def ref_name(a, idx):
    """Resolve a package index: negative = import, positive = export, 0 = null."""
    if not isinstance(idx, int) or idx == 0:
        return None
    if idx < 0:
        imp = a['Imports'][-idx - 1]
        return 'import:' + str(imp.get('ObjectName'))
    return 'export:' + str(a['Exports'][idx - 1].get('ObjectName'))


def short(v, a, depth=0):
    if isinstance(v, dict):
        t = v.get('$type', '').split(',')[0].split('.')[-1]
        if t == 'ObjectPropertyData':
            return ref_name(a, v.get('Value'))
        if 'Value' in v and not isinstance(v['Value'], (list, dict)):
            return v['Value']
        if t in ('StructPropertyData',) and isinstance(v.get('Value'), list):
            parts = []
            for p in v['Value'][:6]:
                parts.append(f"{p.get('Name')}={short(p, a, depth + 1)}")
            return '{' + ', '.join(parts) + '}'
        if t in ('VectorPropertyData', 'RotatorPropertyData'):
            val = v.get('Value', {})
            return {k: round(val[k], 1) for k in val if isinstance(val.get(k), (int, float))}
        if isinstance(v.get('Value'), list) and depth < 2:
            return '[' + ', '.join(str(short(x, a, depth + 1)) for x in v['Value'][:8]) + (']' if len(v['Value']) <= 8 else ', ...]')
        if isinstance(v.get('Value'), dict):
            return {k: (round(x, 1) if isinstance(x, float) else x) for k, x in v['Value'].items() if not isinstance(x, (dict, list))}
    return v


def main():
    a = load(sys.argv[1])
    subs = [s.lower() for s in sys.argv[2:]]
    for i, e in enumerate(a['Exports'], 1):
        name = str(e.get('ObjectName'))
        cls = ref_name(a, e.get('ClassIndex'))
        if subs and not any(s in name.lower() or s in str(cls).lower() for s in subs):
            continue
        props = []
        for p in e.get('Data') or []:
            if not isinstance(p, dict):
                continue
            props.append(f"{p.get('Name')}={short(p, a)}")
        print(f"[{i}] {name}  class={cls}  outer={ref_name(a, e.get('OuterIndex'))}")
        for s in props[:40]:
            print('     ', str(s)[:220])


if __name__ == '__main__':
    main()
