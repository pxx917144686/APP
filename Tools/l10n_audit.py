#!/usr/bin/env python3
import re, sys, glob, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = os.path.join(ROOT, "APP", "Resources")

def parse_strings(path):
    text = open(path, encoding="utf-8-sig", errors="ignore").read()
    return {m.group(1): m.group(2)
            for m in re.finditer(r'"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', text, re.S)}

def placeholders(s):
    return sorted(re.findall(r'%(?:\d+\$)?[@difs]|%\.\d+f', s))

used = {}
for base in ("APP", "Shared", "APPWidget"):
    for path in glob.glob(os.path.join(ROOT, base, "**", "*.swift"), recursive=True):
        rel = os.path.relpath(path, ROOT)
        for i, line in enumerate(open(path, encoding="utf-8", errors="ignore"), 1):
            for pat in (r'"([A-Za-z0-9_.]+)"\s*\.localized',
                        r'LanguageManager\.localized\(\s*"([A-Za-z0-9_.]+)"',
                        r'NSLocalizedString\(\s*"([A-Za-z0-9_.]+)"',
                        r'String\(localized:\s*"([A-Za-z0-9_.]+)"'):
                for m in re.finditer(pat, line):
                    used.setdefault(m.group(1), f"{rel}:{i}")

langs = {}
for path in sorted(glob.glob(os.path.join(RES, "*.lproj", "Localizable.strings"))):
    langs[os.path.basename(os.path.dirname(path)).replace(".lproj", "")] = parse_strings(path)

if "en" not in langs:
    sys.exit("en.lproj/Localizable.strings not found")
en = langs["en"]

print(f"keys used in code: {len(used)}   keys in en: {len(en)}   languages: {len(langs)}")

failed = False
missing = sorted(k for k in used if k not in en)
if missing:
    failed = True
    print(f"\nen uses keys missing from en.lproj ({len(missing)}):")
    for k in missing:
        print(f"  {k}  <- {used[k]}")

for lang, table in langs.items():
    if lang == "en":
        continue
    miss = [k for k in en if k not in table]
    extra = [k for k in table if k not in en]
    phbad = [k for k in en if k in table and placeholders(en[k]) != placeholders(table[k])]
    if miss or extra or phbad:
        failed = True
        print(f"\n{lang}: missing={len(miss)} extra={len(extra)} placeholder_mismatch={len(phbad)}")
        for k in miss[:10]:
            print(f"  missing  {k}")
        for k in extra[:10]:
            print(f"  extra    {k}")
        for k in phbad[:10]:
            print(f"  format   {k}: {placeholders(table[k])} vs {placeholders(en[k])}")

unused = sorted(k for k in en if k not in used)
print(f"\nunused keys in en (not referenced by code): {len(unused)}")

if failed:
    print("\nRESULT: FAILED")
    sys.exit(1)
print("\nRESULT: OK — every language matches en.lproj")
