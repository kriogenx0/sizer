APP      := Sizer
SRC      := $(wildcard Sources/*.swift)
FLAGS    := -framework Cocoa -framework Carbon -framework ApplicationServices

BUILD_DIR := build
DIST_DIR  := dist
INST_DIR  := /Applications
RES_DIR   := Resources

DEV_BUNDLE  := $(BUILD_DIR)/$(APP).app
DIST_BUNDLE := $(DIST_DIR)/$(APP).app
INST_BUNDLE := $(INST_DIR)/$(APP).app
ICON_ICNS   := $(RES_DIR)/$(APP).icns

.PHONY: build dev run publish install open reinstall-open reinstall icon close clean uninstall

# Generate the app icon (.icns) from the drawing code.
icon: $(ICON_ICNS)

$(ICON_ICNS): Scripts/generate-icon.swift
	@mkdir -p $(RES_DIR)
	@echo "→ Generating icon…"
	@swiftc Scripts/generate-icon.swift -framework Cocoa -o /tmp/sizer-icon-gen
	@/tmp/sizer-icon-gen
	@iconutil -c icns $(RES_DIR)/$(APP).iconset -o $@
	@rm -rf $(RES_DIR)/$(APP).iconset /tmp/sizer-icon-gen
	@echo "✓ $@"

# Build for dev. Don't open.
build: $(DEV_BUNDLE)

$(DEV_BUNDLE): $(SRC) Info.plist $(ICON_ICNS)
	@rm -rf $@
	@mkdir -p $@/Contents/MacOS $@/Contents/Resources
	@echo "→ Building (dev)…"
	swiftc $(SRC) $(FLAGS) -o $@/Contents/MacOS/$(APP)
	@cp Info.plist $@/Contents/Info.plist
	@cp $(ICON_ICNS) $@/Contents/Resources/$(APP).icns
	@echo "✓ $@"

# Just run it.
dev run: build
	open $(DEV_BUNDLE)

# Build for production. Don't install.
publish: $(DIST_BUNDLE)

$(DIST_BUNDLE): $(SRC) Info.plist $(ICON_ICNS)
	@rm -rf $@
	@mkdir -p $@/Contents/MacOS $@/Contents/Resources
	@echo "→ Building (production)…"
	swiftc $(SRC) $(FLAGS) -O -o $@/Contents/MacOS/$(APP)
	@cp Info.plist $@/Contents/Info.plist
	@cp $(ICON_ICNS) $@/Contents/Resources/$(APP).icns
	@echo "✓ $@"

# Build and install into production.
install: publish
	@echo "→ Installing to $(INST_BUNDLE)…"
	@rm -rf $(INST_BUNDLE)
	@cp -R $(DIST_BUNDLE) $(INST_BUNDLE)
	@echo "✓ Installed"

# Open in production. Build and install first if not present.
open:
	@if [ ! -d "$(INST_BUNDLE)" ]; then $(MAKE) install; fi
	open $(INST_BUNDLE)

# Close app, build for production, install fresh, and open.
reinstall-open:
	@pkill -x $(APP) || true
	@$(MAKE) publish
	@rm -rf $(INST_BUNDLE)
	@cp -R $(DIST_BUNDLE) $(INST_BUNDLE)
	open $(INST_BUNDLE)

# Uninstall and reinstall from the current dist build.
reinstall: uninstall install

# Kill the running app.
close:
	@pkill -x $(APP) || true

# Clean everything, even cache.
clean:
	rm -rf $(BUILD_DIR) $(DIST_DIR) $(RES_DIR)
	@echo "✓ Cleaned"

uninstall:
	@pkill -x $(APP) || true
	@sleep 0.5
	@rm -rf $(INST_BUNDLE)
	@echo "✓ Uninstalled"
