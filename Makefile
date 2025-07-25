###--- Shared variables ---###
# Browser types (browser, but "chrome" adjusted as required)
BROWSER_TYPE = $(browser)
CSS_PLATFORM_NAME = $(browser)
ifneq ('$(browser)','firefox')
  CSS_PLATFORM_NAME = chrome-mv3
  BROWSER_TYPE = chrome
endif

# Output directory for builds.
BUILD_DIR = build/$(browser)/$(type)
ifeq ($(browser),test)
  BUILD_DIR := build/test
endif
INTERMEDIATES_DIR = build/.intermediates

## All source files that potentially need to be bundled or copied.
WATCHED_FILES = $(shell find -L browsers/ shared/ packages/ unit-test/ -type f -not -path "packages/*/node_modules/*" -not -name "*~")
# If the node_modules/@duckduckgo/ directory exists, include those source files
# in the list too.
ifneq ("$(wildcard node_modules/@duckduckgo/)","")
  WATCHED_FILES += $(shell find -L node_modules/@duckduckgo/ -type f -not -path "node_modules/@duckduckgo/*/.git/*" -not -path "node_modules/@duckduckgo/*/node_modules/*" -not -name "*~")
endif


###--- Top level targets ---###
# TODO:
#  - Add default `help` target.
#  - Set browser/type automatically where possible.
#  - Add check that browser+type are set when necessary.

## release: Create a release build for a platform in build/$(browser)/release
## specify browser=(chrome|chrome-mv2|firefox) type=release
release: clean npm copy build

.PHONY: release

## chrome-beta: Create a beta Chrome build in build/$(browser)/release
## specify browser=chrome type=release
chrome-beta: release chrome-beta-zip

.PHONY: chrome-beta

## beta-firefox: Create a beta Firefox build in build/$(browser)/release
## specify browser=firefox type=release
beta-firefox: release beta-firefox-zip

.PHONY: beta-firefox

## dev: Create a debug build for a platform in build/$(browser)/dev.
##      Pass reloader=0 to disable automatic extension reloading.
## specify browser=(chrome|chrome-mv2|firefox) type=dev [reloader=1]
dev: copy build $(BUILD_DIR)/buildtime.txt

.PHONY: dev

## watch: Create a debug build for a platform in build/$(browser)/dev, and keep
##        it up to date as files are changed.
##        Pass reloader=0 to disable automatic extension reloading.
## specify browser=(chrome|chrome-mv2|firefox) type=dev [reloader=1]
MAKE = make $(type) browser=$(browser) type=$(type)
watch:
	$(MAKE)
	@echo "\n** Build ready -  Watching for changes **\n"
	while true; do $(MAKE) -q --silent || $(MAKE); sleep 1; done

.PHONY: watch

