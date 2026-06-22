# DVWA + Wazuh Agent Docker Deployment

This project runs two containers:

- `dvwa`: Damn Vulnerable Web Application from `vulnerables/web-dvwa`.
- `wazuh-agent`: Wazuh agent from `wazuh/wazuh-agent`, customized only to collect DVWA Apache logs.

It intentionally does not run a Wazuh manager, indexer, or dashboard. Those belong on your existing Wazuh VM.

## Why Shared Apache Logs

Docker logs are useful, but they are not always enough for web attack testing. For DVWA, the practical signal is usually in Apache access and error logs: login attempts, suspicious query strings, upload paths, command execution requests, SQL injection payloads, XSS payloads, file inclusion attempts, and many failed or unusual HTTP responses.

The main trade-off is that this setup shares `/var/log/apache2` from the DVWA container into the Wazuh agent as read-only `/dvwa-logs`. That is more targeted than mounting broad host paths, and it avoids putting the Wazuh agent inside the DVWA container.
The project also shares the DVWA web root into the agent as read-only `/dvwa-webroot` so Wazuh FIM can see files created through attacks such as command injection or upload abuse.

## Setup

1. Copy the environment template:

   ```sh
   cp .env.example .env
   ```

2. Edit `.env`:

   ```env
   WAZUH_MANAGER=192.168.1.100
   WAZUH_REGISTRATION_SERVER=192.168.1.100
   WAZUH_REGISTRATION_PASSWORD=
   WAZUH_AGENT_IMAGE_TAG=4.13.0
   ```

   In practice, set `WAZUH_AGENT_IMAGE_TAG` to a version that matches your manager version or is lower than it. A newer agent than the manager can create compatibility problems.
   Leave `WAZUH_REGISTRATION_PASSWORD` empty unless the manager has `<use_password>yes</use_password>` in its `<auth>` configuration.

3. Start the deployment:

   ```sh
   docker compose up --build -d
   ```

4. Open DVWA:

   ```text
   http://localhost:8080
   ```

   If you changed `DVWA_HTTP_PORT`, use that port instead.

5. In DVWA, click `Create / Reset Database` on the setup page.

6. Log in with the default DVWA credentials:

   ```text
   Username: admin
   Password: password
   ```

## Wazuh Validation

Check that both containers are running:

```sh
docker compose ps
```

Check that DVWA writes Apache logs:

```sh
docker compose exec dvwa ls -l /var/log/apache2
```

Check that the Wazuh agent can see those logs read-only:

```sh
docker compose exec wazuh-agent ls -l /dvwa-logs
```

Check the Wazuh agent status:

```sh
docker compose logs wazuh-agent
```

Then check your external Wazuh dashboard for the agent name from `.env`, for example `dvwa-agent`.

## Agent Configuration

This project now uses a repo-owned Wazuh agent template:

```text
config/wazuh_agent/ossec.conf.template
```

At container startup, the script renders that template into the real:

```text
/var/ossec/etc/ossec.conf
```

The render hook is scheduled after the image's base Wazuh init step and before the agent daemon starts, so the agent reads the rendered config on first boot rather than one restart later.
The hook runs through `with-contenv` so the `.env` values from Docker Compose are available during the s6 init phase.

The trade-off here is straightforward:

- a template is easier to reason about as the config grows
- `.env` still remains the only source for sensitive values and manager addresses
- the generated file inside the volume is recreated on every container start, so template edits apply immediately without deleting agent identity state
- agent enrollment is still handled by the official Wazuh container startup using the environment variables, not by an `<enrollment>` block inside `ossec.conf`
- if the init environment does not expose the manager variables the way we expect, the render hook falls back to the manager address and port already written by the image's own `0-wazuh-init` step

Use the optional snippet folder for small add-ons:

```text
config/wazuh_agent/snippets/*.conf
```

Do not include the outer `<ossec_config>` tag in snippets.

Use the template and snippets for agent-side collection settings such as extra `<localfile>` blocks or `<syscheck>` monitoring. Do not put VirusTotal API config here. VirusTotal is a Wazuh manager integration, so the API key and `<integration>` block belong on your external Wazuh manager VM.

For this two-container layout, agent paths must match mounted paths:

- use `/dvwa-logs/...` for Apache logs
- use `/dvwa-webroot/...` for file integrity monitoring

Watching `/var/www/html` or `/var/log/apache2` inside the agent container will not see DVWA changes unless those directories are also mounted there.

## Preserving The Agent Identity

The Compose file uses persistent named volumes for:

- `/var/ossec/etc`
- `/var/ossec/var`

The important file is usually `/var/ossec/etc/client.keys`. Preserving that state prevents the manager from creating a new agent ID every time you rebuild or recreate the container.

Use this when rebuilding:

```sh
docker compose up --build -d
```

Avoid deleting the Wazuh volumes unless you intentionally want a fresh enrollment:

```sh
docker compose down -v
```

That command removes named volumes and can cause the agent to enroll as a new identity.

## Attack Testing Notes

This setup is appropriate for observing DVWA traffic related to:

- Brute force
- Command execution
- CSRF
- File inclusion
- File upload
- SQL injection and blind SQL injection
- XSS
- Insecure CAPTCHA

The Wazuh agent forwards the logs. Detection quality still depends on your manager-side rules, decoders, and active integrations. VirusTotal or malware scanning can be added later without changing the two-container baseline.
For FIM specifically, scheduled scans are more reliable than real-time mode on shared/container volumes, especially on Docker Desktop.

## Troubleshooting

If the agent does not appear in Wazuh:

- Confirm `WAZUH_MANAGER` and `WAZUH_REGISTRATION_SERVER` are reachable from the Docker host.
- Confirm manager ports `1514` and `1515` are open.
- Confirm the registration password matches the manager configuration. If the manager has `<use_password>no</use_password>`, leave `WAZUH_REGISTRATION_PASSWORD` empty.
- Check `docker compose logs wazuh-agent`.

If DVWA works but no web events appear in Wazuh:

- Generate a request in DVWA, then inspect `/var/log/apache2/access.log` inside the DVWA container.
- Confirm the agent sees the same file under `/dvwa-logs/access.log`.
- Confirm the agent is connected to the manager.
- Check manager-side rules if raw logs arrive but alerts do not trigger.
