.PHONY: bootstrap check gen gen-watch test test-coverage lint format format-check release outdated dev-linux

bootstrap:
	./tool/bootstrap.sh

check:
	./tool/check.sh

gen:
	dart run build_runner build

gen-watch:
	dart run build_runner watch

test:
	flutter test

test-coverage:
	flutter test --coverage

lint:
	flutter analyze --no-fatal-infos

format:
	./tool/dart_format.sh

format-check:
	./tool/dart_format.sh --check

release:
	@echo "Usage: make release VERSION=v0.3.0 [IPA=1]"
	@echo "       IPA=1 also builds and uploads an iOS IPA (macOS only)"
	@test -n "$(VERSION)" || (echo "Error: VERSION is required" && exit 1)
	./tool/release.sh $(VERSION) $(if $(IPA),--ipa)

outdated:
	flutter pub outdated
	dart pub outdated

dev-linux:
	./tool/dev_app.sh linux
