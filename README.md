# Kubernetes Connector — Standalone Installer (DEPRECATED)

> **⚠️ This tool is deprecated and no longer maintained.**

## Deprecation Notice

The standalone installer tool previously provided in this branch is **no longer needed**.

Starting with **Konnector V2**, standalone installation (including GitOps support and private registry mirroring) is **supported natively** as part of the default Kubernetes Connector experience. There is no longer a need for a separate standalone installer tool.

## I downloaded the V2 standalone installer from the Cortex portal — how do I mirror images?

If you obtained the V2 standalone installer directly from the Cortex portal and need to mirror container images to your private registry, please use the **`kcli`** tool instead:

➡️ **https://github.com/PaloAltoNetworks/cortex-cloud/tree/main/tools/kcli**

`kcli` is the supported tooling for mirroring Cortex Kubernetes Connector images and related private-registry workflows going forward.

## Questions / Support

For any questions, please contact Palo Alto Networks Cortex support or refer to the official Cortex Cloud documentation.
