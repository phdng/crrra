# IDA Export Coverage

Method is reproducible via `tools/prove_export_identity.py`.

## 1. Which binary does each export belong to?

Each `*_export_for_ai/memory/START--END.txt` file is a hex+ASCII dump of the
analyzed image, keyed by virtual address. Those bytes were compared against
**every** fat slice of the candidate binary using the slice's own
segment vaddr→file-offset map. Result:

| Export directory | Candidate binary | Slice | `__text` match | Arm64e match | Verdict |
|---|---|---|---:|---:|---|
| ` Crane.dylib_export_for_ai` | `Library/MobileSubstrate/DynamicLibraries/ Crane.dylib` | 0 (arm64) | **5020/5020 = 100.000%** | 606/5264 = 11.512% | IDENTIFIED |
| `CraneSB.dylib_export_for_ai` | `.../CraneSB.dylib` | 0 (arm64) | **104212/104212 = 100.000%** | 12446/108740 = 11.446% | IDENTIFIED |
| `CraneSupport.dylib_export_for_ai` | `.../CraneSupport.dylib` | 0 (arm64) | **87048/87048 = 100.000%** | 8658/90912 = 9.523% | IDENTIFIED |
| `CranePrefs_export_for_ai` | `Library/PreferenceBundles/CranePrefs.bundle/CranePrefs` | 0 (arm64) | **233000/233000 = 100.000%** | 24216/239920 = 10.093% | IDENTIFIED |
| `CraneApplication_export_for_ai` | `Applications/CraneApplication.app/CraneApplication` | 0 (arm64) | **1620/1620 = 100.000%** | n/a (thin binary) | IDENTIFIED |

Identified UUIDs (arm64 slice, LC_UUID load command, CONFIRMED_STATIC):

| Binary | arm64 UUID | arm64e UUID |
|---|---|---|
| ` Crane.dylib` | `a222ac90-27f6-3fca-b8be-7fd4561df577` | `f22b61c6-76f8-37a3-959d-6393e15902c4` |
| `CraneSB.dylib` | `6e732c16-8065-3ba0-aa73-0454d9fe1ce7` | `cc2bd1e2-55f8-3785-bf4b-9f471f83f7da` |
| `CraneSupport.dylib` | `a1f4f544-d5f2-3f58-952c-9fe38883915e` | `cc9b44fc-3bad-38f1-9447-c90c32427606` |
| `CranePrefs` | `a265f862-7754-3217-9868-6b51073fc662` | `bde452d5-e8bc-375e-bf46-aa1ab73cfc7f` |
| `CraneApplication` | `6abe3d9b-4dfc-3d32-8cf7-452320484259` | — |

### Why a lower overall match is expected

Whole-image comparison gives 97–98% rather than 100% because the dumps come
from an image on which the loader applied relocations. The differences are
confined to exactly the sections that legitimately differ:

`tools/section_diff.py` output, per section:

| Section class | Match |
|---|---|
| `__TEXT,__text` | **100.000%** for every binary |
| `__TEXT,__cstring`, `__objc_methname`, `__objc_classname`, `__objc_methtype`, `__unwind_info`, `__gcc_except_tab`, `__eh_frame`, `__stubs`, `__stub_helper`, `__const` | **100.000%** |
| `__DATA,__objc_const`, `__objc_selrefs`, `__data`, `__objc_ivar`, `__objc_classlist`, `__objc_superrefs`, `__objc_protolist`, `__objc_protorefs`, `__objc_imageinfo`, `__mod_init_func` | 100% |
| `__DATA,__bss`, `__common` | 0% — zero on disk, populated by IDA |
| `__DATA,__got`, `__la_symbol_ptr`, `__objc_classrefs`, `__objc_data`, `__cfstring`, `__const` | 62–99% — pointer / CFConstantString rebasing |

No executable byte differs. That is what makes the identity claim
CONFIRMED_STATIC rather than INFERRED.

## 2. Is the export complete?

