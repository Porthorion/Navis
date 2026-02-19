.PHONY: bootstrap check gen gen-watch test test-coverage lint format format-check release

bootstrap:
	./tool/bootstrap.sh

check:
	./tool/check.sh

gen:
	dart run build_runner build --delete-conflicting-outputs

gen-watch:
	dart run build_runner watch --delete-conflicting-outputs

test:
	flutter test

test-coverage:
	flutter test --coverage

lint:
	flutter analyze && dart run custom_lint

format:
	dart format .

format-check:
	dart format --set-exit-if-changed .

release:
	@echo "Usage: make release VERSION=v0.2.0"
	@test -n "$(VERSION)" || (echo "Error: VERSION is required" && exit 1)
	./tool/release.sh $(VERSION)

outdated:
	flutter pub outdated
	dart pub outdated
