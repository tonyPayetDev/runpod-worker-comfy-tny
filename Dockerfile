# Stage 1: Base image with common dependencies
FROM nvidia/cuda:11.8.0-cudnn8-runtime-ubuntu22.04 as base

# Prevents prompts from packages asking for user input during installation
ENV DEBIAN_FRONTEND=noninteractive
# Prefer binary wheels over source distributions for faster pip installations
ENV PIP_PREFER_BINARY=1
# Ensures output from python is printed immediately to the terminal without buffering
ENV PYTHONUNBUFFERED=1 
# Speed up some cmake builds
ENV CMAKE_BUILD_PARALLEL_LEVEL=8

# Install Python, git and other necessary tools
RUN apt-get update && apt-get install -y \
    python3.10 \
    python3-pip \
    git \
    wget \
    libgl1 \
    && ln -sf /usr/bin/python3.10 /usr/bin/python \
    && ln -sf /usr/bin/pip3 /usr/bin/pip \
    && apt-get autoremove -y && apt-get clean -y && rm -rf /var/lib/apt/lists/*

# Install comfy-cli
RUN pip install comfy-cli

# Install ComfyUI
RUN /usr/bin/yes | comfy --workspace /comfyui install --cuda-version 11.8 --nvidia --version 0.2.7

# Change working directory to ComfyUI
WORKDIR /comfyui

# Install runpod
RUN pip install runpod requests

# Support for the network volume
COPY src/extra_model_paths.yaml ./

# Add scripts
COPY src/start.sh src/restore_snapshot.sh src/rp_handler.py test_input.json ./
# RUN chmod 755 /start.sh /restore_snapshot.sh

# Optionally copy the snapshot file
COPY 2025-03-20_20-03-04_snapshot.json /

# Restore the snapshot to install custom nodes
#RUN /restore_snapshot.sh
RUN comfy --workspace /comfyui node restore-snapshot "2025-03-20_20-03-04_snapshot.json" --pip-non-url

# Install additional dependencies and tools
RUN apt-get update && apt-get install -y \
    software-properties-common build-essential \
    libglib2.0-0 zlib1g-dev libncurses5-dev libgdbm-dev libnss3-dev libssl-dev \
    libreadline-dev libffi-dev && \
    add-apt-repository -y ppa:git-core/ppa && apt update -y && \
    apt install -y python-is-python3 sudo nano aria2 curl git git-lfs unzip unrar ffmpeg && \
    aria2c --console-log-level=error -c -x 16 -s 16 -k 1M https://developer.download.nvidia.com/compute/cuda/12.6.2/local_installers/cuda_12.6.2_560.35.03_linux.run -d /content -o cuda_12.6.2_560.35.03_linux.run && \
    sh cuda_12.6.2_560.35.03_linux.run --silent --toolkit && \
    echo "/usr/local/cuda/lib64" >> /etc/ld.so.conf && ldconfig

# Install python dependencies
RUN pip install torch==2.5.1+cu124 torchvision==0.20.1+cu124 torchaudio==2.5.1+cu124 \
    torchtext==0.18.0 torchdata==0.8.0 --extra-index-url https://download.pytorch.org/whl/cu124 && \
    pip install xformers==0.0.28.post3 opencv-python imageio imageio-ffmpeg ffmpeg-python \
    torchsde diffusers accelerate peft timm scikit-image matplotlib numpy==1.25.0 einops transformers==4.28.1 \
    tokenizers==0.13.3 sentencepiece aiohttp==3.11.8 yarl==1.18.0 pyyaml Pillow scipy tqdm psutil kornia==0.7.1 \
    spandrel soundfile av comfyui-frontend-package==1.10.17

# Clone ComfyUI repo and download necessary models
RUN git clone https://github.com/comfyanonymous/ComfyUI /content/ComfyUI && \
    aria2c --console-log-level=error -c -x 16 -s 16 -k 1M https://huggingface.co/Lightricks/LTX-Video/resolve/main/ltx-video-2b-v0.9.5.safetensors -d /content/ComfyUI/models/checkpoints -o ltx-video-2b-v0.9.5.safetensors && \
    aria2c --console-log-level=error -c -x 16 -s 16 -k 1M https://huggingface.co/Comfy-Org/mochi_preview_repackaged/resolve/main/split_files/text_encoders/t5xxl_fp16.safetensors -d /content/ComfyUI/models/text_encoders -o t5xxl_fp16.safetensors

WORKDIR /content/ComfyUI
CMD ["/start.sh"]