## unit-test: Run the unit tests.
ESBUILD_TESTS = unit-test/background/*.js unit-test/background/**/*.js unit-test/ui/**/*.js unit-test/shared-utils/*.js
unit-test:
	$(ESBUILD) --sourcemap=inline --outdir=build/test --inject:./unit-test/inject-chrome-shim.js $(ESBUILD_TESTS)
	node_modules/.bin/karma start karma.conf.js

.PHONY: unit-test

NODE_TESTS = unit-test/node/**/*.js
node-test:
	$(ESBUILD) --platform=node --outdir=build/node --inject:./unit-test/inject-chrome-shim.js --external:jsdom $(NODE_TESTS)
	node_modules/.bin/jasmine build/node/*.js

## npm: Pull in the external dependencies (npm install).
npm:
	npm ci --ignore-scripts
	npm rebuild puppeteer
	## Install the privacy-test-pages package for integration tests
	cd node_modules/privacy-test-pages && npm install

.PHONY: npm

## clean: Clear the builds and temporary files.
clean:
	rm -f build/.smarter_encryption.txt integration-test/artifacts/attribution.json
	rm -rf $(BUILD_DIR)

.PHONY: clean


###--- Release packaging ---###
chrome-release-zip:
	rm -f build/chrome/release/chrome-release-*.zip
	cd build/chrome/release/ && zip -rq chrome-release-$(shell date +"%Y%m%d_%H%M%S").zip *

.PHONY: chrome-release-zip

chrome-beta-zip: prepare-chrome-beta chrome-release-zip


.PHONY: chrome-beta-zip

prepare-chrome-beta:
	sed 's/__MSG_appName__/DuckDuckGo Privacy Essentials Beta/' ./browsers/chrome/manifest.json > build/chrome/release/manifest.json
	cp -r build/chrome/release/img/beta/* build/chrome/release/img/

.PHONY: prepare-chrome-beta

remove-firefox-id:
	sed '/jid1-ZAdIEUB7XOzOJw@jetpack/d' ./browsers/firefox/manifest.json > build/firefox/release/manifest.json

.PHONY: remove-firefox-id

beta-firefox-zip: remove-firefox-id
	cd build/firefox/release/ && web-ext build

.PHONY: beta-firefox-zip

###--- Integration test setup ---###
# Artifacts produced by the integration tests.
setup-artifacts-dir:
	rm -rf integration-test/artifacts
	mkdir -p integration-test/artifacts/screenshots
	mkdir -p integration-test/artifacts/api_schemas

.PHONY: setup-artifacts-dir

###--- Mkdir targets ---#
# Note: Intermediate directories can be omitted.
MKDIR_TARGETS = $(BUILD_DIR)/_locales $(BUILD_DIR)/data/bundled $(BUILD_DIR)/html \
                $(BUILD_DIR)/img $(BUILD_DIR)/dashboard $(BUILD_DIR)/web_accessible_resources \
                $(BUILD_DIR)/public/js/content-scripts $(BUILD_DIR)/public/css \
                $(BUILD_DIR)/public/font \
                $(INTERMEDIATES_DIR)

$(MKDIR_TARGETS):
	mkdir -p $@


###--- Copy targets ---###
# The empty $(LAST_COPY) file is used to keep track of file copying, since translating the necessary
# copying to proper Makefile targets is problematic.
# See https://www.gnu.org/software/make/manual/html_node/Empty-Targets.html
LAST_COPY = build/.last-copy-$(browser)-$(type)

RSYNC = rsync -ra --exclude="*~"

$(LAST_COPY): $(WATCHED_FILES) | $(MKDIR_TARGETS)
	$(RSYNC) browsers/$(browser)/* browsers/chrome/_locales shared/data shared/html shared/img $(BUILD_DIR)
	$(RSYNC) node_modules/@duckduckgo/privacy-dashboard/build/app/* $(BUILD_DIR)/dashboard
	$(RSYNC) node_modules/@duckduckgo/autofill/dist/autofill.css $(BUILD_DIR)/public/css/autofill.css
	$(RSYNC) node_modules/@duckduckgo/autofill/dist/autofill-host-styles_$(BROWSER_TYPE).css $(BUILD_DIR)/public/css/autofill-host-styles.css
	$(RSYNC) node_modules/@duckduckgo/autofill/dist/*.js shared/js/content-scripts/*.js $(BUILD_DIR)/public/js/content-scripts
	$(RSYNC) node_modules/@duckduckgo/tracker-surrogates/surrogates/* $(BUILD_DIR)/web_accessible_resources
	touch $@

copy: $(LAST_COPY)

.PHONY: copy

###--- Build targets ---###
ESBUILD = node_modules/.bin/esbuild --bundle --target=firefox91,chrome92 --define:BUILD_TARGET=\"$(browser)\"
# Ensure sourcemaps are included for the bundles during development.
ifeq ($(type),dev)
  ESBUILD += --sourcemap
endif

## Extension background/serviceworker script.
ifeq ($(type), dev)
  # Developer builds include the devbuilds module for debugging.
  ESBUILD += --define:DEBUG=true
  # Unless reloader=0 is passed, they also contain an auto-reload module.
  ifneq ($(reloader),0)
    ESBUILD += --define:RELOADER=true
  else
    ESBUILD += --define:RELOADER=false
  endif
else
  ESBUILD += --define:DEBUG=false --define:RELOADER=false
endif

$(BUILD_DIR)/public/js/background.js: $(WATCHED_FILES)
	$(ESBUILD) shared/js/background/background.js > $@

## Locale resources for UI
shared/js/ui/base/locale-resources.js: $(shell find -L shared/locales/ -type f)
	node scripts/bundleLocales.mjs > $@

## Extension UI/Devtools scripts.
$(BUILD_DIR)/public/js/base.js: $(WATCHED_FILES) shared/js/ui/base/locale-resources.js
	mkdir -p `dirname $@`
	$(ESBUILD) shared/js/ui/base/index.js > $@

$(BUILD_DIR)/public/js/feedback.js: $(WATCHED_FILES)
	$(ESBUILD) shared/js/ui/pages/feedback.js > $@

$(BUILD_DIR)/public/js/options.js: $(WATCHED_FILES)
	$(ESBUILD) shared/js/ui/pages/options.js > $@

$(BUILD_DIR)/public/js/devtools-panel.js: $(WATCHED_FILES)
	$(ESBUILD) shared/js/devtools/panel.js > $@

$(BUILD_DIR)/public/js/list-editor.js: $(WATCHED_FILES)
	$(ESBUILD) shared/js/devtools/list-editor.js > $@

$(BUILD_DIR)/public/js/rollouts.js: $(WATCHED_FILES)
	$(ESBUILD) shared/js/devtools/rollouts.js > $@

$(BUILD_DIR)/public/js/newtab.js: $(WATCHED_FILES)
	$(ESBUILD) shared/js/newtab/newtab.js > $@

$(BUILD_DIR)/public/js/fire.js: $(WATCHED_FILES)
	$(ESBUILD) shared/js/fire/index.js > $@

JS_BUNDLES = background.js base.js feedback.js options.js devtools-panel.js list-editor.js newtab.js fire.js rollouts.js

BUILD_TARGETS = $(addprefix $(BUILD_DIR)/public/js/, $(JS_BUNDLES))

## Content Scope Scripts
CONTENT_SCOPE_SCRIPTS = node_modules/@duckduckgo/content-scope-scripts

# Rebuild content-scope-scripts if it's a local checkout (.git is present), but
# not otherwise. That is important, since content-scope-scripts releases often
# have newer source files than build files.
CONTENT_SCOPE_SCRIPTS_DEPS =
CONTENT_SCOPE_SCRIPTS_LOCALES_DEPS =
ifneq ("$(wildcard $(CONTENT_SCOPE_SCRIPTS)/.git/)","")
  CONTENT_SCOPE_SCRIPTS_DEPS += $(shell find $(CONTENT_SCOPE_SCRIPTS)/injected/src $(CONTENT_SCOPE_SCRIPTS)/injected/entry-points $(CONTENT_SCOPE_SCRIPTS)/injected/scripts -type f -not -name "*~")
  CONTENT_SCOPE_SCRIPTS_DEPS += $(CONTENT_SCOPE_SCRIPTS)/package.json
  CONTENT_SCOPE_SCRIPTS_DEPS += $(CONTENT_SCOPE_SCRIPTS)/node_modules
  CONTENT_SCOPE_SCRIPTS_DEPS += $(CONTENT_SCOPE_SCRIPTS)/build/locales

  CONTENT_SCOPE_SCRIPTS_LOCALES_DEPS += $(shell find $(CONTENT_SCOPE_SCRIPTS)/injected/src/locales $(CONTENT_SCOPE_SCRIPTS)/injected/scripts)
  CONTENT_SCOPE_SCRIPTS_LOCALES_DEPS += $(CONTENT_SCOPE_SCRIPTS)/package.json
  CONTENT_SCOPE_SCRIPTS_LOCALES_DEPS += $(CONTENT_SCOPE_SCRIPTS)/node_modules
endif

$(CONTENT_SCOPE_SCRIPTS)/node_modules: $(CONTENT_SCOPE_SCRIPTS)/package.json
	cd $(CONTENT_SCOPE_SCRIPTS); npm install
	touch $@

$(CONTENT_SCOPE_SCRIPTS)/build/locales: $(CONTENT_SCOPE_SCRIPTS_LOCALES_DEPS)
	cd $(CONTENT_SCOPE_SCRIPTS)/injected; npm run build-locales
	touch $@

$(CONTENT_SCOPE_SCRIPTS)/build/$(CSS_PLATFORM_NAME)/inject.js: $(CONTENT_SCOPE_SCRIPTS_DEPS)
	cd $(CONTENT_SCOPE_SCRIPTS)/injected; npm run build-$(CSS_PLATFORM_NAME)

$(BUILD_DIR)/public/js/inject.js: $(CONTENT_SCOPE_SCRIPTS)/build/$(CSS_PLATFORM_NAME)/inject.js shared/data/bundled/tracker-lookup.json shared/data/bundled/extension-config.json
	node scripts/bundleContentScopeScripts.mjs $@ $^

BUILD_TARGETS += $(BUILD_DIR)/public/js/inject.js

## SASS
SASS = node_modules/.bin/sass
SCSS_SOURCE = $(shell find shared/scss/ -type f)
OUTPUT_CSS_FILES = $(BUILD_DIR)/public/css/options.css $(BUILD_DIR)/public/css/feedback.css
$(BUILD_DIR)/public/css/base.css: shared/scss/base/base.scss $(SCSS_SOURCE)
	$(SASS) $< $@
$(BUILD_DIR)/public/css/%.css: shared/scss/%.scss $(SCSS_SOURCE)
	$(SASS) $< $@

BUILD_TARGETS += $(BUILD_DIR)/public/css/base.css $(OUTPUT_CSS_FILES)

## Fonts
FONT_FILES = ProximaNova-Reg-webfont.woff ProximaNova-Sbold-webfont.woff ProximaNova-Bold-webfont.woff ProximaNova-Reg-webfont.woff2 ProximaNova-Bold-webfont.woff2
BUILD_TARGETS += $(addprefix $(BUILD_DIR)/public/font/, $(FONT_FILES))

$(BUILD_DIR)/public/font/%: $(INTERMEDIATES_DIR)/%
	cp $< $@

# Fetch fonts from the webserver to be included in the generated build
.SECONDARY:
$(INTERMEDIATES_DIR)/%:
	curl -s -o $@ https://duckduckgo.com/font/all/`basename $@`

## Other

# Fetch Smarter Encryption data for bundled Smarter Encryption
# declarativeNetRequest rules.
build/.smarter_encryption.txt:
	curl https://staticcdn.duckduckgo.com/https/smarter_encryption.txt.gz | gunzip -c > $@

# Generate Smarter Encryption declarativeNetRequest rules for MV3 builds.
$(BUILD_DIR)/data/bundled/smarter-encryption-rules.json: build/.smarter_encryption.txt
	npx ddg2dnr smarter-encryption $< $@

ifeq ('$(browser)','chrome')
  BUILD_TARGETS += $(BUILD_DIR)/data/bundled/smarter-encryption-rules.json
endif

# Generate the list of "surrogate" (stub) scripts.
$(BUILD_DIR)/data/surrogates.txt: $(LAST_COPY)
	node scripts/generateListOfSurrogates.mjs -i $(BUILD_DIR)/web_accessible_resources/ > $@

.SECONDARY:
$(INTERMEDIATES_DIR)/surrogates.json: $(LAST_COPY)
	node scripts/generateListOfSurrogates.mjs --json -i $(BUILD_DIR)/web_accessible_resources/ > $@

BUILD_TARGETS += $(BUILD_DIR)/data/surrogates.txt

# Update buildtime.txt for development builds, for auto-reloading.
# Note: Keep this below the other build targets, since it depends on the
#       $(BUILD_TARGETS) variable.
$(BUILD_DIR)/buildtime.txt: $(BUILD_TARGETS) $(LAST_COPY)
	echo $(shell date +"%Y%m%d_%H%M%S") > $(BUILD_DIR)/buildtime.txt

# Ensure directories exist before build targets are created.
$(BUILD_TARGETS): | $(MKDIR_TARGETS)

build: $(BUILD_TARGETS)

.PHONY: build
