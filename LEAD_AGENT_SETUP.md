# Setting Up the Wonni Lead Agent

This guide explains how to set up autonomous nightly work on your Wonni project using a lead agent pattern.

## What This Does

Every night at 2 AM:
1. Lead agent checks GitHub for new issues
2. Picks top 2-3 bugs/features to work on
3. Spawns focused sub-agents to implement fixes
4. Collects results and creates a summary
5. **Notifies YOU with ONE message:** "X issues fixed, PR ready at [link]"

You only get pinged when there's work ready to review. No constant updates.

---

## Setup Steps

### Step 1: Commit the lead agent prompt

The LEAD_AGENT_PROMPT.md file is already committed. This is the personality/instructions for your lead agent.

### Step 2: Schedule the nightly run

In your terminal, run ONE of these commands:

**Option A: Using Claude Code CLI (simplest)**
```bash
cd /Users/jerryshi/Documents/GitHub/wonni
claude schedule "work on wonni nightly" --cron "0 2 * * *"
```

**Option B: Using the /schedule skill in Claude Code**

Open Claude Code and type:
```
/schedule "Run nightly Wonni lead agent to triage issues, spawn sub-agents for bugs, and prepare summary PR" --cron "0 2 * * *"
```

The cron schedule `0 2 * * *` means:
- 0 = minute (0)
- 2 = hour (2 AM)
- * = every day
- * = every month
- * = every day of week

### Step 3: Configure the lead agent prompt

When you run /schedule, you'll get a scheduled agent. That agent should use this system prompt:

```
You are the Wonni Lead Agent. Read LEAD_AGENT_PROMPT.md from the repo for your full instructions.

Your job: Work autonomously on Wonni during off-hours.

Tasks:
1. cd to /Users/jerryshi/Documents/GitHub/wonni
2. Check GitHub: gh issue list --state open --limit 10
3. Read LEAD_AGENT_PROMPT.md for full instructions
4. Triage issues by severity
5. Spawn sub-agents for top 2-3 items
6. Collect results and create summary PR
7. Notify Jerry with ONE message: "X issues done, PR ready at [link]"

Rules:
- Work autonomously, don't ask for approval on normal decisions
- Only escalate critical bugs immediately (don't wait for morning)
- Batch everything else into ONE summary message
- All code must pass tests before notifying Jerry
```

### Step 4: Test it (optional)

Want to test the lead agent before the 2 AM run? Run this manually:

```bash
/loop "Run Wonni lead agent: check issues, spawn sub-agents, prepare summary"
```

This will run it immediately so you can see how it works.

---

## How It Works

### The Flow Each Night

```
2:00 AM → Lead Agent wakes up
  ↓
Check GitHub issues
  ↓
Triage (bugs → features → chores)
  ↓
Spawn Agent #1 (fix issue #2)
Spawn Agent #2 (fix issue #4)
  ↓
Wait for sub-agents to complete
  ↓
Collect branches & summaries
  ↓
Run tests on everything
  ↓
Create summary PR with all changes
  ↓
Send message to Jerry:
"✅ 2 bugs fixed
  - Issue #2: Fixed X
  - Issue #4: Fixed Y
  
PR ready: github.com/jerrashi/wonni/pull/123"
```

### What You'll Receive

Each morning, ONE notification:

```
🌙 Nightly Work Summary

✅ Completed:
- Issue #2 (bug): Select multiple drafts + edit
- Issue #4 (enhancement): Listing drafts screen sluggish

📊 Tests: All passing
🔗 PR: github.com/jerrashi/wonni/pull/123

Next steps: Review PR, approve, or request changes
```

No other notifications. Just one summary when work is ready.

---

## What the Lead Agent Can Do

### ✅ YES - Do these without asking:
- Fix bugs from open issues
- Implement features from backlog
- Write tests for changes
- Update documentation
- Create branches and PRs
- Run existing tests
- Review and suggest improvements to code

### ❌ NO - Ask for approval first:
- Delete code/features
- Breaking changes to APIs
- Merge to main (create PR, wait for you)
- Deploy to production
- Change architecture fundamentally

### 🚨 ESCALATE IMMEDIATELY:
- Security vulnerabilities
- Data loss risks
- Main branch broken
- Tests failing

---

## Customization

### Change the schedule

Edit the cron expression:
- `0 2 * * *` = 2 AM every day (default)
- `0 2 * * 1-5` = 2 AM weekdays only
- `0 10 * * *` = 10 AM every day
- `0 22 * * *` = 10 PM every day

### Change how many issues per night

Edit LEAD_AGENT_PROMPT.md line:
```
**Work on top 2-3 items** (depending on complexity)
```

Change "2-3" to "1" for fewer issues, or "5" for more aggressive.

### Change the priorities

Edit the triage order in LEAD_AGENT_PROMPT.md if you have different priorities.

---

## Monitoring & Troubleshooting

### See lead agent runs
```bash
# Check scheduled agent status (if using /schedule)
claude schedule list
```

### If lead agent gets stuck
- It will time out after 30 minutes (built-in safety)
- Check the summary message for any "couldn't complete" notes
- Manual override: You can always create a PR yourself

### If tests fail
- Lead agent will NOT notify you (only notifies on success)
- Check the logs to see what failed
- Manually fix and try again

---

## Next Steps

1. ✅ LEAD_AGENT_PROMPT.md is committed
2. ⏳ Run `/schedule` to create the scheduled agent
3. 🧪 (Optional) Run `/loop` to test it immediately
4. 💤 Go to bed - let it work overnight!
5. ☀️ Wake up to a summary PR ready to review

You're all set! Your lead agent will start autonomous nightly work.
