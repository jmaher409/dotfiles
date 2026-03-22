# AppFolio Developer Context

## Identity

- **Email**: justin.maher@appfolio.com

## Searching Internal Documentation with `otto ask`

When you need information about AppFolio systems, domain knowledge, processes, or tooling, use `otto ask` to search the internal Developer Portal. It uses an LLM to answer questions and cites up to 3 source links from the portal.

**One-shot** (answer printed, then exit):
```sh
otto ask "How do I run the property app tests?"
otto ask "What is otto up?"
otto ask "How do I deploy to production?"
```

### What it answers well

- Internal domain knowledge and system architecture (how payments work, billing flows, data models, team ownership)
- How AppFolio processes work (deployments, onboarding, CI/CD)
- How to use Otto commands (`otto up`, `otto brew`, etc.)
- Service-specific setup and troubleshooting (Percona, devcontainer, AWS, etc.)
- Where to find Slack channels, runbooks, or documentation for a team or system

### What it does not answer

- Questions about private codebases or repos not indexed in the Developer Portal
- Real-time information (incidents, on-call schedules, current PR status)
- Anything requiring access to production systems or secrets

### Output format

Each response contains:
1. An LLM-generated answer (plain text or markdown)
2. `Top 3 sources:` — titles of the source documents
3. `🔗` — direct links to those documents on the Developer Portal

Direct the user to read and provide the full documentation when you need more detail than the summary provides.
