#!/usr/bin/env python3
"""kf_fall_manifest.py -- measure FLOW's falling clips and emit a Lua manifest.

The Hit Reactions Animated method, applied to falls: every group is measured
from its own keyframes rather than labelled from its name, and the runtime
selects on those numbers.

Forward kinematics over the real skeleton (meshes/xbase_anim.nif from
Morrowind.bsa): a bone's local transform is the clip's key where it has one
and the bind pose where it does not; world = parent * local. Sampled at
`start`, the middle and `stop` of each group, plus every 1/30 s for motion.

Per group:
  dur        seconds between its start and stop keys
  travel     root (Bip01) displacement start->stop in actor space (x right, y fwd, z up)
  bearing    degrees the root travels, off the actor's forward (+ = right)
  torso      angle of the pelvis->neck line from vertical at stop (0 upright, 90 lying)
  facing     'up' | 'down' | 'side' | 'upright' -- which way the chest faces at stop
  spin       total change of the torso's heading over the clip, degrees
  tumble     total change of the torso's tilt over the clip, degrees (pitch/roll activity)
  headLow    lowest head height above the root during the clip (units)
  pelvisEnd  pelvis height above the root at stop
  flip/roll  signed body rotation over the clip: flip + = forward somersault,
             roll + = rolling over to the right (integrated spine rotation)
  turn       atan2(roll, flip): the direction the body tumbles, as a bearing
             off the actor's forward (0 forward, 90 right, 180 back, -90 left).
             This is what selection scores against the fall's travel bearing.
  role       land | landHard | recover | air (see role_of)
  chainTo    the group in the same file whose first frame matches this one's last

Usage: kf_fall_manifest.py <skeleton.nif> <es3 lib dir> <file.kf> [...] [--lua out.lua]
"""
import math
import sys

import numpy as np


