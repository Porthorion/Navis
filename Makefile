.PHONY: bootstrap check gen gen-watch test test-coverage lint format format-check

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
