# Convenience targets; build.sh does the real work.
.PHONY: all list clean distclean deps check

all:
	./build.sh

# Show which versions would be built, without building.
list:
	./build.sh --list

# Verify host prerequisites are present.
check:
	@command -v podman >/dev/null || command -v docker >/dev/null || { echo "need podman or docker"; exit 1; }
	@for c in curl tar gpg python3 dpkg; do command -v $$c >/dev/null || { echo "missing $$c"; exit 1; }; done
	@echo "host prerequisites OK"

# Remove scratch build space, keep packages.
clean:
	rm -rf build

# Remove everything generated.
distclean: clean
	rm -rf dist
