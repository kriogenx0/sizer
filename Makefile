# --- paths ------------------------------------------------------------------
APP      := Sizer
BUILD    := build
BUNDLE   := $(BUILD)/$(APP).app
MACOS    := $(BUNDLE)/Contents/MacOS
RESOURCES:= $(BUNDLE)/Contents/Resources
SRC      := Sources/main.swift

# --- default target ---------------------------------------------------------
.PHONY: all
all: $(BUNDLE)

# --- build ------------------------------------------------------------------
$(BUNDLE): $(SRC) Info.plist
	@echo "→ Compiling…"
	@rm -rf $(BUILD)
	@mkdir -p $(MACOS) $(RESOURCES)
	swiftc $(SRC) \
		-framework Cocoa \
		-framework Carbon \
		-framework ApplicationServices \
		-O \
		-o $(MACOS)/$(APP)
	@cp Info.plist $(BUNDLE)/Contents/Info.plist
	@echo "✓ Built $(BUNDLE)"

# --- run --------------------------------------------------------------------
.PHONY: run
run: $(BUNDLE)
	open $(BUNDLE)

# --- clean ------------------------------------------------------------------
.PHONY: clean
clean:
	rm -rf $(BUILD)
	@echo "✓ Cleaned"

# --- install to /Applications -----------------------------------------------
.PHONY: install
install: $(BUNDLE)
	@echo "→ Installing to /Applications/$(APP).app …"
	cp -R $(BUNDLE) /Applications/$(APP).app
	@echo "✓ Installed"

.PHONY: uninstall
uninstall:
	rm -rf /Applications/$(APP).app
	@echo "✓ Uninstalled"
