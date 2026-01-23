# Documentation Conventions

## Goals

- Keep docs actionable for future iterations.
- Make every behavior traceable back to code paths and data.
- Avoid leaking secrets; use placeholders and redaction guidance.

## Naming

- Folder: `doc/` at repository root.
- File names:
  - English: `NN-topic-in-kebab-case.md`
  - Chinese: `NN-topic-in-kebab-case.zh-CN.md`
- Keep numbering stable; append new topics using the next number.

## Content Structure

Use this structure unless the document is a short note:

1. Purpose
2. Scope / Non-goals
3. Terminology
4. High-level Flow (prefer Mermaid for complex flows)
5. Key Types & Responsibilities (map to files/classes)
6. Error Handling
7. Security & Privacy Notes
8. Operational Notes (paths, configs, toggles)
9. Verification (tests, manual checks)

## Code References

- Use relative paths in docs (e.g. `Sources/VoiceMemo/AudioRecorder.swift`).
- When referencing key functions/types, include the file path and the identifier name.

## Secrets & PII

- Never paste real AccessKeyId / AccessKeySecret / AppKey into docs.
- Use placeholders like:
  - `AK_ID=...`
  - `AK_SECRET=...`
  - `TINGWU_APPKEY=...`

