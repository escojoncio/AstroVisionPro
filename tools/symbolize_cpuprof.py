#!/usr/bin/env python3
"""Names the functions in a CPU profile of the headset (cpuprof-<date>.txt in VPS4/LOGS, written
by the diagnostics mode: shadps4-arm64-main/src/common/cpu_profiler.h).

    symbolize_cpuprof.py <cpuprof.txt> [<AstroQuest.symbols.txt.gz>] [--from S] [--to S]
                         [--top N] [--folded <file>]

The symbol map is the one the build publishes next to the app (release visionos-latest): the
app's `nm -n`, with its UUID in the first line. It must be the map of the build that wrote the
profile (the UUIDs are compared). Without a map, the symbols the headset itself wrote are used.

The profile has one section per 30 s; they are added up, or only those between --from and --to
(seconds since the profiler started) are. For each thread: the functions by exclusive samples (it
was running, or waiting, in the function itself) and by inclusive samples (the function was
anywhere in the stack). --folded writes the stacks as `thread;root;...;leaf samples`, for a flame
graph. Only the 200 hottest frames and stacks of each section are in the profile: "listed" says
how many of the samples they hold. Inclusive counts of a function outside the app may count a
sample twice. Names are as the linker has them: pipe through `c++filt` to read them.
"""
import argparse
import bisect
import collections
import gzip
import re
import sys


def read_map(path):
    """The UUID (or None), and the functions' addresses and names, by address."""
    opener = gzip.open if open(path, 'rb').read(2) == b'\x1f\x8b' else open
    uuid = None
    symbols = []
    with opener(path, 'rt', encoding='utf-8', errors='replace') as lines:
        for line in lines:
            if line.startswith('UUID:'):
                uuid = line.split()[1].replace('-', '').upper()
                continue
            match = re.match(r'^([0-9a-fA-F]+) [tT] (\S.*)$', line.rstrip('\n'))
            if match:
                # (Mach-O puts a '_' before every name; the headset's own symbols come without it)
                symbols.append((int(match.group(1), 16), match.group(2).removeprefix('_')))
    symbols.sort()
    return uuid, [address for address, _ in symbols], [name for _, name in symbols]


def read_profile(path):
    """The image line's fields, and the whole intervals: (t0, t1, [thread]), a thread being
    (name, {field: number}, excl lines, incl lines, folded lines)."""
    image = {}
    intervals = []
    current = None
    with open(path, encoding='utf-8', errors='replace') as lines:
        lines = [line.rstrip('\n') for line in lines]
    at = 0
    while at < len(lines):
        words = lines[at].split()
        at += 1
        if not words or words[0].startswith('#'):
            continue
        if words[0] == 'image':
            image = dict(word.split('=', 1) for word in words[2:])
            image['name'] = words[1]
        elif words[0] == 'interval':
            fields = dict(word.split('=', 1) for word in words[1:])
            current = (float(fields['t0']), float(fields['t1']), [])
        elif words[0] == 'thread' and current is not None:
            fields = {key: int(value) for key, value in (word.split('=', 1) for word in words[2:])}
            current[2].append((words[1], fields, [], [], []))
        elif words[0] in ('excl', 'incl', 'folded') and current is not None and current[2]:
            count = int(words[1])
            current[2][-1][2 + ('excl', 'incl', 'folded').index(words[0])].extend(lines[at:at + count])
            at += count
        elif words[0] == 'end' and current is not None:
            intervals.append(current)  # (an interval the app's end cut short never gets here)
            current = None
    return image, intervals


class Namer:
    def __init__(self, image, addresses, names):
        self.image = image.get('name')
        self.vmaddr = int(image.get('vmaddr', '0'), 16)
        self.addresses = addresses
        self.names = names
        self.seen = {}  # frame -> the symbol the headset gave it

    def name(self, frame):
        """The function a frame is in, or the frame itself when nothing names it."""
        frame, _, symbol = frame.partition('=')
        if symbol:
            self.seen[frame] = symbol
        image, _, offset = frame.rpartition('+0x')
        if image == self.image and self.addresses:
            at = bisect.bisect_right(self.addresses, self.vmaddr + int(offset, 16)) - 1
            if at >= 0:
                return self.names[at]
        return self.seen.get(frame, frame)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('profile')
    parser.add_argument('map', nargs='?')
    parser.add_argument('--from', dest='start', type=float, default=0.0)
    parser.add_argument('--to', dest='end', type=float, default=float('inf'))
    parser.add_argument('--top', type=int, default=50)
    parser.add_argument('--folded')
    arguments = parser.parse_args()

    image, intervals = read_profile(arguments.profile)
    uuid, addresses, names = read_map(arguments.map) if arguments.map else (None, [], [])
    if arguments.map and not addresses:
        sys.exit(f'{arguments.map}: no symbols in it')
    if uuid and uuid != image.get('uuid', '').upper():
        sys.exit(f'The map is of another build: its UUID is {uuid}, the profile\'s {image.get("uuid")}')
    if arguments.map and not uuid:
        print('The map has no UUID line: not checked against the profile', file=sys.stderr)
    namer = Namer(image, addresses, names)
    # (the lists carry the symbols the headset gave: all read before any frame is named)
    for _, _, parts in intervals:
        for _, _, excl, incl, _ in parts:
            for row in excl + incl:
                namer.name(row.split(' ', 1)[1])

    threads = collections.OrderedDict()
    for t0, t1, parts in intervals:
        if t1 <= arguments.start or t0 >= arguments.end:
            continue
        for name, fields, excl, incl, folded in parts:
            thread = threads.setdefault(name, {
                'seconds': 0.0, 'fields': collections.Counter(), 'excl': collections.Counter(),
                'incl': collections.Counter(), 'folded': collections.Counter()})
            thread['seconds'] += t1 - t0
            thread['fields'].update(fields)
            for kind, rows in (('excl', excl), ('incl', incl)):
                for row in rows:
                    count, frame = row.split(' ', 1)
                    thread[kind][namer.name(frame)] += int(count)
            for row in folded:
                stack, count = row.rsplit(' ', 1)
                thread['folded'][';'.join(namer.name(frame) for frame in stack.split(';'))] += int(count)

    if not threads:
        sys.exit('No whole interval in the profile (or none in the span asked for)')
    print(f'image {image.get("name")} uuid={image.get("uuid")} functions={image.get("functions")}')
    for name, thread in threads.items():
        fields = thread['fields']
        samples = max(fields['samples'], 1)
        print(f'\nthread {name} samples={fields["samples"]} seconds={thread["seconds"]:.1f} '
              f'missed={fields["missed"]} '
              f'suspended={fields["suspended_us"] / max(thread["seconds"], 1e-9) / 1e4:.2f}% '
              f'stacks_dropped={fields["stacks_dropped"]} pcs_dropped={fields["pcs_dropped"]}')
        for kind, title in (('excl', 'exclusive'), ('incl', 'inclusive')):
            listed = f', listed {sum(thread[kind].values()) / samples:.1%} of the samples' if kind == 'excl' else ''
            print(f'{title} (top {arguments.top} of {len(thread[kind])}{listed})')
            for function, count in thread[kind].most_common(arguments.top):
                print(f'{count / samples:7.2%} {count:8d}  {function}')
        print(f'stacks: listed {sum(thread["folded"].values()) / samples:.1%} of the samples')

    if arguments.folded:
        with open(arguments.folded, 'w', encoding='utf-8') as out:
            for name, thread in threads.items():
                for stack, count in thread['folded'].most_common():
                    out.write(f'{name};{stack} {count}\n')


if __name__ == '__main__':
    main()
