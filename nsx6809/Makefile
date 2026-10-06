# Thin wrapper - the real logic is in build.sh / run.sh / test/verify.sh
all:
	./build.sh
data:
	./get_mnist.sh
train: all
	./run.sh --train --no-build
run: all
	./run.sh --no-build
test: all
	test/verify.sh
clean:
	./build.sh clean
.PHONY: all data train run test clean
