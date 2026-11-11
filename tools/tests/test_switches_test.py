#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
#
# The table of the settings' «Pruebas» switches (visionos/App/Core/TestSwitches.swift) against the
# code: every row is in the table's one-line form, no id and no variable is there twice, and each
# variable is read (the first argument of a call that is not setenv / unsetenv / putenv) by the
# emulator's sources or by the sources of VPKEngine's gpu the app builds.
#
#   python3 tools/tests/test_switches_test.py <VPKEngine checkout, or its gpu folder>
#
# Ends with 0 when all is well; else it says what is not and ends with 1.

import pathlib
import re
import sys

ROW = re.compile(
    r'^\s*TestSwitch\(id: "([a-z0-9_]+)", title: "([^"\\]+)", variable: "([A-Z][A-Z0-9_]*)", '
    r'value: "([^"\\\s]+)", on: (true|false)\),$'
)
READ = re.compile(r'(\w+)\(\s*"([A-Z][A-Z0-9_]*)"\s*[,)]')
WRITERS = {"setenv", "unsetenv", "putenv"}
SUFFIXES = {".cpp", ".h", ".hpp", ".mm", ".m", ".c", ".inc"}


def variables_read(folders):
    """The variables read under `folders`, each with the first file that reads it."""
    found = {}
    for folder in folders:
        for path in sorted(folder.rglob("*")):
            if path.suffix not in SUFFIXES or "tests" in path.parts or not path.is_file():
                continue
            for call, name in READ.findall(path.read_text(encoding="utf-8", errors="replace")):
                if call not in WRITERS:
                    found.setdefault(name, path)
    return found


def main():
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <VPKEngine checkout, or its gpu folder>")
        return 1
    repo = pathlib.Path(__file__).resolve().parents[2]
    table = repo / "visionos/App/Core/TestSwitches.swift"
    gpu = pathlib.Path(sys.argv[1])
    if (gpu / "gpu").is_dir():
        gpu = gpu / "gpu"
    # (what shadps4-arm64-main/CMakeLists.txt builds of VPKEngine's gpu)
    engine = [gpu / "core", gpu / "metal2", gpu / "ps4", gpu / "shader/ir", gpu / "shader/msl", gpu / "shader/gcn"]
    problems = [f"{folder}: no such folder" for folder in engine if not folder.is_dir()]
    if not table.is_file():
        problems.append(f"{table}: no table")
    if problems:
        print("\n".join(problems))
        return 1

    rows = []
    for number, line in enumerate(table.read_text(encoding="utf-8").splitlines(), 1):
        if "TestSwitch(" not in line or line.lstrip().startswith("//"):
            continue
        match = ROW.match(line)
        if match is None:
            problems.append(f"{table.name}:{number}: not in the table's form: {line.strip()}")
        else:
            rows.append((number, match.group(1), match.group(3)))
    if not rows:
        problems.append(f"{table.name}: no switches")

    read = variables_read(engine + [repo / "shadps4-arm64-main/src"])
    ids, variables = set(), set()
    for number, name, variable in rows:
        if name in ids:
            problems.append(f"{table.name}:{number}: the id {name} is there twice")
        if variable in variables:
            problems.append(f"{table.name}:{number}: the variable {variable} is there twice")
        ids.add(name)
        variables.add(variable)
        if variable not in read:
            problems.append(f"{table.name}:{number}: nothing reads {variable}")

    if problems:
        print("\n".join(problems))
        return 1
    print(f"test_switches_test: {len(rows)} switches, each variable is read")
    return 0


if __name__ == "__main__":
    sys.exit(main())
