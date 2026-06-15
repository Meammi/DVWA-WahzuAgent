ARG WAZUH_AGENT_IMAGE_TAG
FROM wazuh/wazuh-agent:${WAZUH_AGENT_IMAGE_TAG}

COPY config/etc/cont-init.d/2-dvwa-logs /etc/cont-init.d/2-dvwa-logs
RUN chmod 0755 /etc/cont-init.d/2-dvwa-logs

