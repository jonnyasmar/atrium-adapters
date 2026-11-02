---
kind: routine
id: atrium/role-scan
revision: 1
title: Role scan
summary: New roles that fit what you're after, ranked, each with why.
category: career
tags: [jobs, roles, job-search, career, linkedin, hiring]
icon: BriefcaseBusiness
target: director
mode: standing
schedule: { cron: "30 7 * * 1-5", tz: "{timezone}" }
scheduleLabel: Weekdays 7:30
params:
  - { key: target_roles, label: Roles you want, kind: text, help: "Titles or kinds of work, in your own words." }
  - { key: seniority, label: Level, kind: choice, options: ["entry level", "mid level", "senior", "staff or principal", "manager", "director or above"] }
  - { key: location, label: "Where you'd work", kind: text, help: "A city or region, remote, or both." }
needs:
  - id: linkedin
    label: LinkedIn
    why: search roles and see who you know at a company
    required: false
    anyOf: [{ login: www.linkedin.com }]
effects: [read, notify]
asksFirst: ["applying anywhere, or contacting a recruiter or company", "changing a profile"]
minAtrium: "0.351.0"
attribution: { author: atrium, license: CC0-1.0 }
---

## Prompt

Scan for new roles that fit the owner.

- Roles: {target_roles}
- Level: {seniority}
- Where: {location}

1. Search what you can reach for roles posted since your last pass: LinkedIn if the owner is signed in, company career pages, and any boards your playbook or notebook names.
2. Read each posting in full. Skip roles you've already shown the owner, ones they passed on, and ones that miss a must-have in your notebook.
3. Rank what's left, best fit first. For each: title, company, where, how long ago it was posted, the link, and one line on why it fits (and the gap, if there is one). Use anything your playbook adds.
4. Add them to the Roles part of your dashboard. Message the owner only if there's a strong new fit; otherwise stay quiet.

Never apply, contact a recruiter, or change the owner's profile.

If you can't reach a source you need, say so once, ask for access, and stop until the next pass.
