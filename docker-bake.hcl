variable "TAG" {
  default = "slim"
}

# === Version Pins (single source of truth) ===
variable "COMFYUI_VERSION" {
  default = "v0.27.0"
}
variable "MANAGER_SHA" {
  default = "8e06ee6552a7"
}
variable "KJNODES_SHA" {
  default = "e27a505b3ba6"
}
variable "CIVICOMFY_SHA" {
  default = "555e984bbcb0"
}
variable "RUNPODDIRECT_SHA" {
  default = "809065c9d2f3"
}
variable "INT8FAST_SHA" {
  default = "48a88b2fde88"
}
variable "CONTROLALTAI_SHA" {
  default = "721492b66c9c"
}
variable "CRTNODES_SHA" {
  default = "c0798d356bc3"
}
variable "LOGIN_SHA" {
  default = "3f09fcbd5e18"
}
# Regular image (cu128)
variable "TORCH_VERSION" {
  default = "2.10.0+cu128"
}
variable "TORCHVISION_VERSION" {
  default = "0.25.0+cu128"
}
variable "TORCHAUDIO_VERSION" {
  default = "2.10.0+cu128"
}
# 5090 image (cu130) — can diverge from regular when needed
variable "TORCH_VERSION_5090" {
  default = "2.10.0+cu130"
}
variable "TORCHVISION_VERSION_5090" {
  default = "0.25.0+cu130"
}
variable "TORCHAUDIO_VERSION_5090" {
  default = "2.10.0+cu130"
}
variable "FILEBROWSER_VERSION" {
  default = "v2.59.0"
}
variable "FILEBROWSER_SHA256" {
  default = "8cd8c3baecb086028111b912f252a6e3169737fa764b5c510139e81f9da87799"
}

group "default" {
  targets = ["common", "dev"]
}

# Common settings for all targets (defaults to regular CUDA 12.8 / cu128)
target "common" {
  context    = "."
  dockerfile = "Dockerfile"
  platforms  = ["linux/amd64"]
  args = {
    COMFYUI_VERSION     = COMFYUI_VERSION
    MANAGER_SHA         = MANAGER_SHA
    KJNODES_SHA         = KJNODES_SHA
    CIVICOMFY_SHA       = CIVICOMFY_SHA
    RUNPODDIRECT_SHA    = RUNPODDIRECT_SHA
    INT8FAST_SHA        = INT8FAST_SHA
    CONTROLALTAI_SHA    = CONTROLALTAI_SHA
    CRTNODES_SHA        = CRTNODES_SHA
    LOGIN_SHA           = LOGIN_SHA
    TORCH_VERSION       = TORCH_VERSION
    TORCHVISION_VERSION = TORCHVISION_VERSION
    TORCHAUDIO_VERSION  = TORCHAUDIO_VERSION
    FILEBROWSER_VERSION = FILEBROWSER_VERSION
    FILEBROWSER_SHA256  = FILEBROWSER_SHA256
    CUDA_VERSION_DASH   = "12-8"
    TORCH_INDEX_SUFFIX  = "cu128"
  }
}

# Regular ComfyUI image (CUDA 12.8 — default)
target "regular" {
  inherits = ["common"]
  tags = [
    "runpod/comfyui:${TAG}-cuda12.8",
    "runpod/comfyui:cuda12.8",
    "runpod/comfyui:latest",
  ]
}

# Dev image for local testing
target "dev" {
  inherits = ["common"]
  tags = [
    "runpod/comfyui:dev",
    "ghcr.io/panchosep/comfyui-redcraft:dev",
  ]
  output = ["type=docker"]
}

# Dev push targets (for CI pushing dev tags, without overriding latest)
target "devpush" {
  inherits = ["common"]
  tags = ["runpod/comfyui:dev-cuda12.8"]
}

target "devpush-cuda13" {
  inherits = ["common"]
  tags = ["runpod/comfyui:dev-cuda13.0"]
  args = {
    TORCH_VERSION       = TORCH_VERSION_5090
    TORCHVISION_VERSION = TORCHVISION_VERSION_5090
    TORCHAUDIO_VERSION  = TORCHAUDIO_VERSION_5090
    CUDA_VERSION_DASH   = "13-0"
    TORCH_INDEX_SUFFIX  = "cu130"
  }
}

# CUDA 13.0 image (Blackwell / RTX 5090+)
target "cuda13" {
  inherits = ["common"]
  tags = [
    "runpod/comfyui:${TAG}-cuda13.0",
    "runpod/comfyui:cuda13.0",
  ]
  args = {
    TORCH_VERSION       = TORCH_VERSION_5090
    TORCHVISION_VERSION = TORCHVISION_VERSION_5090
    TORCHAUDIO_VERSION  = TORCHAUDIO_VERSION_5090
    CUDA_VERSION_DASH   = "13-0"
    TORCH_INDEX_SUFFIX  = "cu130"
  }
}
