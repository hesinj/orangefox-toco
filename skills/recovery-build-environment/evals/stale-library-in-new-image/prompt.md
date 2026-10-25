---
tags: [recovery-build-environment]
max_turns: 20
timeout_seconds: 600
allowed_tools: [Read, Glob, Grep, Skill, Write, Edit, Bash]
---

I removed libops.so from my device tree because it pulled in the display stack, rebuilt, and the new recovery image still has it. And my nocrypt image seems to contain decryption init files. What is going on, and how do I make sure it never happens again?
