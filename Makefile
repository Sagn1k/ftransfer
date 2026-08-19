.PHONY: start app release test parity check clean

start:  ## Share ./shared via a Cloudflare quick tunnel
	./start.sh

app:  ## Build the macOS menu bar app (clients/mac/FTransfer.app)
	clients/mac/build.sh

release:  ## Build the self-contained distributable zip (dist/)
	scripts/release.sh

test:  ## Run server smoke tests
	tests/smoke.sh

parity:  ## Check the Swift server matches server.py (needs: make app)
	tests/parity.sh

check: test app parity  ## Everything CI runs

clean:  ## Remove build output
	rm -rf clients/mac/FTransfer.app clients/mac/build clients/mac/vendor dist
