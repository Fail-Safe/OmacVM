# Kernel sources for the driver patch test

The four files of `drivers/gpu/drm/virtio` that OmacVM's guest driver patches
change (`src/app/guest/virtio-gpu/linux-virtio-gpu-*.patch`), as kernel.org's
stable tree has them at the tags named by the folders: v7.2.11 (the app VMs'
kernel in October 2026) and v7.3 (the next one). `src/tests/virtio-gpu-patches.sh`
applies the patches to them in the builder's order, without fuzz, so CI sees a
patch that no longer fits before a VM does.

From https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git
(`drivers/gpu/drm/virtio/<file>?h=v<version>`), unchanged. Their licence is
the one at the top of each file (MIT-style, Red Hat and others). Add a folder
for a new kernel the same way.