`.export_progress` declares `done` for **every** address in all five
directories (no `fallback`, `failed`, or `skipped` entries), and the number of
`decompile/*.c` files equals the `# Total exported:` line in
`function_index.txt`:

| Export dir | `.export_progress` statuses | `# Total exported` | `decompile/*.c` | Parsed records |
|---|---|---:|---:|---:|
| ` Crane.dylib` | done=68 | 68 | 68 | 68 |
| `CraneSB.dylib` | done=538 | 538 | 538 | 538 |
| `CraneSupport.dylib` | done=624 | 624 | 624 | 624 |
| `CranePrefs` | done=1368 | 1368 | 1368 | 1368 |
| `CraneApplication` | done=53 | 53 | 53 | 53 |
| **Total** | | **2651** | **2651** | **2651** |

`disassembly/` exists in all five directories but is **empty**. So the only
instruction-level evidence available is inside the Hex-Rays output (IDA
inlined a `c` file per function) plus the raw `memory/` dumps. That is
sufficient to reason about control flow, but it means there is no independent
disassembly to cross-check decompiler errors against.

## 3. File-level inventory

`analysis/ida_export_inventory.md` is generated per directory with exact file
counts. Summary of subdirectories:

| Export dir | `memory/` | `decompile/` | `disassembly/` | root files |
|---|---:|---:|---:|---:|
| ` Crane.dylib` | 25 | 68 | 0 (empty) | 6 |
| `CraneSB.dylib` | 32 | 538 | 0 (empty) | 6 |
| `CraneSupport.dylib` | 30 | 624 | 0 (empty) | 6 |
| `CranePrefs` | 32 | 1368 | 0 (empty) | 6 |
| `CraneApplication` | 23 | 53 | 0 (empty) | 6 |

Root files are `.export_progress`, `exports.txt`, `function_index.txt`,
`imports.txt`, `pointers.txt`, `strings.txt`.

## 4. What the exports do and do not tell us

Reliable, and used as the primary evidence throughout this project:

- The exact call/edge graph between 2651 functions
  (`analysis/callers_index.csv`).
- Function bodies as decompiled C, with named locals, resolved ObjC class and
  selector `msgSend` calls, `CFSTR` literals, and `objc_getClass` class names.
- Hook registration sites: the exact class, selector, hook function and
  original-storage symbol for every `MSHookMessageEx`, `MSHookFunction`,
  `class_addMethod`, `HCHookFunctions` and `initUNProtocol` registration
  (159 registrations, `analysis/hooks_index.csv`).
- Module constructors (`InitFunc_0/1/2`) and per-process init entry points.
- String tables (`analysis/strings_index.csv`, 3667 rows) — paths, preference
  keys, notification names, localization keys.

Known limitations, recorded so they are not mistaken for gaps in the analysis:

1. **Selector/class names on hook targets are exact** because they appear as
   string literals at the registration site. **Type encodings** are frequently
   absent (`objc_msgSend` sites lose the encoding).
2. Hex-Rays occasionally mis-types `objc_msgSend` receivers; several functions
   read `-[NSString isEqualToString:]` where the source clearly called it
   *on* an `NSString` instance. Receiver typing is therefore treated as
   advisory, and any behaviour claim that depends on it is marked INFERRED.
3. `__DATA` values in the dumps are post-reload; do not cite dump contents for
   global initial values.
4. **Six binaries have no export at all**, most importantly
   `usr/lib/libcrane.dylib`. Behaviour that lives only there (container
   registry, backup/restore, keychain, XPC client) is UNKNOWN beyond its API
   surface.

## 5. Reuse policy applied

No decompilation was re-run. The exports were used as-is. All new work was
either (a) indexing the existing files (`build_export_index.py`,
`extract_hooks.py`, `pref_schema.py`, `pref_access.py`, `crane_api.py`),
(b) parsing the on-disk Mach-O to fill what the exports do not carry
(`macho_inspect.py`, `objc_classes.py` — used mainly for the six
unexported binaries and to cross-check the exported ones), or (c) the
byte-level identity proof in `prove_export_identity.py`.