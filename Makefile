.PHONY: bootstrap check gen gen-watch test test-coverage lint format format-check release outdated dev-linux phase1-closeout phase4-codec-closeout

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
	@echo "Usage: make release VERSION=v0.3.0 [IPA=1]"
	@echo "       IPA=1 also builds and uploads an iOS IPA (macOS only)"
	@test -n "$(VERSION)" || (echo "Error: VERSION is required" && exit 1)
	./tool/release.sh $(VERSION) $(if $(IPA),--ipa)

outdated:
	flutter pub outdated
	dart pub outdated

dev-linux:
	./tool/dev_app.sh linux

phase1-closeout:
	./tool/phase1_closeout.sh

phase4-codec-closeout:
	@echo "Usage: make phase4-codec-closeout DEVICE_ID=<adb-device-id> [SERVER_VARIANT=OpenSubsonic]"
	@test -n "$(DEVICE_ID)" || (echo "Error: DEVICE_ID is required" && exit 1)
	./tool/phase4_codec_closeout.sh $(DEVICE_ID) $(SERVER_VARIANT)
