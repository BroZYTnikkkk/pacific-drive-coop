"""List files in UE4.26/4.27 (pak v11) unencrypted pak indexes. Usage: paklist.py out.txt pak..."""
import struct, sys, os

def fstr(b, o):
    n = struct.unpack_from('<i', b, o)[0]; o += 4
    if n == 0: return '', o
    if n < 0:
        s = b[o:o - n * 2].decode('utf-16-le').rstrip('\0'); return s, o - n * 2
    s = b[o:o + n].decode('utf-8', 'replace').rstrip('\0'); return s, o + n

def listing(path):
    sz = os.path.getsize(path)
    with open(path, 'rb') as f:
        f.seek(sz - 221); foot = f.read(221)
        i = foot.find(struct.pack('<I', 0x5A6F12E1))
        ver, ioff, isz = struct.unpack_from('<iqq', foot, i + 4)
        f.seek(ioff); idx = f.read(isz)
        o = 0
        mount, o = fstr(idx, o)
        nent, seed = struct.unpack_from('<iQ', idx, o); o += 12
        has_ph = struct.unpack_from('<I', idx, o)[0]; o += 4
        if has_ph: o += 8 + 8 + 20
        has_fd = struct.unpack_from('<I', idx, o)[0]; o += 4
        if not has_fd: return mount, []
        fdoff, fdsz = struct.unpack_from('<qq', idx, o)
        f.seek(fdoff); d = f.read(fdsz)
    o = 0; out = []
    ndirs = struct.unpack_from('<i', d, o)[0]; o += 4
    for _ in range(ndirs):
        dname, o = fstr(d, o)
        nf = struct.unpack_from('<i', d, o)[0]; o += 4
        for _ in range(nf):
            fname, o = fstr(d, o); o += 4
            out.append(dname + fname)
    return mount, out

with open(sys.argv[1], 'w', encoding='utf-8') as w:
    for p in sys.argv[2:]:
        m, files = listing(p)
        for x in files: w.write(f"{os.path.basename(p)}\t{m}{x}\n")
        print(os.path.basename(p), m, len(files))
