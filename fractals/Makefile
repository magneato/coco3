# Thin wrapper - the real logic is in build.sh / run.sh / test/verify.sh
all:
	./build.sh
run: all
	./run.sh --no-build
test: all
	test/verify.sh
clean:
	./build.sh clean
.PHONY: all run test clean
