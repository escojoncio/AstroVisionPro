#!/usr/bin/env python3
"""Checks tools/symbolize_cpuprof.py against a profile written by the profiler's own code
(tools/tests/cpu_profile_test.cpp, which leaves it where it is told to):

    build/tests/cpu_profile_test build/tests/cpuprof-sample.txt
    python3 tools/tests/symbolize_cpuprof_test.py build/tests/cpuprof-sample.txt
"""
import gzip
import os
import subprocess
import sys
import tempfile

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'symbolize_cpuprof.py')

# As the build makes it: `dwarfdump --uuid`, then `nm -nU` (Mach-O names, with their '_').
MAP = """UUID: 0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9 (arm64) /build/AstroQuest.app/AstroQuest
0000000100000000 T __mh_execute_header
0000000100001000 t _alpha
0000000100001040 t __ZN4beta3runEv
000000010000116c T _gamma
0000000100008000 d _data_is_no_function
"""

failures = 0


def check(ok, what):
    global failures
    print(('ok  ' if ok else 'FAIL'), '', what)
    failures += 0 if ok else 1


def run(*arguments):
    done = subprocess.run([sys.executable, SCRIPT, *arguments], capture_output=True, text=True)
    return done.returncode, done.stdout, done.stderr


def main():
    sample = sys.argv[1]
    with tempfile.TemporaryDirectory() as folder:
        def write(name, text, zipped=False):
            path = os.path.join(folder, name)
            with (gzip.open if zipped else open)(path, 'wt', encoding='utf-8') as out:
                out.write(text)
            return path

        plain = write('map.txt', MAP)
        folded = os.path.join(folder, 'folded.txt')

        code, out, err = run(sample, plain, '--folded', folded)
        lines = out.splitlines()
        check(code == 0 and err == '', 'a profile and its map are read')
        check('thread cp_thread samples=20 seconds=60.0 missed=2 suspended=1.00% stacks_dropped=0 pcs_dropped=0' in lines,
              'the whole intervals of a thread add up; the one cut short is left out')
        check('thread game_main samples=30 seconds=30.0 missed=0 suspended=1.00% stacks_dropped=0 pcs_dropped=0' in lines,
              'a thread that is in one interval only has that interval\'s time')
        cp = lines[lines.index('thread cp_thread samples=20 seconds=60.0 missed=2 suspended=1.00% '
                               'stacks_dropped=0 pcs_dropped=0'):]
        cp = cp[:cp.index('')] if '' in cp else cp
        check(cp[1] == 'exclusive (top 50 of 4, listed 100.0% of the samples)' and
              cp[2:6] == [' 45.00%        9  -[Lock_wait:until_]', ' 35.00%        7  _ZN4beta3runEv',
                          ' 15.00%        3  gamma', '  5.00%        1  [jit]'],
              'exclusive: the app\'s functions by the map\'s names, the others by the headset\'s')
        check(cp[6] == 'inclusive (top 50 of 6)' and
              cp[7:13] == [' 95.00%       19  alpha', ' 65.00%       13  gamma', ' 45.00%        9  -[Lock_wait:until_]',
                           ' 35.00%        7  _ZN4beta3runEv', ' 30.00%        6  lib_system.dylib+0x200',
                           '  5.00%        1  [jit]'],
              'inclusive: a frame nothing names stays as it was written')
        check(cp[13] == 'stacks: listed 100.0% of the samples', 'the samples the stacks hold are told')
        with open(folded, encoding='utf-8') as stacks:
            stacks = stacks.read().splitlines()
        check(stacks == ['cp_thread;alpha;gamma;_ZN4beta3runEv 7',
                         'cp_thread;alpha;lib_system.dylib+0x200;-[Lock_wait:until_] 6',
                         'cp_thread;alpha;gamma 3',
                         'cp_thread;alpha;gamma;-[Lock_wait:until_] 3',
                         'cp_thread;[jit] 1',
                         'game_main;[jit] 20',
                         'game_main;[jit];alpha 10'],
              'the stacks are named, added up and put under their thread')

        code, zipped_out, _ = run(sample, write('map.txt.gz', MAP, zipped=True))
        check(code == 0 and zipped_out == out, 'a compressed map is read the same')

        code, late, _ = run(sample, plain, '--from', '30')
        check(code == 0 and 'thread cp_thread samples=8 seconds=30.0 missed=0 suspended=0.00% '
              'stacks_dropped=0 pcs_dropped=0' in late.splitlines() and 'game_main' not in late,
              '--from leaves out the intervals that ended before it')
        code, early, _ = run(sample, plain, '--to', '30')
        check(code == 0 and 'thread cp_thread samples=12 seconds=30.0 missed=2 suspended=2.00% '
              'stacks_dropped=0 pcs_dropped=0' in early.splitlines() and 'thread game_main samples=30' in early,
              '--to leaves out the intervals that started after it')
        code, _, err = run(sample, plain, '--from', '90')
        check(code != 0 and 'No whole interval' in err, 'a span with nothing whole in it is an error')

        code, top, _ = run(sample, plain, '--top', '1')
        check(code == 0 and ' 45.00%        9  -[Lock_wait:until_]' in top.splitlines() and
              ' 15.00%        3  gamma' not in top.splitlines(), '--top limits the lists')

        code, _, err = run(sample, write('other.txt', MAP.replace('0A1B', 'FFFF')))
        check(code != 0 and 'another build' in err, 'the map of another build is refused')
        code, no_uuid, err = run(sample, write('nouuid.txt', MAP.split('\n', 1)[1]))
        check(code == 0 and no_uuid == out and 'no UUID' in err, 'a map with no UUID is used, and said to be unchecked')
        code, _, err = run(sample, write('empty.txt', 'UUID: 0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9 (arm64) x\n'))
        check(code != 0 and 'no symbols' in err, 'a map with no symbols is an error')

        code, bare, _ = run(sample)
        bare = bare.splitlines()
        check(code == 0 and ' 35.00%        7  _ZN4beta3runEv' in bare and ' 95.00%       19  AstroQuest+0x1000' in bare,
              'without a map the headset\'s own symbols are used')

    print(f'{failures} failure(s)')
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
