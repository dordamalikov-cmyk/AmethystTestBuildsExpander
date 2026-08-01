# Prerequisite variables
SOURCEDIR := src
OUTPUTDIR := build

SOURCES := $(shell find $(SOURCEDIR) -type f -name '*.java')
CLASSES := $(SOURCES:$(SOURCEDIR)/%.java=$(OUTPUTDIR)/%.class)

TARGETS := $(shell find $(SOURCEDIR) -mindepth 1 -maxdepth 1 -type d)
TARGETS := $(TARGETS:$(SOURCEDIR)/%=$(OUTPUTDIR)/%.jar)

# The launcher compiles against the old prebuilt Amethyst LWJGL jars
# (libs/lwjgl), which contain the expected API surface (e.g.
# GLFW.mGLFWWindowWidth). They must come BEFORE the freshly built stock sets
# (libs/lwjgl-333, libs/lwjgl-341), whose vanilla GLFW class lacks those
# fields. At runtime only the merged versioned jars are used.
JCFLAGS := -cp "$(subst $() $(),:,$(wildcard $(SOURCEDIR)/*/):$(wildcard libs/lwjgl/*.jar):$(wildcard libs/lwjgl-333/*.jar):$(wildcard libs/lwjgl-341/*.jar):$(wildcard libs/others/*.jar):$(wildcard libs/caciocavallo/*.jar):$(wildcard libs/caciocavallo17/*.jar))" -XDignore.symbol.file

all: $(TARGETS)
	
# Sometimes the CI produces empty class file resulting in broken jar, so we check and abort here
check_empty_classes:
	@set -e
	@echo "Checking for empty class files"
	$(eval EMPTY_CLASSES := $(shell find $(OUTPUTDIR) -name '*.class' -size 0))
	@if [ -n "$(EMPTY_CLASSES)" ]; then \
		echo "Error: found empty class files in $@: $(EMPTY_CLASSES)"; \
		exit 1; \
	fi

# Rules for building java class
#
# Each source file is compiled into its OWN output directory
# (build/classes/<path-with-underscores>). javac implicitly recompiles other
# sources it depends on, and with a shared -d directory two parallel javac
# invocations could write the same class file concurrently; the jar rules'
# check_empty_classes then catches the resulting 0-byte file. Per-file output
# dirs make every cp copy only files written by the javac invocation that just
# completed, so the race cannot happen.
$(CLASSES): $(OUTPUTDIR)/%.class: $(SOURCEDIR)/%.java
	@set -e; \
	CLASSDIR="$(OUTPUTDIR)/classes/$(subst /,_,$*)"; \
	mkdir -p "$$CLASSDIR" "$(dir $@)"; \
	echo "Compiling $<"; \
	$(BOOTJDK)/javac $(JCFLAGS) -d "$$CLASSDIR" $<; \
	cp "$$CLASSDIR/$(patsubst $(word 2, $(subst /, ,$@))/%,%,$*)"*.class "$(dir $@)/"

$(OUTPUTDIR)/launcher.jar: $(CLASSES) check_empty_classes
	@set -e
	@echo "Creating $@"
	@cp -r $(SOURCEDIR)/launcher/META-INF $(basename $@)/ 2>/dev/null || true
	@$(BOOTJDK)/jar -cf $@ -C $(basename $@) .

# Build one merged LWJGL jar per version (3.3.3 and 3.4.1). The stock jars
# from libs/lwjgl-<version> are merged with the Amethyst overlay classes in
# build/lwjgl/ (src/lwjgl/**), plus the Caciocavallo audio provider and the
# javax.sound META-INF service registration.
$(OUTPUTDIR)/lwjgl-%.jar: $(CLASSES) check_empty_classes
	@set -e
	@echo "Creating $@"
	@mkdir -p $(OUTPUTDIR)/lwjgl_lib_$*
	@cd $(OUTPUTDIR)/lwjgl_lib_$* && find ../../libs/lwjgl-$* -name 'lwjgl*.jar' -exec $(BOOTJDK)/jar -xf {} \; && rm -rf META-INF
	@cp -R $(OUTPUTDIR)/lwjgl/* $(OUTPUTDIR)/lwjgl_lib_$*/
	@mkdir -p $(OUTPUTDIR)/lwjgl_lib_$*/com/apple/ios/audio
	@cp -R $(OUTPUTDIR)/launcher/com/apple/ios/audio/*.class $(OUTPUTDIR)/lwjgl_lib_$*/com/apple/ios/audio/
	@mkdir -p $(OUTPUTDIR)/lwjgl_lib_$*/META-INF/services
	@cp $(SOURCEDIR)/launcher/META-INF/services/javax.sound.sampled.spi.MixerProvider $(OUTPUTDIR)/lwjgl_lib_$*/META-INF/services/
	@$(BOOTJDK)/jar -cf $@ -C $(OUTPUTDIR)/lwjgl_lib_$* .

# Kept as a no-op placeholder: all: $(TARGETS) still lists lwjgl.jar because
# src/lwjgl is a source directory. The runtime uses lwjgl-333.jar or
# lwjgl-341.jar instead, and build/lwjgl.jar must NOT land in the app libs.
$(OUTPUTDIR)/lwjgl.jar: $(OUTPUTDIR)/lwjgl-333.jar $(OUTPUTDIR)/lwjgl-341.jar
	@echo "Skipping $@ (lwjgl-333.jar / lwjgl-341.jar are used instead)"

$(OUTPUTDIR)/patchjna_agent.jar: $(CLASSES)
	@set -e
	@mv $(basename $@)/com/sun/jna/Platform.class $(basename $@)/com/sun/jna/Platform.class.patch
	@echo "Creating $@"
	@$(BOOTJDK)/jar -cfm $@ $(SOURCEDIR)/patchjna_agent.txt -C $(basename $@) .

clean:
	rm -rf $(OUTPUTDIR)

.SUFFIXES: .java
.PHONY: all clean
