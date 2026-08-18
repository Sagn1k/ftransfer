.PHONY: start app test clean

start:  ## Share ./shared via a Cloudflare quick tunnel
	./start.sh

app:  ## Build the macOS menu bar app (clients/mac/FTransfer.app)
	clients/mac/build.sh

test:  ## Run server smoke tests
	tests/smoke.sh

clean:  ## Remove build output
	rm -rf clients/mac/FTransfer.app
