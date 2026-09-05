Agent: zeus
Task: SMOKE TEST — confirm opencode CLI is functional. Write exactly one file, then STOP.

Repo: /home/santhosh/projects/Noir-Android-app
Deliverables (exact path):
  1. /home/santhosh/projects/Noir-Android-app/.noir/smoke_test_marker.txt — content: "smoke_test_passed_v1\n"

Constraints:
  - Write this single file in ONE tool call, then run `ls -la .noir/smoke_test_marker.txt` and STOP.
  - Do NOT run flutter, do NOT touch any other files, do NOT analyze the repo.
  - Do NOT read SOURCE_OF_TRUTH.md, do NOT run git status beyond confirming the file was created.
  - First output = the tool call to create the file. Zero commentary lines.

Self-review: confirm the file exists with the exact content above. Report in <=3 lines, then STOP.
