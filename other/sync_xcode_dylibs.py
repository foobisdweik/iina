#!/usr/bin/env python3
"""Make the dylib references in iina.xcodeproj match the files in deps/lib.

The Xcode project lists every dylib by its exact file name, for example
libplacebo.360.dylib. When a dependency changes its major version, the file
name changes (libplacebo.387.dylib), and Xcode stops the build because the old
file is missing. When the dependency set changes, new dylibs must also be
linked and copied into the app bundle.

This script compares deps/lib with the project and then:
  * renames a reference when only the version part of a dylib name changed,
  * adds a dylib that is in deps/lib but not in the project, by copying the
    six project entries of an existing dylib with new object IDs,
  * removes a dylib that is in the project but not in deps/lib.

Each dylib in the project has exactly six entries: a file reference, an entry
in the Frameworks group, a build file and an entry for the "Link Binary With
Libraries" phase, and a build file and an entry for the "Copy Dylibs" phase.

Usage:
  other/sync_xcode_dylibs.py           update the project
  other/sync_xcode_dylibs.py --check   only report, exit with status 1 if the
                                       project does not match deps/lib
"""

import argparse
import os
import re
import secrets
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJECT = os.path.join(ROOT, "iina.xcodeproj", "project.pbxproj")
LIB_DIR = os.path.join(ROOT, "deps", "lib")

ENTRIES_PER_DYLIB = 6
FILE_REF_RE = re.compile(
    r'^\s*([0-9A-F]{24}) /\* (\S+\.dylib) \*/ = \{isa = PBXFileReference;.*path = "?deps/lib/\2"?;')
BUILD_FILE_RE = re.compile(
    r"^\s*([0-9A-F]{24}) /\* (\S+\.dylib) in [^*]+\*/ = \{isa = PBXBuildFile; fileRef = ([0-9A-F]{24}) ")
STEM_RE = re.compile(r"^(.*?)(?:\.\d+)*\.dylib$")
# The values of "name = ...;" and "path = ...;" in a project entry.
VALUE_RE = re.compile(r'\b(name|path) = ("?)([^";]+)\2;')
# Xcode writes a value without quotes only when it has no other characters than these.
UNQUOTED_RE = re.compile(r"^[A-Za-z0-9_./]+$")


def stem(name):
    """Return the dylib name without its version, for example libplacebo for libplacebo.360.dylib."""
    return STEM_RE.match(name).group(1)


def replace_name(line, old, new):
    """Replace a dylib name in one project entry, and quote name and path values the way Xcode does."""
    line = line.replace(old, new)
    return VALUE_RE.sub(lambda m: f"{m.group(1)} = {m.group(3) if UNQUOTED_RE.match(m.group(3)) else chr(34) + m.group(3) + chr(34)};", line)


def fail(message):
    print(f"error: {message}", file=sys.stderr)
    sys.exit(2)


def find_dylibs(lines):
    """Return {dylib name: set of object IDs} for every dylib in the project."""
    file_refs = {}
    for line in lines:
        m = FILE_REF_RE.match(line)
        if m:
            file_refs[m.group(2)] = m.group(1)
    ids = {name: {ref} for name, ref in file_refs.items()}
    ref_to_name = {ref: name for name, ref in file_refs.items()}
    for line in lines:
        m = BUILD_FILE_RE.match(line)
        if m and m.group(3) in ref_to_name:
            ids[ref_to_name[m.group(3)]].add(m.group(1))
    return ids


def lines_with_ids(lines, ids):
    return [i for i, line in enumerate(lines) if any(obj_id in line for obj_id in ids)]


def new_object_id(text, taken):
    while True:
        obj_id = secrets.token_hex(12).upper()
        if obj_id not in text and obj_id not in taken:
            taken.add(obj_id)
            return obj_id


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true", help="report differences without changing the project")
    args = parser.parse_args()

    if not os.path.isdir(LIB_DIR):
        fail(f"{LIB_DIR} does not exist. Download or build the dependencies first.")
    on_disk = sorted(f for f in os.listdir(LIB_DIR)
                     if f.endswith(".dylib") and not os.path.islink(os.path.join(LIB_DIR, f)))
    if not on_disk:
        fail(f"{LIB_DIR} has no dylibs. Download or build the dependencies first.")

    with open(PROJECT, encoding="utf-8") as f:
        text = f.read()
    lines = text.splitlines(keepends=True)
    in_project = find_dylibs(lines)
    if not in_project:
        fail("no dylib references found in the project")
    for name, ids in in_project.items():
        count = len(lines_with_ids(lines, ids))
        if len(ids) != 3 or count != ENTRIES_PER_DYLIB:
            fail(f"unexpected project structure for {name}: {len(ids)} IDs, {count} entries")

    disk_by_stem, project_by_stem = {}, {}
    for name in on_disk:
        if stem(name) in disk_by_stem:
            fail(f"deps/lib has two versions of {stem(name)}: {disk_by_stem[stem(name)]} and {name}")
        disk_by_stem[stem(name)] = name
    for name in in_project:
        project_by_stem[stem(name)] = name

    renames = [(project_by_stem[s], disk_by_stem[s]) for s in sorted(disk_by_stem)
               if s in project_by_stem and project_by_stem[s] != disk_by_stem[s]]
    additions = [disk_by_stem[s] for s in sorted(disk_by_stem) if s not in project_by_stem]
    removals = [project_by_stem[s] for s in sorted(project_by_stem) if s not in disk_by_stem]

    if not (renames or additions or removals):
        print("The Xcode project already matches deps/lib.")
        return 0
    for old, new in renames:
        print(f"rename  {old} -> {new}")
    for name in additions:
        print(f"add     {name}")
    for name in removals:
        print(f"remove  {name}")
    if args.check:
        print("The Xcode project does not match deps/lib. Run other/sync_xcode_dylibs.py to update it.")
        return 1

    # Rename: replace the name only in the six entries of that dylib.
    for old, new in renames:
        for i in lines_with_ids(lines, in_project[old]):
            lines[i] = replace_name(lines[i], old, new)

    # Add: copy the entries of a template dylib that stays in the project, with new IDs and the new name.
    if additions:
        template = next(n for n in sorted(in_project) if n not in removals and stem(n) in disk_by_stem)
        template_name = dict(renames).get(template, template)
        template_ids = sorted(in_project[template])
        taken = set()
        for name in additions:
            id_map = {old_id: new_object_id(text, taken) for old_id in template_ids}
            result = []
            for line in lines:
                result.append(line)
                if any(old_id in line for old_id in template_ids):
                    copy = replace_name(line, template_name, name)
                    for old_id, new_id in id_map.items():
                        copy = copy.replace(old_id, new_id)
                    result.append(copy)
            lines = result

    # Remove: drop the six entries of each dylib that is no longer in deps/lib.
    for name in removals:
        drop = set(lines_with_ids(lines, in_project[name]))
        lines = [line for i, line in enumerate(lines) if i not in drop]

    # Check the result before writing it.
    final = find_dylibs(lines)
    if sorted(final) != on_disk:
        fail(f"internal error: the project would list {sorted(final)}, expected {on_disk}")
    for name, ids in final.items():
        if len(ids) != 3 or len(lines_with_ids(lines, ids)) != ENTRIES_PER_DYLIB:
            fail(f"internal error: wrong number of entries for {name}")

    with open(PROJECT, "w", encoding="utf-8") as f:
        f.write("".join(lines))
    print("Updated iina.xcodeproj to match deps/lib.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
