APP_NAME      := Nodens
BUNDLE_ID     := io.github.monad-wireless.nodens
BUNDLE        := build/$(APP_NAME).app
BINARY        := .build/release/Nodens
ICON          := Resources/AppIcon.icns
HOOK          := Resources/nodens-hook
INSTALL_TO    := $(HOME)/Applications
# Ad hoc by default, so anyone can build. A stable identity keeps Keychain
# access and macOS permissions across rebuilds:
#   make install SIGN_IDENTITY="Apple Development"
SIGN_IDENTITY ?= -
DRY           := build/hook-dry

.PHONY: build test check-hook art app install run clean

build:
	swift build -c release

test: check-hook
	swift test

# Syntax check plus dry runs of the root hook: it reads the real routing table
# and network services but only prints route/networksetup commands, and writes
# its records and resolver files under build/hook-dry.
check-hook:
	sh -n $(HOOK)
	rm -rf $(DRY)
	mkdir -p $(DRY)/etc
	printf '203.0.113.7\n' > $(DRY)/etc/dry-0000.hosts
	env NODENS_DRY_RUN=1 NODENS_STATE_DIR=$(DRY)/state NODENS_ETC_DIR=$(DRY)/etc \
	    NODENS_RESOLVER_DIR=$(DRY)/resolver NODENS_ASSUME_FULL=1 NODENS_SLUG=dry-0000 \
	    NODENS_ROUTE_STRATEGY=host-routes dev=utun99 \
	    "foreign_option_1=dhcp-option DNS 192.0.2.53" "foreign_option_2=dhcp-option DOMAIN example.internal" \
	    sh $(HOOK) ovpn-up
	test -f $(DRY)/resolver/example.internal
	env NODENS_DRY_RUN=1 NODENS_STATE_DIR=$(DRY)/state NODENS_ETC_DIR=$(DRY)/etc NODENS_RESOLVER_DIR=$(DRY)/resolver \
	    sh $(HOOK) cleanup-stale
	test ! -e $(DRY)/resolver/example.internal
	test ! -e $(DRY)/state/tunnels/dry-0000
	printf '203.0.113.8\n' > $(DRY)/etc/drywg-0000.hosts
	env NODENS_DRY_RUN=1 NODENS_STATE_DIR=$(DRY)/state NODENS_ETC_DIR=$(DRY)/etc \
	    NODENS_RESOLVER_DIR=$(DRY)/resolver NODENS_WG_RUN_DIR=$(DRY)/wgrun NODENS_ASSUME_FULL=1 \
	    NODENS_ROUTE_STRATEGY=scoped-default "NODENS_DNS_SERVERS=10.8.0.1 not-an-ip" \
	    "NODENS_DNS_DOMAINS=Corp.Internal lan" \
	    sh $(HOOK) wg-up drywg-0000 utun97
	test -f $(DRY)/resolver/corp.internal
	test ! -e $(DRY)/resolver/lan
	test "$$(cat $(DRY)/state/tunnels/drywg-0000/kind)" = wg
	env NODENS_DRY_RUN=1 NODENS_STATE_DIR=$(DRY)/state NODENS_ETC_DIR=$(DRY)/etc NODENS_RESOLVER_DIR=$(DRY)/resolver \
	    NODENS_WG_RUN_DIR=$(DRY)/wgrun sh $(HOOK) cleanup-stale
	test ! -e $(DRY)/resolver/corp.internal
	test ! -e $(DRY)/state/tunnels/drywg-0000
	env NODENS_DRY_RUN=1 NODENS_STATE_DIR=$(DRY)/state sh $(HOOK) wg-up drywg-0000 'utun1;id' | grep -q 'invalid device'

# Renders the icon set and the README images (docs/images), then packs AppIcon.icns.
# The outputs are checked in, so `make app` does not need this step.
art:
	swift run -c release RenderArt "$(CURDIR)"
	iconutil -c icns build/AppIcon.iconset -o "$(ICON)"

# Wraps the binary in a signed .app (LSUIElement: menu bar only, no Dock icon).
app: build
	rm -rf "$(BUNDLE)"
	mkdir -p "$(BUNDLE)/Contents/MacOS" "$(BUNDLE)/Contents/Resources"
	cp "$(BINARY)" "$(BUNDLE)/Contents/MacOS/Nodens"
	cp Resources/Info.plist "$(BUNDLE)/Contents/Info.plist"
	cp "$(ICON)" "$(BUNDLE)/Contents/Resources/AppIcon.icns"
	install -m 0755 "$(HOOK)" "$(BUNDLE)/Contents/Resources/nodens-hook"
	codesign --force --sign "$(SIGN_IDENTITY)" --identifier "$(BUNDLE_ID)" "$(BUNDLE)"

# Tests, builds, replaces the installed copy and starts it. The old copy gets
# SIGTERM; the new one waits up to 3 s for it to exit (single-instance guard).
install: test app
	-pkill -x Nodens
	mkdir -p "$(INSTALL_TO)"
	rm -rf "$(INSTALL_TO)/$(APP_NAME).app"
	cp -R "$(BUNDLE)" "$(INSTALL_TO)/"
	open "$(INSTALL_TO)/$(APP_NAME).app"

run: app
	open "$(BUNDLE)"

clean:
	rm -rf .build build
