# AIODev agent entry point

Project knowledge and work tracking live in the Obsidian vault, not this repository.

Vault root: `C:\Users\chale\Obsidian Vaults\Main\Main`

Before project work, read these files from the vault:

- `AIODev/AIODev.md`: project home and current position.
- `AIODev/System/Organization.md`: note types, statuses, linking, and maintenance.
- `AIODev/System/Idea capture.md`: when to start owner requests and how to track them.
- `AIODev/Work/Work.md`: work dashboard; follow links to relevant individual records.
- `AIODev/Engineering Standards.md`: follow its links to applicable engineering rules.
- `AIODev/Validation Tooling/Recipes/Feature map.md`: current user-facing features
  and verification routes. Read the index at session start; before changing or
  verifying a feature, follow its entry to the relevant feature note and recipes.
  Update affected entries when user paths, prerequisites, or proof change.

Follow `AIODev/System/Idea capture.md#Purpose` for owner requests. Track the
request in a work item while carrying out the requested work.

Work items own status, dependencies, progress, and evidence. Update item properties,
dated progress, and evidence when status changes; maintain narrative navigation as
needed. Link exact note sections and
decision records. Keep accepted decisions and historical evidence intact.

Use ID-only work and decision filenames, such as WORK-029.md and D-032.md. Store
readable titles in the title property and heading, using a colon after the ID.
Use short phrases for other filenames; do not use em or en dash separators. Validate
links using Obsidian's trimmed targets, require nonempty destination notes, and check
section headings. Never allow trailing spaces or periods in filename stems.

The vault is a Git repository. Follow AIODev/System/Organization.md#Version control:
read a note before changing it, never reuse an existing ID or filename, leave others'
uncommitted changes alone, and when you finish changing notes, commit them in the vault
(stage only your paths, Conventional Commit message) before ending the turn.

Do all source work in your own git worktree and branch, never in this main checkout;
other sessions edit and commit here concurrently (vault: Reference/Engineering/Commits.md).
Commit completed, validated source work automatically using Conventional Commits.
All project Markdown belongs in the vault; AGENTS.md and CLAUDE.md are the narrow
exception for agent startup routing. Do not duplicate plans or backlogs here.
