all: build make-target
build: build-crystal build-apk

build-crystal:
	#!/bin/sh
	cd crystal
	shards build

build-apk:
	#!/bin/sh
	cd apksrc
	muon setup \
		-Dhelp=enabled \
		-Ddocs=disabled \
		-Dzstd=enabled \
		-Dlua_version=5.5 \
		build

	muon meson compile -C build

make-target:
	#!/bin/sh
	install -Dm755 apksrc/build/src/apk target/bin/apk
	install -Dm755 crystal/bin/labuild-core target/bin/labuild-core
	install -Dm755 lua/labuild-sh.sh target/share/labuild/labuild-sh.sh
	install -Dm644 lua/labuild.lua target/share/labuild/labuild.lua
	install -Dm755 launcher/labuild target/bin/labuild

clean:
	rm -rf target crystal/bin apksrc/build
