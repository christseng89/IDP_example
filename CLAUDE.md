# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

This directory contains a Claude Skill archive (`cs-idp-propose.skill`) and its pre-generated output files. The skill generates Traditional Chinese IDP (Internal Developer Platform) / Platform Engineering deliverables.

The `.skill` file is a ZIP archive. Extract it to work with the source files:

```bash
unzip cs-idp-propose.skill
cd cs-idp-propose/
```

## Generating deliverables

Use `scripts/build.sh` from the extracted skill directory. Set `SKILL_DIR` to the extraction path.

```bash
# Generate all three deliverables (default)
bash scripts/build.sh [WORK_DIR] all

# Generate specific deliverable
bash scripts/build.sh [WORK_DIR] docx       # IDP 提案白皮書 (Word, ~18 pages)
bash scripts/build.sh [WORK_DIR] pptx       # IDP 提案簡報 (PowerPoint, 13 slides)
bash scripts/build.sh [WORK_DIR] backstack  # Backstack 架構指南 (Word, ~16 pages)
```

Or run generators directly:

```bash
# Step 1: render shared architecture diagram (needed for docx and pptx)
python3 assets/render_diagram.py

# Step 2: install npm deps
npm install docx       # for Word generators
npm install pptxgenjs  # for PowerPoint generator

# Step 3: run a generator
node assets/create_idp_doc.js        # → IDP_內部開發者平台.docx
node assets/create_idp_pptx.js       # → IDP_提案_簡報.pptx
node assets/create_backstack_doc.js  # → IDP_Backstack架構指南.docx
```

**Validate output page counts:**

```bash
libreoffice --headless --convert-to pdf <output>.docx
pdfinfo <output>.pdf | grep Pages
# Expected: whitepaper ~18, backstack ~16
```

## Architecture overview

Three JavaScript generators share a single reference architecture and style. Each runs with Node.js and outputs a fully-formatted document in one pass:

| Generator | Output | Key npm dep |
|---|---|---|
| `assets/create_idp_doc.js` | Word whitepaper, 18-page proposal | `docx` |
| `assets/create_idp_pptx.js` | PowerPoint pitch, 13 slides | `pptxgenjs` |
| `assets/create_backstack_doc.js` | Word guide focused on API lifecycle | `docx` |

`assets/render_diagram.py` generates `idp_arch_v2_final.png` (the shared architecture diagram) using Python PIL — it must run before the docx/pptx generators.

The `references/` directory contains the content library that all generators draw from — editing these files is the primary way to update content without touching generator code.

## Reference files

| File | Purpose |
|---|---|
| `references/architecture.md` | 五縱兩橫 six-layer framework |
| `references/cncf-tools-2026.md` | Authoritative CNCF tool status (Graduated/Incubating/Sandbox) |
| `references/api-lifecycle.md` | API v1→v2→v3 lifecycle, RFC 8594 Sunset Header patterns |
| `references/anti-patterns.md` | 8 IDP failure modes from CNCF Platforms WG + Humanitec |
| `references/maturity-model.md` | CNCF Platform Engineering Maturity Model v1.0 |
| `references/style-guide.md` | Editorial conventions (tone, punctuation, color palette) |
| `references/section-templates.md` | Per-chapter blueprints for the whitepaper |
| `references/glossary.md` | 30-term bilingual glossary |
| `references/pptx-design.md` | PowerPoint layout and color rules |
| `references/diagram-design.md` | Architecture diagram customization |

## Key content conventions

**CNCF status** — always cite on first mention with status + year:
- Argo CD (CNCF Graduated, 2022-12) — official spelling has a space
- Crossplane (CNCF Graduated, 2024-10), Kyverno (CNCF Graduated, 2024-11)
- Istio (CNCF Graduated, 2024-08), Cilium (CNCF Graduated, 2023-10)
- Backstage (CNCF Incubating), OpenTelemetry (CNCF Incubating)
- NOT CNCF (label explicitly): Grafana, Kong, Apigee, Port, Humanitec

**Bilingual first-mention**: `降低認知負擔（Cognitive Load Reduction）` — English in full-width parentheses, Chinese-only on subsequent mentions.

**Tone**: neutral (`選用考量` not `推薦理由`); cite CNCF/DORA/Humanitec for adoption claims; no emojis in any output.

**Punctuation**: full-width Chinese (`，。：；「」（）`); em-dash as `——` (doubled full-width).

**Document styling** (baked into generators, do not change ad hoc):
- Body: 9.5pt single line spacing
- H1: 16pt bold `#1F3A5F`, page break before
- H2: 13pt bold `#2F5496`, H3: 11.5pt bold `#1F3864`
- Table headers: navy `#1F3A5F` + white bold; alternating rows white/`#F4F9FC`
- Code blocks: Consolas 9pt, `#F2F4F7` background
