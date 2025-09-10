# CUDA 12.6 + Ubuntu 22.04
FROM nvidia/cuda:12.6.2-devel-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive TZ=UTC
# EULA envs to avoid interactive prompt at first isaacsim call
ENV ACCEPT_EULA=Y OMNI_KIT_ACCEPT_EULA=Y

# 0) Core tools
RUN apt-get update && apt-get install -y --no-install-recommends \
    wget curl git git-lfs ca-certificates \
    build-essential cmake pkg-config \
    # (optional but harmless GUI libs if you run with DISPLAY)
    libglib2.0-0 libxext6 libx11-6 libxcursor1 libxrender1 libxi6 libxrandr2 \
    libxcomposite1 libasound2 libatk1.0-0 libatk-bridge2.0-0 libcairo2 libnss3 \
    libfontconfig1 libsm6 libice6 libegl1 libopengl0 libxkbcommon0 libwayland-client0 \
 && rm -rf /var/lib/apt/lists/* && git lfs install

RUN apt-get update && apt-get install -y --no-install-recommends \
    libvulkan1 vulkan-tools \
    libgl1 libglu1-mesa libxt6 \
 && rm -rf /var/lib/apt/lists/*

# 1) Miniconda (so we can "conda create -n unitree_sim_env python=3.11")
ENV CONDA_DIR=/opt/conda
RUN curl -sSL https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -o /tmp/miniconda.sh \
 && bash /tmp/miniconda.sh -b -p $CONDA_DIR \
 && rm -f /tmp/miniconda.sh
ENV PATH=$CONDA_DIR/bin:$PATH

# 2) Create virtual environment
RUN conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main && \
    conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r && \
    conda update -y -n base -c defaults conda && \
    conda create -y -n unitree_sim_env python=3.11 && \
    conda install -y -n unitree_sim_env -c conda-forge libstdcxx-ng


# Make that env default for subsequent RUN steps
SHELL ["/bin/bash", "-lc"]
ENV PATH=/opt/conda/envs/unitree_sim_env/bin:$PATH

# 3) Install PyTorch (CUDA 12.6 wheels)
RUN pip install --upgrade pip \
 && pip install --no-cache-dir \
      torch==2.7.0 torchvision==0.22.0 torchaudio==2.7.0 \
      --index-url https://download.pytorch.org/whl/cu126

# 4) Install Isaac Sim 5.0.0 via pip
RUN pip install --no-cache-dir "isaacsim[all,extscache]==5.0.0" \
      --extra-index-url https://pypi.nvidia.com

# Non-interactive EULA acceptance (first isaacsim call typically asks)
# Using `-h` keeps it headless and quick; failure won’t break the build.
RUN isaacsim -h || true

WORKDIR /workspace

# 5) Install Isaac Lab (v2.2.0)
RUN git clone https://github.com/isaac-sim/IsaacLab.git \
 && cd IsaacLab \
 && git checkout v2.2.0 \
 && ./isaaclab.sh --install

# --- Build & install CycloneDDS from source (per Unitree dev instructions) ---
WORKDIR /opt
RUN git clone https://github.com/eclipse-cyclonedds/cyclonedds -b releases/0.10.x && \
    cd cyclonedds && mkdir -p build install && cd build && \
    cmake .. -DCMAKE_INSTALL_PREFIX=../install && \
    cmake --build . --target install

# Make CycloneDDS discoverable for subsequent builds
ENV CYCLONEDDS_HOME=/opt/cyclonedds/install
ENV CMAKE_PREFIX_PATH=/opt/cyclonedds/install
# (optional but helpful for find_package/pkg-config)
ENV PKG_CONFIG_PATH=/opt/cyclonedds/install/lib/pkgconfig:/opt/cyclonedds/install/lib64/pkgconfig:$PKG_CONFIG_PATH
WORKDIR /workspace

# 6) Install unitree_sdk2_python (editable)
RUN git clone https://github.com/unitreerobotics/unitree_sdk2_python \
 && cd unitree_sdk2_python \
 && pip install -e .

WORKDIR /workspace
ADD https://github.com/unitreerobotics/unitree_sim_isaaclab/archive/refs/heads/main.zip .
RUN apt-get update && apt-get install -y unzip && \
    unzip main.zip && \
    mv unitree_sim_isaaclab-main unitree_sim_isaaclab

# 8) Asset download (exact instructions)
WORKDIR /workspace/unitree_sim_isaaclab
RUN apt-get update && apt-get install -y --no-install-recommends git-lfs unzip && \
    git lfs install && \
    . ./fetch_assets.sh

# 9) Install “other dependencies”  (requirements.txt)
RUN if [ -f requirements.txt ]; then \
      pip install --no-cache-dir -r requirements.txt; \
    fi

RUN apt-get update && apt-get install -y --no-install-recommends \
    libvulkan1 vulkan-tools libgl1 libglu1-mesa libxt6 gcc-12 libgcc-12-dev libstdc++-12-dev && \
    echo "export LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libgcc_s.so.1" >> ~/.bashrc

# Final shell
ENTRYPOINT ["/bin/bash"]
