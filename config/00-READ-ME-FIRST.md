# Read this first

You can read `/workspace`, except credential-bearing and private metadata paths intentionally hidden by the sandbox. You may write only inside `/workspace/rogue-workdir` and your private `/state`; everything else is read-only. Do not probe hidden paths or try to bypass failed writes.

You can reach only the local model service. Internet, LAN, host namespaces, Docker, host credentials, and operator activity logs are unavailable. The wrapper supervises lifecycle and stops both containers when the operator exits. Preserve useful facts and decisions in durable memory or concise notes here; never copy secrets.
