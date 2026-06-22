# Project Skill: DVWA + Wazuh Agent

Use these rules when working in this repository.

## Core Rules

- Keep the runtime deployment to exactly two containers: `dvwa` and `wazuh-agent`.
- Do not add Wazuh manager, indexer, dashboard, Filebeat, or unrelated services to this project.
- Keep manager addresses, enrollment passwords, agent names, groups, ports, and image tags in `.env`.
- Never commit a real `.env` file or real Wazuh secrets.
- Preserve Wazuh agent identity by keeping `/var/ossec/etc` and `/var/ossec/var` on persistent named volumes.
- Prefer shared DVWA Apache logs over Docker logs for DVWA attack visibility.
- Mount DVWA logs into the agent read-only.
- Keep `config/wazuh_agent/ossec.conf.template` as the repo-owned source of truth for the agent base config.
- Put optional extra agent-side collection config in `config/wazuh_agent/snippets/*.conf`.
- Keep manager-side integrations, such as VirusTotal API configuration, on the external Wazuh manager VM.

## Design Guidance

- Treat DVWA as intentionally vulnerable lab software. Do not expose it publicly.
- Keep the Wazuh agent customization small and additive to the official image behavior.
- Do not put the Wazuh agent inside the DVWA container; separate containers make rebuilds, testing, and troubleshooting cleaner.
- If malware detection or VirusTotal integration is added later, keep it as a separate, explicit change.

## Logging Rule

After completing a task, add a short entry to `TASK_LOG.md` under `Codex Log`.

Each entry should include:

- date
- what changed
- why it changed

The user maintains the `User Log` section manually.
