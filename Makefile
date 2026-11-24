.PHONY: diff-rules deploy-rules

# Show how /etc/prometheus/rules on the Pi and OCI differ from prometheus/rules/.
diff-rules:
	scripts/deploy-rules.sh --dry-run

# Deploy prometheus/rules/*.yml to both HA replicas (promtool check + SIGHUP + verify).
deploy-rules:
	scripts/deploy-rules.sh
