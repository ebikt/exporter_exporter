GITHUB_ORG  = QubitProducts
GITHUB_REPO = exporter_exporter
VERSION      = 0.4.5.file

DOCKER_ARCHS:=amd64 i386
DEBIAN_DISTS:=bullseye
GO_FLAVORS:=alpine $(DEBIAN_DISTS)

# alpine//latest-alpine debian/bullseye-bullseye scratch-alpine scratch-bullseye
DOCKER_FULL_DISTS:=alpine//latest-alpine $(foreach DIST, $(DEBIAN_DISTS),debian//$(DIST)-$(DIST)) $(addprefix scratch-, $(GO_FLAVORS))

DOCKER_NAME         = exporter_exporter

SHELL        := /usr/bin/env bash
GO           := go
FIRST_GOPATH := $(firstword $(subst :, ,$(GOPATH)))
FILES         = $(shell find . -name '*.go' | grep -v vendor)
PREFIX       ?= $(shell pwd)
BIN_DIR      ?= $(shell pwd)

PACKAGE_TARGET     = deb
PACKAGE_NAME       = expexp
PACKAGE_VERSION    = $(VERSION)
PACKAGE_REVISION   = 3
PACKAGE_ARCH       = amd64
PACKAGE_MAINTAINER = tristan@qubit.com
PACKAGE_FILE       = $(PACKAGE_NAME)_$(PACKAGE_VERSION)-$(PACKAGE_REVISION)_$(PACKAGE_ARCH).$(PACKAGE_TARGET)
BINNAME            = exporter_exporter

PWD := $(shell pwd)

all: package
clean:
	rm -f $(PACKAGE_FILE)
	rm -rf dist
	rm -rf build

.PHONY: test
test:
	echo ">> running short tests"
	$(GO) test -short $(pkgs)

.PHONY: test-static
test-static:
	echo ">> running static tests"
	$(GO) vet $(pkgs)
	[[ "$(shell gofmt -l $(files))" == "" ]] || (echo "gofmt check failed"; exit 1)

.PHONY: format
format:
	echo ">> formatting code"
	$(GO) fmt $(pkgs)

.PHONY: vet
vet:
	echo ">> vetting code"
	$(GO) vet $(pkgs)

.PHONY: prepare-package clean-package package
prepare-package: clean-package build/$(BINNAME)-$(VERSION).linux-amd64/$(BINNAME)
	mkdir -p dist/usr/local/bin
	mkdir -p dist/etc/init
	mkdir -p dist/etc/default
	mkdir -p dist/etc/exporter_exporter.d/
	install -m755 build/$(BINNAME)-$(VERSION).linux-amd64/$(BINNAME) dist/usr/local/bin/$(BINNAME)
	install -m644 $(BINNAME).conf dist/etc/init/$(BINNAME).conf
	install -m644 $(BINNAME).defaults dist/etc/default/$(BINNAME)
	install -m644 expexp.yaml dist/etc/exporter_exporter.yaml
	touch dist/etc/exporter_exporter.d/.dir

clean-package:
	rm -rf dist

.PHONY: AUTHORS
AUTHORS:
	# There's only so much credit I need.
	git log --format='%aN <%aE>' | grep -v Tristan\ Colgate\  | sort -u > AUTHORS

$(PACKAGE_FILE): prepare-package
	cd dist && \
	  fpm \
		-f \
	  -t $(PACKAGE_TARGET) \
	  -m $(PACKAGE_MAINTAINER) \
	  -n $(PACKAGE_NAME) \
	  -a $(PACKAGE_ARCH) \
	  -v $(PACKAGE_VERSION) \
	  --iteration $(PACKAGE_REVISION) \
	  --config-files /etc/$(BINNAME).yaml \
	  --config-files /etc/init/$(BINNAME).conf \
	  --config-files /etc/default/$(BINNAME) \
	  -s dir \
	  -p ../$(PACKAGE_FILE) \
	  .

