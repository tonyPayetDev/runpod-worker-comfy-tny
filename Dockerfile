# Stage 1: Base image with common dependencies 
FROM nvidia/cuda:11.8.0-cudnn8-runtime-ubuntu22.04 as base

# Empêcher les invites interactives des paquets
ENV DEBIAN_FRONTEND=noninteractive
ENV PIP_PREFER_BINARY=1
ENV PYTHONUNBUFFERED=1 
ENV CMAKE_BUILD_PARALLEL_LEVEL=8

# Installer Python, git et autres outils nécessaires
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3.10 \
    python3-pip \
    git \
    wget \
    libgl1 \
    && ln -sf /usr/bin/python3.10 /usr/bin/python \
    && ln -sf /usr/bin/pip3 /usr/bin/pip \
    && apt-get autoremove -y && apt-get clean -y && rm -rf /var/lib/apt/lists/*

# Installer comfy-cli
RUN pip install comfy-cli

# Installer ComfyUI
RUN /usr/bin/yes | comfy --workspace /comfyui install --cuda-version 11.8 --nvidia --version 0.2.7

# Cloner LTX repository pour les custom nodes
RUN git clone https://github.com/Lightricks/ComfyUI-LTXVideo.git /comfyui/custom_nodes/ComfyUI-LTXVideo

# Installer les dépendances pour LTX
WORKDIR /comfyui/custom_nodes/ComfyUI-LTXVideo
RUN pip install -r requirements.txt

# Créer les répertoires nécessaires
RUN mkdir -p /comfyui/models/checkpoints

# Télécharger le modèle LTX
RUN wget --progress=bar:force -O /comfyui/models/checkpoints/ltx-video-2b-v0.9.1.safetensors \
    https://huggingface.co/Lightricks/LTX-Video/resolve/main/ltx-video-2b-v0.9.1.safetensors

# Télécharger le modèle google_t5-v1_1-xxl_encoderonly
RUN wget --progress=bar:force -O /comfyui/models/checkpoints/t5xxl_fp8_e4m3fn.safetensors \
    https://huggingface.co/mcmonkey/google_t5-v1_1-xxl_encoderonly/resolve/main/t5xxl_fp8_e4m3fn.safetensors

# Changer le répertoire de travail vers ComfyUI
WORKDIR /comfyui

# Installer runpod et requests
RUN pip install runpod requests

# Ajouter la configuration supplémentaire
COPY src/extra_model_paths.yaml ./ 

# Retour à la racine
WORKDIR /

# Ajouter les scripts
COPY src/start.sh src/restore_snapshot.sh src/rp_handler.py test_input.json ./ 
RUN chmod +x /start.sh /restore_snapshot.sh

# Copier éventuellement le fichier snapshot
#COPY *snapshot*.json / || true

# Restaurer le snapshot pour installer les custom nodes
RUN /restore_snapshot.sh

# Mettre à jour toutes les dépendances et récupérer les dernières modifications
RUN python main.py --update-all && git pull

# Démarrer le conteneur
CMD ["/start.sh"]

# Stage 2: Téléchargement des modèles
FROM base as downloader

ARG HUGGINGFACE_ACCESS_TOKEN
ARG MODEL_TYPE

# Changer de répertoire
WORKDIR /comfyui

# Créer les dossiers nécessaires
RUN mkdir -p models/checkpoints models/vae models/unet models/clip

# Télécharger les modèles en fonction du type
RUN if [ "$MODEL_TYPE" = "sdxl" ]; then \
      wget --progress=bar:force -O models/checkpoints/sd_xl_base_1.0.safetensors \
        https://huggingface.co/stabilityai/stable-diffusion-xl-base-1.0/resolve/main/sd_xl_base_1.0.safetensors && \
      wget --progress=bar:force -O models/vae/sdxl_vae.safetensors \
        https://huggingface.co/stabilityai/sdxl-vae/resolve/main/sdxl_vae.safetensors && \
      wget --progress=bar:force -O models/vae/sdxl-vae-fp16-fix.safetensors \
        https://huggingface.co/madebyollin/sdxl-vae-fp16-fix/resolve/main/sdxl_vae.safetensors; \
    elif [ "$MODEL_TYPE" = "sd3" ]; then \
      wget --header="Authorization: Bearer ${HUGGINGFACE_ACCESS_TOKEN}" --progress=bar:force \
        -O models/checkpoints/sd3_medium_incl_clips_t5xxlfp8.safetensors \
        https://huggingface.co/stabilityai/stable-diffusion-3-medium/resolve/main/sd3_medium_incl_clips_t5xxlfp8.safetensors; \
    elif [ "$MODEL_TYPE" = "flux1-schnell" ]; then \
      wget --progress=bar:force -O models/unet/flux1-schnell.safetensors \
        https://huggingface.co/black-forest-labs/FLUX.1-schnell/resolve/main/flux1-schnell.safetensors && \
      wget --progress=bar:force -O models/clip/clip_l.safetensors \
        https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/clip_l.safetensors && \
      wget --progress=bar:force -O models/clip/t5xxl_fp8_e4m3fn.safetensors \
        https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/t5xxl_fp8_e4m3fn.safetensors && \
      wget --progress=bar:force -O models/vae/ae.safetensors \
        https://huggingface.co/black-forest-labs/FLUX.1-schnell/resolve/main/ae.safetensors; \
    elif [ "$MODEL_TYPE" = "flux1-dev" ]; then \
      wget --header="Authorization: Bearer ${HUGGINGFACE_ACCESS_TOKEN}" --progress=bar:force \
        -O models/unet/flux1-dev.safetensors \
        https://huggingface.co/black-forest-labs/FLUX.1-dev/resolve/main/flux1-dev.safetensors && \
      wget --progress=bar:force -O models/clip/clip_l.safetensors \
        https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/clip_l.safetensors && \
      wget --progress=bar:force -O models/clip/t5xxl_fp8_e4m3fn.safetensors \
        https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/t5xxl_fp8_e4m3fn.safetensors && \
      wget --header="Authorization: Bearer ${HUGGINGFACE_ACCESS_TOKEN}" --progress=bar:force \
        -O models/vae/ae.safetensors \
        https://huggingface.co/black-forest-labs/FLUX.1-dev/resolve/main/ae.safetensors; \
    fi

# Stage 3: Image finale
FROM base as final

# Copier les modèles téléchargés dans l'image finale
COPY --from=downloader /comfyui/models /comfyui/models

# Démarrer le conteneur
CMD ["/start.sh"]
