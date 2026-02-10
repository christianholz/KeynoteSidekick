.PHONY: test app

test:
	CLANG_MODULE_CACHE_PATH=/tmp/clang-module-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/swiftpm-module-cache swift test --disable-sandbox

app:
	./scripts/build_app.sh