# build-docker-$(DIST)-$(ARCH), where DIST is one of: alpine//latest-alpine debian/bullseye-bullseye scratch-alpine scratch-bullseye
DOCKER_FULL_DESTS:=$(foreach DIST, $(DOCKER_FULL_DISTS), $(addprefix build-docker-$(DIST)-, $(DOCKER_ARCHS)))
.PHONY: $(DOCKER_FULL_DESTS)
$(DOCKER_FULL_DESTS): build-docker-%:
	eval '$(join BASEDIST= FLAVOR= ARCH=,$(subst -, ,$(subst //,:,$*)))' ; \
	case $$BASEDIST in \
		scratch) \
			PREFIX=scratch-$$FLAVOR-$$ARCH ; \
		;; \
		*) \
			PREFIX=$$FLAVOR-$$ARCH ; \
			BASEDIST=$$ARCH/$$BASEDIST ; \
		;; \
	esac ; \
	docker build -t $$PREFIX/$(DOCKER_NAME):$(VERSION) --build-arg ARCH=$$ARCH --build-arg FLAVOR=$$FLAVOR --build-arg BASEDIST=$$BASEDIST .

# build-docker-$(DIST), where DIST is one of: alpine//latest-alpine debian/bullseye-bullseye scratch-alpine scratch-bullseye
.PHONY: $(addprefix build-docker-, $(DOCKER_FULL_DISTS))
$(addprefix build-docker-, $(DOCKER_FULL_DISTS)): build-docker-%: $(addprefix build-docker-%-, $(DOCKER_ARCHS))


# build-docker-$(FLAVOR)-$(ARCH), where FLAVOR is one of: alpine bullseye
DOCKER_SHORT_DESTS:=$(foreach FLAVOR, $(GO_FLAVORS), $(addprefix build-docker-$(FLAVOR)-, $(DOCKER_ARCHS)))
.PHONY: $(DOCKER_SHORT_DESTS)

$(addprefix build-docker-alpine-, $(DOCKER_ARCHS)): build-docker-alpine-%: build-docker-alpine//latest-alpine-%
.SECONDEXPANSION:
$(foreach DIST, $(DEBIAN_DISTS), $(addprefix build-docker-$(DIST)-, $(DOCKER_ARCHS))): build-docker-%: build-docker-debian//$$(word 1,$$(subst -, ,$$*))-$$*

# build-docker-$(ARCH) build-docker-$(FLAVOR), where FLAVOR is one of: alpine bullseye
.PHONY: $(addprefix build-docker-, $(DOCKER_ARCHS)) $(addprefix build-docker-, $(GO_FLAVORS))
$(addprefix build-docker-, $(DOCKER_ARCHS)): build-docker-%: build-docker-alpine-%
$(addprefix build-docker-, $(GO_FLAVORS)): build-docker-%: $(addprefix build-docker-%-, $(DOCKER_ARCHS))

LDFLAGS = -X main.Version=$(VERSION) \
					-X main.Branch=$(BRANCH) \
					-X main.Revision=$(REVISION) \
					-X main.BuildUser=$(BUILDUSER) \
					-X main.BuildDate=$(BUILDDATE)

build/$(BINNAME)-$(VERSION).windows-amd64/$(BINNAME).exe: $(SRCS)
	@GOOS=windows GOARCH=amd64 $(GO) build \
	 -ldflags "$(LDFLAGS)" \
	 -o $@ \
	 .

build/$(BINNAME)-$(VERSION).windows-amd64.zip: build/exporter_exporter-$(VERSION).windows-amd64/$(BINNAME).exe
	zip -j $@ $<

build/$(BINNAME)-$(VERSION).%-arm64/$(BINNAME): $(SRCS)
	GOOS=$* GOARCH=arm64 $(GO) build \
 	 -ldflags "$(LDFLAGS)" \
 	 -o $@ \
	 .

