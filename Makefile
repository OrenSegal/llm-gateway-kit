# Local machines with `swiftly` installed can have its toolchain (e.g. 6.3.2)
# shadow Xcode's bundled toolchain (e.g. 6.3.3) earlier in $PATH, producing a
# linker flag mismatch (`ld: unknown option: -no_warn_duplicate_libraries`) at
# the final link step. `xcrun swift` forces Xcode's own consistent
# toolchain+linker pairing regardless of $PATH order.

.PHONY: build test run

build:
	xcrun swift build

test:
	xcrun swift test

run:
	xcrun swift run LLMGatewayKitDemo