def quat_to_m(q):
    w, x, y, z = q
    n = math.sqrt(w * w + x * x + y * y + z * z) or 1.0
    w, x, y, z = w / n, x / n, y / n, z / n
    return np.array([
        [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
        [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
        [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]])


def slerp(a, b, t):
    a, b = np.array(a, float), np.array(b, float)
    d = float(np.dot(a, b))
    if d < 0:
        b, d = -b, -d
    if d > 0.9995:
        r = a + (b - a) * t
        return r / np.linalg.norm(r)
    th = math.acos(max(-1.0, min(1.0, d)))
    return (math.sin((1 - t) * th) * a + math.sin(t * th) * b) / math.sin(th)


def sample_rot(keys, t):
    if keys is None or len(keys) == 0:
        return None
    times = keys[:, 0]
    if t <= times[0]:
        return keys[0, 1:5]
    if t >= times[-1]:
        return keys[-1, 1:5]
    i = int(np.searchsorted(times, t)) - 1
    t0, t1 = times[i], times[i + 1]
    f = 0.0 if t1 == t0 else (t - t0) / (t1 - t0)
    return slerp(keys[i, 1:5], keys[i + 1, 1:5], f)


def sample_pos(keys, t):
    if keys is None or len(keys) == 0:
        return None
    times = keys[:, 0]
    if t <= times[0]:
        return keys[0, 1:4]
    if t >= times[-1]:
        return keys[-1, 1:4]
    i = int(np.searchsorted(times, t)) - 1
    t0, t1 = times[i], times[i + 1]
    f = 0.0 if t1 == t0 else (t - t0) / (t1 - t0)
    return keys[i, 1:4] * (1 - f) + keys[i + 1, 1:4] * f


def load(nifmod, path):
    s = nifmod.NiStream()
    s.load(path)
    return s


def skeleton(nifmod, path):
    s = load(nifmod, path)
    bones = {}

    def walk(node, parent):
        name = getattr(node, 'name', None)
        if name:
            bones[name] = {'parent': parent, 't': np.array(node.translation, float),
                           'r': np.array(node.rotation, float).reshape(3, 3)}
        for ch in (getattr(node, 'children', None) or []):
            if ch is not None:
                walk(ch, name if name else parent)
    walk(s.roots[0], None)
    return bones


def kf_tracks(nifmod, path):
    s = load(nifmod, path)
    root = s.roots[0]
    names, textkeys = [], []
    e = root.extra_data
    while e is not None:
        tn = type(e).__name__
        if tn == 'NiTextKeyExtraData':
            for t, v in e.keys.tolist():
                for line in str(v).replace('\r', '').split('\n'):
                    if ':' in line:
                        textkeys.append((float(t), line.strip()))
        elif tn == 'NiStringExtraData':
            names.append(e.string_data)
        e = e.next
    tracks = {}
    c, i = root.controller, 0
    while c is not None:
        d = c.data
        rot = None
        try:
            if getattr(d.rotations, 'euler_data', ()) != ():
                d.rotations.convert_to_quaternions()
            rot = np.array(d.rotations.keys) if len(d.rotations.keys) else None
        except Exception:
            rot = None
        pos = np.array(d.translations.keys) if len(d.translations.keys) else None
        if i < len(names):
            tracks[names[i]] = (rot, pos)
        c, i = c.next, i + 1
    return tracks, textkeys


def groups_from(textkeys):
    g = {}
    for t, line in textkeys:
        name, _, what = line.partition(':')
        name, what = name.strip().lower(), what.strip().lower()
        if what in ('start', 'stop'):
            g.setdefault(name, {})[what] = t
    return g


def world(bones, tracks, t):
    out = {}

    def get(name):
        if name in out:
            return out[name]
        b = bones[name]
        rot, pos = tracks.get(name, (None, None))
        q = sample_rot(rot, t)
        R = quat_to_m(q) if q is not None else b['r']
        p = sample_pos(pos, t)
        T = np.array(p, float) if p is not None else b['t']
        if b['parent'] and b['parent'] in bones:
            PR, PT = get(b['parent'])
            res = (PR @ R, PT + PR @ T)
        else:
            res = (R, T)
        out[name] = res
        return res
    return get


def measure(bones, tracks, t0, t1):
    def at(t):
        g = world(bones, tracks, t)
        root = g('Bip01')[1]
        pel = g('Bip01 Pelvis')[1]
        neck = g('Bip01 Neck')[1]
        head = g('Bip01 Head')[1]
        lcl = g('Bip01 L Clavicle')[1]
        rcl = g('Bip01 R Clavicle')[1]
        return root, pel, neck, head, lcl, rcl, g('Bip01 Spine')[0]

    # The skeleton's own frame: Morrowind characters face -Y in the nif? Take
    # it from the bind pose: chest normal at rest is the forward axis.
    def chest_normal(neck, pel, lcl, rcl):
        up = neck - pel
        across = lcl - rcl
        n = np.cross(across, up)
        return n / (np.linalg.norm(n) or 1)

    root0, pel0, neck0, head0, l0, r0, _ = at(t0)
    # The actor frame comes from the BIND pose (no tracks), never from the
    # clip's own first frame: a clip that starts lying face down would make
    # "forward" point at the floor.
    gb = world(bones, {}, 0.0)
    fwd_rest = chest_normal(gb('Bip01 Neck')[1], gb('Bip01 Pelvis')[1],
                            gb('Bip01 L Clavicle')[1], gb('Bip01 R Clavicle')[1])
    samples = []
    t = t0
    while t <= t1 + 1e-6:
        samples.append((t, at(t)))
        t += 1 / 30
    rootE, pelE, neckE, headE, lE, rE, _ = samples[-1][1]

    def tilt(neck, pel):
        v = neck - pel
        return math.degrees(math.acos(max(-1, min(1, v[2] / (np.linalg.norm(v) or 1)))))

    def heading(neck, pel, l, r):
        n = chest_normal(neck, pel, l, r)
        return math.degrees(math.atan2(n[0], n[1]))

    spin = tumble = 0.0
    prevH = prevT = None
    headLow = 1e9
    # Signed body rotation, integrated from frame-to-frame increments of the
    # spine's world rotation, expressed in the actor frame: flip = about the
    # actor's right axis by the right-hand rule, NEGATED so + = forward
    # somersault (head going forward and down); roll = about the actor's
    # forward axis, + = rolling over to the right.
    f2 = np.array([fwd_rest[0], fwd_rest[1], 0.0]); f2 /= (np.linalg.norm(f2) or 1)
    right = np.array([f2[1], -f2[0], 0.0])
    flip = roll = 0.0
    prevR = None
    for _, smp in samples:
        R = smp[6]
        if prevR is not None:
            d = R @ prevR.T
            ang = math.acos(max(-1, min(1, (np.trace(d) - 1) / 2)))
            if ang > 1e-6:
                axis = np.array([d[2, 1] - d[1, 2], d[0, 2] - d[2, 0], d[1, 0] - d[0, 1]]) / (2 * math.sin(ang))
                w = axis * math.degrees(ang)
                flip -= float(w @ right)
                roll += float(w @ f2)
        prevR = R
    for _, (root, pel, neck, head, l, r, _sp) in samples:
        h, tl = heading(neck, pel, l, r), tilt(neck, pel)
        if prevH is not None:
            dh = (h - prevH + 180) % 360 - 180
            spin += abs(dh)
            tumble += abs(tl - prevT)
        prevH, prevT = h, tl
        headLow = min(headLow, head[2] - root[2])
    torsoE = tilt(neckE, pelE)
    nE = chest_normal(neckE, pelE, lE, rE)
    if torsoE < 35:
        facing = 'upright'
    elif nE[2] > 0.5:
        facing = 'up'
    elif nE[2] < -0.5:
        facing = 'down'
    else:
        facing = 'side'
    travel = rootE - root0
    pelTravel = (pelE - rootE) - (pel0 - root0)
    torso0 = tilt(neck0, pel0)
    n0 = chest_normal(neck0, pel0, l0, r0)
    facing0 = 'upright' if torso0 < 35 else ('up' if n0[2] > 0.5 else ('down' if n0[2] < -0.5 else 'side'))
    return {
        'pelTravel': pelTravel, 'flip': flip, 'roll': roll, 'torso0': torso0, 'facing0': facing0,
        'travel': travel, 'fwd_rest': fwd_rest,
        'torso': torsoE, 'facing': facing, 'spin': spin, 'tumble': tumble,
        'headLow': headLow, 'pelvisEnd': pelE[2] - rootE[2],
    }


def pose_at(bones, tracks, t):
    g = world(bones, tracks, t)
    return {n: g(n)[0] for n in bones if n.startswith('Bip01')}


def pose_gap(p, q):
    a = []
    for n in p:
        R = p[n].T @ q[n]
        a.append(math.degrees(math.acos(max(-1, min(1, (np.trace(R) - 1) / 2)))))
    return float(np.mean(a))


CHAIN_GAP = 8.0   # mean bone angle (deg) under which one clip's end IS another's start


def role_of(r):
    """Role from the numbers, not the name.
    land     starts lying face down, ends on the feet       (a dive landing)
    landHard starts lying face down, ends lying             (needs a follow-up)
    recover  starts lying, ends standing                    (getting up / righting)
    air      starts and ends off the feet                   (out-of-control fall loop)"""
    lying0, lyingE = r['torso0'] >= 45, r['torso'] >= 45
    if not lyingE and lying0:
        return 'land' if r['facing0'] == 'down' and r['tumble'] > 180 and r['pelvisEnd'] < -5 else 'recover'
    if lying0 and lyingE:
        return 'landHard' if r['facing0'] == 'down' else 'air'
    return 'air'


def main(argv):
    if len(argv) < 3:
        print(__doc__); return 2
    skel_path, es3_lib, rest = argv[0], argv[1], argv[2:]
    sys.path.insert(0, es3_lib)
    from es3 import nif as nifmod  # noqa: E402
    lua_out = None
    if '--lua' in rest:
        i = rest.index('--lua'); lua_out = rest[i + 1]; rest = rest[:i] + rest[i + 2:]
    bones = skeleton(nifmod, skel_path)
    rows = []
    for path in rest:
        tracks, tk = kf_tracks(nifmod, path)
        gs = groups_from(tk)
        ends = {n: (pose_at(bones, tracks, se['start']), pose_at(bones, tracks, se['stop']))
                for n, se in gs.items() if 'start' in se and 'stop' in se and se['stop'] > se['start']}
        for name, se in sorted(gs.items()):
            if 'start' not in se or 'stop' not in se or se['stop'] <= se['start']:
                rows.append({'file': path, 'group': name, 'broken': se}); continue
            m = measure(bones, tracks, se['start'], se['stop'])
            # actor frame from the rest chest normal (forward) and z up
            f = m['fwd_rest']; f2 = np.array([f[0], f[1], 0.0]); f2 /= (np.linalg.norm(f2) or 1)
            right = np.array([f2[1], -f2[0], 0.0])
            tr = m['travel'] if np.linalg.norm(m['travel']) > 1 else m['pelTravel']
            loc = (float(tr @ right), float(tr @ f2), float(tr[2]))
            bearing = math.degrees(math.atan2(loc[0], loc[1])) if math.hypot(loc[0], loc[1]) > 1 else 0.0
            chain = None
            for other, (st, _) in ends.items():
                if other != name and pose_gap(ends[name][1], st) < CHAIN_GAP:
                    chain = other
            rows.append({'file': path, 'group': name, 'dur': se['stop'] - se['start'], 'travel': loc, 'chainTo': chain,
                         'bearing': bearing, **{k: m[k] for k in ('flip', 'roll', 'torso0', 'facing0', 'torso', 'facing', 'spin', 'tumble', 'headLow', 'pelvisEnd')}})
    for r in rows:
        if 'broken' not in r:
            r['role'] = role_of(r)
            r['turn'] = math.degrees(math.atan2(r['roll'], r['flip'])) if math.hypot(r['flip'], r['roll']) > 15 else 0.0
    print('%-12s %-8s %6s %-9s %5s %6s %6s  %-22s %7s %-13s %6s %-7s %6s %6s %7s %7s' % ('group', 'role', 'turn', 'chainTo', 'dur', 'flip', 'roll', 'travel (x,y,z)', 'bearing', 'start', 'torso', 'facing', 'spin', 'tumble', 'headLow', 'pelvisE'))
    for r in rows:
        if 'broken' in r:
            print('%-12s BROKEN keys %s' % (r['group'], r['broken'])); continue
        print('%-12s %-8s %6.0f %-9s %5.2f %6.0f %6.0f  (%6.1f,%6.1f,%6.1f) %7.1f %-7s%6.1f %6.1f %-7s %6.0f %6.0f %7.1f %7.1f' % (
            r['group'], r['role'], r['turn'], r['chainTo'] or '-', r['dur'], r['flip'], r['roll'], *r['travel'], r['bearing'], r['facing0'], r['torso0'], r['torso'], r['facing'], r['spin'], r['tumble'], r['headLow'], r['pelvisEnd']))
    if lua_out:
        with open(lua_out, 'w') as f:
            f.write('-- Generated by kf_fall_manifest.py from the shipped .kf files. Do not edit by hand.\n')
            f.write('-- Measured with forward kinematics over meshes/xbase_anim.nif (see the tool).\n')
            f.write('return {\n')
            for r in rows:
                if 'broken' in r:
                    f.write('    -- %s: incomplete start/stop keys, not offered\n' % r['group']); continue
                f.write("    { group = '%s', role = '%s', turn = %.0f, chainTo = %s, dur = %.3f, flip = %.0f, roll = %.0f, bearing = %.1f, travel = { %.1f, %.1f, %.1f }, startFacing = '%s', startTorso = %.1f, torso = %.1f, facing = '%s', spin = %.0f, tumble = %.0f, headLow = %.1f, pelvisEnd = %.1f },\n" % (
                    r['group'], r['role'], r['turn'], ("'%s'" % r['chainTo']) if r['chainTo'] else 'nil', r['dur'], r['flip'], r['roll'], r['bearing'], *r['travel'], r['facing0'], r['torso0'], r['torso'], r['facing'], r['spin'], r['tumble'], r['headLow'], r['pelvisEnd']))
            f.write('}\n')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
