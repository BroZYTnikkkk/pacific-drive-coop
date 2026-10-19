"""Extract files from an unencrypted UE4.26/4.27 (pak v11) pak. Zlib or uncompressed only.
Usage: pakextract.py pak outdir substring [substring...]"""
import struct, sys, os, zlib

def fstr(b, o):
    n = struct.unpack_from('<i', b, o)[0]; o += 4
    if n == 0: return '', o
    if n < 0: return b[o:o - n * 2].decode('utf-16-le').rstrip('\0'), o - n * 2
    return b[o:o + n].decode('utf-8', 'replace').rstrip('\0'), o + n

pak, outdir, subs = sys.argv[1], sys.argv[2], sys.argv[3:]
sz = os.path.getsize(pak)
f = open(pak, 'rb')
f.seek(sz - 221); foot = f.read(221)
i = foot.find(struct.pack('<I', 0x5A6F12E1))
ver, ioff, isz = struct.unpack_from('<iqq', foot, i + 4)
names = [foot[i + 44 + k * 32: i + 76 + k * 32].split(b'\0')[0].decode() for k in range(5)]
print('compression methods:', names)
f.seek(ioff); idx = f.read(isz)
o = 0
mount, o = fstr(idx, o)
nent, seed = struct.unpack_from('<iQ', idx, o); o += 12
if struct.unpack_from('<I', idx, o)[0]: o += 4 + 36
else: o += 4
o += 4
fdoff, fdsz = struct.unpack_from('<qq', idx, o); o += 36
enc_size = struct.unpack_from('<i', idx, o)[0]; o += 4
enc = idx[o:o + enc_size]
f.seek(fdoff); d = f.read(fdsz)
o = 0; files = {}
for _ in range(struct.unpack_from('<i', d, 0)[0]):
    pass
o = 4
for _ in range(struct.unpack_from('<i', d, 0)[0]):
    dn, o = fstr(d, o)
    nf = struct.unpack_from('<i', d, o)[0]; o += 4
    for _ in range(nf):
        fn, o = fstr(d, o); loc = struct.unpack_from('<i', d, o)[0]; o += 4
        files[dn + fn] = loc

def decode(p):
    v = struct.unpack_from('<I', enc, p)[0]; p += 4
    if (v & 0x3f) == 0x3f: bs = struct.unpack_from('<I', enc, p)[0]; p += 4
    else: bs = (v & 0x3f) << 11
    meth = (v >> 23) & 0x3f
    def rd(flag):
        nonlocal p
        if v & flag: x = struct.unpack_from('<I', enc, p)[0]; p += 4
        else: x = struct.unpack_from('<Q', enc, p)[0]; p += 8
        return x
    off = rd(1 << 31); usz = rd(1 << 29)
    csz = rd(1 << 30) if meth else usz
    encrypted = bool(v & (1 << 22)); nblk = (v >> 6) & 0xffff
    blocks = []
    hdr = 8 * 3 + 4 + 20 + (4 + 16 * nblk if meth else 0) + 1 + 4
    if meth:
        if nblk == 1 and not encrypted:
            blocks = [csz]
        else:
            for _ in range(nblk):
                blocks.append(struct.unpack_from('<I', enc, p)[0]); p += 4
    return off, usz, csz, meth, encrypted, blocks, hdr

for name, loc in files.items():
    if not any(s.lower() in name.lower() for s in subs): continue
    if loc < 0: print('skip (non-encoded entry)', name); continue
    off, usz, csz, meth, encr, blocks, hdr = decode(loc)
    if encr: print('encrypted', name); continue
    f.seek(off + hdr)
    if meth == 0: data = f.read(usz)
    else:
        m = names[meth - 1]
        if m.lower() != 'zlib': print('unsupported', m, name); continue
        data = b''.join(zlib.decompress(f.read(b)) for b in blocks)
    out = os.path.join(outdir, name.lstrip('/'))
    os.makedirs(os.path.dirname(out), exist_ok=True)
    open(out, 'wb').write(data)
    print('ok', name, len(data))
