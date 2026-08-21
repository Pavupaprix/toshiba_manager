<!--
Sync Impact Report
==================
Version change: (unratified template) → 1.0.0
Rationale: Initial ratification. Prior file held only unfilled template
placeholders ([PROJECT_NAME], [PRINCIPLE_1_NAME], ...), so no prior
governance version existed. This is a first adoption, not an amendment.

Modified principles: n/a (first fill)
Added sections:
  - Core Principles I–V (Simplicity First, Data Safety & Confidentiality,
    French-First UX Consistency, Toshiba XML Template Integrity,
    Manual Verification Over Automated Suite)
  - Technology Constraints
  - Development Workflow
  - Governance
Removed sections: none

Templates requiring updates (read this constitution at runtime; not
modified by this command):
  - .specify/templates/plan-template.md — ⚠ pending manual check for
    alignment with Principles I/IV/V (simplicity gate, XML validation,
    manual verification gate)
  - .specify/templates/spec-template.md — ⚠ pending manual check
  - .specify/templates/tasks-template.md — ⚠ pending manual check

Deferred items: none. RATIFICATION_DATE set to today per project owner
context (first real adoption date); revise if an earlier true adoption
date is later identified.
-->

# ToshibaManager Constitution

## Core Principles

### I. Simplicity First (YAGNI)
ToshibaManager is a small internal Flask tool (address book, SMTP test,
Toshiba scan-to-email XML template editor) used by OMB Informatique.
New code MUST prefer the simplest solution that solves the actual
request. No new framework, service, database engine, or abstraction
layer may be introduced unless the existing Flask + flat-file/XLSX
approach demonstrably cannot meet the requirement. Speculative
generalization ("might need it later") is not sufficient justification.

**Rationale**: Single-purpose internal tool with one primary
maintainer; unused flexibility only adds maintenance cost.

### II. Data Safety & Confidentiality
Address-book contacts, SMTP credentials, and any uploaded files
(`uploads/`) contain real customer/contact data and mail-server
secrets. Secrets MUST NOT be hardcoded in source or templates; they
MUST be read from configuration/environment, not committed to version
control. Files under `uploads/` MUST stay excluded from version
control. Any feature that transmits data externally (SMTP send, file
export) MUST be traceable to an explicit user action — no silent
background transmission.

**Rationale**: The app handles real contact and mail-credential data;
a leak or accidental commit has direct consequences for OMB
Informatique and its clients.

### III. French-First UX Consistency
User-facing text (templates, flash/error messages, button labels) MUST
be written in French and MUST match the tone/branding already used in
`templates/` (e.g. `hub.html`, `addressbook.html`, `parametrage.html`)
and the OMB Informatique logo/branding assets already in `static/`.
New pages MUST reuse the existing layout/CSS patterns rather than
introduce a divergent style.

**Rationale**: The tool is used by French-speaking staff; consistent
language and look keeps the internal hub coherent as pages accumulate.

### IV. Toshiba XML Template Integrity
Code that reads, edits, or writes the Toshiba scan-to-email/address-book
XML (`modele_xml/template_base.xml` and any generated variant) MUST
keep the output well-formed XML and MUST preserve the element
structure the physical Toshiba multifunction device expects. Before a
template is considered done, it MUST be validated (parses via
`xml.etree.ElementTree` or equivalent, then round-tripped through the
app's load/export path) — a broken template only surfaces as a failure
on the physical scanner, which is expensive to diagnose after the
fact.

**Rationale**: The XML is consumed by hardware outside this codebase;
correctness cannot be caught by the device until deployed, so it must
be caught here first.

### V. Manual Verification Over Automated Suite (NON-NEGOTIABLE)
This project currently has no automated test suite. Every change that
touches a route, template, XML generation, or SMTP flow MUST be
manually verified by running the app (`app.py`) and exercising the
affected page/flow end-to-end before being considered complete. If a
change is later covered by an automated test, the test MUST be added
rather than removed; automated coverage may only grow, never be
deleted to "save time."

**Rationale**: Without CI, manual smoke verification is the only
safety net; skipping it lets regressions reach production silently.

## Technology Constraints

Stack is Python + Flask, server-rendered Jinja templates, static
JS/CSS, and flat XML/XLSX files for data — no database engine. New
dependencies (Python packages, JS libraries) MUST be justified against
Principle I before being added to the project. Uploaded and generated
runtime files (`uploads/`, `__pycache__/`, screenshots) stay out of
version control via `.gitignore` (or the project's ignore
configuration once one exists).

## Development Workflow

Changes are made and verified locally by running `app.py` and clicking
through the affected flow (hub → target page → action) before being
treated as done, per Principle V. XML template changes are additionally
checked by loading them back through the app's "load default" / export
endpoints per Principle IV. Since this is a single/small-maintainer
project without CI, the author is responsible for this verification
before considering work complete — there is no separate reviewer gate.

## Governance

This constitution supersedes ad hoc practice for ToshibaManager. Any
change to these principles is an amendment: it MUST update this file,
bump the version per semantic versioning (MAJOR for incompatible
principle removal/redefinition, MINOR for a new/materially expanded
principle or section, PATCH for wording/clarification), and update
`Last Amended`. Feature plans, specs, and tasks generated by Spec Kit
commands MUST remain consistent with these principles; a plan that
conflicts with a principle MUST either be revised or the conflict
explicitly justified in that plan's own complexity-tracking section.

**Version**: 1.0.0 | **Ratified**: 2026-08-20 | **Last Amended**: 2026-08-20
