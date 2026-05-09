# Project conventions for Claude Code

This file is auto-loaded by Claude Code at session start when working in this
repository.
Conventions documented here apply to all work in this repo unless explicitly
overridden in a session.

## Markdown style — semantic line breaks (sembr)

Write all new markdown using semantic line breaks
([sembr.org](https://sembr.org)).
Each line ends at a clause or sentence boundary; the rendered output is
unchanged because markdown collapses single newlines into spaces.

Why:
edits land on a single line, so `git diff` shows only the changed clause instead
of reflowing the whole paragraph.
Code review and prose editing become much cleaner.

Rules:

- Break the line at every period, semicolon, em-dash, and most commas.
- One sentence per line is the floor; one clause per line is the ceiling.
- Don't break inside code fences, tables, link refs, or HTML blocks.
- Don't reflow existing files unless you're editing them for substantive
  reasons.
  Bulk-reformatting churns diffs without functional benefit.
- The `mdslw` tool (`pre-commit run mdslw --all-files`) enforces this on staged
  `.md` files; authoring directly in sembr matches what the tool produces.

The pre-commit hook will reformat staged markdown automatically; authoring in
sembr from the start avoids surprise diffs at commit time.

## Other repo-specific conventions

The full set of conventions is documented across `docs/`; load relevant docs
when the task touches the area:

- Service / file naming:
  `aorus-egpu-*` for userspace, `tb_egpu_*` / `NVreg_TbEgpu*` / `TB_EGPU_*` for
  driver-internal.
  Run `tools/lint-identifiers.sh` before commits to catch drift.
- Service retirements:
  preserve binary + unit on disk as documented archive; document retirement in
  `docs/service-retirement-roadmap.md` and a memory entry.
- Lever catalog discipline:
  every reliability lever gets a permanent spec entry in
  `docs/lever-catalog.md`.
- Reliability methodology:
  one variable per test, written hypothesis, n>=3 to resolve, cheaper
  experiments first.
  Living ledger at `docs/reliability-hypothesis-ledger.md`.