build/$(BINNAME)-$(VERSION).%-amd64/$(BINNAME): $(SRCS)
	GOOS=$* GOARCH=amd64 $(GO) build \
	 -ldflags  "$(LDFLAGS)" \
	 -o $@ \
	 .

build/$(BINNAME)-$(VERSION).%-arm64.tar.gz: build/$(BINNAME)-$(VERSION).%-arm64/$(BINNAME)
	cd build && \
		tar cfzv $(BINNAME)-$(VERSION).$*-arm64.tar.gz $(BINNAME)-$(VERSION).$*-arm64

build/$(BINNAME)-$(VERSION).%-amd64.tar.gz: build/$(BINNAME)-$(VERSION).%-amd64/$(BINNAME)
	cd build && \
		tar cfzv $(BINNAME)-$(VERSION).$*-amd64.tar.gz $(BINNAME)-$(VERSION).$*-amd64

# build-scratch/$(FLAVOR)-$(ARCH)/exporter_exporter
$(foreach FLAVOR, $(GO_FLAVORS), $(addprefix build-scratch/$(FLAVOR)-, $(addsuffix /$(BINNAME), $(DOCKER_ARCHS)))): build-scratch/%/$(BINNAME): build-docker-scratch-%
	mkdir -p $(dir $@)
	docker save scratch-$*/exporter_exporter:$(VERSION) | tar --wildcards -Ox '*.tar' | tar -Ox usr/bin/exporter_exporter > $@

# build-scratch-$(FLAVOR)-$(ARCH)
DOCKER_SCRATCH_DESTS:=$(foreach FLAVOR, $(GO_FLAVORS), $(addprefix build-scratch-$(FLAVOR)-, $(DOCKER_ARCHS)))
.PHONY: $(DOCKER_SCRATCH_DESTS)
$(DOCKER_SCRATCH_DESTS): build-scratch-%: build-scratch/%/$(BINNAME)

# build-scratch-$(FLAVOR)
.PHONY: $(addprefix build-scratch-, $(GO_FLAVORS))
$(addprefix build-scratch-, $(GO_FLAVORS)): build-scratch-%: $(addprefix build-scratch-%-, $(DOCKER_ARCHS))

package: $(PACKAGE_FILE)

package-release: $(PACKAGE_FILE)
	go run github.com/aktau/github-release upload \
	  -u $(GITHUB_ORG) \
	 	-r $(GITHUB_REPO) \
	 	--tag v$(VERSION) \
		--name $(PACKAGE_FILE) \
		--file $(PACKAGE_FILE)

release-windows: build/exporter_exporter-$(VERSION).windows-amd64.zip
	go run github.com/aktau/github-release upload \
		-u $(GITHUB_ORG) \
		-r $(GITHUB_REPO) \
		--tag v$(VERSION) \
		--name exporter_exporter-$(VERSION).windows-amd64.zip \
		-f ./build/exporter_exporter-$(VERSION).windows-amd64.zip

.PRECIOUS: \
	build/exporter_exporter-$(VERSION).darwin-amd64.tar.gz \
	build/exporter_exporter-$(VERSION).linux-arm64.tar.gz \
	build/exporter_exporter-$(VERSION).linux-amd64.tar.gz \
	build/exporter_exporter-$(VERSION).windows-amd64.zip


release-%: build/exporter_exporter-$(VERSION).%.tar.gz
	go run github.com/aktau/github-release upload \
		-u $(GITHUB_ORG) \
		-r $(GITHUB_REPO) \
		--tag v$(VERSION) \
		--name exporter_exporter-$(VERSION).$*.tar.gz \
		-f ./build/exporter_exporter-$(VERSION).$*.tar.gz

release:
	git tag v$(VERSION)
	git push origin v$(VERSION)
	go run github.com/aktau/github-release release \
		-u $(GITHUB_ORG) \
		-r $(GITHUB_REPO) \
		--tag v$(VERSION) \
		--name v$(VERSION)
	make release-darwin-amd64 release-linux-amd64 release-linux-arm64 release-windows package-release release-docker
