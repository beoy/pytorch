#!/bin/bash

COMPACT_JOB_NAME="${BUILD_ENVIRONMENT}-build"
export PATH="/usr/local/bin:$PATH"
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Set up conda environment
export PYTORCH_ENV_DIR="${HOME}/pytorch-ci-env"
# If a local installation of conda doesn't exist, we download and install conda
if [ ! -d "${PYTORCH_ENV_DIR}/miniconda3" ]; then
  mkdir -p ${PYTORCH_ENV_DIR}
  curl https://repo.continuum.io/miniconda/Miniconda3-latest-MacOSX-x86_64.sh -o ${PYTORCH_ENV_DIR}/miniconda3.sh
  bash ${PYTORCH_ENV_DIR}/miniconda3.sh -b -p ${PYTORCH_ENV_DIR}/miniconda3
fi
export PATH="${PYTORCH_ENV_DIR}/miniconda3/bin:$PATH"
source ${PYTORCH_ENV_DIR}/miniconda3/bin/activate
conda install -y mkl mkl-include numpy pyyaml setuptools cmake cffi ninja
rm -rf ${PYTORCH_ENV_DIR}/miniconda3/lib/python3.6/site-packages/torch*

git submodule update --init --recursive
export CMAKE_PREFIX_PATH=${PYTORCH_ENV_DIR}/miniconda3/

# Build PyTorch
if [[ "${JOB_BASE_NAME}" == *cuda9.2* ]]; then
  export CUDA_VERSION=9.2
  export TORCH_CUDA_ARCH_LIST=5.2
  export PATH=/Developer/NVIDIA/CUDA-${CUDA_VERSION}/bin${PATH:+:${PATH}}
  export DYLD_LIBRARY_PATH=/Developer/NVIDIA/CUDA-${CUDA_VERSION}/lib${DYLD_LIBRARY_PATH:+:${DYLD_LIBRARY_PATH}}
  export CUDA_HOME=/Developer/NVIDIA/CUDA-${CUDA_VERSION}
  export NO_CUDA=0

  # Eigen gives "explicit specialization of class must precede its first use" error
  # when compiling with Xcode 9.1 toolchain, so we have to use Xcode 8.2 toolchain instead.
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
else
  export DEVELOPER_DIR=/Applications/Xcode9.app/Contents/Developer
fi

export MACOSX_DEPLOYMENT_TARGET=10.9
export CXX=clang++
export CC=clang
if which sccache > /dev/null; then
  printf "#!/bin/sh\nexec sccache $(which clang++) \$*" > "${PYTORCH_ENV_DIR}/clang++"
  chmod a+x "${PYTORCH_ENV_DIR}/clang++"

  printf "#!/bin/sh\nexec sccache $(which clang) \$*" > "${PYTORCH_ENV_DIR}/clang"
  chmod a+x "${PYTORCH_ENV_DIR}/clang"

  if [[ "${JOB_BASE_NAME}" == *cuda* ]]; then
    printf "#!/bin/sh\nexec sccache $(which nvcc) \$*" > "${PYTORCH_ENV_DIR}/nvcc"
    chmod a+x "${PYTORCH_ENV_DIR}/nvcc"
    export CUDA_NVCC_EXECUTABLE="${PYTORCH_ENV_DIR}/nvcc"
  fi

  export PATH="${PYTORCH_ENV_DIR}:$PATH"
fi
# If we run too many parallel jobs, we will OOM
export MAX_JOBS=2

export IMAGE_COMMIT_TAG=${BUILD_ENVIRONMENT}-${IMAGE_COMMIT_ID}

python setup.py install

# this is a bit hacky, but not too bad. Bundle the test binaries into
# the installation directory, so they can catch a free ride on the 7z
# train.
mkdir -p ${PYTORCH_ENV_DIR}/miniconda3/lib/python3.6/site-packages/torch/test_binaries/build
mv build/{bin,lib} ${PYTORCH_ENV_DIR}/miniconda3/lib/python3.6/site-packages/torch/test_binaries/build/

# Upload torch binaries when the build job is finished
7z a ${IMAGE_COMMIT_TAG}.7z ${PYTORCH_ENV_DIR}/miniconda3/lib/python3.6/site-packages/torch*
aws s3 cp ${IMAGE_COMMIT_TAG}.7z s3://ossci-macos-build/pytorch/${IMAGE_COMMIT_TAG}.7z --acl public-read
