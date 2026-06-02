APP      := Sizer
SRC      := $(wildcard Sources/*.swift)
FLAGS    := -framework Cocoa -framework Carbon -framework ApplicationServices -framework ServiceManagement

BUILD_DIR := build
DIST_DIR  := dist
INST_DIR  := /Applications
RES_DIR   := Resources

DEV_BUNDLE  := $(BUILD_DIR)/$(APP).app
DIST_BUNDLE := $(DIST_DIR)/$(APP).app
INST_BUNDLE := $(INST_DIR)/$(APP).app
ICON_ICNS   := $(RES_DIR)/$(APP).icns

.PHONY: dev build open close install uninstall reinstall icon clean all

all: open

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

# Build for development and open.
dev: $(DEV_BUNDLE)
	open $(DEV_BUNDLE)

$(DEV_BUNDLE): $(SRC) Info.plist $(ICON_ICNS)
	@rm -rf $@
	@mkdir -p $@/Contents/MacOS $@/Contents/Resources
	@echo "→ Building (dev)…"
	swiftc $(SRC) $(FLAGS) -o $@/Contents/MacOS/$(APP)
	@cp Info.plist $@/Contents/Info.plist
	@cp $(ICON_ICNS) $@/Contents/Resources/$(APP).icns
	@echo "✓ $@"

# Build for production.
build:
	@rm -rf $(DIST_BUNDLE)
	@mkdir -p $(DIST_BUNDLE)/Contents/MacOS $(DIST_BUNDLE)/Contents/Resources
	@echo "→ Building (production)…"
	swiftc $(SRC) $(FLAGS) -O -o $(DIST_BUNDLE)/Contents/MacOS/$(APP)
	@cp Info.plist $(DIST_BUNDLE)/Contents/Info.plist
	@cp $(ICON_ICNS) $(DIST_BUNDLE)/Contents/Resources/$(APP).icns
	@echo "✓ $(DIST_BUNDLE)"

# Build for production and install.
install: build
	@echo "→ Installing to $(INST_BUNDLE)…"
	@rm -rf $(INST_BUNDLE)
	@cp -R $(DIST_BUNDLE) $(INST_BUNDLE)
	@echo "✓ Installed"

# Build for production and open.
open:
	@pkill -x $(APP) || true
	@$(MAKE) install
	open $(INST_BUNDLE)

# Kill the app.
close:
	@pkill -x $(APP) || true

# Close the app and remove if installed.
uninstall:
	@pkill -x $(APP) || true
	@sleep 0.5
	@rm -rf $(INST_BUNDLE)
	@echo "✓ Uninstalled"

# Uninstall and reinstall.
reinstall: uninstall install

# Clean existing builds.
clean:
	rm -rf $(BUILD_DIR) $(DIST_DIR) $(RES_DIR)
	@echo "✓ Cleaned"
