export AGENT_PROFILE_DIRS

build:
	swift build

test:
	swift test

app:
	./scripts/make-app.sh

install: app
	./scripts/install.sh

.PHONY: build test app install
