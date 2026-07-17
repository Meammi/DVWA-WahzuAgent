# Display Output Service

Tiny mock chat display for the Wazuh AI bridge PoC. This is a LINE substitute, not a real notification service.

## Run on the display VM

```bash
docker build -t display-output-service .
docker run -d --name display-output -p 9000:9000 display-output-service
```

Open:

```text
http://DISPLAY_VM_IP:9000/
```

Debug JSON:

```bash
curl http://DISPLAY_VM_IP:9000/messages
```

## Connect AI bridge

On the Wazuh / AI bridge VM, set:

```env
DISPLAY_OUTPUT_URL=http://DISPLAY_VM_IP:9000/messages
```
