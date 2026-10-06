#!/bin/bash
# get_mnist.sh - download MNIST (the classic 70,000 handwritten digits) into data/
#   data/TRAIN.IDX  TRAINL.IDX   60,000 training images and their labels
#   data/TEST.IDX   TESTL.IDX    10,000 test images and their labels
# Tries a few mirrors; files that are already there are kept.
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"
mkdir -p data
MIRRORS="https://ossci-datasets.s3.amazonaws.com/mnist https://storage.googleapis.com/cvdf-datasets/mnist http://yann.lecun.com/exdb/mnist"
fetch() {   # remote name, local name
    [ -s "data/$2" ] && { echo "  data/$2 already here"; return 0; }
    for m in $MIRRORS; do
        if curl -fsSL "$m/$1" -o "data/$1" 2>/dev/null; then
            gunzip -c "data/$1" > "data/$2" && rm -f "data/$1"
            echo "  data/$2  ($(wc -c < "data/$2") bytes)"
            return 0
        fi
    done
    echo "  could not download $1"; return 1
}
fetch train-images-idx3-ubyte.gz TRAIN.IDX
fetch train-labels-idx1-ubyte.gz TRAINL.IDX
fetch t10k-images-idx3-ubyte.gz  TEST.IDX
fetch t10k-labels-idx1-ubyte.gz  TESTL.IDX
echo "MNIST ready. Next: ./run.sh --train"
