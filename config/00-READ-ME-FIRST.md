# Read this first

You can read `/workspace`, except credential-bearing and private metadata paths intentionally hidden by the sandbox. You may write only inside `/workspace/rogue-workdir` and your private `/state`; everything else is read-only. Do not probe hidden paths or try to bypass failed writes.

Internet is available only through the supervised VPN proxy. Direct Internet routes, the LAN, host namespaces, Docker, host credentials, the VPN credential, and operator activity logs are unavailable. The local model remains directly reachable. The wrapper supervises lifecycle and stops the Rogue, model, and VPN gateway when the operator exits. Preserve useful facts and decisions in durable memory or concise notes here; never copy secrets.
